'use strict';

const { withTransaction, query } = require('../../config/db');
const { redis } = require('../../config/redis');
const walletService = require('../wallet/wallet.service');
const agora = require('../../integrations/agora');
const logger = require('../../utils/logger');
const {
  REDIS,
  CALL_STATUS,
  CALL_END_REASON,
  LEDGER_REASON,
  EARNING_REASON,
  LOW_BALANCE_WARNING_MINUTES,
  TICK_INTERVAL_SECONDS,
  coinsPerMinute,
  listenerSharePerMinute,
  FREE_TRIAL_SECONDS,
} = require('../../utils/constants');

/**
 * The billing engine.
 *
 * Design (Project Summary §5), and the reasoning behind each guard:
 *
 *  - Redis holds live per-call state so a tick does not need to read Postgres
 *    just to know what minute it is on.
 *  - A per-call Redis lock (SET NX PX) serialises ticks, so a retried or
 *    duplicated job cannot bill twice.
 *  - The debit uses `WHERE coin_balance >= $1`, so even if two ticks somehow
 *    ran concurrently the second cannot overdraw.
 *  - `call_ticks (call_id, minute_index)` is UNIQUE, so a duplicate minute is
 *    rejected by Postgres even if Redis is wiped and every lock is lost. The
 *    lock is an optimisation; this constraint is the actual correctness
 *    guarantee.
 *  - Billing is full-minute: the started minute is billed in full.
 *
 * Ordering matters in `settleTick`: the debit happens before the tick row is
 * inserted, but both are in one transaction, so an insufficient balance aborts
 * the whole thing and no partial state survives.
 */

/** Acquire the per-call tick lock. Returns a token to release with, or null. */
async function acquireTickLock(callId) {
  const token = `${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const ok = await redis.set(REDIS.callLockKey(callId), token, 'PX', REDIS.lockTtlMs, 'NX');
  return ok ? token : null;
}

async function releaseTickLock(callId, token) {
  try {
    await redis.releaseLock(REDIS.callLockKey(callId), token);
  } catch (err) {
    // The lock expires on its own; a failed release costs at most one skipped
    // tick, never a double bill.
    logger.warn({ err, callId }, 'failed to release tick lock');
  }
}

/** Writes the live call state Redis holds for the duration of the call. */
async function initCallState(call, callerBalance) {
  const now = Date.now();
  await redis.hset(REDIS.callStateKey(call.id), {
    call_id: String(call.id),
    caller_id: String(call.caller_id),
    listener_id: String(call.listener_id),
    type: call.type,
    start_ts: String(now),
    last_tick_ts: String(now),
    minute_index: '0',
    caller_balance_snapshot: String(callerBalance),
    agora_channel: call.agora_channel,
    free_seconds: String(call.free_seconds_granted || 0),
  });
  await redis.expire(REDIS.callStateKey(call.id), REDIS.callStateTtlSeconds);
}

async function getCallState(callId) {
  const state = await redis.hgetall(REDIS.callStateKey(callId));
  return state && Object.keys(state).length > 0 ? state : null;
}

async function clearCallState(callId) {
  await redis.del(REDIS.callStateKey(callId));
}

/**
 * Pre-flight check. A call may not connect unless the caller can fund a full
 * minute at the relevant rate — this is what stops a call starting only to be
 * force-ended seconds later.
 *
 * A caller who still has their new-user bonus passes regardless, since the
 * first 60 seconds cost nothing.
 */
async function preflight({ callerId, callType }) {
  const { rows } = await query(
    `SELECT u.free_trial_used, COALESCE(w.coin_balance, 0) AS coin_balance
       FROM users u LEFT JOIN wallets w ON w.user_id = u.id
      WHERE u.id = $1`,
    [callerId],
  );

  const row = rows[0];
  if (!row) return { ok: false, reason: 'user_not_found' };

  const required = coinsPerMinute(callType);
  const freeTrialAvailable = !row.free_trial_used;

  if (freeTrialAvailable) {
    return {
      ok: true,
      balance: row.coin_balance,
      required,
      freeSeconds: FREE_TRIAL_SECONDS,
    };
  }

  if (row.coin_balance < required) {
    return { ok: false, reason: 'insufficient_balance', balance: row.coin_balance, required };
  }

  return { ok: true, balance: row.coin_balance, required, freeSeconds: 0 };
}

/**
 * Bills one minute of a call.
 *
 * Returns a result object describing what happened rather than throwing on the
 * expected "ran out of coins" path — that outcome is normal operation, not an
 * error, and the caller (the tick worker) needs to act on it by ending the call.
 */
async function settleTick({ callId, minuteIndex }) {
  const lockToken = await acquireTickLock(callId);
  if (!lockToken) {
    // Another worker holds this call's tick. Skipping is correct: the holder
    // is doing exactly the work we would have done.
    logger.debug({ callId }, 'tick skipped, lock held');
    return { status: 'locked' };
  }

  try {
    const call = await loadLiveCall(callId);
    if (!call) return { status: 'not_active' };

    const rate = coinsPerMinute(call.type);
    const listenerShare = listenerSharePerMinute(call.type);
    const platformShare = rate - listenerShare;

    try {
      const result = await withTransaction(async (client) => {
        // Re-check status inside the transaction and lock the row, so a
        // concurrent /calls/:id/end cannot settle a call we are billing.
        const { rows: liveRows } = await client.query(
          `SELECT id, status, billed_minutes FROM calls WHERE id = $1 FOR UPDATE`,
          [callId],
        );
        if (!liveRows[0] || liveRows[0].status !== CALL_STATUS.ACTIVE) {
          return { status: 'not_active' };
        }

        const balanceAfter = await walletService.debit(client, {
          userId: call.caller_id,
          amount: rate,
          reason: LEDGER_REASON.CALL_DEBIT,
          refId: String(callId),
        });

        // Rejected by the UNIQUE constraint if this minute was already billed.
        await client.query(
          `INSERT INTO call_ticks (call_id, minute_index, coins_debited, listener_share, platform_share)
           VALUES ($1, $2, $3, $4, $5)`,
          [callId, minuteIndex, rate, listenerShare, platformShare],
        );

        await walletService.creditListener(client, {
          listenerId: call.listener_id,
          amount: listenerShare,
          reason: EARNING_REASON.CALL_CREDIT,
          refId: String(callId),
        });

        await client.query(
          `UPDATE calls
              SET billed_minutes = billed_minutes + 1,
                  coins_spent = coins_spent + $2,
                  listener_earned = listener_earned + $3
            WHERE id = $1`,
          [callId, rate, listenerShare],
        );

        return { status: 'billed', balanceAfter, rate, listenerShare, platformShare };
      });

      if (result.status !== 'billed') return result;

      await redis.hset(REDIS.callStateKey(callId), {
        last_tick_ts: String(Date.now()),
        minute_index: String(minuteIndex),
        caller_balance_snapshot: String(result.balanceAfter),
      });

      const minutesRemaining = Math.floor(result.balanceAfter / rate);
      logger.info(
        { callId, minuteIndex, charged: result.rate, balanceAfter: result.balanceAfter },
        'tick billed',
      );

      return {
        ...result,
        minuteIndex,
        minutesRemaining,
        lowBalance: minutesRemaining <= LOW_BALANCE_WARNING_MINUTES,
      };
    } catch (err) {
      if (err.code === 'insufficient_balance' || err.code === '23514') {
        logger.info({ callId, minuteIndex }, 'tick failed: insufficient balance');
        return { status: 'insufficient_balance' };
      }
      if (err.code === '23505') {
        // This minute was already billed — a retry of a job that succeeded.
        logger.warn({ callId, minuteIndex }, 'duplicate tick rejected by constraint');
        return { status: 'duplicate' };
      }
      throw err;
    }
  } finally {
    await releaseTickLock(callId, lockToken);
  }
}

/** Loads a call only if it is currently active. */
async function loadLiveCall(callId) {
  const { rows } = await query(
    `SELECT id, caller_id, listener_id, type, status, agora_channel, billed_minutes, started_at
       FROM calls WHERE id = $1 AND status = $2`,
    [callId, CALL_STATUS.ACTIVE],
  );
  return rows[0] || null;
}

/**
 * Ends a call and performs final settlement.
 *
 * Idempotent: ending an already-ended call returns its existing summary rather
 * than settling twice. Both the client hang-up path and the disconnect webhook
 * land here, and they can race, so this must be safe to call more than once.
 */
async function endCall({ callId, reason, actorId = null }) {
  const summary = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT id, caller_id, listener_id, type, status, agora_channel,
              billed_minutes, coins_spent, listener_earned, started_at, ended_at, end_reason
         FROM calls WHERE id = $1 FOR UPDATE`,
      [callId],
    );

    const call = rows[0];
    if (!call) return null;

    if (call.status === CALL_STATUS.ENDED || call.status === CALL_STATUS.FAILED) {
      return { ...call, alreadyEnded: true };
    }

    const endedStatus =
      call.status === CALL_STATUS.RINGING ? CALL_STATUS.FAILED : CALL_STATUS.ENDED;

    const { rows: updated } = await client.query(
      `UPDATE calls
          SET status = $2, ended_at = now(), end_reason = $3
        WHERE id = $1
        RETURNING id, caller_id, listener_id, type, status, agora_channel, billed_minutes,
                  coins_spent, listener_earned, started_at, ended_at, end_reason`,
      [callId, endedStatus, reason],
    );

    // Free the listener for the next caller in the same transaction, so a
    // crash cannot leave them permanently marked busy.
    await client.query(
      `UPDATE listener_profiles SET is_busy = FALSE, updated_at = now() WHERE user_id = $1`,
      [call.listener_id],
    );

    if (endedStatus === CALL_STATUS.ENDED) {
      await client.query(
        `UPDATE listener_profiles SET total_calls = total_calls + 1 WHERE user_id = $1`,
        [call.listener_id],
      );
    }

    return { ...updated[0], alreadyEnded: false, actorId };
  });

  if (!summary) return null;

  if (!summary.alreadyEnded) {
    await clearCallState(callId);
    // Kick the media channel so a client that ignores the socket event still
    // stops talking — this is what stops a forced end from being advisory.
    await agora.terminateChannel(summary.agora_channel, reason);
    logger.info(
      { callId, reason, minutes: summary.billed_minutes, coins: summary.coins_spent },
      'call ended',
    );
  }

  return summary;
}

/**
 * Sweeps calls that are still marked live but have stopped ticking.
 *
 * This is the backstop for the disconnect case in §5: if a client dies and no
 * webhook arrives, the call would otherwise sit 'active' forever. Because the
 * caller is only ever billed by a tick, a stuck call costs nothing while it
 * sits here — but it does keep a listener marked busy, so it must be cleaned up.
 */
async function sweepStaleCalls({ staleAfterSeconds = TICK_INTERVAL_SECONDS * 3 } = {}) {
  const { rows } = await query(
    `SELECT id, status, started_at, created_at FROM calls
      WHERE status IN ($1, $2)
        AND COALESCE(started_at, created_at) < now() - ($3 || ' seconds')::interval`,
    [CALL_STATUS.ACTIVE, CALL_STATUS.RINGING, String(staleAfterSeconds)],
  );

  const swept = [];
  for (const call of rows) {
    const state = await getCallState(call.id);
    const lastTick = state ? Number(state.last_tick_ts) : 0;
    const silentFor = Date.now() - lastTick;

    // A call with fresh Redis state is genuinely live; leave it alone.
    if (state && silentFor < staleAfterSeconds * 1000) continue;

    const reason =
      call.status === CALL_STATUS.RINGING ? CALL_END_REASON.TIMEOUT : CALL_END_REASON.DISCONNECT;
    await endCall({ callId: call.id, reason });
    swept.push({ callId: call.id, reason });
  }

  if (swept.length > 0) logger.warn({ swept }, 'swept stale calls');
  return swept;
}

module.exports = {
  preflight,
  initCallState,
  getCallState,
  clearCallState,
  settleTick,
  endCall,
  sweepStaleCalls,
  acquireTickLock,
  releaseTickLock,
  loadLiveCall,
};

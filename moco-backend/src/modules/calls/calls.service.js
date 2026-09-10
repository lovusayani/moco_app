'use strict';

const { withTransaction, query } = require('../../config/db');
const billing = require('./billing.engine');
const agora = require('../../integrations/agora');
const callEvents = require('../../realtime/call.events');
const presence = require('../../realtime/presence');
const walletService = require('../wallet/wallet.service');
const { scheduleTick } = require('../../workers/queues');
const { notificationQueue } = require('../../workers/queues');
const logger = require('../../utils/logger');
const {
  CALL_STATUS,
  CALL_END_REASON,
  KYC_STATUS,
  TICK_INTERVAL_SECONDS,
  FREE_TRIAL_SECONDS,
  coinsPerMinute,
  listenerSharePerMinute,
} = require('../../utils/constants');
const { badRequest, notFound, conflict, insufficientBalance, forbidden } =
  require('../../utils/errors');

/**
 * Call lifecycle. The billing engine owns the money; this owns who may call
 * whom, and when the meter starts.
 */

/**
 * Initiates a call.
 *
 * Ordering is deliberate: the listener is claimed (marked busy) in the same
 * transaction that creates the call row, using a conditional UPDATE. Two
 * callers racing for the same listener therefore cannot both succeed — the
 * second finds `is_busy` already true and is told the listener is unavailable.
 */
async function initiate({ caller, listenerId, callType }) {
  if (Number(listenerId) === Number(caller.id)) {
    throw badRequest('self_call', 'You cannot call yourself');
  }

  const blocked = await query(
    `SELECT 1 FROM blocks
      WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)`,
    [caller.id, listenerId],
  );
  if (blocked.rows.length > 0) throw forbidden('This user is not available');

  const preflight = await billing.preflight({ callerId: caller.id, callType });
  if (!preflight.ok) {
    if (preflight.reason === 'insufficient_balance') {
      throw insufficientBalance(
        `You need at least ${preflight.required} coins to start this call`,
      );
    }
    throw badRequest('preflight_failed', 'Call cannot be started');
  }

  const rate = coinsPerMinute(callType);
  const listenerRate = listenerSharePerMinute(callType);

  const call = await withTransaction(async (client) => {
    // Claim the listener. The WHERE clause is the lock: only one caller can
    // flip is_busy from false to true.
    const { rows: claimed } = await client.query(
      `UPDATE listener_profiles
          SET is_busy = TRUE, updated_at = now()
        WHERE user_id = $1 AND is_online = TRUE AND is_busy = FALSE AND kyc_status = $2
        RETURNING user_id, audio_rate, video_rate`,
      [listenerId, KYC_STATUS.APPROVED],
    );

    if (claimed.length === 0) {
      throw conflict('listener_unavailable', 'This listener is not available right now');
    }

    const channel = agora.buildChannelName(`${caller.id}_${listenerId}`);

    const { rows } = await client.query(
      `INSERT INTO calls (caller_id, listener_id, type, status, agora_channel,
                          rate_per_minute, listener_rate_per_minute, free_seconds_granted)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       RETURNING *`,
      [
        caller.id,
        listenerId,
        callType,
        CALL_STATUS.RINGING,
        channel,
        rate,
        listenerRate,
        preflight.freeSeconds || 0,
      ],
    );

    return rows[0];
  });

  // Both sides need a token for the same channel, each with their own uid.
  const callerToken = agora.buildRtcToken({ channelName: call.agora_channel, uid: caller.id });
  const listenerToken = agora.buildRtcToken({
    channelName: call.agora_channel,
    uid: listenerId,
  });

  await callEvents.incomingCall(listenerId, {
    callId: call.id,
    callType,
    caller: { id: caller.id, name: caller.display_name },
    agoraChannel: call.agora_channel,
    agoraToken: listenerToken,
  });

  // Push as well as socket: the listener's app may be backgrounded.
  await notificationQueue.add('incoming_call', {
    userId: listenerId,
    title: 'Incoming call',
    body: `${caller.display_name || 'Someone'} is calling you`,
    data: { type: 'incoming_call', callId: String(call.id), callType },
    highPriority: true,
  });

  logger.info({ callId: call.id, callerId: caller.id, listenerId, callType }, 'call initiated');

  return {
    call,
    agoraChannel: call.agora_channel,
    agoraToken: callerToken,
    freeSeconds: preflight.freeSeconds || 0,
    ratePerMinute: rate,
    balance: preflight.balance,
  };
}

/**
 * The listener accepts. This is where the meter starts.
 *
 * The first minute is billed immediately rather than after 60 seconds, because
 * billing is full-minute: the started minute is billed in full. A caller on the
 * free trial gets their first minute free, so the first tick is deferred.
 */
async function accept({ callId, listenerId }) {
  const call = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `UPDATE calls SET status = $3, started_at = now()
        WHERE id = $1 AND listener_id = $2 AND status = $4
        RETURNING *`,
      [callId, listenerId, CALL_STATUS.ACTIVE, CALL_STATUS.RINGING],
    );
    if (rows.length === 0) {
      throw conflict('call_not_ringing', 'This call is no longer ringing');
    }
    return rows[0];
  });

  const balance = await query('SELECT coin_balance FROM wallets WHERE user_id = $1', [
    call.caller_id,
  ]);
  await billing.initCallState(call, balance.rows[0]?.coin_balance ?? 0);

  const usesFreeTrial = call.free_seconds_granted > 0;

  if (usesFreeTrial) {
    // Burn the trial now so a dropped call cannot be used to farm free minutes.
    await query('UPDATE users SET free_trial_used = TRUE WHERE id = $1', [call.caller_id]);
    // First minute free: the first charge lands after the free window.
    await scheduleTick(call.id, 1, FREE_TRIAL_SECONDS);
  } else {
    // Bill minute 1 now, then chain every 60s.
    await scheduleTick(call.id, 1, 0);
  }

  await callEvents.callAccepted(call.caller_id, {
    callId: call.id,
    startedAt: call.started_at,
    freeSeconds: call.free_seconds_granted,
  });

  logger.info({ callId: call.id, usesFreeTrial }, 'call accepted');
  return call;
}

/** Either party ends the call, or the listener rejects a ringing one. */
async function end({ callId, actorId, reason }) {
  const { rows } = await query(
    'SELECT caller_id, listener_id, status FROM calls WHERE id = $1',
    [callId],
  );
  const call = rows[0];
  if (!call) throw notFound('Call');

  // actorId is null for system-initiated ends (the Agora disconnect webhook and
  // the stale-call sweeper), which have no participant to authorise.
  const isParticipant =
    Number(call.caller_id) === Number(actorId) || Number(call.listener_id) === Number(actorId);
  if (actorId !== null && !isParticipant) {
    throw forbidden('You are not part of this call');
  }

  const endReason =
    reason ||
    (call.status === CALL_STATUS.RINGING
      ? CALL_END_REASON.REJECTED
      : Number(actorId) === Number(call.caller_id)
        ? CALL_END_REASON.CALLER_HANGUP
        : CALL_END_REASON.LISTENER_HANGUP);

  const summary = await billing.endCall({ callId, reason: endReason, actorId });
  if (!summary) throw notFound('Call');

  // The caller's balance after settlement, for the Call Ended Summary — read
  // fresh rather than derived, since the wallet remains the only source of truth.
  const callerBalance = await walletService.getBalance(summary.caller_id);

  const payload = {
    callId,
    reason: summary.end_reason,
    billedMinutes: summary.billed_minutes,
    coinsSpent: summary.coins_spent,
    durationSeconds: summary.started_at
      ? Math.max(0, Math.round((new Date(summary.ended_at) - new Date(summary.started_at)) / 1000))
      : 0,
    callerBalance,
  };

  if (!summary.alreadyEnded) {
    await callEvents.callEnded(summary.caller_id, payload);
    await callEvents.callEnded(summary.listener_id, {
      ...payload,
      earned: summary.listener_earned,
    });
  }

  return { ...summary, ...payload };
}

/** Call history for either role, used by the recent-calls list. */
async function history({ userId, limit = 30, before }) {
  const { rows } = await query(
    `SELECT c.id, c.type, c.status, c.billed_minutes, c.coins_spent, c.listener_earned,
            c.started_at, c.ended_at, c.end_reason, c.caller_id, c.listener_id,
            caller.display_name AS caller_name, caller.avatar_url AS caller_avatar,
            listener.display_name AS listener_name, listener.avatar_url AS listener_avatar
       FROM calls c
       JOIN users caller ON caller.id = c.caller_id
       JOIN users listener ON listener.id = c.listener_id
      WHERE (c.caller_id = $1 OR c.listener_id = $1)
        AND ($2::bigint IS NULL OR c.id < $2)
      ORDER BY c.id DESC
      LIMIT $3`,
    [userId, before ?? null, Math.min(limit, 100)],
  );

  return rows.map((row) => {
    const outgoing = Number(row.caller_id) === Number(userId);
    return {
      id: row.id,
      type: row.type,
      status: row.status,
      direction: outgoing ? 'outgoing' : 'incoming',
      counterparty: {
        id: outgoing ? row.listener_id : row.caller_id,
        name: outgoing ? row.listener_name : row.caller_name,
        avatarUrl: outgoing ? row.listener_avatar : row.caller_avatar,
      },
      billedMinutes: row.billed_minutes,
      // A caller sees what they spent; a listener sees what they earned.
      coins: outgoing ? row.coins_spent : row.listener_earned,
      startedAt: row.started_at,
      endedAt: row.ended_at,
      endReason: row.end_reason,
    };
  });
}

module.exports = { initiate, accept, end, history };

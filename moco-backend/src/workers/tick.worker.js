'use strict';

const billing = require('../modules/calls/billing.engine');
const callEvents = require('../realtime/call.events');
const { scheduleTick, ensureSweep } = require('../jobs');
const logger = require('../utils/logger');
const { TICK_INTERVAL_SECONDS, CALL_END_REASON, coinsPerMinute } = require('../utils/constants');

/**
 * The tick handler — the code that actually charges for calls. It runs as the
 * Vercel Queues consumer for the moco-tick topic (api/queues/tick.mjs).
 *
 * One job bills one minute of one call, then chains the next minute. The
 * outcomes it must handle:
 *
 *   billed               → notify both parties, warn if low, chain the next tick
 *   insufficient_balance → force-end the call server-side
 *   duplicate / locked   → another worker has this minute; chain and move on
 *   not_active           → the call ended; stop the chain by doing nothing
 *
 * Delivery is at-least-once and ticks for different calls run concurrently;
 * correctness for the *same* call is guarded by the per-call lock and the
 * UNIQUE(call_id, minute_index) constraint in the billing engine.
 */

async function handleTick(job) {
  const callId = Number(job.data.callId);
  const minuteIndex = Number(job.data.minuteIndex);

  const result = await billing.settleTick({ callId, minuteIndex });

  switch (result.status) {
    case 'billed': {
      const call = await billing.loadLiveCall(callId);
      if (!call) return result;

      const payload = {
        callId,
        minuteIndex,
        coinsCharged: result.rate,
        balance: result.balanceAfter,
        minutesRemaining: result.minutesRemaining,
      };

      await callEvents.tick(call.caller_id, payload);
      await callEvents.tick(call.listener_id, {
        callId,
        minuteIndex,
        earned: result.listenerShare,
      });

      if (result.lowBalance) {
        // Non-blocking by design: the client shows the inline recharge overlay
        // over a still-live call rather than ending it.
        await callEvents.lowBalance(call.caller_id, {
          callId,
          balance: result.balanceAfter,
          minutesRemaining: result.minutesRemaining,
          coinsPerMinute: coinsPerMinute(call.type),
        });
      }

      await scheduleTick(callId, minuteIndex + 1, TICK_INTERVAL_SECONDS);
      // Keep the stale-call backstop alive for as long as calls are billing.
      await ensureSweep();
      return result;
    }

    case 'insufficient_balance': {
      const call = await billing.loadLiveCall(callId);
      const summary = await billing.endCall({
        callId,
        reason: CALL_END_REASON.INSUFFICIENT_BALANCE,
      });

      if (call && summary) {
        const payload = {
          callId,
          reason: CALL_END_REASON.INSUFFICIENT_BALANCE,
          billedMinutes: summary.billed_minutes,
          coinsSpent: summary.coins_spent,
        };
        await callEvents.forcedEnd(call.caller_id, payload);
        await callEvents.forcedEnd(call.listener_id, {
          ...payload,
          earned: summary.listener_earned,
        });
      }

      logger.info({ callId }, 'call force-ended: caller out of coins');
      return { status: 'force_ended' };
    }

    case 'duplicate':
    case 'locked':
      // Someone else billed (or is billing) this minute. Keep the chain alive
      // so the call does not silently stop being billed.
      await scheduleTick(callId, minuteIndex + 1, TICK_INTERVAL_SECONDS);
      return result;

    case 'not_active':
    default:
      // The call is over. Scheduling nothing ends the chain.
      logger.debug({ callId, minuteIndex }, 'tick chain stopped');
      return result;
  }
}

module.exports = { handleTick };

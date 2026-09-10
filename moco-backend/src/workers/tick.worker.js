'use strict';

const { Worker } = require('bullmq');
const { createQueueConnection } = require('../config/redis');
const billing = require('../modules/calls/billing.engine');
const callEvents = require('../realtime/call.events');
const { scheduleTick } = require('./queues');
const logger = require('../utils/logger');
const {
  BULL_QUEUES,
  TICK_INTERVAL_SECONDS,
  CALL_END_REASON,
  coinsPerMinute,
} = require('../utils/constants');

/**
 * The tick worker — the process that actually charges for calls.
 *
 * One job bills one minute of one call, then chains the next minute. The
 * outcomes it must handle:
 *
 *   billed               → notify both parties, warn if low, chain the next tick
 *   insufficient_balance → force-end the call server-side
 *   duplicate / locked   → another worker has this minute; chain and move on
 *   not_active           → the call ended; stop the chain by doing nothing
 *
 * Concurrency is set well above one because ticks for *different* calls are
 * independent; correctness for the *same* call is guarded by the per-call lock
 * and the UNIQUE(call_id, minute_index) constraint in the billing engine.
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

function start() {
  const connection = createQueueConnection();

  const worker = new Worker(BULL_QUEUES.TICK, handleTick, {
    connection,
    concurrency: 50,
  });

  worker.on('failed', (job, err) => {
    logger.error({ jobId: job?.id, callId: job?.data?.callId, err }, 'tick job failed');
  });

  worker.on('error', (err) => logger.error({ err }, 'tick worker error'));

  // Backstop for calls whose chain died with the process (a crash between
  // billing a minute and enqueueing the next one).
  const sweeper = setInterval(() => {
    billing.sweepStaleCalls().catch((err) => logger.error({ err }, 'sweep failed'));
  }, TICK_INTERVAL_SECONDS * 1000);

  const shutdown = async () => {
    logger.info('tick worker shutting down');
    clearInterval(sweeper);
    // Let in-flight ticks finish so no minute is billed without its chain.
    await worker.close();
    process.exit(0);
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  logger.info('tick worker started');
  return worker;
}

if (require.main === module) start();

module.exports = { start, handleTick };

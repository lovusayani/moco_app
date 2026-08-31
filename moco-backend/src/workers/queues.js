'use strict';

const { Queue } = require('bullmq');
const { createQueueConnection } = require('../config/redis');
const { BULL_QUEUES, TICK_INTERVAL_SECONDS } = require('../utils/constants');

/**
 * Queue handles shared by the API process (which enqueues) and the workers
 * (which consume). Kept in one module so a queue name is never typed twice.
 */

const connection = createQueueConnection();

const defaultJobOptions = {
  removeOnComplete: { count: 1000 },
  removeOnFail: { count: 5000 },
  attempts: 3,
  backoff: { type: 'exponential', delay: 2000 },
};

const tickQueue = new Queue(BULL_QUEUES.TICK, { connection, defaultJobOptions });
const payoutQueue = new Queue(BULL_QUEUES.PAYOUT, { connection, defaultJobOptions });
const notificationQueue = new Queue(BULL_QUEUES.NOTIFICATION, { connection, defaultJobOptions });

/**
 * Enqueues one billing tick for a call, `delaySeconds` from now.
 *
 * Ticks are chained rather than scheduled as a BullMQ repeatable: each tick
 * schedules the next one only if the call is still active. A repeatable job
 * would need explicit cancellation on every end path (hang-up, forced end,
 * disconnect, sweep), and any missed path would leave a schedule billing a
 * dead call. Chaining makes ending a call the absence of an action, which is
 * far harder to get wrong.
 *
 * The job id encodes the minute, so an accidental double-enqueue for the same
 * minute collapses into one job.
 */
async function scheduleTick(callId, minuteIndex, delaySeconds = TICK_INTERVAL_SECONDS) {
  return tickQueue.add(
    'tick',
    { callId: String(callId), minuteIndex },
    { delay: delaySeconds * 1000, jobId: `tick-${callId}-${minuteIndex}` },
  );
}

async function closeAll() {
  await Promise.all([tickQueue.close(), payoutQueue.close(), notificationQueue.close()]);
  await connection.quit();
}

module.exports = { tickQueue, payoutQueue, notificationQueue, scheduleTick, closeAll };

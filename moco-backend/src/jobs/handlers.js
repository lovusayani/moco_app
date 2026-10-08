'use strict';

const { redis } = require('../config/redis');
const { REDIS } = require('../utils/constants');
const { TOPICS } = require('./index');
const monitoring = require('../utils/monitoring');

/**
 * Topic → handler. Used by the Vercel Queues consumer functions in api/queues/
 * and by `inline` mode in local development, so both run the same code.
 *
 * Handlers are required lazily: the tick worker requires the billing engine,
 * which pulls in most of the app, and a consumer should only load what its
 * topic needs.
 */
const HANDLERS = {
  [TOPICS.TICK]: () => require('../workers/tick.worker').handleTick,
  [TOPICS.SWEEP]: () => require('../workers/sweep.worker').handleSweep,
  [TOPICS.PAYOUT]: () => require('../workers/payout.worker').handlePayout,
  [TOPICS.NOTIFICATION]: () => require('../workers/notification.worker').handleNotification,
  [TOPICS.PRESENCE]: () => require('../workers/presence.worker').handlePresenceCheck,
  [TOPICS.LIVE]: () => require('../workers/live.worker').handleLive,
};

/**
 * Records when each job type last ran, for the admin system-health page. There
 * is no worker process to send a heartbeat any more, so "last processed" is
 * the honest signal.
 */
async function markProcessed(topic) {
  await redis
    .set(REDIS.jobLastRunKey(topic), String(Date.now()), 'EX', REDIS.jobLastRunTtlSeconds)
    .catch(() => {});
}

function resolveHandler(topic) {
  const resolve = HANDLERS[topic];
  if (!resolve) throw new Error(`no handler for topic ${topic}`);
  return resolve();
}

/**
 * Runs one job. A failure is reported to monitoring before it propagates (the
 * queue then retries it), and pending reports are flushed before the
 * consumer function returns.
 */
async function handle(topic, payload) {
  try {
    const result = await resolveHandler(topic)({ data: payload });
    await markProcessed(topic);
    return result;
  } catch (err) {
    monitoring.captureException(err, { topic });
    throw err;
  } finally {
    await monitoring.flush();
  }
}

module.exports = { handle, resolveHandler };

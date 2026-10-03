'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');
const { TICK_INTERVAL_SECONDS } = require('../utils/constants');

/**
 * Background jobs — Vercel Queues in production, replacing BullMQ workers.
 *
 * There are no long-running worker processes on Vercel. A job is a message on
 * a Vercel Queues topic, and Vercel invokes the matching consumer function in
 * api/queues/ for each one (push mode). Delivery is at-least-once, so every
 * handler is idempotent. The billing engine's per-call lock and
 * UNIQUE(call_id, minute_index) constraint already guaranteed that for ticks.
 *
 * Modes (env.jobs.mode):
 *   vercel  — publish with @vercel/queue (default on Vercel)
 *   inline  — run the handler in this process after the delay (local dev)
 *   record  — only record the job (the test suite, which used to enqueue into
 *             BullMQ with no worker running)
 */

const TOPICS = {
  TICK: 'moco-tick',
  SWEEP: 'moco-sweep',
  PAYOUT: 'moco-payout',
  NOTIFICATION: 'moco-notification',
  PRESENCE: 'moco-presence',
};

// Messages a consumer never acknowledges stop mattering after this. A billing
// tick or a push that is a day late is worse than none, and the sweeper ends
// calls whose chain died.
const RETENTION_SECONDS = 6 * 60 * 60;

const recorded = [];
let queueSend = null;
const inlineSeen = new Set();

function mode() {
  return env.jobs.mode;
}

async function sendVercel(topic, payload, { delaySeconds, idempotencyKey }) {
  if (!queueSend) {
    // eslint-disable-next-line global-require
    queueSend = require('@vercel/queue').send;
  }
  const options = { retentionSeconds: RETENTION_SECONDS };
  if (delaySeconds > 0) options.delaySeconds = Math.ceil(delaySeconds);
  if (idempotencyKey) options.idempotencyKey = idempotencyKey;
  return queueSend(topic, payload, options);
}

function runInline(topic, payload, { delaySeconds, idempotencyKey }) {
  if (idempotencyKey) {
    if (inlineSeen.has(idempotencyKey)) return { messageId: null };
    inlineSeen.add(idempotencyKey);
  }
  const timer = setTimeout(async () => {
    try {
      // eslint-disable-next-line global-require
      await require('./handlers').handle(topic, payload);
    } catch (err) {
      logger.error({ err, topic }, 'inline job failed');
    }
  }, Math.max(0, delaySeconds) * 1000);
  timer.unref?.();
  return { messageId: null };
}

/**
 * Publishes one job. `idempotencyKey` deduplicates repeated publishes (Vercel
 * keeps the key for min(retention, 24h)).
 */
async function enqueue(topic, payload, { delaySeconds = 0, idempotencyKey } = {}) {
  switch (mode()) {
    case 'vercel':
      return sendVercel(topic, payload, { delaySeconds, idempotencyKey });
    case 'inline':
      return runInline(topic, payload, { delaySeconds, idempotencyKey });
    default:
      recorded.push({ topic, payload, delaySeconds, idempotencyKey });
      return { messageId: null };
  }
}

/**
 * Enqueues one billing tick for a call, `delaySeconds` from now.
 *
 * Ticks are chained, not scheduled on a timer: each tick schedules the next
 * only while the call is still active, so ending a call is the absence of an
 * action. The idempotency key encodes the minute, so a double-enqueue for the
 * same minute collapses into one message.
 */
function scheduleTick(callId, minuteIndex, delaySeconds = TICK_INTERVAL_SECONDS) {
  return enqueue(
    TOPICS.TICK,
    { callId: String(callId), minuteIndex },
    { delaySeconds, idempotencyKey: `tick-${callId}-${minuteIndex}` },
  );
}

/**
 * Makes sure a stale-call sweep runs within the next minute.
 *
 * The sweep is the backstop for calls whose tick chain died (and for ringing
 * calls nobody answered). It re-schedules itself every minute while any call is
 * ringing or active and stops when none are, so it costs nothing when idle.
 * Keying the message by minute means every caller of this in the same minute
 * shares one sweep.
 */
function ensureSweep(delaySeconds = TICK_INTERVAL_SECONDS) {
  const runAt = Date.now() + delaySeconds * 1000;
  const bucket = Math.floor(runAt / (TICK_INTERVAL_SECONDS * 1000));
  return enqueue(TOPICS.SWEEP, { bucket }, { delaySeconds, idempotencyKey: `sweep-${bucket}` });
}

const sendNotification = (job) => enqueue(TOPICS.NOTIFICATION, job);

const processPayout = (payoutId) =>
  enqueue(TOPICS.PAYOUT, { payoutId: Number(payoutId) }, { idempotencyKey: `payout-${payoutId}` });

/** Test helpers: what was published in `record` mode. */
const recordedJobs = () => recorded.slice();
const clearRecordedJobs = () => {
  recorded.length = 0;
};

module.exports = {
  TOPICS,
  enqueue,
  scheduleTick,
  ensureSweep,
  sendNotification,
  processPayout,
  recordedJobs,
  clearRecordedJobs,
};

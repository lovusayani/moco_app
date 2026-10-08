'use strict';

const jobs = require('../jobs');
const live = require('../modules/live/live.service');
const logger = require('../utils/logger');

/**
 * Moco Live jobs (topic moco-live).
 *
 *  task 'sync'    — one provider sync, then the next one in 30 s, but only
 *                   while someone has browsed Live in the last 10 minutes,
 *                   so an idle system makes no provider calls at all. The
 *                   listing endpoint restarts the chain.
 *  task 'cleanup' — daily: provider-reported deletions and the 30-day
 *                   absence rule (enqueued by the daily cron).
 *
 * Provider failures never throw (the next run simply tries again), so a bad
 * provider minute cannot turn into a queue retry storm.
 */
async function handleLive(job) {
  const { task = 'sync' } = job.data || {};

  if (task === 'cleanup') {
    return { status: 'cleaned', ...(await live.cleanup()) };
  }

  const result = await live.sync();
  if (result.status !== 'not_configured' && (await live.hasDemand())) {
    await jobs.ensureLiveSync();
    return { ...result, rescheduled: true };
  }
  logger.debug('no recent Live viewers, live sync chain stopped');
  return { ...result, rescheduled: false };
}

module.exports = { handleLive };

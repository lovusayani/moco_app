'use strict';

const billing = require('../modules/calls/billing.engine');
const { query } = require('../config/db');
const jobs = require('../jobs');
const logger = require('../utils/logger');
const { CALL_STATUS } = require('../utils/constants');

/**
 * The stale-call sweep — formerly a setInterval inside the tick worker
 * process.
 *
 * It ends calls whose tick chain died (a crash between billing a minute and
 * enqueueing the next one) and ringing calls nobody answered. It then
 * re-schedules itself for the next minute, but only while any call is still
 * ringing or active, so an idle system schedules nothing.
 */
async function handleSweep() {
  const swept = await billing.sweepStaleCalls();

  const { rows } = await query(
    'SELECT EXISTS (SELECT 1 FROM calls WHERE status IN ($1, $2)) AS live',
    [CALL_STATUS.ACTIVE, CALL_STATUS.RINGING],
  );
  if (rows[0]?.live) {
    await jobs.ensureSweep();
  } else {
    logger.debug('no live calls, sweep chain stopped');
  }

  return { status: 'swept', swept: swept.length, rescheduled: Boolean(rows[0]?.live) };
}

module.exports = { handleSweep };

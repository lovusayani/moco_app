'use strict';

const { Worker } = require('bullmq');
const { createQueueConnection } = require('../config/redis');
const { withTransaction, query } = require('../config/db');
const walletService = require('../modules/wallet/wallet.service');
const { notificationQueue } = require('./queues');
const notifications = require('../modules/notifications/notifications.service');
const logger = require('../utils/logger');
const { BULL_QUEUES, PAYOUT_STATUS, EARNING_REASON } = require('../utils/constants');

/**
 * Processes admin-approved withdrawals.
 *
 * Money leaves the platform here, so the flow is deliberately conservative:
 * the earnings debit and the payout status change commit together, and the
 * status transition is guarded by `WHERE status = 'approved'` so a job
 * delivered twice cannot pay a listener twice.
 *
 * The actual UPI transfer is left as an explicit integration point — wiring a
 * real disbursement API is a decision with compliance implications and should
 * be made deliberately, not defaulted into.
 */

async function handlePayout(job) {
  const payoutId = Number(job.data.payoutId);

  return withTransaction(async (client) => {
    const { rows } = await client.query(
      `SELECT id, listener_id, amount, status FROM payouts WHERE id = $1 FOR UPDATE`,
      [payoutId],
    );

    const payout = rows[0];
    if (!payout) {
      logger.warn({ payoutId }, 'payout not found');
      return { status: 'missing' };
    }

    if (payout.status !== PAYOUT_STATUS.APPROVED) {
      // Already paid, rejected, or not yet approved. Never pay from here.
      logger.info({ payoutId, status: payout.status }, 'payout not in approved state, skipping');
      return { status: 'skipped' };
    }

    await walletService.debitListener(client, {
      listenerId: payout.listener_id,
      amount: payout.amount,
      reason: EARNING_REASON.PAYOUT,
      refId: String(payoutId),
    });

    // TODO(integration): call the UPI disbursement API here and record its
    // reference. Until then payouts are marked paid by the admin action that
    // approved them, and upi_ref is filled in manually.
    await client.query(
      `UPDATE payouts SET status = $2, processed_at = now() WHERE id = $1 AND status = $3`,
      [payoutId, PAYOUT_STATUS.PAID, PAYOUT_STATUS.APPROVED],
    );

    await notificationQueue.add('payout_paid', {
      userId: payout.listener_id,
      title: 'Withdrawal sent',
      body: `Your withdrawal of ${payout.amount} has been processed.`,
    });
    await notifications.create({
      userId: payout.listener_id,
      type: 'payout_paid',
      title: 'Withdrawal sent',
      body: `Your withdrawal of ₹${payout.amount} has been processed.`,
      data: { payoutId },
    });

    logger.info({ payoutId, listenerId: payout.listener_id, amount: payout.amount }, 'payout paid');
    return { status: 'paid' };
  });
}

function start() {
  const connection = createQueueConnection();
  // Concurrency 1: payouts are low-volume and money leaving the platform is
  // not worth parallelising.
  const worker = new Worker(BULL_QUEUES.PAYOUT, handlePayout, { connection, concurrency: 1 });

  worker.on('failed', (job, err) =>
    logger.error({ jobId: job?.id, err }, 'payout job failed'),
  );

  const shutdown = async () => {
    await worker.close();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  logger.info('payout worker started');
  return worker;
}

if (require.main === module) start();

module.exports = { start, handlePayout };

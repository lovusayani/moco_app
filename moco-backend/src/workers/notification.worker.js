'use strict';

const { Worker } = require('bullmq');
const { createQueueConnection } = require('../config/redis');
const { query } = require('../config/db');
const fcm = require('../integrations/fcm');
const logger = require('../utils/logger');
const { BULL_QUEUES } = require('../utils/constants');

/**
 * Delivers push notifications off the request path, so a slow FCM call never
 * delays an API response or a call setup.
 */

async function handleNotification(job) {
  const { userId, title, body, data = {}, highPriority = false } = job.data;

  const { rows } = await query('SELECT fcm_token FROM users WHERE id = $1', [userId]);
  const token = rows[0]?.fcm_token;

  if (!token) {
    logger.debug({ userId }, 'no fcm token registered, skipping push');
    return { status: 'no_token' };
  }

  const result = await fcm.send({ token, title, body, data, highPriority });
  return { status: result.ok ? 'sent' : 'failed' };
}

function start() {
  const connection = createQueueConnection();
  const worker = new Worker(BULL_QUEUES.NOTIFICATION, handleNotification, {
    connection,
    concurrency: 20,
  });

  worker.on('failed', (job, err) =>
    logger.error({ jobId: job?.id, err }, 'notification job failed'),
  );

  const shutdown = async () => {
    await worker.close();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  logger.info('notification worker started');
  return worker;
}

if (require.main === module) start();

module.exports = { start, handleNotification };

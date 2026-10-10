'use strict';

const { query } = require('../config/db');
const fcm = require('../integrations/fcm');
const logger = require('../utils/logger');

/**
 * Delivers push notifications off the request path, so a slow FCM call never
 * delays an API response or a call setup.
 *
 * A dead token (app uninstalled, token rotated) is cleared so it is not tried
 * again; it is cleared only if it is still the user's current token, so a
 * fresh token registered meanwhile survives. A transient FCM failure throws,
 * which makes the queue redeliver the job.
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
  if (result.ok) return { status: result.skipped ? 'skipped' : 'sent' };

  if (result.reason === 'unregistered') {
    await query('UPDATE users SET fcm_token = NULL WHERE id = $1 AND fcm_token = $2', [userId, token]);
    logger.info({ userId }, 'cleared a stale fcm token');
    return { status: 'stale_token_cleared' };
  }
  if (result.retryable) {
    throw new Error(`push delivery failed for user ${userId}; will retry`);
  }
  return { status: 'failed', reason: result.reason };
}

module.exports = { handleNotification };

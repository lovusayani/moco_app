'use strict';

const { query } = require('../config/db');
const fcm = require('../integrations/fcm');
const logger = require('../utils/logger');

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

module.exports = { handleNotification };

'use strict';

const { query } = require('../config/db');
const { redis } = require('../config/redis');
const callEvents = require('../realtime/call.events');
const logger = require('../utils/logger');
const { REDIS } = require('../utils/constants');

/**
 * Decides whether a user whose last socket closed is really gone.
 *
 * Runs presenceGraceSeconds after the disconnect (socket.server.js). If the
 * user reconnected in the meantime (a network blip, or Vercel recycling the
 * function instance that held the socket), there is nothing to do. Otherwise
 * presence is cleared and, for a listener who is set to online, discovery is
 * told they are no longer callable — exactly what the disconnect handler used
 * to do immediately.
 */
async function handlePresenceCheck(job) {
  const userId = String(job.data.userId);

  const connections = Number(await redis.get(REDIS.presenceConnectionsKey(userId))) || 0;
  if (connections > 0) return { status: 'reconnected' };

  await redis.del(REDIS.presenceKey(userId), REDIS.presenceConnectionsKey(userId));

  const { rows } = await query(
    'SELECT 1 FROM listener_profiles WHERE user_id = $1 AND is_online',
    [userId],
  );
  if (!rows[0]) return { status: 'offline' };

  await callEvents.listenerPresence({ listenerId: userId, isOnline: false });
  logger.debug({ userId }, 'listener announced offline after socket loss');
  return { status: 'listener_offline' };
}

module.exports = { handlePresenceCheck };

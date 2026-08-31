'use strict';

const { redis } = require('../config/redis');
const { query } = require('../config/db');
const { REDIS } = require('../utils/constants');

/**
 * Listener online state.
 *
 * Postgres holds the listener's *intent* (they flipped themselves online) while
 * Redis holds the *fact* (a socket is actually connected). Discovery requires
 * both, so a listener whose app was killed stops receiving calls within a
 * heartbeat rather than ringing into the void.
 */

const isConnected = async (userId) => (await redis.exists(REDIS.presenceKey(userId))) === 1;

async function filterConnected(userIds) {
  if (userIds.length === 0) return [];
  const pipeline = redis.pipeline();
  userIds.forEach((id) => pipeline.exists(REDIS.presenceKey(id)));
  const results = await pipeline.exec();
  return userIds.filter((_, index) => results[index][1] === 1);
}

async function setOnline(userId, isOnline) {
  await query(
    `UPDATE listener_profiles SET is_online = $2, updated_at = now() WHERE user_id = $1`,
    [userId, isOnline],
  );
  if (isOnline) {
    await redis.setex(REDIS.presenceKey(userId), REDIS.presenceTtlSeconds, '1');
  } else {
    await redis.del(REDIS.presenceKey(userId));
  }
}

module.exports = { isConnected, filterConnected, setOnline };

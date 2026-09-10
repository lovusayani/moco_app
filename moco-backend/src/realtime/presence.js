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
  const { rows } = await query(
    `UPDATE listener_profiles SET is_online = $2, updated_at = now()
      WHERE user_id = $1 RETURNING is_busy`,
    [userId, isOnline],
  );

  if (isOnline) {
    await redis.setex(REDIS.presenceKey(userId), REDIS.presenceTtlSeconds, '1');
  } else {
    await redis.del(REDIS.presenceKey(userId));
  }

  // Announce so open discovery grids update without a refresh. Required lazily:
  // call.events requires socket.server, which would otherwise cycle back here.
  // A failed announce must not fail the toggle — the listener IS online either
  // way, and the next discovery fetch reflects it.
  try {
    // eslint-disable-next-line global-require
    const callEvents = require('./call.events');
    await callEvents.listenerPresence({
      listenerId: userId,
      isOnline,
      isBusy: rows[0]?.is_busy ?? false,
    });
  } catch {
    // Presence is best-effort; HTTP remains the source of truth.
  }
}

module.exports = { isConnected, filterConnected, setOnline };

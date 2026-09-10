'use strict';

const { Server } = require('socket.io');
const { verifyToken } = require('../middleware/auth');
const { query } = require('../config/db');
const { redis } = require('../config/redis');
const { REDIS } = require('../utils/constants');
const logger = require('../utils/logger');

/**
 * Socket.IO server carrying tick, low-balance and forced-end events.
 *
 * Every socket joins a room named after its user id, so emitting to a user is
 * `io.to('user:123')` and works regardless of how many devices they have open.
 */

let io = null;

function init(httpServer) {
  io = new Server(httpServer, {
    cors: { origin: '*' },
    // Mobile networks drop; give a reconnecting client room before declaring
    // the socket dead and letting the sweeper end the call.
    pingInterval: 20_000,
    pingTimeout: 25_000,
  });

  io.use((socket, next) => {
    try {
      const token = socket.handshake.auth?.token || socket.handshake.query?.token;
      if (!token) return next(new Error('unauthorized'));
      const payload = verifyToken(token);
      socket.userId = String(payload.sub);
      return next();
    } catch {
      return next(new Error('unauthorized'));
    }
  });

  io.on('connection', async (socket) => {
    const room = `user:${socket.userId}`;
    socket.join(room);
    // Everyone joins the broadcast room so presence updates reach open
    // discovery grids without a per-client subscription.
    socket.join('discovery');
    await redis.setex(REDIS.presenceKey(socket.userId), REDIS.presenceTtlSeconds, '1');
    logger.debug({ userId: socket.userId }, 'socket connected');

    // Heartbeat doubles as the client-side liveness signal the billing sweeper
    // uses to tell a dropped call from a quiet one.
    socket.on('heartbeat', async ({ callId } = {}) => {
      await redis.setex(REDIS.presenceKey(socket.userId), REDIS.presenceTtlSeconds, '1');
      if (callId) {
        await redis.hset(REDIS.callStateKey(callId), 'last_heartbeat_ts', String(Date.now()));
      }
    });

    socket.on('disconnect', async () => {
      await redis.del(REDIS.presenceKey(socket.userId));

      // A listener whose socket dropped is no longer callable. Discovery
      // requires BOTH the profile flag and a live socket, so announce the
      // change rather than leaving stale cards showing them as available.
      try {
        const { rows } = await query(
          'SELECT 1 FROM listener_profiles WHERE user_id = $1 AND is_online',
          [socket.userId],
        );
        if (rows[0]) {
          await onListenerDisconnect(socket.userId);
        }
      } catch (err) {
        logger.warn({ err, userId: socket.userId }, 'presence announce on disconnect failed');
      }

      logger.debug({ userId: socket.userId }, 'socket disconnected');
    });
  });

  logger.info('socket.io ready');
  return io;
}

/**
 * Emits to a user's room.
 *
 * Deliberately tolerant of `io` being null: the workers run as separate PM2
 * processes that have no socket server of their own, and they publish through
 * Redis (see call.events.js) instead. A missing io here must never crash a
 * worker mid-settlement.
 */
function emitToUser(userId, event, payload) {
  if (!io) {
    logger.debug({ event, userId }, 'no socket server in this process');
    return false;
  }
  io.to(`user:${userId}`).emit(event, payload);
  return true;
}

/** Emits to a named room — used for broadcast events such as presence. */
function emitToRoom(room, event, payload) {
  if (!io) {
    logger.debug({ event, room }, 'no socket server in this process');
    return false;
  }
  io.to(room).emit(event, payload);
  return true;
}

/**
 * Called when a listener's socket drops.
 *
 * Assigned by server.js rather than imported, because call.events already
 * requires this module and importing it back would be a cycle.
 */
let onListenerDisconnect = async () => {};
const setListenerDisconnectHandler = (fn) => {
  onListenerDisconnect = fn;
};

const getIo = () => io;

module.exports = {
  init,
  emitToUser,
  emitToRoom,
  setListenerDisconnectHandler,
  getIo,
};

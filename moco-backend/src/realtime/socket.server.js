'use strict';

const { Server } = require('socket.io');
const { verifyToken } = require('../middleware/auth');
const { redis } = require('../config/redis');
const { isAllowedOrigin } = require('../middleware/cors');
const jobs = require('../jobs');
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
    // Clients use the WebSocket transport only (Vercel Functions do not keep
    // HTTP long-polling sessions on one instance).
    transports: ['websocket'],
    // Browsers send an Origin; only the allow-listed web/admin origins may
    // open a socket. Native clients (the Android app) send none and
    // authenticate with their token like everyone else.
    allowRequest: (req, callback) => {
      const origin = req.headers.origin;
      callback(null, !origin || isAllowedOrigin(origin));
    },
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
    const connectionsKey = REDIS.presenceConnectionsKey(socket.userId);
    const [, [, open]] = await redis
      .multi()
      .setex(REDIS.presenceKey(socket.userId), REDIS.presenceTtlSeconds, '1')
      .incr(connectionsKey)
      .expire(connectionsKey, REDIS.presenceTtlSeconds)
      .exec();
    // A counter that drifted below zero (a decrement after its key expired)
    // must not make this live socket count as none.
    if (open < 1) await redis.set(connectionsKey, '1', 'EX', REDIS.presenceTtlSeconds);
    logger.debug({ userId: socket.userId }, 'socket connected');

    // Presence means "a socket is connected", so keep it alive for as long as
    // the connection is: Socket.IO's own ping/pong (every pingInterval) proves
    // that without any client change. Every other pong is enough to stay well
    // inside the TTL while keeping Redis traffic low.
    let pongs = 0;
    socket.conn.on('packet', (packet) => {
      if (packet.type !== 'pong' || (pongs += 1) % 2 !== 0) return;
      redis
        .multi()
        .setex(REDIS.presenceKey(socket.userId), REDIS.presenceTtlSeconds, '1')
        .expire(connectionsKey, REDIS.presenceTtlSeconds)
        .exec()
        .catch((err) => logger.warn({ err, userId: socket.userId }, 'presence refresh failed'));
    });

    // Heartbeat doubles as the client-side liveness signal the billing sweeper
    // uses to tell a dropped call from a quiet one.
    socket.on('heartbeat', async ({ callId } = {}) => {
      await redis
        .multi()
        .setex(REDIS.presenceKey(socket.userId), REDIS.presenceTtlSeconds, '1')
        .expire(connectionsKey, REDIS.presenceTtlSeconds)
        .exec();
      if (callId) {
        await redis.hset(REDIS.callStateKey(callId), 'last_heartbeat_ts', String(Date.now()));
      }
    });

    socket.on('disconnect', async () => {
      // A user is gone only when their LAST socket closes, and only if it is
      // not replaced within a short grace period. On Vercel a socket also
      // closes when its function instance reaches its maximum duration; the
      // client reconnects within a second or two, and that must not flicker
      // every online listener offline. The presence job (workers/
      // presence.worker.js) makes the call after the grace period.
      try {
        const remaining = await redis.decr(connectionsKey);
        if (remaining <= 0) {
          await jobs.enqueue(
            jobs.TOPICS.PRESENCE,
            { userId: socket.userId, disconnectedAt: Date.now() },
            { delaySeconds: REDIS.presenceGraceSeconds },
          );
        }
      } catch (err) {
        logger.warn({ err, userId: socket.userId }, 'presence check on disconnect failed');
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
 * Deliberately tolerant of `io` being null: queue consumers run in function
 * instances with no socket server of their own, and they publish through
 * Redis (see call.events.js) instead. A missing io here must never crash a
 * handler mid-settlement.
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

const getIo = () => io;

module.exports = {
  init,
  emitToUser,
  emitToRoom,
  getIo,
};

'use strict';

const http = require('http');
const { createApp } = require('./app');
const env = require('./config/env');
const logger = require('./utils/logger');
const socketServer = require('./realtime/socket.server');
const callEvents = require('./realtime/call.events');
const db = require('./config/db');
const redisConfig = require('./config/redis');

/**
 * API process entry point. Workers run as separate PM2 processes so a slow job
 * can never block an API request, and so the API can be restarted without
 * interrupting billing mid-call.
 */

const app = createApp();
const server = http.createServer(app);

socketServer.init(server);
// This process holds the sockets, so it subscribes to the event channel the
// workers publish tick/low-balance/forced-end events on.
const subscriber = callEvents.startSubscriber();

server.listen(env.port, () => {
  logger.info({ port: env.port, env: env.nodeEnv }, 'moco api listening');
});

/**
 * Graceful shutdown: stop taking new connections, then close the DB and Redis.
 * PM2 sends SIGINT on reload, so getting this right is what makes a deploy
 * during a live call non-disruptive.
 */
let shuttingDown = false;

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.info({ signal }, 'shutting down');

  server.close(async () => {
    try {
      await subscriber.quit();
      await db.close();
      await redisConfig.close();
      logger.info('shutdown complete');
      process.exit(0);
    } catch (err) {
      logger.error({ err }, 'error during shutdown');
      process.exit(1);
    }
  });

  // Don't let a hung connection hold the process open forever.
  setTimeout(() => {
    logger.error('forced exit after shutdown timeout');
    process.exit(1);
  }, 15_000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

process.on('unhandledRejection', (err) => {
  logger.error({ err }, 'unhandled rejection');
});

process.on('uncaughtException', (err) => {
  // An uncaught exception leaves the process in an unknown state; log and let
  // PM2 restart it rather than continuing to serve money-moving requests.
  logger.fatal({ err }, 'uncaught exception, exiting');
  process.exit(1);
});

module.exports = { server, app };

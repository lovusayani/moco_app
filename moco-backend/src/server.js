'use strict';

const env = require('./config/env');
const logger = require('./utils/logger');
const db = require('./config/db');
const redisConfig = require('./config/redis');
const { buildServer } = require('./http');

/**
 * Local development entry point (`npm run dev` / `npm start`).
 *
 * Production does not run this file: on Vercel the same server is exported by
 * api/index.mjs, and background jobs are Vercel Queues consumers in
 * api/queues/. Locally, jobs run in this process (JOBS_MODE=inline), so the
 * whole backend, billing ticks included, works from one command.
 */

const { server, subscriber } = buildServer();

server.listen(env.port, () => {
  logger.info({ port: env.port, env: env.nodeEnv, jobs: env.jobs.mode }, 'moco api listening');
});

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

module.exports = { server };

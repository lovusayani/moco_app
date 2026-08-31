'use strict';

const IORedis = require('ioredis');
const env = require('./env');
const logger = require('../utils/logger');

function buildOptions(extra = {}) {
  return {
    host: env.redis.host,
    port: env.redis.port,
    password: env.redis.password,
    tls: env.redis.tls,
    db: env.redis.db,
    lazyConnect: false,
    ...extra,
  };
}

/** General-purpose connection: live call state, presence, OTP, locks. */
const redis = new IORedis(buildOptions());

redis.on('error', (err) => logger.error({ err }, 'redis error'));

/**
 * BullMQ requires its own connections with `maxRetriesPerRequest: null`, and
 * blocking commands need a connection that is not shared with normal traffic.
 */
function createQueueConnection() {
  return new IORedis(buildOptions({ maxRetriesPerRequest: null, enableReadyCheck: false }));
}

/**
 * Release a lock only if this holder still owns it. Checking and deleting in
 * two round-trips would let a lock that expired mid-check be deleted out from
 * under its new owner, so the compare-and-delete is done in one Lua script.
 */
const RELEASE_LOCK_SCRIPT = `
if redis.call("get", KEYS[1]) == ARGV[1] then
  return redis.call("del", KEYS[1])
else
  return 0
end`;

redis.defineCommand('releaseLock', { numberOfKeys: 1, lua: RELEASE_LOCK_SCRIPT });

async function close() {
  await redis.quit();
}

module.exports = { redis, createQueueConnection, close };

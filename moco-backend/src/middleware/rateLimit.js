'use strict';

const { redis } = require('../config/redis');
const { tooManyRequests } = require('../utils/errors');
const logger = require('../utils/logger');

/**
 * Fixed-window rate limiter backed by Redis, so the limit holds across PM2
 * cluster workers — an in-process limiter would let a 4-instance cluster serve
 * 4x the intended rate.
 */
function rateLimit({ windowSeconds = 60, max = 60, keyPrefix = 'rl', by } = {}) {
  return async (req, res, next) => {
    try {
      const identity = by ? by(req) : req.user?.id || req.ip;
      const window = Math.floor(Date.now() / 1000 / windowSeconds);
      const key = `${keyPrefix}:${identity}:${window}`;

      const count = await redis.incr(key);
      if (count === 1) await redis.expire(key, windowSeconds);

      res.setHeader('X-RateLimit-Limit', max);
      res.setHeader('X-RateLimit-Remaining', Math.max(0, max - count));

      if (count > max) return next(tooManyRequests());
      return next();
    } catch (err) {
      // A Redis blip must not take the whole API down; fail open and alert.
      logger.error({ err }, 'rate limiter unavailable, failing open');
      return next();
    }
  };
}

module.exports = { rateLimit };

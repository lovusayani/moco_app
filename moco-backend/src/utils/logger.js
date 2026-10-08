'use strict';

const pino = require('pino');
const env = require('../config/env');
const monitoring = require('./monitoring');

monitoring.init();

/**
 * One logger for the whole process. In development it is pretty-printed; in
 * production it stays as JSON lines, which Vercel's runtime logs keep
 * searchable. Error-level lines are also reported to Sentry when SENTRY_DSN
 * is set (src/utils/monitoring.js decides what of them may leave).
 */
const logger = pino({
  level: env.logLevel,
  base: undefined,
  redact: {
    paths: ['req.headers.authorization', 'password', 'otp', '*.otp', 'token'],
    censor: '[redacted]',
  },
  hooks: {
    logMethod(args, method, level) {
      if (level >= 50) {
        const [first, second] = args;
        if (first && typeof first === 'object') monitoring.captureLog(first, typeof second === 'string' ? second : undefined);
        else monitoring.captureLog(null, typeof first === 'string' ? first : undefined);
      }
      return method.apply(this, args);
    },
  },
  transport: env.isProduction
    ? undefined
    : { target: 'pino-pretty', options: { colorize: true, translateTime: 'HH:MM:ss' } },
});

module.exports = logger;

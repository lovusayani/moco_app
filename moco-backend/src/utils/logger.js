'use strict';

const pino = require('pino');
const env = require('../config/env');

/**
 * One logger for the whole process. In development it is pretty-printed; in
 * production it stays as JSON lines, which Vercel's runtime logs keep
 * searchable.
 */
const logger = pino({
  level: env.logLevel,
  base: undefined,
  redact: {
    paths: ['req.headers.authorization', 'password', 'otp', '*.otp', 'token'],
    censor: '[redacted]',
  },
  transport: env.isProduction
    ? undefined
    : { target: 'pino-pretty', options: { colorize: true, translateTime: 'HH:MM:ss' } },
});

module.exports = logger;

'use strict';

const pino = require('pino');
const env = require('../config/env');

/**
 * One logger for the whole process. In development it is pretty-printed; on
 * the droplet it stays as JSON lines so PM2's log files remain greppable.
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

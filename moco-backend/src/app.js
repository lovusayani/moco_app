'use strict';

const express = require('express');
const helmet = require('helmet');
const env = require('./config/env');
const logger = require('./utils/logger');
const { errorHandler, notFoundHandler } = require('./middleware/error');
const { RATES, COIN_PACKS, FREE_TRIAL_SECONDS } = require('./utils/constants');

const authRoutes = require('./modules/auth/auth.routes');
const usersRoutes = require('./modules/users/users.routes');
const walletRoutes = require('./modules/wallet/wallet.routes');
const listenersRoutes = require('./modules/listeners/listeners.routes');
const callsRoutes = require('./modules/calls/calls.routes');
const chatRoutes = require('./modules/chat/chat.routes');
const payoutsRoutes = require('./modules/payouts/payouts.routes');
const safetyRoutes = require('./modules/safety/safety.routes');
const adminRoutes = require('./modules/admin/admin.routes');

function createApp() {
  const app = express();

  app.disable('x-powered-by');
  // nginx terminates TLS on the droplet, so trust its X-Forwarded-For or every
  // request will appear to come from 127.0.0.1 and rate limiting will be global.
  app.set('trust proxy', 1);
  app.use(helmet());

  /**
   * Webhook routes are mounted BEFORE the JSON body parser and given a raw
   * parser instead. Signature verification has to run over the exact bytes the
   * sender signed; re-serialising a parsed object changes key order and
   * whitespace and would break every signature.
   */
  app.use('/api/wallet/webhook', express.raw({ type: '*/*', limit: '256kb' }));
  app.use('/api/calls/webhook', express.raw({ type: '*/*', limit: '256kb' }));

  app.use(express.json({ limit: '1mb' }));

  app.get('/health', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

  /** Client bootstrap: rates, packs and enabled languages in one call. */
  app.get('/api/config', (req, res) => {
    res.json({
      rates: {
        audio: RATES.audio.coinsPerMinute,
        video: RATES.video.coinsPerMinute,
      },
      packs: COIN_PACKS,
      freeTrialSeconds: FREE_TRIAL_SECONDS,
      languages: ['en', 'hi', 'te'],
      minAppVersion: process.env.MIN_APP_VERSION || '1.0.0',
    });
  });

  app.use('/api/auth', authRoutes);
  app.use('/api/users', usersRoutes);
  app.use('/api/wallet', walletRoutes);
  app.use('/api/listeners', listenersRoutes);
  app.use('/api/calls', callsRoutes);
  app.use('/api/chat', chatRoutes);
  app.use('/api/payouts', payoutsRoutes);
  app.use('/api/safety', safetyRoutes);
  app.use('/api/admin', adminRoutes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  logger.info({ env: env.nodeEnv }, 'express app built');
  return app;
}

module.exports = { createApp };

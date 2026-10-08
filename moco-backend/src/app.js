'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const express = require('express');
const helmet = require('helmet');
const env = require('./config/env');
const logger = require('./utils/logger');
const { errorHandler, notFoundHandler } = require('./middleware/error');
const { cors } = require('./middleware/cors');
const { RATES, COIN_PACKS, FREE_TRIAL_SECONDS } = require('./utils/constants');
const { DEFAULT_CHANNEL, availability: otpAvailability } = require('./modules/auth/otp.channels');

const { publicConfig: loginBackgroundConfig } = require('./modules/settings/login_background');
const authRoutes = require('./modules/auth/auth.routes');
const usersRoutes = require('./modules/users/users.routes');
const walletRoutes = require('./modules/wallet/wallet.routes');
const listenersRoutes = require('./modules/listeners/listeners.routes');
const callsRoutes = require('./modules/calls/calls.routes');
const chatRoutes = require('./modules/chat/chat.routes');
const feedRoutes = require('./modules/feed/feed.routes');
const notificationsRoutes = require('./modules/notifications/notifications.routes');
const purchasesRoutes = require('./modules/purchases/purchases.routes');
const payoutsRoutes = require('./modules/payouts/payouts.routes');
const safetyRoutes = require('./modules/safety/safety.routes');
const adminRoutes = require('./modules/admin/admin.routes');

function createApp() {
  const app = express();

  app.disable('x-powered-by');
  // Vercel's edge terminates TLS and sets X-Forwarded-For to the client IP
  // (overwriting anything the client sent). Trust that one hop, or every
  // request would share one IP and per-IP rate limits would be global.
  app.set('trust proxy', 1);
  // Before helmet and every route, so preflights are answered and blocked
  // origins never reach a handler.
  app.use(cors);
  // The API is called cross-origin by design (web app, admin console), so its
  // responses must be readable cross-origin; CORS still decides who may.
  app.use(helmet({ crossOriginResourcePolicy: { policy: 'cross-origin' } }));

  /**
   * Webhook routes are mounted BEFORE the JSON body parser and given a raw
   * parser instead. Signature verification has to run over the exact bytes the
   * sender signed; re-serialising a parsed object changes key order and
   * whitespace and would break every signature.
   */
  app.use('/api/wallet/webhook', express.raw({ type: '*/*', limit: '256kb' }));
  app.use('/api/calls/webhook', express.raw({ type: '*/*', limit: '256kb' }));

  app.use(express.json({ limit: '1mb' }));

  /**
   * Local development only: the admin console's static files at /admin, on
   * the API's own origin. In production the console is its own Vercel project
   * (admin.lovcamx.online, built from these same files by admin-web/build.mjs)
   * and calls this API cross-origin, so the API serves no UI there. Every
   * request the console makes is authenticated and re-checked against the
   * admin allow-list server-side either way.
   *
   * Its CSP is the global one plus exactly one origin — this project's
   * Supabase Storage — for img/media, because KYC photos and post previews
   * are short-lived signed URLs on that host.
   */
  if (!env.isProduction) {
    const storageOrigin = (() => {
      try {
        const url = new URL(env.supabaseStorage.url);
        return `${url.protocol}//${url.host}`;
      } catch {
        return null;
      }
    })();
    const adminMediaSrc = ["'self'", 'data:', ...(storageOrigin ? [storageOrigin] : [])];
    // blob: lets the settings page preview a picked file before it is saved.
    const adminPreviewSrc = [...adminMediaSrc, 'blob:'];
    const adminDir = path.join(__dirname, '..', 'public', 'admin');
    // The console page is served with content-hashed asset URLs and no-cache,
    // so after an update a browser always loads a matching admin.js +
    // admin.css pair — never a fresh one next to a stale one from its cache.
    const assetVersion = (file) =>
      crypto.createHash('sha1').update(fs.readFileSync(path.join(adminDir, file))).digest('hex').slice(0, 12);
    const adminIndex = (req, res, next) => {
      const url = req.originalUrl.split('?')[0];
      if (req.method !== 'GET' || (url !== '/admin/' && url !== '/admin/index.html')) return next();
      const html = fs
        .readFileSync(path.join(adminDir, 'index.html'), 'utf8')
        .replace('href="admin.css"', `href="admin.css?v=${assetVersion('admin.css')}"`)
        .replace('src="admin.js"', `src="admin.js?v=${assetVersion('admin.js')}"`);
      return res.set('Cache-Control', 'no-cache').type('html').send(html);
    };
    app.use(
      '/admin',
      helmet.contentSecurityPolicy({
        useDefaults: true,
        // connect-src: the console uploads login-background media straight to
        // Storage with a backend-signed URL.
        directives: { 'img-src': adminPreviewSrc, 'media-src': adminPreviewSrc, 'connect-src': adminMediaSrc },
      }),
      adminIndex,
      express.static(adminDir),
    );
  }

  app.get('/health', (req, res) => res.json({ ok: true, uptime: process.uptime() }));

  /** Client bootstrap: rates, packs and enabled languages in one call. */
  app.get('/api/config', async (req, res) => {
    // Admin-managed login background; null = the app's default. Never fails.
    const loginBackground = await loginBackgroundConfig();
    res.json({
      rates: {
        audio: RATES.audio.coinsPerMinute,
        video: RATES.video.coinsPerMinute,
      },
      packs: COIN_PACKS,
      freeTrialSeconds: FREE_TRIAL_SECONDS,
      languages: ['en', 'hi', 'te'],
      minAppVersion: process.env.MIN_APP_VERSION || '1.0.0',
      // Surfaced so local tooling can show the fixed code. env.otp.fixedCode is
      // null in production, so this never leaks a real OTP.
      devOtp: env.otp.fixedCode,
      // Sign-in methods: email by default; the others are offered only when
      // their provider is configured on this deployment.
      auth: { defaultChannel: DEFAULT_CHANNEL, channels: otpAvailability() },
      loginBackground,
    });
  });

  app.use('/api/auth', authRoutes);
  app.use('/api/users', usersRoutes);
  app.use('/api/wallet', walletRoutes);
  app.use('/api/listeners', listenersRoutes);
  app.use('/api/calls', callsRoutes);
  app.use('/api/chat', chatRoutes);
  app.use('/api/feed', feedRoutes);
  app.use('/api/notifications', notificationsRoutes);
  app.use('/api/purchases', purchasesRoutes);
  app.use('/api/payouts', payoutsRoutes);
  app.use('/api/safety', safetyRoutes);
  app.use('/api/admin', adminRoutes);

  app.use(notFoundHandler);
  app.use(errorHandler);

  logger.info({ env: env.nodeEnv }, 'express app built');
  return app;
}

module.exports = { createApp };

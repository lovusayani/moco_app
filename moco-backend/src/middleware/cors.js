'use strict';

const env = require('../config/env');

/**
 * CORS for the browser clients.
 *
 * Production has three origins: the web app (lovcamx.online, www), the admin
 * console (admin.lovcamx.online) and this API (api.lovcamx.online). Only the
 * allow-listed origins (CORS_ORIGINS) get CORS headers; everyone else's
 * browser blocks the response. There is no "*".
 *
 * Auth is a bearer token in the Authorization header, never a cookie, so
 * credentials are not allowed. That also takes cross-site request forgery off
 * the table: a forged cross-origin request carries no token.
 *
 * Requests without an Origin header (the Android app, payment and Agora
 * webhooks, server-to-server calls) are not CORS requests and pass through
 * untouched.
 */

const LOCALHOST = /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/;

function isAllowedOrigin(origin) {
  if (!origin) return false;
  if (env.cors.origins.includes(origin)) return true;
  // Local development: `flutter run -d chrome` and the admin served by
  // `npm run dev` use localhost on arbitrary ports.
  return !env.isProduction && LOCALHOST.test(origin);
}

const ALLOWED_METHODS = 'GET, POST, PUT, PATCH, DELETE, OPTIONS';
const DEFAULT_HEADERS = 'Authorization, Content-Type, Accept, X-Requested-With';
// Header names only: a browser preflight lists the headers the real request
// will carry. Anything odd is dropped rather than reflected.
const HEADER_NAME = /^[A-Za-z0-9-]+$/;

function cors(req, res, next) {
  const origin = req.headers.origin;

  if (origin && isAllowedOrigin(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Access-Control-Expose-Headers', 'X-RateLimit-Limit, X-RateLimit-Remaining');
  }
  // Responses differ by Origin, so a shared cache must key on it.
  res.vary('Origin');

  if (req.method === 'OPTIONS' && req.headers['access-control-request-method']) {
    if (!origin || !isAllowedOrigin(origin)) {
      return res.status(403).end();
    }
    const requested = String(req.headers['access-control-request-headers'] || '')
      .split(',')
      .map((h) => h.trim())
      .filter((h) => HEADER_NAME.test(h));
    res.setHeader('Access-Control-Allow-Methods', ALLOWED_METHODS);
    res.setHeader('Access-Control-Allow-Headers', requested.length ? requested.join(', ') : DEFAULT_HEADERS);
    res.setHeader('Access-Control-Max-Age', '600');
    res.vary('Access-Control-Request-Headers');
    return res.status(204).end();
  }

  return next();
}

module.exports = { cors, isAllowedOrigin };

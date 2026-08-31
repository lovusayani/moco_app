'use strict';

const jwt = require('jsonwebtoken');
const env = require('../config/env');
const { query } = require('../config/db');
const { unauthorized, forbidden } = require('../utils/errors');
const { USER_STATUS, USER_ROLE } = require('../utils/constants');

function signToken(user) {
  return jwt.sign({ sub: String(user.id), role: user.role }, env.jwt.secret, {
    expiresIn: env.jwt.accessTtl,
  });
}

function verifyToken(token) {
  try {
    return jwt.verify(token, env.jwt.secret);
  } catch {
    throw unauthorized('Invalid or expired token');
  }
}

function bearerFrom(req) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) return null;
  return header.slice('Bearer '.length).trim();
}

/**
 * Authenticates the request and loads the current user row.
 *
 * The row is re-read per request rather than trusted from the token, because a
 * suspended account must lose access immediately — a 30-day token would
 * otherwise keep a banned user calling until it expired.
 */
async function authenticate(req, res, next) {
  try {
    const token = bearerFrom(req);
    if (!token) throw unauthorized();

    const payload = verifyToken(token);
    const { rows } = await query(
      `SELECT u.id, u.phone, u.display_name, u.role, u.status, u.language, u.free_trial_used,
              w.coin_balance
         FROM users u
         LEFT JOIN wallets w ON w.user_id = u.id
        WHERE u.id = $1`,
      [payload.sub],
    );

    const user = rows[0];
    if (!user) throw unauthorized('Account no longer exists');
    if (user.status === USER_STATUS.SUSPENDED) throw forbidden('Account suspended');
    if (user.status === USER_STATUS.DELETED) throw unauthorized('Account deleted');

    req.user = user;
    return next();
  } catch (err) {
    return next(err);
  }
}

/** Requires the caller to be able to act as a listener. */
function requireListener(req, res, next) {
  const role = req.user?.role;
  if (role !== USER_ROLE.LISTENER && role !== USER_ROLE.BOTH) {
    return next(forbidden('Listener mode is not enabled on this account'));
  }
  return next();
}

/**
 * Admin endpoints. Backed by an allow-list of phone numbers in env rather than
 * a role flag, so a compromised user row cannot escalate to admin.
 */
function requireAdmin(req, res, next) {
  const admins = (process.env.ADMIN_PHONES || '').split(',').map((s) => s.trim()).filter(Boolean);
  if (!req.user || !admins.includes(req.user.phone)) {
    return next(forbidden('Admin access required'));
  }
  return next();
}

module.exports = { authenticate, requireListener, requireAdmin, signToken, verifyToken };

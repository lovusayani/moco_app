'use strict';

const crypto = require('crypto');
const { withTransaction, query } = require('../../config/db');
const { redis } = require('../../config/redis');
const env = require('../../config/env');
const { signToken } = require('../../middleware/auth');
const { AppError, badRequest, tooManyRequests, unauthorized } = require('../../utils/errors');
const logger = require('../../utils/logger');
const { CHANNELS } = require('./otp.channels');

/**
 * Sign-in by one-time code, over any channel (email, sms, whatsapp,
 * telegram — see otp.channels.js). One flow for all of them:
 *
 *   sendCode   → one live code per identity (email address or phone number),
 *                delivered by the chosen channel
 *   verifyCode → check it, then find the user by that identity or create one
 *                (with a wallet), and issue the normal Moco JWT
 *
 * Signing in IS registering: there is no separate sign-up, and the response
 * never says whether an account existed, so the endpoints cannot be used to
 * discover who has an account. Role and onboarding (user vs. listener,
 * profile, KYC) happen after sign-in exactly as before.
 *
 * Codes live in Redis with a TTL, never in Postgres, and only as an HMAC —
 * a Redis dump does not hand over live codes. A code is single-use and dies
 * after OTP_MAX_ATTEMPTS wrong guesses.
 */

const keyFor = (identity, value) => `${identity}:${value}`;
const otpKey = (k) => `otp:${k}`;
const attemptsKey = (k) => `otp_attempts:${k}`;
const sendsKey = (k) => `otp_sends:${k}`;
const cooldownKey = (k) => `otp_cooldown:${k}`;

const hashOtp = (k, code) => crypto.createHmac('sha256', env.jwt.secret).update(`${k}:${code}`).digest('hex');

function generateCode() {
  if (env.otp.fixedCode) return env.otp.fixedCode;
  // crypto.randomInt is uniform; Math.random would bias the distribution and
  // is not suitable for anything guarding an account.
  return String(crypto.randomInt(100000, 1000000));
}

function resolve(channel, identifier) {
  const ch = CHANNELS[channel];
  if (!ch) throw badRequest('invalid_channel', 'Choose how to receive your code');
  const value = ch.normalize(identifier);
  if (!value) {
    throw ch.identity === 'email'
      ? badRequest('invalid_email', 'Enter a valid email address')
      : badRequest('invalid_phone', 'Enter a valid mobile number');
  }
  return { ch, identity: ch.identity, value, k: keyFor(ch.identity, value) };
}

async function logEvent({ identity, value, userId = null, event, ip }) {
  await query(`INSERT INTO auth_events (user_id, phone, email, event, ip) VALUES ($1, $2, $3, $4, $5)`, [
    userId,
    identity === 'phone' ? value : null,
    identity === 'email' ? value : null,
    event,
    ip || null,
  ]);
}

/**
 * Sends a sign-in code. Rate-limited per identity (and per IP at the route),
 * so the endpoint cannot be used to spam someone or run up provider costs.
 */
async function sendCode({ channel, identifier, ip }) {
  const { ch, identity, value, k } = resolve(channel, identifier);
  if (!ch.isConfigured()) {
    throw badRequest('channel_unavailable', 'This sign-in method is not available right now');
  }

  // Cooldown between codes to the same identity, across channels.
  const cooldown = env.otp.resendCooldownSeconds;
  const free = await redis.set(cooldownKey(k), '1', 'EX', cooldown, 'NX');
  if (!free) {
    const retryAfter = Math.max(1, await redis.ttl(cooldownKey(k)));
    throw new AppError(429, 'otp_cooldown', `Please wait ${retryAfter}s before requesting another code`, { retryAfter });
  }

  const sends = await redis.incr(sendsKey(k));
  if (sends === 1) await redis.expire(sendsKey(k), 3600);
  if (sends > env.otp.maxSendsPerHour) {
    throw tooManyRequests('Too many codes requested. Please try again later.');
  }

  const code = generateCode();
  const ttl = env.otp.ttlSeconds;
  await redis.setex(otpKey(k), ttl, hashOtp(k, code));
  await redis.del(attemptsKey(k));

  const delivered = await ch.send(value, code, ttl);
  if (!delivered?.ok) {
    // Nothing usable was sent: drop the code and lift the cooldown so the
    // user can retry or pick another method straight away.
    await redis.del(otpKey(k), cooldownKey(k));
    throw new AppError(
      502,
      'otp_delivery_failed',
      identity === 'email' ? 'Unable to send email. Please try again later.' : 'Unable to send the code. Please try again later.',
    );
  }

  await logEvent({ identity, value, event: 'otp_requested', ip });
  logger.info({ channel, identity }, 'otp sent');
  return { sent: true, channel, expiresIn: ttl, resendIn: cooldown };
}

/**
 * Checks a code and signs in — creating the account on first sign-in. The
 * stored hash is deleted as soon as it verifies, so a code is strictly
 * single-use even within its TTL.
 */
async function verifyCode({ channel, identifier, code, ip }) {
  const { identity, value, k } = resolve(channel, identifier);

  const attempts = await redis.incr(attemptsKey(k));
  if (attempts === 1) await redis.expire(attemptsKey(k), env.otp.ttlSeconds);
  if (attempts > env.otp.maxAttempts) {
    await redis.del(otpKey(k));
    throw tooManyRequests('Too many incorrect attempts. Request a new code.');
  }

  const stored = await redis.get(otpKey(k));
  if (!stored) throw badRequest('otp_expired', 'This code has expired. Request a new one.');

  const provided = hashOtp(k, String(code));
  const a = Buffer.from(stored);
  const b = Buffer.from(provided);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    throw unauthorized('Incorrect code');
  }

  await redis.del(otpKey(k), attemptsKey(k));

  const { user, isNew } = await findOrCreateUser({ [identity]: value });
  await logEvent({ identity, value, userId: user.id, event: 'login', ip });
  return { token: signToken(user), user, isNew };
}

/** Backwards compatible: the original phone-only endpoints are SMS codes. */
const requestOtp = ({ phone, ip }) => sendCode({ channel: 'sms', identifier: phone, ip });
const verifyOtp = ({ phone, code, ip }) => verifyCode({ channel: 'sms', identifier: phone, code, ip });

/**
 * Finds the user who owns this verified identity, or creates one with a
 * wallet — an account without a wallet is not a valid state.
 *
 * An identity maps to exactly one account by an exact match on the stored,
 * normalized value. Accounts are never merged by guesswork: a new email is a
 * new account, even if a phone-only account belongs to the same person.
 *
 * Accepts a bare phone string for existing callers.
 */
async function findOrCreateUser(identity) {
  const { phone = null, email = null } = typeof identity === 'string' ? { phone: identity } : identity;
  if (!phone === !email) throw new Error('findOrCreateUser needs exactly one of phone or email');

  return withTransaction(async (client) => {
    const existing = phone
      ? await client.query('SELECT * FROM users WHERE phone = $1', [phone])
      : await client.query('SELECT * FROM users WHERE email = $1', [email]);
    if (existing.rows[0]) return { user: existing.rows[0], isNew: false };

    const { rows } = await client.query(
      `INSERT INTO users (phone, email) VALUES ($1, $2) RETURNING *`,
      [phone, email],
    );
    const user = rows[0];

    await client.query('INSERT INTO wallets (user_id, coin_balance) VALUES ($1, 0)', [user.id]);

    logger.info({ userId: user.id, via: phone ? 'phone' : 'email' }, 'new user registered');
    return { user, isNew: true };
  });
}

module.exports = { sendCode, verifyCode, requestOtp, verifyOtp, findOrCreateUser };

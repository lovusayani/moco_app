'use strict';

const crypto = require('crypto');
const { withTransaction, query } = require('../../config/db');
const { redis } = require('../../config/redis');
const env = require('../../config/env');
const sms = require('../../integrations/sms');
const { signToken } = require('../../middleware/auth');
const { badRequest, tooManyRequests, unauthorized } = require('../../utils/errors');
const logger = require('../../utils/logger');

/**
 * Phone + OTP authentication.
 *
 * OTPs live in Redis with a TTL, never in Postgres — they are short-lived
 * secrets and there is no reason to persist them. Only a hash is stored, so a
 * dump of Redis does not hand over live codes.
 */

const otpKey = (phone) => `otp:${phone}`;
const attemptsKey = (phone) => `otp_attempts:${phone}`;
const requestKey = (phone) => `otp_requests:${phone}`;

const hashOtp = (phone, code) =>
  crypto.createHmac('sha256', env.jwt.secret).update(`${phone}:${code}`).digest('hex');

function generateCode() {
  if (env.otp.fixedCode) return env.otp.fixedCode;
  // crypto.randomInt is uniform; Math.random would bias the distribution and
  // is not suitable for anything guarding an account.
  return String(crypto.randomInt(100000, 1000000));
}

/**
 * Sends an OTP, rate-limited per phone number so the endpoint cannot be used
 * to bill us for SMS or to spam someone else's phone.
 */
async function requestOtp({ phone, ip }) {
  const requests = await redis.incr(requestKey(phone));
  if (requests === 1) await redis.expire(requestKey(phone), 3600);
  if (requests > 5) throw tooManyRequests('Too many OTP requests. Try again later.');

  const code = generateCode();
  await redis.setex(otpKey(phone), env.otp.ttlSeconds, hashOtp(phone, code));
  await redis.del(attemptsKey(phone));

  await sms.sendOtp(phone, code);
  await query(`INSERT INTO auth_events (phone, event, ip) VALUES ($1, 'otp_requested', $2)`, [
    phone,
    ip || null,
  ]);

  logger.info({ phone }, 'otp requested');
  return { sent: true, expiresIn: env.otp.ttlSeconds };
}

/**
 * Verifies an OTP and returns a token, creating the account on first login.
 *
 * The stored hash is deleted as soon as it verifies, so a code is strictly
 * single-use even within its TTL.
 */
async function verifyOtp({ phone, code, ip }) {
  const attempts = await redis.incr(attemptsKey(phone));
  if (attempts === 1) await redis.expire(attemptsKey(phone), env.otp.ttlSeconds);
  if (attempts > env.otp.maxAttempts) {
    await redis.del(otpKey(phone));
    throw tooManyRequests('Too many incorrect attempts. Request a new code.');
  }

  const stored = await redis.get(otpKey(phone));
  if (!stored) throw badRequest('otp_expired', 'This code has expired. Request a new one.');

  const provided = hashOtp(phone, code);
  const a = Buffer.from(stored);
  const b = Buffer.from(provided);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    throw unauthorized('Incorrect code');
  }

  await redis.del(otpKey(phone), attemptsKey(phone));

  const { user, isNew } = await findOrCreateUser(phone);

  await query(
    `INSERT INTO auth_events (user_id, phone, event, ip) VALUES ($1, $2, 'login', $3)`,
    [user.id, phone, ip || null],
  );

  return { token: signToken(user), user, isNew };
}

/** Creates the user and their wallet together — an account without a wallet is not a valid state. */
async function findOrCreateUser(phone) {
  return withTransaction(async (client) => {
    const existing = await client.query('SELECT * FROM users WHERE phone = $1', [phone]);
    if (existing.rows[0]) return { user: existing.rows[0], isNew: false };

    const { rows } = await client.query(
      `INSERT INTO users (phone) VALUES ($1) RETURNING *`,
      [phone],
    );
    const user = rows[0];

    await client.query('INSERT INTO wallets (user_id, coin_balance) VALUES ($1, 0)', [user.id]);

    logger.info({ userId: user.id }, 'new user registered');
    return { user, isNew: true };
  });
}

module.exports = { requestOtp, verifyOtp, findOrCreateUser };

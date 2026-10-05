'use strict';

const crypto = require('crypto');
const { withTransaction, query } = require('../../config/db');
const { redis } = require('../../config/redis');
const env = require('../../config/env');
const sms = require('../../integrations/sms');
const whatsapp = require('../../integrations/whatsapp');
const { signToken } = require('../../middleware/auth');
const { AppError, badRequest, tooManyRequests, unauthorized } = require('../../utils/errors');
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
const whatsappRequestKey = (phone) => `otp_wa_requests:${phone}`;
const cooldownKey = (phone) => `otp_cooldown:${phone}`;

/** Delivery channels for the same Moco OTP. SMS is primary, WhatsApp the fallback. */
const CHANNELS = Object.freeze({ SMS: 'sms', WHATSAPP: 'whatsapp' });

/** Which channels can deliver a code right now — shown to the client. */
const availableChannels = () => ({ sms: true, whatsapp: whatsapp.isAvailable() });

const hashOtp = (phone, code) =>
  crypto.createHmac('sha256', env.jwt.secret).update(`${phone}:${code}`).digest('hex');

function generateCode() {
  if (env.otp.fixedCode) return env.otp.fixedCode;
  // crypto.randomInt is uniform; Math.random would bias the distribution and
  // is not suitable for anything guarding an account.
  return String(crypto.randomInt(100000, 1000000));
}

/**
 * Issues a login code for `phone` and delivers it on `channel`.
 *
 * There is ONE live code per phone, whatever the channel: asking for the
 * WhatsApp fallback replaces the SMS code (the SMS one stops working), and
 * both are checked by the same verifyOtp — which is what keeps SMS and
 * WhatsApp from ever creating competing logins or accounts.
 *
 * Limits, all per phone and Redis-backed: a resend cooldown across channels,
 * the hourly cap across channels, and a tighter hourly cap for WhatsApp.
 * A delivery failure lifts the cooldown so the other channel can be offered
 * at once, and is reported as a typed error (never the provider's own text).
 */
async function requestOtp({ phone, ip, channel = CHANNELS.SMS }) {
  if (channel === CHANNELS.WHATSAPP && !whatsapp.isAvailable()) {
    throw badRequest('whatsapp_unavailable', 'WhatsApp codes are not available right now.');
  }

  // Atomic: only one send per cooldown window, on any channel.
  const free = await redis.set(cooldownKey(phone), channel, 'EX', env.otp.resendCooldownSeconds, 'NX');
  if (!free) {
    const retryAfter = Math.max(1, await redis.ttl(cooldownKey(phone)));
    throw new AppError(429, 'otp_cooldown', `Please wait ${retryAfter}s before requesting another code.`, { retryAfter });
  }

  const requests = await redis.incr(requestKey(phone));
  if (requests === 1) await redis.expire(requestKey(phone), 3600);
  if (requests > env.otp.maxRequestsPerHour) throw tooManyRequests('Too many OTP requests. Try again later.');

  if (channel === CHANNELS.WHATSAPP) {
    const waRequests = await redis.incr(whatsappRequestKey(phone));
    if (waRequests === 1) await redis.expire(whatsappRequestKey(phone), 3600);
    if (waRequests > env.otp.maxWhatsappPerHour) {
      throw new AppError(429, 'whatsapp_limit', 'Too many WhatsApp codes requested. Try again later.');
    }
  }

  const code = generateCode();
  await redis.setex(otpKey(phone), env.otp.ttlSeconds, hashOtp(phone, code));
  await redis.del(attemptsKey(phone));

  const result =
    channel === CHANNELS.WHATSAPP ? await whatsapp.sendAuthCode(phone, code) : await sms.sendOtp(phone, code);
  if (!result.ok) {
    // Not delivered: drop the undeliverable code and the cooldown, so the
    // fallback channel can be used straight away.
    await redis.del(otpKey(phone), cooldownKey(phone));
    await query('INSERT INTO auth_events (phone, event, ip) VALUES ($1, $2, $3)', [
      phone,
      channel === CHANNELS.WHATSAPP ? 'otp_send_failed_wa' : 'otp_send_failed_sms',
      ip || null,
    ]);
    if (channel === CHANNELS.WHATSAPP) {
      throw new AppError(502, 'whatsapp_delivery_failed', 'We could not send a WhatsApp message to this number.', {
        reason: result.reason === 'recipient_unreachable' ? 'not_on_whatsapp' : 'unavailable',
      });
    }
    throw new AppError(502, 'sms_delivery_failed', 'We could not send an SMS to this number.', {
      fallbackChannels: whatsapp.isAvailable() ? [CHANNELS.WHATSAPP] : [],
    });
  }

  await query('INSERT INTO auth_events (phone, event, ip) VALUES ($1, $2, $3)', [
    phone,
    channel === CHANNELS.WHATSAPP ? 'otp_requested_wa' : 'otp_requested',
    ip || null,
  ]);

  logger.info({ phone: whatsapp.maskPhone(phone), channel }, 'otp requested');
  return {
    sent: true,
    channel,
    expiresIn: env.otp.ttlSeconds,
    resendIn: env.otp.resendCooldownSeconds,
    // The client offers these under "Didn't receive the code?".
    fallbackChannels: channel === CHANNELS.SMS && whatsapp.isAvailable() ? [CHANNELS.WHATSAPP] : [],
  };
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

  await redis.del(otpKey(phone), attemptsKey(phone), cooldownKey(phone));

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

module.exports = { requestOtp, verifyOtp, findOrCreateUser, availableChannels, CHANNELS };

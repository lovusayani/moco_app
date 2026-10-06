'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * OTP delivery over Telegram — the Telegram Gateway API
 * (core.telegram.org/gateway).
 *
 * The ordinary Bot API cannot message someone who has not started the bot,
 * so it cannot deliver sign-in codes to a phone number. Telegram's Gateway is
 * the official service for exactly this: it sends a verification code to the
 * Telegram account registered to an E.164 phone number. We pass our own code
 * (4–8 digits) and TTL, so verification stays in the same backend flow as
 * every other channel.
 *
 * Configured by TELEGRAM_GATEWAY_TOKEN (gateway.telegram.org account, paid
 * per delivered code). Unconfigured = the channel is not offered.
 */

const GATEWAY_URL = 'https://gatewayapi.telegram.org/sendVerificationMessage';

function isConfigured() {
  return Boolean(env.telegram.gatewayToken);
}

const maskPhone = (phone) => `${String(phone).slice(0, 4)}****${String(phone).slice(-2)}`;

async function sendOtp(phone, code, ttlSeconds) {
  if (!isConfigured()) return { ok: false, reason: 'not_configured' };
  try {
    const response = await fetch(GATEWAY_URL, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.telegram.gatewayToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        phone_number: phone,
        code,
        // The Gateway accepts 30..3600 seconds.
        ttl: Math.min(3600, Math.max(30, ttlSeconds)),
      }),
      signal: AbortSignal.timeout(10_000),
    });
    const body = await response.json().catch(() => null);
    if (!response.ok || !body?.ok) {
      // e.g. PHONE_NUMBER_NOT_FOUND when the number has no Telegram account.
      logger.error({ status: response.status, error: body?.error, to: maskPhone(phone) }, 'telegram OTP send failed');
      return { ok: false, reason: 'provider_error' };
    }
    return { ok: true };
  } catch (err) {
    logger.error({ err: { name: err?.name }, to: maskPhone(phone) }, 'telegram OTP send errored');
    return { ok: false, reason: 'provider_error' };
  }
}

module.exports = { sendOtp, isConfigured };

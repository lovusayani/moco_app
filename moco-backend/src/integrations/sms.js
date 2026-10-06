'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * OTP delivery by SMS. Provider-agnostic behind one function so swapping MSG91
 * for another Indian gateway is a config change.
 *
 * The 'log' provider prints the OTP instead of sending it, which is how local
 * development and emulator QA sign in without spending SMS credits. It never
 * runs in production: the code would land in the runtime logs, where anyone
 * with log access could sign in as anyone.
 */

function isConfigured() {
  if (env.sms.provider === 'log') return !env.isProduction;
  if (env.sms.provider === 'msg91') return Boolean(env.sms.apiKey);
  return false;
}

async function sendOtp(phone, code) {
  if (env.sms.provider === 'log') {
    if (env.isProduction) {
      logger.error('SMS_PROVIDER=log refused in production; no code was sent');
      return { ok: false, reason: 'not_configured' };
    }
    logger.info({ phone }, `[dev] OTP for ${phone} is ${code}`);
    return { ok: true, provider: 'log' };
  }

  if (env.sms.provider === 'msg91' && isConfigured()) {
    try {
      const response = await fetch('https://control.msg91.com/api/v5/otp', {
        method: 'POST',
        headers: { authkey: env.sms.apiKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          mobile: phone.replace('+', ''),
          otp: code,
          sender: env.sms.senderId,
        }),
        signal: AbortSignal.timeout(10_000),
      });
      if (!response.ok) {
        logger.error({ status: response.status }, 'sms send failed');
        return { ok: false, reason: 'provider_error' };
      }
      return { ok: true, provider: 'msg91' };
    } catch (err) {
      logger.error({ err: { name: err?.name } }, 'sms provider errored');
      return { ok: false, reason: 'provider_error' };
    }
  }

  logger.error({ provider: env.sms.provider }, 'sms provider not configured');
  return { ok: false, reason: 'not_configured' };
}

module.exports = { sendOtp, isConfigured };

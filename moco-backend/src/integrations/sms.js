'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * OTP delivery. Provider-agnostic behind one function so swapping MSG91 for
 * another Indian gateway is a config change.
 *
 * The 'log' provider prints the OTP instead of sending it, which is how local
 * development and emulator QA sign in without spending SMS credits.
 */
async function sendOtp(phone, code) {
  if (env.sms.provider === 'log') {
    logger.info({ phone }, `[dev] OTP for ${phone} is ${code}`);
    return { ok: true, provider: 'log' };
  }

  if (env.sms.provider === 'msg91') {
    try {
      const response = await fetch('https://control.msg91.com/api/v5/otp', {
        method: 'POST',
        headers: { authkey: env.sms.apiKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          mobile: phone.replace('+', ''),
          otp: code,
          sender: env.sms.senderId,
        }),
      });
      if (!response.ok) {
        logger.error({ status: response.status }, 'sms send failed');
        return { ok: false };
      }
      return { ok: true, provider: 'msg91' };
    } catch (err) {
      logger.error({ err }, 'sms provider errored');
      return { ok: false };
    }
  }

  logger.error({ provider: env.sms.provider }, 'unknown sms provider');
  return { ok: false };
}

module.exports = { sendOtp };

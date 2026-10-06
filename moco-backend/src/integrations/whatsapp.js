'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * OTP delivery over WhatsApp — WhatsApp Cloud API, Authentication template.
 *
 * Meta only allows a business to start a conversation with an approved
 * template; for sign-in codes that is an "Authentication" category template
 * whose body is "{{1}} is your verification code" plus a copy-code button.
 * Both take the code as their parameter.
 *
 * Configured by WHATSAPP_ACCESS_TOKEN, WHATSAPP_PHONE_NUMBER_ID and
 * WHATSAPP_OTP_TEMPLATE (+ _LANGUAGE). Unconfigured = the channel is not
 * offered. Never logs the code, the token or a full phone number.
 */

function isConfigured() {
  const w = env.whatsapp;
  return Boolean(w.accessToken && w.phoneNumberId && w.templateName);
}

const maskPhone = (phone) => `${String(phone).slice(0, 4)}****${String(phone).slice(-2)}`;

/** The Cloud API request body for an Authentication template. */
function templatePayload(phone, code) {
  return {
    messaging_product: 'whatsapp',
    to: phone.replace('+', ''),
    type: 'template',
    template: {
      name: env.whatsapp.templateName,
      language: { code: env.whatsapp.templateLanguage },
      components: [
        { type: 'body', parameters: [{ type: 'text', text: code }] },
        { type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: code }] },
      ],
    },
  };
}

async function sendOtp(phone, code) {
  if (!isConfigured()) return { ok: false, reason: 'not_configured' };
  const { graphVersion, phoneNumberId, accessToken } = env.whatsapp;
  try {
    const response = await fetch(`https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(templatePayload(phone, code)),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) {
      logger.error({ status: response.status, to: maskPhone(phone) }, 'whatsapp OTP send failed');
      return { ok: false, reason: 'provider_error' };
    }
    return { ok: true };
  } catch (err) {
    logger.error({ err: { name: err?.name }, to: maskPhone(phone) }, 'whatsapp OTP send errored');
    return { ok: false, reason: 'provider_error' };
  }
}

module.exports = { sendOtp, isConfigured, templatePayload };

'use strict';

const crypto = require('crypto');
const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * WhatsApp Cloud API (Meta Graph API) — the fallback OTP delivery channel.
 *
 * Sends ONLY the approved Authentication template (category AUTHENTICATION),
 * whose body Meta fixes as "<code> is your verification code…" — never a
 * free-form message. The code goes in the body parameter and, for a template
 * with a copy-code/one-tap button, in the button parameter too (Meta
 * requires both).
 *
 * Never logs the code, the access token or a full phone number. Errors are
 * reduced to a small set of reasons the auth service can act on.
 */

const isConfigured = () =>
  Boolean(env.whatsapp.accessToken && env.whatsapp.phoneNumberId && env.whatsapp.templateName);

/** Available for login: configured for real, or dev-logging outside production. */
const isAvailable = () => isConfigured() || env.whatsapp.devLog;

/** "+919876543210" → "+91******3210" — enough to correlate, not to identify. */
const maskPhone = (phone) => String(phone).replace(/^(\+\d{2})\d+(\d{4})$/, '$1******$2');

/**
 * Meta error codes worth distinguishing. Everything else is "provider_error".
 * https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes
 */
function classifyError(status, error) {
  const code = Number(error?.code);
  if (status === 401 || code === 190) return 'auth_failed'; // token invalid/expired
  if ([131030, 131026, 131047, 131051].includes(code)) return 'recipient_unreachable';
  if ([132000, 132001, 132005, 132007, 132012, 132015, 132016].includes(code)) return 'template_invalid';
  if ([4, 80007, 130429, 131048, 131056].includes(code)) return 'rate_limited';
  if ([131042, 131031].includes(code)) return 'account_blocked'; // payment / account issue
  return 'provider_error';
}

/**
 * Sends `code` to `phone` (E.164) as the authentication template.
 * Resolves { ok: true, messageId } or { ok: false, reason }.
 */
async function sendAuthCode(phone, code) {
  if (!isConfigured()) {
    if (env.whatsapp.devLog) {
      // Non-production only (env forces devLog off in production).
      logger.info({ phone: maskPhone(phone) }, `[dev] WhatsApp OTP for ${phone} is ${code}`);
      return { ok: true, messageId: 'dev-log' };
    }
    return { ok: false, reason: 'not_configured' };
  }

  const { graphVersion, phoneNumberId, accessToken, templateName, templateLanguage, templateHasCodeButton } =
    env.whatsapp;
  const components = [{ type: 'body', parameters: [{ type: 'text', text: code }] }];
  if (templateHasCodeButton) {
    components.push({ type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: code }] });
  }

  let response;
  let body = {};
  try {
    response = await fetch(`https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        recipient_type: 'individual',
        to: phone.replace(/^\+/, ''),
        type: 'template',
        template: { name: templateName, language: { code: templateLanguage }, components },
      }),
      signal: AbortSignal.timeout(10000),
    });
    body = await response.json().catch(() => ({}));
  } catch (err) {
    logger.error({ phone: maskPhone(phone), err: err.name }, 'whatsapp send failed: network');
    return { ok: false, reason: 'unreachable' };
  }

  if (!response.ok) {
    const reason = classifyError(response.status, body.error);
    // Meta's error code/subcode only — the request (which holds the code)
    // and the token are never logged.
    logger.error(
      { phone: maskPhone(phone), status: response.status, metaCode: body.error?.code, metaSubcode: body.error?.error_subcode, reason },
      'whatsapp send failed',
    );
    return { ok: false, reason };
  }

  const messageId = body.messages?.[0]?.id ?? null;
  logger.info({ phone: maskPhone(phone), messageId }, 'whatsapp otp sent');
  return { ok: true, messageId };
}

/**
 * Verifies a webhook POST: Meta signs the raw body with the app secret
 * (X-Hub-Signature-256: sha256=<hex>). Constant-time comparison.
 */
function verifySignature(rawBody, header) {
  if (!env.whatsapp.appSecret || !header || !Buffer.isBuffer(rawBody)) return false;
  const expected = `sha256=${crypto.createHmac('sha256', env.whatsapp.appSecret).update(rawBody).digest('hex')}`;
  const a = Buffer.from(expected);
  const b = Buffer.from(String(header));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

module.exports = { isConfigured, isAvailable, sendAuthCode, verifySignature, maskPhone, classifyError };

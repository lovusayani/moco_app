'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * Transactional email — today only the sign-in code.
 *
 * Providers (EMAIL_PROVIDER):
 *   resend — Resend's HTTP API (production). Needs RESEND_API_KEY and an
 *            EMAIL_FROM on a domain verified in Resend.
 *   log    — prints the code instead of sending it. Local development only;
 *            refused in production, where the code would land in the logs.
 *
 * Never logs the code, and never logs a full address.
 */

const RESEND_URL = 'https://api.resend.com/emails';

function isConfigured() {
  if (env.email.provider === 'log') return !env.isProduction;
  if (env.email.provider === 'resend') return Boolean(env.email.resendApiKey && env.email.from);
  return false;
}

/** a***@example.com — enough to correlate a log line, not enough to identify. */
function maskEmail(email) {
  const [local, domain] = String(email).split('@');
  return `${(local || '').slice(0, 1)}***@${domain || ''}`;
}

const escapeHtml = (value) =>
  String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/**
 * The sign-in code email. Plain, mobile-friendly, no tracking, no personal
 * data beyond the code itself.
 */
function otpEmail(code, ttlSeconds) {
  const minutes = Math.max(1, Math.round(ttlSeconds / 60));
  const safeCode = escapeHtml(code);
  const subject = `${code} is your Moco verification code`;
  const text = [
    'Moco',
    '',
    'Your verification code is:',
    '',
    code,
    '',
    `This code expires in ${minutes} minute${minutes === 1 ? '' : 's'}.`,
    '',
    'If you did not request this code, you can ignore this email.',
  ].join('\n');
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Your Moco verification code</title>
</head>
<body style="margin:0;padding:0;background:#f4f1f4;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f1f4;padding:32px 16px;">
<tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:440px;background:#ffffff;border-radius:16px;padding:32px 28px;">
<tr><td style="font-size:22px;font-weight:700;color:#e54f9a;letter-spacing:-0.3px;">Moco</td></tr>
<tr><td style="padding-top:20px;font-size:16px;color:#2b1d2b;">Your verification code is:</td></tr>
<tr><td style="padding:16px 0 8px;">
<div style="display:inline-block;font-size:34px;font-weight:700;letter-spacing:10px;color:#120a12;background:#f7eef4;border-radius:12px;padding:14px 20px;font-family:'SFMono-Regular',Menlo,Consolas,monospace;">${safeCode}</div>
</td></tr>
<tr><td style="padding-top:12px;font-size:14px;color:#5c4a5c;">This code expires in ${minutes} minute${minutes === 1 ? '' : 's'}.</td></tr>
<tr><td style="padding-top:20px;font-size:13px;color:#8a788a;line-height:1.5;">If you did not request this code, you can ignore this email.</td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
  return { subject, text, html };
}

/**
 * Sends the sign-in code. Returns { ok: true } or { ok: false, reason }.
 * Reasons are coarse on purpose; callers turn them into one generic message.
 */
async function sendOtp(email, code, ttlSeconds) {
  if (env.email.provider === 'log') {
    if (env.isProduction) {
      logger.error('EMAIL_PROVIDER=log refused in production; no code was sent');
      return { ok: false, reason: 'not_configured' };
    }
    logger.info({ to: maskEmail(email) }, `[dev] email OTP for ${email} is ${code}`);
    return { ok: true };
  }

  if (env.email.provider !== 'resend' || !isConfigured()) {
    return { ok: false, reason: 'not_configured' };
  }

  const { subject, text, html } = otpEmail(code, ttlSeconds);
  try {
    const response = await fetch(RESEND_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.email.resendApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ from: env.email.from, to: [email], subject, text, html }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) {
      // The body can echo request fields; log only the status.
      logger.error({ status: response.status, to: maskEmail(email) }, 'email OTP send failed');
      return { ok: false, reason: response.status === 429 ? 'rate_limited' : 'provider_error' };
    }
    return { ok: true };
  } catch (err) {
    logger.error({ err: { name: err?.name }, to: maskEmail(email) }, 'email OTP send errored');
    return { ok: false, reason: 'provider_error' };
  }
}

module.exports = { sendOtp, isConfigured, otpEmail, maskEmail };

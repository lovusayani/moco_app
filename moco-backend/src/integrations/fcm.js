'use strict';

const crypto = require('crypto');
const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * Push notifications through Firebase Cloud Messaging, HTTP v1 API.
 *
 * Used for incoming-call alerts when the callee's socket is not connected,
 * for payout status changes, and for the admin console's test push.
 *
 * Auth is the Firebase project's service account (FCM_SERVICE_ACCOUNT_JSON on
 * moco-api only): its key signs a JWT that is exchanged for a short-lived
 * OAuth2 access token. The key never leaves this process and is never logged.
 * (The legacy `fcm/send` endpoint and its server key were shut down by Google
 * in 2024.)
 *
 * Every message carries a `notification` block, so Android shows it in the
 * tray while the app is in the background or not running at all, plus string
 * `data` the app uses to open the right screen when it is tapped. In the
 * foreground the app shows the notification itself.
 */

const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

/** Android notification channels; the app creates the same ids. */
const CHANNELS = Object.freeze({ calls: 'moco_calls', general: 'moco_general' });

let credentials;
function serviceAccount() {
  if (credentials !== undefined) return credentials;
  credentials = null;
  const raw = env.fcm.serviceAccountJson.trim();
  if (!raw) return credentials;
  try {
    // Accept the downloaded JSON as-is, or base64 of it (easier to paste).
    const json = raw.startsWith('{') ? raw : Buffer.from(raw, 'base64').toString('utf8');
    const parsed = JSON.parse(json);
    if (parsed.project_id && parsed.client_email && parsed.private_key) {
      credentials = {
        projectId: parsed.project_id,
        clientEmail: parsed.client_email,
        privateKey: parsed.private_key,
      };
    } else {
      logger.error('FCM_SERVICE_ACCOUNT_JSON is missing project_id, client_email or private_key');
    }
  } catch {
    logger.error('FCM_SERVICE_ACCOUNT_JSON is not valid JSON');
  }
  return credentials;
}

const isConfigured = () => Boolean(serviceAccount());

let cachedAccessToken = null;
let cachedAccessTokenExpiresAt = 0;

/** OAuth2 access token via a JWT bearer grant (RFC 7523), cached until shortly before expiry. */
async function getAccessToken() {
  if (cachedAccessToken && Date.now() < cachedAccessTokenExpiresAt) return cachedAccessToken;

  const sa = serviceAccount();
  const now = Math.floor(Date.now() / 1000);
  const encode = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const unsigned = `${encode({ alg: 'RS256', typ: 'JWT' })}.${encode({
    iss: sa.clientEmail,
    scope: SCOPE,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  })}`;
  const signature = crypto.sign('RSA-SHA256', Buffer.from(unsigned), sa.privateKey);

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${signature.toString('base64url')}`,
    }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    logger.error({ status: response.status }, 'fcm token exchange failed');
    throw new Error('fcm_auth_failed');
  }
  const body = await response.json();
  cachedAccessToken = body.access_token;
  cachedAccessTokenExpiresAt = Date.now() + (body.expires_in - 60) * 1000;
  return cachedAccessToken;
}

/** FCM data values must all be strings. */
function stringData(data) {
  const out = {};
  for (const [key, value] of Object.entries(data || {})) {
    if (value !== undefined && value !== null) out[key] = String(value);
  }
  return out;
}

/** The v1 request body for one device. Exported for tests. */
function buildMessage({ token, title, body, data = {}, highPriority = false }) {
  return {
    message: {
      token,
      notification: { title, body },
      data: stringData({ title, body, ...data }),
      android: {
        priority: highPriority ? 'HIGH' : 'NORMAL',
        // An unanswered call is stale after a minute; other notices keep for a day.
        ttl: highPriority ? '60s' : '86400s',
        notification: {
          channel_id: highPriority ? CHANNELS.calls : CHANNELS.general,
        },
      },
    },
  };
}

/**
 * Sends one push. Resolves `{ ok, reason?, retryable? }` and never throws.
 *
 * `reason: 'unregistered'` means FCM says the token is dead (the app was
 * uninstalled or the token rotated); the caller should forget it.
 */
async function send({ token, title, body, data = {}, highPriority = false }) {
  if (!token) return { ok: false, reason: 'no_token' };

  if (!isConfigured()) {
    if (env.isProduction) {
      logger.error({ type: data.type }, 'push not sent — FCM_SERVICE_ACCOUNT_JSON is not configured');
      return { ok: false, reason: 'not_configured' };
    }
    logger.info({ title, data }, '[dev] push suppressed — FCM not configured');
    return { ok: true, skipped: true };
  }

  try {
    const accessToken = await getAccessToken();
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(serviceAccount().projectId)}/messages:send`,
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(buildMessage({ token, title, body, data, highPriority })),
        signal: AbortSignal.timeout(10_000),
      },
    );
    if (response.ok) return { ok: true };

    let fcmStatus = '';
    try {
      const payload = await response.json();
      fcmStatus =
        payload?.error?.details?.find((d) => d.errorCode)?.errorCode || payload?.error?.status || '';
    } catch {
      // Body is not JSON; the HTTP status is enough.
    }
    // 404 / UNREGISTERED: the app instance is gone. INVALID_ARGUMENT on a body
    // we built ourselves means the token itself is malformed.
    if (response.status === 404 || fcmStatus === 'UNREGISTERED' || fcmStatus === 'INVALID_ARGUMENT') {
      logger.info({ status: response.status, fcmStatus }, 'fcm token is no longer valid');
      return { ok: false, reason: 'unregistered' };
    }
    if (response.status === 401) cachedAccessToken = null;
    logger.error({ status: response.status, fcmStatus }, 'fcm send failed');
    return { ok: false, reason: 'failed', retryable: response.status === 429 || response.status >= 500 };
  } catch (err) {
    logger.error({ err: { name: err.name, message: err.message } }, 'fcm errored');
    return { ok: false, reason: 'failed', retryable: true };
  }
}

/** Test hook: forget cached credentials and access token. */
function resetForTests() {
  credentials = undefined;
  cachedAccessToken = null;
  cachedAccessTokenExpiresAt = 0;
}

module.exports = { send, isConfigured, buildMessage, CHANNELS, resetForTests };

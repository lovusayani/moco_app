'use strict';

const crypto = require('crypto');
const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * Google Play Developer API purchase verification.
 *
 * This is the ONLY code path allowed to say a Google Play purchase happened.
 * A client's purchase token is never trusted on its own — it proves the
 * client attempted a purchase, not that Google settled it — so every coin
 * credit for a real purchase must pass through here.
 *
 * NOT LIVE-VERIFIED: this environment has no Play Console service account
 * (`GOOGLE_PLAY_PACKAGE_NAME` / `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` are
 * unset), so the real Play API call below has never actually run against
 * Google. The integration boundary, the request shape, and everything
 * downstream of a verified purchase (idempotent credit, ledger, transaction)
 * are complete and tested against a mock verifier — see
 * tests/purchases.test.js. Only the live HTTP call to Google is unverified.
 * Do not represent Google Play billing as "done" until that call has been
 * exercised against a real Play Console test purchase.
 */

const isConfigured = () =>
  Boolean(env.googlePlay.packageName && env.googlePlay.serviceAccountJson);

/**
 * Purchase states the Play API returns for a `products.get` call.
 * 0 = purchased, 1 = cancelled, 2 = pending.
 */
const PURCHASE_STATE = Object.freeze({ PURCHASED: 0, CANCELLED: 1, PENDING: 2 });

let cachedAccessToken = null;
let cachedAccessTokenExpiresAt = 0;

/**
 * Exchanges the service account key for a short-lived OAuth2 access token via
 * a JWT bearer grant (RFC 7523) — the standard server-to-server auth flow for
 * the Play Developer API. Cached until shortly before expiry so a burst of
 * purchases does not mint a fresh token per request.
 */
async function getAccessToken() {
  if (cachedAccessToken && Date.now() < cachedAccessTokenExpiresAt) {
    return cachedAccessToken;
  }

  const credentials = JSON.parse(env.googlePlay.serviceAccountJson);
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: credentials.client_email,
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  };

  const encode = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const unsigned = `${encode(header)}.${encode(claims)}`;
  const signature = crypto.sign('RSA-SHA256', Buffer.from(unsigned), credentials.private_key);
  const assertion = `${unsigned}.${signature.toString('base64url')}`;

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });

  if (!response.ok) {
    logger.error({ status: response.status }, 'google play token exchange failed');
    throw new Error('google_play_auth_failed');
  }

  const body = await response.json();
  cachedAccessToken = body.access_token;
  // Refresh a minute early rather than racing the actual expiry.
  cachedAccessTokenExpiresAt = Date.now() + (body.expires_in - 60) * 1000;
  return cachedAccessToken;
}

/**
 * Verifies one purchase token against Google's own records.
 *
 * Throws `google_play_not_configured` (never a fabricated success) when no
 * service account is set up, so a misconfigured production deployment fails
 * loudly rather than silently crediting unverified coins.
 *
 * Returns `{ valid, purchaseState, orderId, consumed }` on a real answer from
 * Google. `valid` is true only for `PURCHASED` and not yet consumed —
 * everything else (cancelled, pending, or already consumed by an earlier
 * verify) is `valid: false` with a reason, never treated as a purchase.
 */
async function verifyPurchase({ productId, purchaseToken }) {
  if (!isConfigured()) {
    const err = new Error('Google Play verification is not configured');
    err.code = 'google_play_not_configured';
    throw err;
  }

  const accessToken = await getAccessToken();
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/` +
    `${encodeURIComponent(env.googlePlay.packageName)}/purchases/products/` +
    `${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`;

  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (response.status === 404 || response.status === 400) {
    // Google has no record of this token — an invalid or forged token reads
    // this way, not as a server error.
    return { valid: false, reason: 'not_found' };
  }
  if (!response.ok) {
    logger.error({ status: response.status, productId }, 'google play verify failed');
    throw new Error('google_play_verify_failed');
  }

  const body = await response.json();
  const purchaseState = body.purchaseState;
  // consumptionState: 0 = yet to be consumed, 1 = consumed. A consumable
  // that Google already marked consumed must not be credited a second time
  // purely from its Play-side state — the purchases table's own unique
  // constraint is still the real idempotency guarantee (see purchases
  // .service.js), this is a second, independent check.
  const alreadyConsumed = body.consumptionState === 1;

  return {
    valid: purchaseState === PURCHASE_STATE.PURCHASED && !alreadyConsumed,
    reason:
      purchaseState !== PURCHASE_STATE.PURCHASED
        ? 'not_purchased'
        : alreadyConsumed
          ? 'already_consumed'
          : null,
    purchaseState,
    orderId: body.orderId ?? null,
  };
}

module.exports = { isConfigured, verifyPurchase, PURCHASE_STATE };

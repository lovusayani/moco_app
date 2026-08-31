'use strict';

const crypto = require('crypto');
const { RtcTokenBuilder, RtcRole } = require('agora-token');
const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * Agora RTC integration.
 *
 * Tokens are minted per user per channel and are short-lived. The uid embedded
 * in the token is the Moco user id, which is what lets the server tie an Agora
 * webhook back to a call without trusting anything the client sends.
 */

/** Channel names must be unique and unguessable so nobody can join a stranger's call. */
function buildChannelName(callId) {
  return `moco_${callId}_${crypto.randomBytes(6).toString('hex')}`;
}

function buildRtcToken({ channelName, uid, role = 'publisher', ttlSeconds }) {
  if (!env.agora.appId || !env.agora.appCertificate) {
    // Local development without Agora credentials still needs call flows to
    // work end-to-end; the client treats a null token as "join in mock mode".
    logger.warn('Agora credentials not configured — issuing null token (dev only)');
    return null;
  }

  const expiry = ttlSeconds ?? env.agora.tokenTtlSeconds;
  const privilegeExpiredTs = Math.floor(Date.now() / 1000) + expiry;

  return RtcTokenBuilder.buildTokenWithUid(
    env.agora.appId,
    env.agora.appCertificate,
    channelName,
    Number(uid),
    role === 'publisher' ? RtcRole.PUBLISHER : RtcRole.SUBSCRIBER,
    privilegeExpiredTs,
    privilegeExpiredTs,
  );
}

/**
 * Verifies the signature on an Agora Notification Center webhook.
 *
 * Constant-time comparison: a plain `===` on a signature leaks timing
 * information an attacker can use to forge one byte at a time.
 */
function verifyWebhookSignature(rawBody, signature) {
  if (!env.agora.webhookSecret) {
    logger.warn('Agora webhook secret not set — skipping signature verification');
    return !env.isProduction;
  }
  if (!signature) return false;

  const expected = crypto
    .createHmac('sha256', env.agora.webhookSecret)
    .update(rawBody)
    .digest('hex');

  const a = Buffer.from(expected);
  const b = Buffer.from(String(signature));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

/**
 * Ends a live channel server-side. This is what makes the forced-end path
 * trustworthy: when a caller runs out of coins we do not ask the client to hang
 * up politely, we kick the channel.
 *
 * Agora exposes this over its RESTful "kicking-rule" API. Credentials are
 * customer-key based rather than app-certificate based, so this is a no-op
 * unless they are configured.
 */
async function terminateChannel(channelName, reason = 'forced_end') {
  const customerKey = process.env.AGORA_CUSTOMER_KEY;
  const customerSecret = process.env.AGORA_CUSTOMER_SECRET;

  if (!customerKey || !customerSecret) {
    logger.warn({ channelName, reason }, 'Agora REST credentials absent — skipping channel kick');
    return { ok: false, skipped: true };
  }

  const auth = Buffer.from(`${customerKey}:${customerSecret}`).toString('base64');
  try {
    const response = await fetch(
      `https://api.agora.io/dev/v1/kicking-rule`,
      {
        method: 'POST',
        headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          appid: env.agora.appId,
          cname: channelName,
          // uid 0 with a channel name kicks every participant in the channel.
          uid: 0,
          time_in_seconds: 60,
          privileges: ['join_channel'],
        }),
      },
    );

    if (!response.ok) {
      logger.error(
        { channelName, status: response.status, body: await response.text() },
        'agora channel kick failed',
      );
      return { ok: false };
    }
    logger.info({ channelName, reason }, 'agora channel terminated');
    return { ok: true };
  } catch (err) {
    // A failed kick must not break settlement — the call is already marked
    // ended in Postgres and billing has stopped, so the worst case is that the
    // media session lingers until the client notices the socket event.
    logger.error({ err, channelName }, 'agora channel kick errored');
    return { ok: false };
  }
}

module.exports = { buildChannelName, buildRtcToken, verifyWebhookSignature, terminateChannel };

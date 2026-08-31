'use strict';

const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * Push notifications. Used for incoming-call alerts when the callee's socket is
 * not connected, and for payout status changes.
 *
 * Incoming calls are sent as high-priority data messages so Android can wake
 * the app and show a full-screen call UI rather than a notification tray entry.
 */
async function send({ token, title, body, data = {}, highPriority = false }) {
  if (!token) return { ok: false, reason: 'no_token' };

  if (!env.fcm.serverKey) {
    logger.info({ title, data }, '[dev] push suppressed — FCM not configured');
    return { ok: true, skipped: true };
  }

  try {
    const response = await fetch('https://fcm.googleapis.com/fcm/send', {
      method: 'POST',
      headers: {
        Authorization: `key=${env.fcm.serverKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        to: token,
        priority: highPriority ? 'high' : 'normal',
        // Data-only payloads let the Flutter client decide how to present the
        // event; a notification block would be rendered by the OS instead.
        data: { title, body, ...data },
        android: { priority: highPriority ? 'high' : 'normal' },
      }),
    });

    if (!response.ok) {
      logger.error({ status: response.status }, 'fcm send failed');
      return { ok: false };
    }
    return { ok: true };
  } catch (err) {
    logger.error({ err }, 'fcm errored');
    return { ok: false };
  }
}

const sendIncomingCall = ({ token, callerName, callId, callType }) =>
  send({
    token,
    title: 'Incoming call',
    body: `${callerName} is calling you`,
    data: { type: 'incoming_call', callId: String(callId), callType },
    highPriority: true,
  });

module.exports = { send, sendIncomingCall };

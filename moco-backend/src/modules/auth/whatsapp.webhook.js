'use strict';

const crypto = require('crypto');
const express = require('express');
const env = require('../../config/env');
const whatsapp = require('../../integrations/whatsapp');
const logger = require('../../utils/logger');

/**
 * WhatsApp Cloud API webhook — delivery status callbacks for OTP messages.
 *
 * Mounted at /api/webhooks/whatsapp with a RAW body parser (see app.js),
 * because the signature covers the exact bytes Meta sent.
 *
 * GET  — Meta's subscription handshake: echo hub.challenge only when
 *        hub.verify_token matches WHATSAPP_WEBHOOK_VERIFY_TOKEN.
 * POST — accepted only with a valid X-Hub-Signature-256 (HMAC-SHA256 of the
 *        raw body with WHATSAPP_APP_SECRET); anything else is 401 and ignored.
 *        Status updates are logged (message id, status, Meta error code,
 *        masked recipient). They never contain the code itself.
 */
const router = express.Router();

const sameSecret = (a, b) => {
  const x = Buffer.from(String(a ?? ''));
  const y = Buffer.from(String(b ?? ''));
  return x.length > 0 && x.length === y.length && crypto.timingSafeEqual(x, y);
};

router.get('/', (req, res) => {
  const mode = req.query['hub.mode'];
  const token = req.query['hub.verify_token'];
  const challenge = req.query['hub.challenge'];
  if (mode === 'subscribe' && env.whatsapp.webhookVerifyToken && sameSecret(token, env.whatsapp.webhookVerifyToken)) {
    return res.type('text/plain').send(String(challenge ?? ''));
  }
  return res.sendStatus(403);
});

router.post('/', (req, res) => {
  if (!whatsapp.verifySignature(req.body, req.get('x-hub-signature-256'))) {
    logger.warn('whatsapp webhook rejected: bad or missing signature');
    return res.sendStatus(401);
  }
  let payload;
  try {
    payload = JSON.parse(req.body.toString('utf8'));
  } catch {
    return res.sendStatus(400);
  }
  for (const entry of payload.entry ?? []) {
    for (const change of entry.changes ?? []) {
      for (const status of change.value?.statuses ?? []) {
        const error = status.errors?.[0];
        const log = error ? logger.warn.bind(logger) : logger.info.bind(logger);
        log(
          {
            messageId: status.id,
            status: status.status,
            recipient: status.recipient_id ? whatsapp.maskPhone(`+${status.recipient_id}`) : undefined,
            metaCode: error?.code,
          },
          'whatsapp delivery status',
        );
      }
    }
  }
  // Always 200 quickly once authenticated, or Meta retries.
  return res.sendStatus(200);
});

module.exports = router;

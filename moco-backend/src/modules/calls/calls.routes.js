'use strict';

const express = require('express');
const { z } = require('zod');
const callsService = require('./calls.service');
const billing = require('./billing.engine');
const agoraIntegration = require('../../integrations/agora');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { CALL_TYPE, CALL_END_REASON } = require('../../utils/constants');
const { query } = require('../../config/db');
const { notFound, forbidden } = require('../../utils/errors');
const logger = require('../../utils/logger');

const router = express.Router();

const initiateSchema = z.object({
  listenerId: z.coerce.number().int().positive(),
  type: z.enum([CALL_TYPE.AUDIO, CALL_TYPE.VIDEO]),
});

router.post(
  '/initiate',
  authenticate,
  // A tight limit here also blunts using call setup to probe who is online.
  rateLimit({ windowSeconds: 60, max: 20, keyPrefix: 'call_init' }),
  validate(initiateSchema),
  asyncHandler(async (req, res) => {
    const result = await callsService.initiate({
      caller: req.user,
      listenerId: req.body.listenerId,
      callType: req.body.type,
    });

    res.status(201).json({
      callId: result.call.id,
      status: result.call.status,
      agora: {
        channel: result.agoraChannel,
        token: result.agoraToken,
        uid: req.user.id,
      },
      ratePerMinute: result.ratePerMinute,
      freeSeconds: result.freeSeconds,
      balance: result.balance,
    });
  }),
);

/** The listener answers. Billing starts here. */
router.post(
  '/:id/accept',
  authenticate,
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const call = await callsService.accept({
      callId: req.params.id,
      listenerId: req.user.id,
    });

    res.json({
      callId: call.id,
      status: call.status,
      startedAt: call.started_at,
      agora: {
        channel: call.agora_channel,
        token: agoraIntegration.buildRtcToken({
          channelName: call.agora_channel,
          uid: req.user.id,
        }),
        uid: req.user.id,
      },
    });
  }),
);

router.post(
  '/:id/end',
  authenticate,
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  validate(
    z.object({ reason: z.enum([CALL_END_REASON.REJECTED, CALL_END_REASON.DISCONNECT]).optional() }),
    'body',
  ),
  asyncHandler(async (req, res) => {
    const summary = await callsService.end({
      callId: req.params.id,
      actorId: req.user.id,
      reason: req.body.reason,
    });

    res.json({
      callId: summary.id,
      status: summary.status,
      endReason: summary.end_reason,
      billedMinutes: summary.billed_minutes,
      coinsSpent: summary.coins_spent,
      listenerEarned: summary.listener_earned,
      durationSeconds: summary.durationSeconds,
    });
  }),
);

/** Live state for a call, used to restore the UI after an app restart. */
router.get(
  '/:id',
  authenticate,
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT id, caller_id, listener_id, type, status, agora_channel, billed_minutes,
              coins_spent, listener_earned, started_at, ended_at, end_reason
         FROM calls WHERE id = $1`,
      [req.params.id],
    );

    const call = rows[0];
    if (!call) throw notFound('Call');
    if (
      Number(call.caller_id) !== Number(req.user.id) &&
      Number(call.listener_id) !== Number(req.user.id)
    ) {
      throw forbidden('You are not part of this call');
    }

    const liveState = await billing.getCallState(call.id);

    res.json({
      callId: call.id,
      type: call.type,
      status: call.status,
      billedMinutes: call.billed_minutes,
      coinsSpent: call.coins_spent,
      startedAt: call.started_at,
      endedAt: call.ended_at,
      endReason: call.end_reason,
      live: liveState
        ? {
            minuteIndex: Number(liveState.minute_index),
            balanceSnapshot: Number(liveState.caller_balance_snapshot),
          }
        : null,
    });
  }),
);

router.get(
  '/',
  authenticate,
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(100).default(30),
      before: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const calls = await callsService.history({
      userId: req.user.id,
      limit: req.query.limit,
      before: req.query.before,
    });
    res.json({ calls, nextCursor: calls.length > 0 ? calls[calls.length - 1].id : null });
  }),
);

/**
 * Agora Notification Center webhook.
 *
 * This is the disconnect backstop from the design: when a participant drops
 * without hanging up, Agora tells us, and we settle rather than letting the
 * call sit active. Mounted with a raw body parser so the signature can be
 * verified against the exact bytes Agora signed.
 */
router.post(
  '/webhook/agora',
  asyncHandler(async (req, res) => {
    const signature = req.headers['agora-signature-v2'] || req.headers['agora-signature'];

    if (!agoraIntegration.verifyWebhookSignature(req.body, signature)) {
      logger.warn({ ip: req.ip }, 'rejected agora webhook with bad signature');
      return res.status(401).json({ ok: false });
    }

    const event = JSON.parse(req.body.toString('utf8'));
    const channelName = event?.payload?.channelName;

    // 101 = channel destroyed, 103 = broadcaster left the channel.
    const isLeaveEvent = [101, 103].includes(event?.eventType);
    if (!isLeaveEvent || !channelName) return res.json({ ok: true, ignored: true });

    const { rows } = await query(
      `SELECT id FROM calls WHERE agora_channel = $1 AND status IN ('ringing', 'active')`,
      [channelName],
    );

    if (rows[0]) {
      await callsService
        .end({
          callId: rows[0].id,
          actorId: null,
          reason: CALL_END_REASON.DISCONNECT,
        })
        .catch((err) => logger.error({ err, callId: rows[0].id }, 'webhook end failed'));
    }

    return res.json({ ok: true });
  }),
);

module.exports = router;

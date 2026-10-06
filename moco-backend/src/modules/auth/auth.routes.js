'use strict';

const express = require('express');
const { z } = require('zod');
const authService = require('./auth.service');
const { CHANNEL_IDS } = require('./otp.channels');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { rateLimit } = require('../../middleware/rateLimit');

const router = express.Router();

/**
 * Sign-in by one-time code. One pair of endpoints for every channel:
 *
 *   POST /auth/otp/send   { channel, identifier }        → { sent, channel, expiresIn, resendIn }
 *   POST /auth/otp/verify { channel, identifier, code }  → { token, isNew, user }
 *
 * `identifier` is an email address for channel "email" and an E.164 phone
 * number (+919876543210) for "sms", "whatsapp" and "telegram"; the service
 * validates and normalizes it. GET /api/config lists which channels are
 * available.
 *
 * The original phone-only shapes still work, as SMS:
 *   POST /auth/otp/request { phone }        POST /auth/otp/verify { phone, code }
 */

const channelSchema = z.enum(CHANNEL_IDS);
const identifierSchema = z.string().trim().min(3).max(254);
const codeSchema = z.string().regex(/^\d{4,8}$/, 'Code must be numeric');
const phoneSchema = z
  .string()
  .regex(/^\+[1-9]\d{7,14}$/, 'Phone must be in international format, e.g. +919876543210');

const sendSchema = z.object({ channel: channelSchema, identifier: identifierSchema });
const verifySchema = z.union([
  z.object({ channel: channelSchema, identifier: identifierSchema, code: codeSchema }),
  // Legacy (SMS by phone).
  z.object({ phone: phoneSchema, code: codeSchema }),
]);

// Per-IP limits on top of the per-identity limits in the service, so one host
// cannot cycle through many addresses or numbers.
const sendLimit = rateLimit({ windowSeconds: 300, max: 10, keyPrefix: 'otp_req', by: (req) => req.ip });
const verifyLimit = rateLimit({ windowSeconds: 300, max: 20, keyPrefix: 'otp_verify', by: (req) => req.ip });

router.post(
  '/otp/send',
  sendLimit,
  validate(sendSchema),
  asyncHandler(async (req, res) => {
    res.json(await authService.sendCode({ channel: req.body.channel, identifier: req.body.identifier, ip: req.ip }));
  }),
);

router.post(
  '/otp/request',
  sendLimit,
  validate(z.object({ phone: phoneSchema })),
  asyncHandler(async (req, res) => {
    res.json(await authService.requestOtp({ phone: req.body.phone, ip: req.ip }));
  }),
);

router.post(
  '/otp/verify',
  verifyLimit,
  validate(verifySchema),
  asyncHandler(async (req, res) => {
    const { channel, identifier, phone, code } = req.body;
    const session = phone
      ? await authService.verifyOtp({ phone, code, ip: req.ip })
      : await authService.verifyCode({ channel, identifier, code, ip: req.ip });

    const { token, user, isNew } = session;
    res.json({
      token,
      isNew,
      user: {
        id: user.id,
        phone: user.phone,
        email: user.email,
        displayName: user.display_name,
        role: user.role,
        language: user.language,
        // Drives whether the client shows the "profile setup" screen.
        profileComplete: Boolean(user.display_name),
      },
    });
  }),
);

module.exports = router;

'use strict';

const express = require('express');
const { z } = require('zod');
const authService = require('./auth.service');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { rateLimit } = require('../../middleware/rateLimit');

const router = express.Router();

// E.164, which is what the Flutter client sends after its country-code picker.
const phoneSchema = z
  .string()
  .regex(/^\+[1-9]\d{7,14}$/, 'Phone must be in international format, e.g. +919876543210');

const requestSchema = z.object({ phone: phoneSchema });
const verifySchema = z.object({
  phone: phoneSchema,
  code: z.string().regex(/^\d{4,8}$/, 'Code must be numeric'),
});

router.post(
  '/otp/request',
  // IP-based limit on top of the per-phone limit in the service, so one host
  // cannot cycle through many numbers.
  rateLimit({ windowSeconds: 300, max: 10, keyPrefix: 'otp_req', by: (req) => req.ip }),
  validate(requestSchema),
  asyncHandler(async (req, res) => {
    const result = await authService.requestOtp({ phone: req.body.phone, ip: req.ip });
    res.json(result);
  }),
);

router.post(
  '/otp/verify',
  rateLimit({ windowSeconds: 300, max: 20, keyPrefix: 'otp_verify', by: (req) => req.ip }),
  validate(verifySchema),
  asyncHandler(async (req, res) => {
    const { token, user, isNew } = await authService.verifyOtp({
      phone: req.body.phone,
      code: req.body.code,
      ip: req.ip,
    });

    res.json({
      token,
      isNew,
      user: {
        id: user.id,
        phone: user.phone,
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

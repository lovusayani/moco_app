'use strict';

const express = require('express');
const { z } = require('zod');
const live = require('./live.service');
const stripcash = require('../../integrations/stripcash');
const jobs = require('../../jobs');
const logger = require('../../utils/logger');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');

/**
 * Moco Live — external live models (Stripcash). Signed-in users only, like
 * the rest of the app's content.
 */
const router = express.Router();
router.use(authenticate);

router.get(
  '/models',
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(60).default(24),
      offset: z.coerce.number().int().min(0).max(1000).default(0),
      language: z.string().trim().toLowerCase().regex(/^[a-z]{2,3}$/).optional(),
      country: z.string().trim().toLowerCase().regex(/^[a-z]{2}$/).optional(),
      tag: z.string().trim().toLowerCase().regex(/^[a-z0-9][a-z0-9/_-]{0,63}$/).optional(),
      sort: z.enum(Object.keys(live.SORTS)).default('default'),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const configured = stripcash.isConfigured();
    if (configured) {
      await live.noteDemand();
      // Keep the 30-second chain alive while people browse; if it had gone
      // idle, refresh now rather than serve an empty or stale page.
      await jobs.ensureLiveSync().catch((err) => logger.warn({ err: { message: err.message } }, 'live sync enqueue failed'));
      await live.syncIfStale().catch((err) => logger.warn({ err: { message: err.message } }, 'live inline sync failed'));
    }

    const viewer = live.viewerFromRequest(req);
    const [models, state] = await Promise.all([live.list(viewer, req.query), live.getState()]);
    res.json({
      provider: stripcash.PROVIDER,
      available: configured,
      updatedAt: state?.last_sync_ok ? state.last_sync_at : state?.last_sync_at ?? null,
      limit: req.query.limit,
      offset: req.query.offset,
      sort: req.query.sort,
      models,
    });
  }),
);

module.exports = router;

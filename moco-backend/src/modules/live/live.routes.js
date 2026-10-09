'use strict';

const express = require('express');
const { z } = require('zod');
const live = require('./live.service');
const liveSettings = require('./live.settings');
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

/**
 * What the app may know about Live: whether it is on, the 18+ gate, the
 * admin's presentation settings (layout, card fields, sort, click
 * behaviour) and the non-secret settings the official Stripchat player
 * needs. The affiliate userId is the one provider value the player requires
 * in the browser; the API key is never part of this response.
 */
router.get(
  '/config',
  asyncHandler(async (req, res) => {
    const settings = await liveSettings.read();
    const enabled = settings.enabled && stripcash.isConfigured();
    res.json({
      enabled,
      provider: stripcash.PROVIDER,
      ...liveSettings.clientView(settings),
      player: enabled ? stripcash.playerConfig() : null,
    });
  }),
);

/**
 * Keeps the 30-second sync chain alive while people browse, and decides how
 * fresh this answer can be without making the viewer wait for the provider
 * (live.prepareListing: fresh / stale-while-revalidate / warming /
 * unavailable).
 */
async function keepFresh() {
  await live.noteDemand();
  await jobs.ensureLiveSync().catch((err) => logger.warn({ err: { message: err.message } }, 'live sync enqueue failed'));
  return live.prepareListing().catch((err) => {
    logger.warn({ err: { message: err.message } }, 'live listing preparation failed');
    return { freshness: 'warming', retryAfterMs: 3000 };
  });
}

router.get(
  '/models',
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(60).optional(),
      offset: z.coerce.number().int().min(0).max(1000).default(0),
      language: z.string().trim().toLowerCase().regex(/^[a-z]{2,3}$/).optional(),
      country: z.string().trim().toLowerCase().regex(/^[a-z]{2}$/).optional(),
      tag: z.string().trim().toLowerCase().regex(/^[a-z0-9][a-z0-9/_-]{0,63}$/).optional(),
      sort: z.enum(Object.keys(live.SORTS)).optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const settings = await liveSettings.read();
    const available = settings.enabled && stripcash.isConfigured();
    const limit = req.query.limit ?? settings.pageSize;
    const sort = req.query.sort ?? settings.sort;
    const body = { provider: stripcash.PROVIDER, available, limit, offset: req.query.offset, sort };
    if (!available) {
      res.json({ ...body, updatedAt: null, models: [] });
      return;
    }

    const plan = await keepFresh();
    const state = await live.getState();
    // No usable snapshot yet: answer now and let the client retry, instead of
    // holding the request open for the whole provider refresh.
    if (!plan.windowSeconds) {
      res.json({
        ...body,
        freshness: plan.freshness,
        ...(plan.retryAfterMs ? { retryAfterMs: plan.retryAfterMs } : {}),
        updatedAt: state?.last_ok_sync_at ?? null,
        models: [],
      });
      return;
    }
    const viewer = live.viewerFromRequest(req);
    const models = await live.list(viewer, { ...req.query, limit, sort, windowSeconds: plan.windowSeconds }, settings);
    res.json({ ...body, freshness: plan.freshness, updatedAt: state?.last_ok_sync_at ?? null, models });
  }),
);

module.exports = { router, keepFresh };

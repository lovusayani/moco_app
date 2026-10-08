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

/** Ensures the sync is running and the stored list is fresh enough. */
async function keepFresh() {
  await live.noteDemand();
  // Keep the 30-second chain alive while people browse; if it had gone idle,
  // refresh now rather than serve an empty or stale page.
  await jobs.ensureLiveSync().catch((err) => logger.warn({ err: { message: err.message } }, 'live sync enqueue failed'));
  await live.syncIfStale().catch((err) => logger.warn({ err: { message: err.message } }, 'live inline sync failed'));
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

    await keepFresh();
    const viewer = live.viewerFromRequest(req);
    const [models, state] = await Promise.all([
      live.list(viewer, { ...req.query, limit, sort }, settings),
      live.getState(),
    ]);
    res.json({ ...body, updatedAt: state?.last_sync_at ?? null, models });
  }),
);

module.exports = { router, keepFresh };

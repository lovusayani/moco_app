'use strict';

const express = require('express');
const { z } = require('zod');
const live = require('./live.service');
const liveSettings = require('./live.settings');
const stripcash = require('../../integrations/stripcash');
const audit = require('../admin/audit.service');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate, requireAdmin } = require('../../middleware/auth');
const { badRequest } = require('../../utils/errors');

/**
 * Admin → Settings → Live. Mounted at /api/admin/live, behind the same
 * authenticate + requireAdmin as the rest of /api/admin.
 *
 * Nothing here can change geoban handling: the settings document has no
 * geoban field, and the preview runs the public listing code for the admin's
 * own location, geobans included.
 */
const router = express.Router();
router.use(authenticate, requireAdmin);

/** Settings, the choices the console offers, and provider status (no secrets). */
router.get(
  '/settings',
  asyncHandler(async (req, res) => {
    const [settings, state, counts] = await Promise.all([liveSettings.read(), live.getState(), live.storedCounts()]);
    res.json({
      settings,
      defaults: liveSettings.DEFAULTS,
      options: liveSettings.OPTIONS,
      maxList: liveSettings.MAX_LIST,
      provider: {
        id: stripcash.PROVIDER,
        configured: stripcash.isConfigured(),
        lastSyncAt: state?.last_sync_at ?? null,
        lastSyncOk: state?.last_sync_ok ?? null,
        lastSyncError: state?.last_sync_error ?? null,
        ...counts,
      },
    });
  }),
);

function parseSettings(body) {
  const parsed = liveSettings.schema.safeParse(body);
  if (!parsed.success) {
    throw badRequest(
      'validation_failed',
      'Invalid Live settings',
      parsed.error.issues.map((i) => ({ field: i.path.join('.'), message: i.message })),
    );
  }
  return parsed.data;
}

router.put(
  '/settings',
  asyncHandler(async (req, res) => {
    const next = parseSettings(req.body?.settings);
    const saved = await liveSettings.save(next, req.user, audit);
    res.json({ settings: saved });
  }),
);

/**
 * What the app would show with these (possibly unsaved) settings, for the
 * admin's own location and languages. Real synced data; geobans applied.
 */
router.post(
  '/preview',
  asyncHandler(async (req, res) => {
    const settings = parseSettings(req.body?.settings);
    if (stripcash.isConfigured()) {
      await live.syncIfStale().catch(() => {});
    }
    const viewer = live.viewerFromRequest(req);
    const models = await live.list(viewer, { limit: settings.pageSize, offset: 0, sort: settings.sort }, settings);
    res.json({ viewer: { country: viewer.country, region: viewer.region, languages: viewer.languages }, models });
  }),
);

/** Stored models for the featured / hidden / selected pickers. */
router.get(
  '/models',
  validate(
    z.object({
      q: z.string().trim().max(64).optional(),
      limit: z.coerce.number().int().min(1).max(60).default(30),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    res.json({ models: await live.searchStored(req.query) });
  }),
);

module.exports = router;

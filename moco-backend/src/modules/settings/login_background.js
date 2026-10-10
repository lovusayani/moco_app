'use strict';

const crypto = require('crypto');
const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { redis } = require('../../config/redis');
const storage = require('../../integrations/storage');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { badRequest } = require('../../utils/errors');
const { FEED_MEDIA } = require('../../utils/constants');
const audit = require('../admin/audit.service');
const logger = require('../../utils/logger');

/**
 * Login screen background — an admin-managed setting.
 *
 * Stored in app_settings under 'login_background' as
 *   { type: 'default' | 'image' | 'video', imagePath, videoPath }
 * (paths only; never URLs). Media lives in the existing private feed-media
 * bucket under app/login-background/, uploaded straight to Storage with a
 * backend-signed URL — the same pattern as every other upload; no Storage
 * credentials reach a browser. The public app gets short-lived signed view
 * URLs through /api/config.
 *
 * With type 'video', imagePath is optional and acts as the poster/fallback
 * shown while the video loads or if it cannot play.
 */

const KEY = 'login_background';
const PREFIX = 'app/login-background';
const BUCKET = FEED_MEDIA.bucket;

const LIMITS = Object.freeze({
  image: { mimeTypes: ['image/jpeg', 'image/png', 'image/webp'], maxBytes: 5 * 1024 * 1024 },
  // MP4 only: it is the format every browser plays. Short clips only — the
  // console also checks duration (≤ maxSeconds) before uploading.
  video: { mimeTypes: ['video/mp4'], maxBytes: 15 * 1024 * 1024, maxSeconds: 30 },
});
const EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'video/mp4': 'mp4' };

// Public view URLs: long enough to outlive a cached /api/config, short
// enough not to be a durable public link to a private bucket.
const VIEW_URL_SECONDS = 6 * 3600;
const CACHE_SECONDS = 3600;
const cacheKey = (stamp) => `cfg:login_bg:${stamp}`;

const DEFAULT = Object.freeze({ type: 'default', imagePath: null, videoPath: null });

async function read(run = query) {
  const { rows } = await run('SELECT value, updated_at, updated_by FROM app_settings WHERE key = $1', [KEY]);
  if (!rows[0]) return { ...DEFAULT, updatedAt: null, updatedBy: null };
  return { ...DEFAULT, ...rows[0].value, updatedAt: rows[0].updated_at, updatedBy: rows[0].updated_by };
}

/**
 * What the app shows, for /api/config: null for the default background, else
 * { type, imageUrl, videoUrl, updatedAt }. Never throws — a settings or
 * Storage problem must never break /api/config (and with it, login).
 */
async function publicConfig() {
  try {
    const setting = await read();
    if (setting.type === 'default') return null;
    const stamp = new Date(setting.updatedAt).getTime();
    const cached = await redis.get(cacheKey(stamp)).catch(() => null);
    if (cached) return JSON.parse(cached);

    const [imageUrl, videoUrl] = await Promise.all([
      setting.imagePath ? storage.createViewUrl(BUCKET, setting.imagePath, { expiresInSeconds: VIEW_URL_SECONDS }) : null,
      setting.type === 'video' && setting.videoPath
        ? storage.createViewUrl(BUCKET, setting.videoPath, { expiresInSeconds: VIEW_URL_SECONDS })
        : null,
    ]);
    if (!imageUrl && !videoUrl) return null;
    const result = { type: setting.type, imageUrl, videoUrl, updatedAt: setting.updatedAt };
    await redis.setex(cacheKey(stamp), CACHE_SECONDS, JSON.stringify(result)).catch(() => {});
    return result;
  } catch (err) {
    logger.warn({ err: err.message }, 'login background unavailable; using the default');
    return null;
  }
}

// ------------------------------------------------------------------- admin

const router = express.Router();

/** Current setting with preview URLs, plus the limits the console enforces. */
router.get(
  '/settings/login-background',
  asyncHandler(async (req, res) => {
    const setting = await read();
    const [imageUrl, videoUrl] = await Promise.all([
      setting.imagePath ? storage.createViewUrl(BUCKET, setting.imagePath) : null,
      setting.videoPath ? storage.createViewUrl(BUCKET, setting.videoPath) : null,
    ]);
    res.json({ ...setting, imageUrl, videoUrl, limits: LIMITS, storageConfigured: storage.isConfigured() });
  }),
);

/** A signed URL to upload one background file straight to Storage. */
router.post(
  '/settings/login-background/upload-url',
  validate(z.object({ kind: z.enum(['image', 'video']), mimeType: z.string() })),
  asyncHandler(async (req, res) => {
    const { kind, mimeType } = req.body;
    if (!LIMITS[kind].mimeTypes.includes(mimeType)) {
      throw badRequest('unsupported_media', `Use ${LIMITS[kind].mimeTypes.join(', ')} for a background ${kind}.`);
    }
    if (!storage.isConfigured()) throw badRequest('storage_unavailable', 'Media storage is not configured.');
    const path = `${PREFIX}/${kind}/${Date.now()}_${crypto.randomBytes(8).toString('hex')}.${EXT[mimeType]}`;
    const upload = await storage.createUploadUrl(BUCKET, path);
    res.json({ ...upload, maxBytes: LIMITS[kind].maxBytes });
  }),
);

/** Checks an uploaded object is ours, exists and is within its cap. */
async function verifyUpload(kind, path) {
  if (!path) return;
  if (!path.startsWith(`${PREFIX}/${kind}/`)) throw badRequest('invalid_path', `Not a background ${kind} upload.`);
  const object = await storage.statObject(BUCKET, path);
  if (!object) throw badRequest('upload_missing', `The ${kind} upload was not found. Upload it again.`);
  if (object.sizeBytes && object.sizeBytes > LIMITS[kind].maxBytes) {
    await storage.remove(BUCKET, path);
    throw badRequest('upload_too_large', `The ${kind} is larger than ${LIMITS[kind].maxBytes / 1024 / 1024} MB.`);
  }
}

/** Saves the setting (audited), then removes media it no longer uses. */
async function save(req, next) {
  const previous = await read();
  const saved = await withTransaction(async (client) => {
    await client.query(
      `INSERT INTO app_settings (key, value, updated_at, updated_by) VALUES ($1, $2, now(), $3)
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by`,
      [KEY, JSON.stringify(next), req.user.id],
    );
    await audit.record(client, {
      admin: req.user,
      action: next.type === 'default' ? 'settings.login_background.reset' : 'settings.login_background.update',
      targetType: 'setting',
      targetId: KEY,
      reason: req.body?.reason || null,
      metadata: { from: previous.type, to: next.type },
    });
    return read(client.query.bind(client));
  });
  const keep = new Set([next.imagePath, next.videoPath].filter(Boolean));
  for (const path of [previous.imagePath, previous.videoPath]) {
    if (path && !keep.has(path)) await storage.remove(BUCKET, path);
  }
  return saved;
}

router.put(
  '/settings/login-background',
  validate(
    z.object({
      type: z.enum(['default', 'image', 'video']),
      imagePath: z.string().max(300).nullable().optional(),
      videoPath: z.string().max(300).nullable().optional(),
      reason: z.string().trim().max(500).optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { type } = req.body;
    const imagePath = type === 'default' ? null : req.body.imagePath || null;
    const videoPath = type === 'video' ? req.body.videoPath || null : null;
    if (type === 'image' && !imagePath) throw badRequest('image_required', 'Choose a background image first.');
    if (type === 'video' && !videoPath) throw badRequest('video_required', 'Choose a background video first.');
    await verifyUpload('image', imagePath);
    await verifyUpload('video', videoPath);
    res.json(await save(req, { type, imagePath, videoPath }));
  }),
);

/** Revert to the app's default background and delete the stored media. */
router.delete(
  '/settings/login-background',
  asyncHandler(async (req, res) => {
    res.json(await save(req, { ...DEFAULT }));
  }),
);

module.exports = { router, publicConfig, LIMITS };

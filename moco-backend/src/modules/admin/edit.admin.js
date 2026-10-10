'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const listenerStorage = require('../../integrations/listener.storage');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { isAdminUser } = require('../../middleware/auth');
const { notFound, badRequest, conflict } = require('../../utils/errors');
const { USER_STATUS, LISTENER_PHOTOS } = require('../../utils/constants');
const audit = require('./audit.service');

/**
 * Admin edits: account details, creator profile, post captions, admin-uploaded
 * creator photos, and deletion of call rows that never billed anything.
 * Mounted under /api/admin behind authenticate + requireAdmin.
 *
 * Every change is audit-logged in the same transaction as the change, with a
 * before/after summary. Identity values (phone, email) are recorded masked —
 * the log says that they changed, not what they are.
 *
 * Deliberately NOT editable here: balances (coins move only through the
 * ledger's adjustment route), call rates (they feed billing), KYC name,
 * document and UPI ID (payout identity), and account status/role (their own
 * audited actions already exist).
 */
const router = express.Router();

const idParam = z.object({ id: z.coerce.number().int().positive() });
const REASON = z.string().trim().min(3, 'Give a reason of at least 3 characters').max(500);
const PHONE = z.string().trim().regex(/^\+[1-9]\d{7,14}$/, 'Use international format, e.g. +919876543210');
const EMAIL = z.string().trim().toLowerCase().email('Enter a valid email address').max(254);
const LANGS = ['en', 'hi', 'te'];
// '' clears an optional field; undefined leaves it alone.
const clearable = (schema) => z.union([schema, z.literal('')]).optional();

const maskPhone = (p) => (p ? `••••${String(p).slice(-4)}` : null);
const maskEmail = (e) => {
  if (!e) return null;
  const [name, domain] = String(e).split('@');
  return `${name.slice(0, 1)}•••@${domain ?? ''}`;
};

/** { field: { from, to } } for the fields that actually changed. */
function diff(before, after, masks = {}) {
  const changes = {};
  for (const [key, to] of Object.entries(after)) {
    const from = before[key] ?? null;
    if (JSON.stringify(from) === JSON.stringify(to)) continue;
    const mask = masks[key];
    changes[key] = mask ? { from: mask(from), to: mask(to) } : { from, to };
  }
  return changes;
}

// ------------------------------------------------------------------ accounts

const userEdit = z
  .object({
    displayName: clearable(z.string().trim().min(1).max(80)),
    email: clearable(EMAIL),
    phone: clearable(PHONE),
    avatarUrl: clearable(z.string().trim().url('Avatar must be a full https:// URL').max(1000).startsWith('https://', 'Avatar must be a full https:// URL')),
    language: z.enum(LANGS).optional(),
    gender: clearable(z.enum(['male', 'female', 'other'])),
    reason: REASON,
  })
  .strict();

/**
 * Edits an account's profile and sign-in identity. Phone/email changes keep
 * the account signable-into: at least one identity must remain, each is
 * unique, and an admin's own identity cannot be changed here (that would
 * silently move them out of the admin allow-list). Existing sessions keep
 * working — tokens are keyed by account id, not by phone or email.
 */
router.patch(
  '/users/:id',
  validate(idParam, 'params'),
  validate(userEdit),
  asyncHandler(async (req, res) => {
    const id = Number(req.params.id);
    const body = req.body;
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        'SELECT id, phone, email, display_name, avatar_url, language, gender, status FROM users WHERE id = $1 FOR UPDATE',
        [id],
      );
      const user = rows[0];
      if (!user) throw notFound('User');
      if (user.status === USER_STATUS.DELETED) throw conflict('account_deleted', 'Deleted accounts cannot be edited');

      const before = {
        displayName: user.display_name,
        email: user.email,
        phone: user.phone,
        avatarUrl: user.avatar_url,
        language: user.language,
        gender: user.gender,
      };
      const after = { ...before };
      for (const key of Object.keys(before)) {
        if (body[key] === undefined) continue;
        after[key] = body[key] === '' ? null : body[key];
      }
      if (after.language === null) after.language = before.language;

      const identityChanged = after.phone !== before.phone || after.email !== before.email;
      if (identityChanged && (isAdminUser(user) || id === Number(req.user.id))) {
        throw conflict('admin_identity', "An admin account's phone or email cannot be changed from the console");
      }
      if (!after.phone && !after.email) {
        throw badRequest('identity_required', 'An account needs a phone number or an email to sign in with');
      }
      if (after.phone && after.phone !== before.phone) {
        const taken = await client.query('SELECT id FROM users WHERE phone = $1 AND id <> $2', [after.phone, id]);
        if (taken.rows[0]) throw conflict('phone_taken', `That phone number already belongs to account #${taken.rows[0].id}`);
      }
      if (after.email && after.email !== before.email) {
        const taken = await client.query('SELECT id FROM users WHERE email = $1 AND id <> $2', [after.email, id]);
        if (taken.rows[0]) throw conflict('email_taken', `That email already belongs to account #${taken.rows[0].id}`);
      }

      const changes = diff(before, after, { phone: maskPhone, email: maskEmail });
      if (Object.keys(changes).length === 0) throw badRequest('no_changes', 'Nothing was changed');

      await client.query(
        `UPDATE users SET display_name = $2, email = $3, phone = $4, avatar_url = $5,
                language = $6, gender = $7, updated_at = now()
          WHERE id = $1`,
        [id, after.displayName, after.email, after.phone, after.avatarUrl, after.language, after.gender],
      );
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'user.edit',
        targetType: 'user',
        targetId: id,
        reason: body.reason,
        metadata: { changes },
      });
      return { auditId, changed: Object.keys(changes) };
    });
    res.json({ id, ...result });
  }),
);

// ------------------------------------------------------------------- creators

const creatorEdit = z
  .object({
    bio: clearable(z.string().trim().max(500)),
    languages: z.array(z.enum(LANGS)).min(1, 'Pick at least one language').max(3).optional(),
    acceptsAudio: z.boolean().optional(),
    acceptsVideo: z.boolean().optional(),
    reason: REASON,
  })
  .strict();

/** Creator profile fields. Rates, KYC identity and payout details are not
 * editable here; account fields (name, phone, email…) use PATCH /users/:id. */
router.patch(
  '/listeners/:id/profile',
  validate(idParam, 'params'),
  validate(creatorEdit),
  asyncHandler(async (req, res) => {
    const id = Number(req.params.id);
    const body = req.body;
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        `SELECT lp.bio, lp.languages, lp.accepts_audio, lp.accepts_video, lp.is_online, u.status
           FROM listener_profiles lp JOIN users u ON u.id = lp.user_id
          WHERE lp.user_id = $1 FOR UPDATE OF lp`,
        [id],
      );
      const lp = rows[0];
      if (!lp) throw notFound('Creator');
      if (lp.status === USER_STATUS.DELETED) throw conflict('account_deleted', 'Deleted accounts cannot be edited');

      const before = {
        bio: lp.bio,
        languages: lp.languages,
        acceptsAudio: lp.accepts_audio,
        acceptsVideo: lp.accepts_video,
      };
      const after = { ...before };
      if (body.bio !== undefined) after.bio = body.bio === '' ? null : body.bio;
      if (body.languages !== undefined) after.languages = [...new Set(body.languages)];
      if (body.acceptsAudio !== undefined) after.acceptsAudio = body.acceptsAudio;
      if (body.acceptsVideo !== undefined) after.acceptsVideo = body.acceptsVideo;
      if (!after.acceptsAudio && !after.acceptsVideo) {
        throw badRequest('call_type_required', 'A creator must accept audio, video or both');
      }

      const changes = diff(before, after);
      if (Object.keys(changes).length === 0) throw badRequest('no_changes', 'Nothing was changed');

      await client.query(
        `UPDATE listener_profiles SET bio = $2, languages = $3, accepts_audio = $4, accepts_video = $5,
                updated_at = now()
          WHERE user_id = $1`,
        [id, after.bio, after.languages, after.acceptsAudio, after.acceptsVideo],
      );
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'listener.edit',
        targetType: 'listener',
        targetId: id,
        reason: body.reason,
        metadata: { changes },
      });
      return { auditId, changed: Object.keys(changes) };
    });
    res.json({ id, ...result });
  }),
);

/** A signed upload URL for a creator photo the admin is adding on the
 * creator's behalf — same bucket, same per-creator folder as their own. */
router.post(
  '/listeners/:id/photos/upload-url',
  validate(idParam, 'params'),
  validate(z.object({ mimeType: z.enum(LISTENER_PHOTOS.allowedMimeTypes) })),
  asyncHandler(async (req, res) => {
    const { rows } = await query('SELECT photo_count FROM listener_profiles WHERE user_id = $1', [req.params.id]);
    if (!rows[0]) throw notFound('Creator');
    if (rows[0].photo_count >= LISTENER_PHOTOS.maxCount) {
      throw badRequest('photo_limit', `A creator can have at most ${LISTENER_PHOTOS.maxCount} photos`);
    }
    if (!listenerStorage.isConfigured()) throw badRequest('storage_not_configured', 'Storage is not configured');
    res.json(await listenerStorage.createUploadUrl({ userId: req.params.id, mimeType: req.body.mimeType }));
  }),
);

/** Registers an uploaded creator photo. The object must exist in Storage
 * under this creator's folder; an oversized one is removed, never kept. */
router.post(
  '/listeners/:id/photos',
  validate(idParam, 'params'),
  validate(z.object({ path: z.string().min(1).max(400), reason: REASON })),
  asyncHandler(async (req, res) => {
    const id = Number(req.params.id);
    const { path } = req.body;
    if (!listenerStorage.pathBelongsToUser(path, id)) throw badRequest('wrong_folder', "That upload is not in this creator's folder");
    const mimeType = listenerStorage.mimeTypeForPath(path);
    if (!mimeType) throw badRequest('unsupported_media', 'Only JPEG, PNG or WebP photos are allowed');
    const object = await listenerStorage.statObject(path);
    if (!object) throw badRequest('media_not_uploaded', 'The upload did not finish. Try again.');
    if (object.sizeBytes !== null && object.sizeBytes > LISTENER_PHOTOS.maxBytes) {
      await listenerStorage.remove(path);
      throw badRequest('media_too_large', 'That photo is too large (8 MB max)');
    }
    try {
      const result = await withTransaction(async (client) => {
        const { rows } = await client.query(
          'SELECT photo_count FROM listener_profiles WHERE user_id = $1 FOR UPDATE',
          [id],
        );
        if (!rows[0]) throw notFound('Creator');
        if (rows[0].photo_count >= LISTENER_PHOTOS.maxCount) {
          throw badRequest('photo_limit', `A creator can have at most ${LISTENER_PHOTOS.maxCount} photos`);
        }
        const inserted = await client.query(
          `INSERT INTO listener_photos (listener_id, storage_path, mime_type, size_bytes)
           VALUES ($1, $2, $3, $4) ON CONFLICT (storage_path) DO NOTHING RETURNING id`,
          [id, path, mimeType, object.sizeBytes],
        );
        const photoId = inserted.rows[0]?.id ?? null;
        const auditId = await audit.record(client, {
          admin: req.user,
          action: 'listener_photo.add',
          targetType: 'listener',
          targetId: id,
          reason: req.body.reason,
          metadata: { photoId, sizeBytes: object.sizeBytes },
        });
        return { photoId, auditId, photoCount: rows[0].photo_count + (photoId ? 1 : 0) };
      });
      res.status(201).json({ listenerId: id, ...result });
    } catch (err) {
      // Never keep an object no row points at.
      await listenerStorage.remove(path);
      throw err;
    }
  }),
);

// --------------------------------------------------------------------- posts

router.patch(
  '/posts/:id',
  validate(idParam, 'params'),
  validate(z.object({ caption: z.string().trim().max(500), reason: REASON }).strict()),
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query('SELECT id, caption FROM posts WHERE id = $1 FOR UPDATE', [req.params.id]);
      const post = rows[0];
      if (!post) throw notFound('Post');
      const caption = req.body.caption === '' ? null : req.body.caption;
      if ((post.caption ?? null) === caption) throw badRequest('no_changes', 'Nothing was changed');
      await client.query('UPDATE posts SET caption = $2 WHERE id = $1', [post.id, caption]);
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'content.edit',
        targetType: 'post',
        targetId: post.id,
        reason: req.body.reason,
        metadata: { changes: { caption: { from: post.caption, to: caption } } },
      });
      return { id: post.id, auditId };
    });
    res.json(result);
  }),
);

// --------------------------------------------------------------------- calls

/**
 * Why a call row may not be deleted, or null if it may. Calls are billing
 * history: any call that connected, billed a minute, used free seconds or is
 * referenced by the coin/earnings ledgers, a rating or a report stays,
 * read-only. Only rows that never carried money — a ring that was missed,
 * declined or failed before connecting — can go.
 */
async function callDeleteBlocker(run, callId) {
  const { rows } = await run(
    `SELECT c.status, c.started_at, c.billed_minutes, c.coins_spent, c.listener_earned, c.free_seconds_granted,
            (SELECT count(*)::int FROM call_ticks WHERE call_id = c.id) AS ticks,
            (SELECT count(*)::int FROM coin_ledger WHERE ref_id = c.id::text) AS coin_rows,
            (SELECT count(*)::int FROM listener_earnings WHERE ref_id = c.id::text) AS earning_rows,
            (SELECT count(*)::int FROM call_ratings WHERE call_id = c.id) AS ratings,
            (SELECT count(*)::int FROM reports WHERE call_id = c.id) AS reports
       FROM calls c WHERE c.id = $1`,
    [callId],
  );
  const c = rows[0];
  if (!c) return { code: 'not_found' };
  if (c.status === 'ringing' || c.status === 'active') return { code: 'live_call', message: 'The call is still live. End it first.' };
  if (c.started_at || c.billed_minutes > 0 || Number(c.coins_spent) > 0 || Number(c.listener_earned) > 0 || c.free_seconds_granted > 0 || c.ticks > 0) {
    return { code: 'billing_history', message: 'This call connected or billed time; it is billing history and stays read-only.' };
  }
  if (c.coin_rows > 0 || c.earning_rows > 0) return { code: 'ledger_reference', message: 'The coin or earnings ledger references this call; it stays read-only.' };
  if (c.ratings > 0) return { code: 'rated', message: 'This call has a rating; it stays read-only.' };
  if (c.reports > 0) return { code: 'reported', message: 'A report references this call; it stays as moderation evidence.' };
  return null;
}

router.get(
  '/calls/:id/deletability',
  validate(idParam, 'params'),
  asyncHandler(async (req, res) => {
    const blocker = await callDeleteBlocker(query, req.params.id);
    if (blocker?.code === 'not_found') throw notFound('Call');
    res.json({ id: Number(req.params.id), deletable: !blocker, blocker });
  }),
);

/** Deletes a never-connected, never-billed call row (see callDeleteBlocker). */
router.delete(
  '/calls/:id',
  validate(idParam, 'params'),
  validate(z.object({ reason: REASON })),
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        'SELECT id, caller_id, listener_id, type, status, end_reason, created_at FROM calls WHERE id = $1 FOR UPDATE',
        [req.params.id],
      );
      const call = rows[0];
      if (!call) throw notFound('Call');
      const blocker = await callDeleteBlocker(client.query.bind(client), call.id);
      if (blocker) throw conflict(blocker.code, blocker.message);
      await client.query('DELETE FROM calls WHERE id = $1', [call.id]);
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'call.delete_unbilled',
        targetType: 'call',
        targetId: call.id,
        reason: req.body.reason,
        metadata: {
          callerId: call.caller_id,
          listenerId: call.listener_id,
          type: call.type,
          status: call.status,
          endReason: call.end_reason,
          createdAt: call.created_at,
        },
      });
      return { id: call.id, auditId };
    });
    res.json({ ...result, deleted: true });
  }),
);

module.exports = router;
module.exports.callDeleteBlocker = callDeleteBlocker;

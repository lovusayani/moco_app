'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { redis } = require('../../config/redis');
const storage = require('../../integrations/storage');
const feedStorage = require('../../integrations/feed.storage');
const listenerStorage = require('../../integrations/listener.storage');
const presence = require('../../realtime/presence');
const socketServer = require('../../realtime/socket.server');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { isAdminPhone } = require('../../middleware/auth');
const { AppError, notFound, badRequest, conflict } = require('../../utils/errors');
const {
  USER_STATUS,
  CHAT_MEDIA,
  FEED_MEDIA,
  LISTENER_PHOTOS,
  REDIS,
  listenerEligibleSql,
} = require('../../utils/constants');
const audit = require('./audit.service');

/**
 * Admin permanent deletion: accounts (users and creators), feed posts,
 * creator photos and chat photos. Mounted under /api/admin behind
 * authenticate + requireAdmin — the console's confirmation UI is a guard
 * against mistakes, never the access control.
 *
 * What "permanent" means for an ACCOUNT is constrained by the money model:
 * coin_ledger and listener_earnings are append-only (a trigger refuses
 * DELETE), and calls/payouts reference users with ON DELETE RESTRICT. So the
 * users row itself stays as an anonymised tombstone (status 'deleted', phone
 * 'deleted_<id>', no name/avatar/push token) that those records keep
 * pointing at, and every piece of personal data or owned content is deleted —
 * rows and stored objects. Accounting therefore still reconciles, and the
 * admin audit log is never touched.
 *
 * Content deletions remove the Storage object INSIDE the database
 * transaction: if Storage refuses, the row deletion rolls back and the admin
 * sees the failure, so a row never outlives its media and media never
 * outlives its row. Removing an already-missing object succeeds, so retrying
 * any of these is safe.
 */
const router = express.Router();

const idParam = z.object({ id: z.coerce.number().int().positive() });
const REASON = z.string().trim().min(5, 'Give a reason of at least 5 characters').max(500);
const BUCKETS = [FEED_MEDIA.bucket, LISTENER_PHOTOS.bucket, CHAT_MEDIA.bucket];

/** A Storage failure surfaces as a clear 502 instead of a generic 500. */
function storageFailure(err) {
  return new AppError(502, err.code || 'storage_failed', `${err.message}. Nothing was deleted; try again.`);
}

async function removeOrFail(bucket, paths) {
  try {
    return await storage.removeStrict(bucket, paths);
  } catch (err) {
    throw storageFailure(err);
  }
}

// ------------------------------------------------------------------ accounts

/**
 * Reasons an account cannot be deleted right now. Each is something the
 * admin can resolve first (end the call, settle the payout) rather than
 * something deletion should silently paper over.
 */
async function deletionBlockers(run, user, adminId) {
  const blockers = [];
  if (Number(user.id) === Number(adminId)) blockers.push({ code: 'self', message: 'You cannot delete your own account.' });
  if (isAdminPhone(user.phone)) blockers.push({ code: 'admin_account', message: 'Admin accounts cannot be deleted from the console.' });
  const { rows } = await run(
    `SELECT
       (SELECT count(*)::int FROM calls
         WHERE (caller_id = $1 OR listener_id = $1) AND status IN ('ringing', 'active')) AS live_calls,
       (SELECT count(*)::int FROM payouts
         WHERE listener_id = $1 AND status IN ('requested', 'approved')) AS open_payouts`,
    [user.id],
  );
  if (rows[0].live_calls > 0) {
    blockers.push({ code: 'live_call', message: 'This account is in a live call. End the call first (Calls).' });
  }
  if (rows[0].open_payouts > 0) {
    blockers.push({
      code: 'open_payout',
      message: `This account has ${rows[0].open_payouts} payout(s) still requested/approved. Pay or reject them first (Payouts).`,
    });
  }
  return blockers;
}

/** What deleting `userId` removes and what it keeps — shown to the admin
 * before they confirm, and recorded in the audit entry. */
async function deletionSummary(run, userId) {
  const { rows } = await run(
    `SELECT
       (SELECT count(*)::int FROM posts WHERE author_user_id = $1) AS posts,
       (SELECT count(*)::int FROM listener_photos WHERE listener_id = $1) AS photos,
       (SELECT count(*)::int FROM conversations WHERE user_a = $1 OR user_b = $1) AS conversations,
       (SELECT count(*)::int FROM messages m JOIN conversations c ON c.id = m.conversation_id
         WHERE c.user_a = $1 OR c.user_b = $1) AS messages,
       (SELECT count(*)::int FROM messages m JOIN conversations c ON c.id = m.conversation_id
         WHERE (c.user_a = $1 OR c.user_b = $1) AND m.media_path IS NOT NULL) AS chat_photos,
       (SELECT count(*)::int FROM message_reactions WHERE user_id = $1) AS reactions,
       (SELECT count(*)::int FROM listener_relations WHERE user_id = $1 OR listener_id = $1) AS follows_favorites,
       (SELECT count(*)::int FROM blocks WHERE blocker_id = $1 OR blocked_id = $1) AS blocks,
       (SELECT count(*)::int FROM notifications WHERE user_id = $1) AS notifications,
       (SELECT count(*)::int FROM coin_ledger WHERE user_id = $1) AS coin_ledger,
       (SELECT count(*)::int FROM listener_earnings WHERE listener_id = $1) AS earnings_ledger,
       (SELECT count(*)::int FROM calls WHERE caller_id = $1 OR listener_id = $1) AS calls,
       (SELECT count(*)::int FROM payouts WHERE listener_id = $1) AS payouts,
       (SELECT count(*)::int FROM purchases WHERE user_id = $1) AS purchases,
       (SELECT count(*)::int FROM reports WHERE reporter_id = $1 OR reported_id = $1) AS reports,
       (SELECT count(*)::int FROM call_ratings WHERE rater_id = $1) AS ratings_given,
       (SELECT count(*)::int FROM auth_events WHERE user_id = $1) AS auth_events,
       (SELECT count(*)::int FROM admin_audit_log WHERE target_type = 'user' AND target_id = $2) AS audit_entries,
       (SELECT COALESCE(coin_balance, 0)::bigint FROM wallets WHERE user_id = $1) AS coin_balance,
       (SELECT earnings_balance::bigint FROM listener_profiles WHERE user_id = $1) AS earnings_balance`,
    [userId, String(userId)],
  );
  const r = rows[0];
  return {
    deleted: {
      posts: r.posts,
      creatorPhotos: r.photos,
      conversations: r.conversations,
      messages: r.messages,
      chatPhotos: r.chat_photos,
      reactions: r.reactions,
      followsAndFavorites: r.follows_favorites,
      blocks: r.blocks,
      notifications: r.notifications,
    },
    anonymized: {
      account: 'phone, name, avatar, gender and push token cleared; status deleted',
      creatorProfile: 'bio, KYC name, KYC document link, UPI ID and review note cleared; offline',
      ratingsGiven: r.ratings_given,
      signInEvents: r.auth_events,
    },
    retained: {
      coinLedgerEntries: r.coin_ledger,
      earningsLedgerEntries: r.earnings_ledger,
      calls: r.calls,
      payouts: r.payouts,
      purchases: r.purchases,
      reports: r.reports,
      auditEntries: r.audit_entries,
      coinBalance: Number(r.coin_balance ?? 0),
      earningsBalance: r.earnings_balance == null ? null : Number(r.earnings_balance),
    },
  };
}

router.get(
  '/users/:id/deletion-preview',
  validate(idParam, 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query('SELECT id, phone, status FROM users WHERE id = $1', [req.params.id]);
    const user = rows[0];
    if (!user) throw notFound('User');
    res.json({
      id: user.id,
      status: user.status,
      blockers: await deletionBlockers(query, user, req.user.id),
      ...(await deletionSummary(query, user.id)),
    });
  }),
);

/**
 * Permanently deletes an account (user or creator). Body:
 * `{ reason, confirm }` where `confirm` must be the account id — a typed
 * confirmation the server checks, so no client can skip it.
 */
router.delete(
  '/users/:id',
  validate(idParam, 'params'),
  validate(z.object({ reason: REASON, confirm: z.string().trim() })),
  asyncHandler(async (req, res) => {
    const id = Number(req.params.id);
    if (req.body.confirm !== String(id)) {
      throw badRequest('confirmation_mismatch', `Type the account id (${id}) to confirm permanent deletion`);
    }

    const { rows: found } = await query('SELECT id, phone, status FROM users WHERE id = $1', [id]);
    if (!found[0]) throw notFound('User');
    const pre = await deletionBlockers(query, found[0], req.user.id);
    if (pre.length) throw conflict(pre[0].code, pre[0].message);

    // Offline first, committed on its own: from here no new call can reach
    // this account while the deletion runs.
    const { rows: profile } = await query('SELECT is_online FROM listener_profiles WHERE user_id = $1', [id]);
    if (profile[0]?.is_online) await presence.setOnline(id, false);

    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        'SELECT id, phone, status, role FROM users WHERE id = $1 FOR UPDATE',
        [id],
      );
      const user = rows[0];
      if (!user) throw notFound('User');
      // Re-checked under the lock: a call could have started a moment ago.
      const blockers = await deletionBlockers(client.query.bind(client), user, req.user.id);
      if (blockers.length) throw conflict(blockers[0].code, blockers[0].message);

      const summary = await deletionSummary(client.query.bind(client), id);
      const paths = await client.query(
        `SELECT
           ARRAY(SELECT media_path FROM posts WHERE author_user_id = $1) AS feed,
           ARRAY(SELECT storage_path FROM listener_photos WHERE listener_id = $1) AS photos,
           ARRAY(SELECT m.media_path FROM messages m JOIN conversations c ON c.id = m.conversation_id
                  WHERE (c.user_a = $1 OR c.user_b = $1) AND m.media_path IS NOT NULL) AS chat`,
        [id],
      );
      const { feed, photos, chat } = paths.rows[0];

      // The audit entry is written first, in the same transaction: the
      // record and the deletion commit together or not at all. No phone or
      // name goes into it — the point is that they stop existing.
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'user.delete_permanent',
        targetType: 'user',
        targetId: id,
        reason: req.body.reason,
        metadata: { previousStatus: user.status, role: user.role, ...summary },
      });

      // Owned content and relations: deleted outright.
      await client.query('DELETE FROM posts WHERE author_user_id = $1', [id]);
      await client.query('DELETE FROM listener_photos WHERE listener_id = $1', [id]);
      // Messages and their reactions cascade from the conversation.
      await client.query('DELETE FROM conversations WHERE user_a = $1 OR user_b = $1', [id]);
      await client.query('DELETE FROM message_reactions WHERE user_id = $1', [id]);
      await client.query('DELETE FROM listener_relations WHERE user_id = $1 OR listener_id = $1', [id]);
      await client.query('DELETE FROM blocks WHERE blocker_id = $1 OR blocked_id = $1', [id]);
      await client.query('DELETE FROM notifications WHERE user_id = $1', [id]);

      // Records that must stay for accounting or moderation: anonymised.
      await client.query('UPDATE call_ratings SET comment = NULL WHERE rater_id = $1', [id]);
      await client.query(
        `UPDATE auth_events SET phone = 'deleted_' || $1::text, ip = NULL
          WHERE user_id = $1 OR phone = $2`,
        [id, user.phone],
      );
      await client.query(
        `UPDATE listener_profiles
            SET is_online = FALSE, bio = NULL, kyc_name = NULL, kyc_doc_url = NULL,
                upi_id = NULL, kyc_review_note = NULL, updated_at = now()
          WHERE user_id = $1`,
        [id],
      );
      // The tombstone. authenticate() rejects status 'deleted' on every
      // request, so every outstanding token stops working right here.
      await client.query(
        `UPDATE users
            SET status = $2, phone = 'deleted_' || id, display_name = NULL, avatar_url = NULL,
                gender = NULL, fcm_token = NULL, updated_at = now()
          WHERE id = $1`,
        [id, USER_STATUS.DELETED],
      );

      // Stored objects, still inside the transaction: every referenced
      // object, then anything else under this account's own folder in each
      // bucket (uploads that were never registered). Any Storage refusal
      // rolls everything above back.
      const removed = { feed: [], photos: [], chat: [], unregistered: [] };
      removed.feed = (await removeOrFail(FEED_MEDIA.bucket, feed)).removed;
      removed.photos = (await removeOrFail(LISTENER_PHOTOS.bucket, photos)).removed;
      removed.chat = (await removeOrFail(CHAT_MEDIA.bucket, chat)).removed;
      for (const bucket of BUCKETS) {
        let leftovers;
        try {
          leftovers = await storage.listPrefix(bucket, String(id));
        } catch (err) {
          throw storageFailure(err);
        }
        removed.unregistered.push(...(await removeOrFail(bucket, leftovers)).removed);
      }

      return { auditId, summary, removed };
    });

    // After commit: end live sessions now rather than at the next request.
    socketServer.disconnectUser(id);
    await redis.del(REDIS.presenceKey(id)).catch(() => {});

    res.json({
      id,
      status: USER_STATUS.DELETED,
      auditId: result.auditId,
      ...result.summary,
      storageObjectsRemoved: {
        feed: result.removed.feed.length,
        creatorPhotos: result.removed.photos.length,
        chat: result.removed.chat.length,
        unregistered: result.removed.unregistered.length,
      },
    });
  }),
);

/** Everything an account has uploaded, for per-item permanent deletion.
 * Chat photos are listed WITHOUT previews: they are private messages, and an
 * admin acting on one (from a report) does not need to browse them. */
router.get(
  '/users/:id/uploads',
  validate(idParam, 'params'),
  asyncHandler(async (req, res) => {
    const id = req.params.id;
    const [posts, photos, chat] = await Promise.all([
      query(
        `SELECT id, media_type, media_path, caption, status, created_at
           FROM posts WHERE author_user_id = $1 ORDER BY id DESC LIMIT 100`,
        [id],
      ),
      query(
        `SELECT id, storage_path, mime_type, size_bytes, created_at
           FROM listener_photos WHERE listener_id = $1 ORDER BY created_at, id`,
        [id],
      ),
      query(
        `SELECT m.id, m.conversation_id, m.created_at,
                CASE WHEN c.user_a = $1 THEN c.user_b ELSE c.user_a END AS other_user_id
           FROM messages m JOIN conversations c ON c.id = m.conversation_id
          WHERE m.sender_id = $1 AND m.media_path IS NOT NULL
          ORDER BY m.id DESC LIMIT 100`,
        [id],
      ),
    ]);
    const [postUrls, photoUrls] = await Promise.all([
      feedStorage.createViewUrls(posts.rows.map((p) => p.media_path)),
      listenerStorage.createViewUrls(photos.rows.map((p) => p.storage_path)),
    ]);
    res.json({
      posts: posts.rows.map(({ media_path: mediaPath, ...p }) => ({ ...p, mediaUrl: postUrls.get(mediaPath) ?? null })),
      photos: photos.rows.map(({ storage_path: storagePath, ...p }) => ({ ...p, url: photoUrls.get(storagePath) ?? null })),
      chatPhotos: chat.rows,
    });
  }),
);

// ------------------------------------------------------------------- content

const reasonBody = z.object({ reason: REASON });

/** Permanently deletes a feed post (image or video): row and stored media.
 * Hide/Restore (POST /posts/:id) remains the reversible option. */
router.delete(
  '/posts/:id',
  validate(idParam, 'params'),
  validate(reasonBody),
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        'SELECT id, author_user_id, media_type, media_path, status FROM posts WHERE id = $1 FOR UPDATE',
        [req.params.id],
      );
      const post = rows[0];
      if (!post) throw notFound('Post');
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'content.delete_permanent',
        targetType: 'post',
        targetId: post.id,
        reason: req.body.reason,
        metadata: { authorId: post.author_user_id, mediaType: post.media_type, previousStatus: post.status },
      });
      await client.query('DELETE FROM posts WHERE id = $1', [post.id]);
      const { removed } = await removeOrFail(FEED_MEDIA.bucket, [post.media_path]);
      return { id: post.id, auditId, storageObjectsRemoved: removed.length };
    });
    res.json({ ...result, deleted: true });
  }),
);

/** Permanently deletes one creator photo. Moderation may take an approved
 * creator below the photo minimum; they are then taken offline, exactly as
 * the eligibility rule requires. */
router.delete(
  '/listener-photos/:id',
  validate(idParam, 'params'),
  validate(reasonBody),
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        'SELECT id, listener_id, storage_path FROM listener_photos WHERE id = $1 FOR UPDATE',
        [req.params.id],
      );
      const photo = rows[0];
      if (!photo) throw notFound('Photo');
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'listener_photo.delete_permanent',
        targetType: 'listener',
        targetId: photo.listener_id,
        reason: req.body.reason,
        metadata: { photoId: photo.id },
      });
      await client.query('DELETE FROM listener_photos WHERE id = $1', [photo.id]);
      const { removed } = await removeOrFail(LISTENER_PHOTOS.bucket, [photo.storage_path]);
      const { rows: after } = await client.query(
        `SELECT photo_count, is_online, ${listenerEligibleSql('lp')} AS eligible
           FROM listener_profiles lp WHERE user_id = $1`,
        [photo.listener_id],
      );
      return {
        id: photo.id,
        listenerId: photo.listener_id,
        auditId,
        storageObjectsRemoved: removed.length,
        photoCount: after[0]?.photo_count ?? 0,
        takeOffline: Boolean(after[0]?.is_online && !after[0]?.eligible),
      };
    });
    if (result.takeOffline) await presence.setOnline(result.listenerId, false);
    const { takeOffline, ...body } = result;
    res.json({ ...body, deleted: true, takenOffline: takeOffline });
  }),
);

/** Permanently deletes one chat photo message (row, reactions and stored
 * image) — for acting on a report about a private photo. */
router.delete(
  '/chat-media/:id',
  validate(idParam, 'params'),
  validate(reasonBody),
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const { rows } = await client.query(
        `SELECT id, conversation_id, sender_id, media_path FROM messages
          WHERE id = $1 AND media_path IS NOT NULL FOR UPDATE`,
        [req.params.id],
      );
      const message = rows[0];
      if (!message) throw notFound('Chat photo');
      const auditId = await audit.record(client, {
        admin: req.user,
        action: 'chat_media.delete_permanent',
        targetType: 'message',
        targetId: message.id,
        reason: req.body.reason,
        metadata: { conversationId: message.conversation_id, senderId: message.sender_id },
      });
      // Reactions on it cascade with the row.
      await client.query('DELETE FROM messages WHERE id = $1', [message.id]);
      const { removed } = await removeOrFail(CHAT_MEDIA.bucket, [message.media_path]);
      return { id: message.id, auditId, storageObjectsRemoved: removed.length };
    });
    res.json({ ...result, deleted: true });
  }),
);

module.exports = router;

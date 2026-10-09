'use strict';

const express = require('express');
const { z } = require('zod');
const { query } = require('../../config/db');
const feedStorage = require('../../integrations/feed.storage');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { redis } = require('../../config/redis');
const notifications = require('../notifications/notifications.service');
const { forbidden, notFound, badRequest } = require('../../utils/errors');
const {
  FEED_MEDIA,
  FEED_MEDIA_MIME_TYPES,
  KYC_STATUS,
  POST_STATUS,
  postMediaTypeForMime,
  feedMaxBytesFor,
  listenerEligibleSql,
} = require('../../utils/constants');

const router = express.Router();
router.use(authenticate);

/**
 * The Feed.
 *
 * Newest-first and deterministic — there is deliberately no ranking or
 * recommendation here. Ordering is by post id descending, which for an
 * identity column is creation order, so keyset pagination on the same column
 * cannot skip or repeat a post the way an OFFSET page can when someone posts
 * mid-scroll. The client dedupes by id as well, but it should never have to.
 */

/**
 * Shapes one row for the client, minting a signed media URL per read.
 *
 * `author.isListener` exists so the client knows whether tapping the author
 * has a destination: the only profile screen that exists is the listener
 * profile, so a non-listener author's name is not a link. That is an honest
 * "no screen for this yet", not a silently broken tap.
 */
async function toPost(row) {
  return {
    id: row.id,
    mediaType: row.media_type,
    mediaUrl: await feedStorage.createViewUrl(row.media_path),
    caption: row.caption,
    createdAt: row.created_at,
    likeCount: Number(row.like_count ?? 0),
    liked: Boolean(row.liked),
    commentCount: Number(row.comment_count ?? 0),
    shareCount: Number(row.share_count ?? 0),
    author: {
      id: row.author_user_id,
      name: row.display_name,
      avatarUrl: row.avatar_url,
      isListener: row.is_listener,
      verified: row.verified,
      // Follow is the existing listener follow (listener_relations): only an
      // eligible listener can be followed, and never yourself.
      canFollow: Boolean(row.can_follow),
      isFollowing: Boolean(row.is_following),
    },
  };
}

/**
 * The feed's post columns for viewer $2: author, the viewer's like/follow
 * state and the like/comment/share counts. $1 = active status, $3 = the
 * approved KYC status. Callers add their own WHERE terms after these.
 */
const POST_SELECT = `
  SELECT p.id, p.author_user_id, p.media_type, p.media_path, p.caption, p.created_at, p.share_count,
         u.display_name, u.avatar_url,
         (lp.user_id IS NOT NULL) AS is_listener,
         -- Same rule as discovery: publish the derived boolean, never the
         -- underlying KYC state.
         (lp.kyc_status = $3) AS verified,
         (SELECT count(*) FROM post_likes l WHERE l.post_id = p.id) AS like_count,
         EXISTS (SELECT 1 FROM post_likes l WHERE l.post_id = p.id AND l.user_id = $2) AS liked,
         (SELECT count(*) FROM post_comments c WHERE c.post_id = p.id) AS comment_count,
         (lp.user_id IS NOT NULL AND ${listenerEligibleSql('lp')} AND p.author_user_id <> $2) AS can_follow,
         EXISTS (SELECT 1 FROM listener_relations r
                  WHERE r.user_id = $2 AND r.listener_id = p.author_user_id AND r.kind = 'follow') AS is_following
    FROM posts p
    JOIN users u ON u.id = p.author_user_id
    LEFT JOIN listener_profiles lp ON lp.user_id = p.author_user_id
   WHERE p.status = $1
     AND u.status = 'active'
     -- The existing one-directional block row, checked in both directions —
     -- the same predicate discovery and chat already use. No second block
     -- system.
     AND NOT EXISTS (
           SELECT 1 FROM blocks b
            WHERE (b.blocker_id = $2 AND b.blocked_id = p.author_user_id)
               OR (b.blocker_id = p.author_user_id AND b.blocked_id = $2))`;

/** One visible post for this viewer, or null (gone, removed, or blocked either way). */
async function visiblePost(postId, viewerId) {
  const { rows } = await query(`${POST_SELECT} AND p.id = $4`, [
    POST_STATUS.ACTIVE,
    viewerId,
    KYC_STATUS.APPROVED,
    postId,
  ]);
  return rows[0] || null;
}

const feedQuerySchema = z.object({
  limit: z.coerce.number().int().min(1).max(30).default(10),
  /** Keyset cursor: the id of the last post the client already has. */
  cursor: z.coerce.number().int().positive().optional(),
});

router.get(
  '/',
  validate(feedQuerySchema, 'query'),
  asyncHandler(async (req, res) => {
    const { limit, cursor } = req.query;

    const { rows } = await query(
      `${POST_SELECT}
          -- Keyset pagination. id DESC is creation order, so this is a stable
          -- "everything older than what I have" with no OFFSET drift.
          AND ($4::bigint IS NULL OR p.id < $4)
        ORDER BY p.id DESC
        LIMIT $5`,
      [POST_STATUS.ACTIVE, req.user.id, KYC_STATUS.APPROVED, cursor ?? null, limit],
    );

    const posts = await Promise.all(rows.map(toPost));

    return res.json({
      posts,
      // Null only when this page was short, which is the one reliable signal
      // that there is nothing older — a full page always gets a cursor even
      // if the next page turns out to be empty.
      nextCursor: rows.length === limit ? rows[rows.length - 1].id : null,
    });
  }),
);

/**
 * Authorizes a post media upload. The client PUTs the bytes straight to
 * Supabase Storage with the returned URL and then calls `POST /feed` with the
 * path — media never travels through this API.
 *
 * The MIME type is validated here, before a URL exists, and it is what
 * decides the stored extension. Everything downstream derives the media type
 * from that path rather than believing the client a second time.
 */
router.post(
  '/media/upload-url',
  rateLimit({ windowSeconds: 3600, max: 30, keyPrefix: 'feed_media_upload' }),
  validate(z.object({ mimeType: z.enum(FEED_MEDIA_MIME_TYPES) })),
  asyncHandler(async (req, res) => {
    if (!feedStorage.isConfigured()) {
      throw badRequest('storage_not_configured', 'Posting is not available right now');
    }

    const mediaType = postMediaTypeForMime(req.body.mimeType);
    const { path, uploadUrl, token } = await feedStorage.createUploadUrl({
      userId: req.user.id,
      mimeType: req.body.mimeType,
    });

    res.json({
      path,
      uploadUrl,
      token,
      mediaType,
      maxBytes: feedMaxBytesFor(mediaType),
      maxVideoSeconds: FEED_MEDIA.maxVideoSeconds,
    });
  }),
);

/**
 * Publishes a post for media the caller has already uploaded.
 *
 * Four things are checked, none of them taken on trust from the request:
 *  1. the path is one minted for THIS user (prefix check — the upload URL was
 *     already scoped to it, this rejects referencing someone else's upload);
 *  2. the media type comes from the path's extension, not the body;
 *  3. the object actually exists in the bucket, so a client cannot publish a
 *     post whose media was never uploaded and would render as a broken item;
 *  4. its real size is within the cap for its type — the signed upload URL
 *     cannot enforce that itself, so it is enforced here before any row
 *     references the object.
 */
router.post(
  '/',
  rateLimit({ windowSeconds: 3600, max: 20, keyPrefix: 'feed_create' }),
  validate(
    z.object({
      mediaPath: z.string().min(1).max(400),
      caption: z.string().trim().max(FEED_MEDIA.maxCaptionLength).optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { mediaPath } = req.body;

    // Authorization first, and deliberately before the storage-availability
    // check: a path that is not this user's is refused whether or not storage
    // happens to be configured. Config state must never widen access.
    if (!feedStorage.pathBelongsToUser(mediaPath, req.user.id)) {
      throw forbidden('This media does not belong to you');
    }

    const mediaType = feedStorage.mediaTypeForPath(mediaPath);
    if (!mediaType) {
      throw badRequest('unsupported_media', 'That file type cannot be posted');
    }

    if (!feedStorage.isConfigured()) {
      throw badRequest('storage_not_configured', 'Posting is not available right now');
    }

    const object = await feedStorage.statObject(mediaPath);
    if (!object) {
      throw badRequest('media_not_uploaded', 'The upload did not finish. Please try again.');
    }

    const maxBytes = feedMaxBytesFor(mediaType);
    if (object.sizeBytes !== null && object.sizeBytes > maxBytes) {
      // Remove it rather than leave a too-large object paid for but unusable.
      await feedStorage.remove(mediaPath);
      throw badRequest('media_too_large', 'That file is too large to post');
    }

    // A blank caption and no caption are the same thing (and the schema's
    // CHECK rejects ''), so normalise to null.
    const caption = req.body.caption && req.body.caption.length > 0 ? req.body.caption : null;

    const { rows } = await query(
      `INSERT INTO posts (author_user_id, media_type, media_path, caption)
       VALUES ($1, $2, $3, $4)
       -- UNIQUE(media_path): a double-tapped Publish re-registering the same
       -- upload is a no-op rather than a duplicate post.
       ON CONFLICT (media_path) DO NOTHING
       RETURNING id, author_user_id, media_type, media_path, caption, created_at`,
      [req.user.id, mediaType, mediaPath, caption],
    );

    if (!rows[0]) {
      throw badRequest('already_posted', 'That media has already been posted');
    }

    res.status(201).json({ post: await toPost(await visiblePost(rows[0].id, req.user.id)) });
  }),
);

// --- one post, likes, comments, shares --------------------------------------

const postIdParam = z.object({ postId: z.coerce.number().int().positive() });

/** One post (for a shared link). 404 when it is gone or blocked either way. */
router.get(
  '/:postId',
  validate(postIdParam, 'params'),
  asyncHandler(async (req, res) => {
    const row = await visiblePost(req.params.postId, req.user.id);
    if (!row) throw notFound('Post');
    res.json({ post: await toPost(row) });
  }),
);

async function likeState(postId, viewerId) {
  const { rows } = await query(
    `SELECT (SELECT count(*)::int FROM post_likes WHERE post_id = $1) AS like_count,
            EXISTS (SELECT 1 FROM post_likes WHERE post_id = $1 AND user_id = $2) AS liked`,
    [postId, viewerId],
  );
  return { postId: Number(postId), liked: rows[0].liked, likeCount: rows[0].like_count };
}

/**
 * Like / unlike. Idempotent (primary key + ON CONFLICT): a double tap or a
 * retry cannot double-count. Always answers with the resulting state so an
 * optimistic client can reconcile.
 */
router.put(
  '/:postId/like',
  rateLimit({ windowSeconds: 60, max: 120, keyPrefix: 'feed_like' }),
  validate(postIdParam, 'params'),
  asyncHandler(async (req, res) => {
    const post = await visiblePost(req.params.postId, req.user.id);
    if (!post) throw notFound('Post');
    const { rowCount } = await query(
      'INSERT INTO post_likes (post_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING',
      [post.id, req.user.id],
    );
    if (rowCount === 1) await notifyLike(post, req.user);
    res.json(await likeState(post.id, req.user.id));
  }),
);

router.delete(
  '/:postId/like',
  rateLimit({ windowSeconds: 60, max: 120, keyPrefix: 'feed_like' }),
  validate(postIdParam, 'params'),
  asyncHandler(async (req, res) => {
    await query('DELETE FROM post_likes WHERE post_id = $1 AND user_id = $2', [req.params.postId, req.user.id]);
    res.json(await likeState(req.params.postId, req.user.id));
  }),
);

async function commentCount(postId) {
  const { rows } = await query('SELECT count(*)::int AS n FROM post_comments WHERE post_id = $1', [postId]);
  return rows[0].n;
}

function toComment(row, viewerId, postAuthorId) {
  const mine = Number(row.author_user_id) === Number(viewerId);
  return {
    id: Number(row.id),
    body: row.body,
    createdAt: row.created_at,
    author: { id: Number(row.author_user_id), name: row.display_name, avatarUrl: row.avatar_url },
    isOwn: mine,
    // The commenter, or the post's author moderating their own post.
    canDelete: mine || Number(postAuthorId) === Number(viewerId),
  };
}

/** Comments, newest first, keyset-paginated. Comments across a block (either way) are hidden. */
router.get(
  '/:postId/comments',
  validate(postIdParam, 'params'),
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(50).default(30),
      cursor: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const post = await visiblePost(req.params.postId, req.user.id);
    if (!post) throw notFound('Post');
    const { limit, cursor } = req.query;
    const { rows } = await query(
      `SELECT c.id, c.body, c.created_at, c.author_user_id, u.display_name, u.avatar_url
         FROM post_comments c JOIN users u ON u.id = c.author_user_id
        WHERE c.post_id = $1
          AND ($2::bigint IS NULL OR c.id < $2)
          AND NOT EXISTS (
                SELECT 1 FROM blocks b
                 WHERE (b.blocker_id = $3 AND b.blocked_id = c.author_user_id)
                    OR (b.blocker_id = c.author_user_id AND b.blocked_id = $3))
        ORDER BY c.id DESC
        LIMIT $4`,
      [post.id, cursor ?? null, req.user.id, limit],
    );
    res.json({
      comments: rows.map((r) => toComment(r, req.user.id, post.author_user_id)),
      nextCursor: rows.length === limit ? Number(rows[rows.length - 1].id) : null,
      commentCount: await commentCount(post.id),
    });
  }),
);

router.post(
  '/:postId/comments',
  rateLimit({ windowSeconds: 60, max: 20, keyPrefix: 'feed_comment' }),
  validate(postIdParam, 'params'),
  validate(z.object({ body: z.string().trim().min(1).max(500) })),
  asyncHandler(async (req, res) => {
    const post = await visiblePost(req.params.postId, req.user.id);
    if (!post) throw notFound('Post');
    const { rows } = await query(
      `INSERT INTO post_comments (post_id, author_user_id, body) VALUES ($1, $2, $3)
       RETURNING id, body, created_at, author_user_id`,
      [post.id, req.user.id, req.body.body],
    );
    await notifyComment(post, req.user, req.body.body);
    const { rows: me } = await query('SELECT display_name, avatar_url FROM users WHERE id = $1', [req.user.id]);
    const comment = toComment({ ...rows[0], ...me[0] }, req.user.id, post.author_user_id);
    res.status(201).json({ comment, commentCount: await commentCount(post.id) });
  }),
);

router.delete(
  '/:postId/comments/:commentId',
  validate(z.object({ postId: z.coerce.number().int().positive(), commentId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const { postId, commentId } = req.params;
    // The commenter, or the author of the post the comment is on.
    const { rowCount } = await query(
      `DELETE FROM post_comments c USING posts p
        WHERE c.id = $1 AND c.post_id = $2 AND p.id = c.post_id
          AND (c.author_user_id = $3 OR p.author_user_id = $3)`,
      [commentId, postId, req.user.id],
    );
    if (rowCount === 0) {
      const { rows } = await query('SELECT 1 FROM post_comments WHERE id = $1 AND post_id = $2', [commentId, postId]);
      // Someone else's comment on someone else's post: not yours to delete.
      if (rows[0]) throw forbidden('You cannot delete this comment');
    }
    res.json({ ok: true, commentCount: await commentCount(postId) });
  }),
);

/**
 * Records that the viewer shared a post (the client calls this only after a
 * share sheet opened or a link was copied — never on render). Counted at
 * most once per user per post per hour.
 */
router.post(
  '/:postId/share',
  rateLimit({ windowSeconds: 3600, max: 120, keyPrefix: 'feed_share' }),
  validate(postIdParam, 'params'),
  validate(z.object({ method: z.enum(['native', 'copy']).optional() })),
  asyncHandler(async (req, res) => {
    const post = await visiblePost(req.params.postId, req.user.id);
    if (!post) throw notFound('Post');
    const fresh = await redis
      .set(`feed:share:${post.id}:${req.user.id}`, '1', 'EX', 3600, 'NX')
      .catch(() => 'OK');
    let shareCount = Number(post.share_count);
    if (fresh === 'OK') {
      const { rows } = await query(
        'UPDATE posts SET share_count = share_count + 1 WHERE id = $1 RETURNING share_count',
        [post.id],
      );
      shareCount = rows[0].share_count;
    }
    res.json({ postId: Number(post.id), shareCount, counted: fresh === 'OK' });
  }),
);

// --- notifications (in-app; deduplicated so taps cannot spam an inbox) -------

const displayName = (user) => user.display_name || 'Someone';

/** One like notification per (post, liker), ever — unliking and re-liking stays quiet. */
async function notifyLike(post, liker) {
  if (Number(post.author_user_id) === Number(liker.id)) return;
  const { rows } = await query(
    `SELECT 1 FROM notifications
      WHERE user_id = $1 AND type = 'post_like' AND data->>'postId' = $2 AND data->>'actorId' = $3
      LIMIT 1`,
    [post.author_user_id, String(post.id), String(liker.id)],
  );
  if (rows[0]) return;
  await notifications.create({
    userId: post.author_user_id,
    type: 'post_like',
    title: `${displayName(liker)} liked your post`,
    data: { postId: Number(post.id), actorId: Number(liker.id) },
  });
}

/** Comments notify the post's author, at most once per commenter per post per 10 minutes. */
async function notifyComment(post, commenter, body) {
  if (Number(post.author_user_id) === Number(commenter.id)) return;
  const { rows } = await query(
    `SELECT 1 FROM notifications
      WHERE user_id = $1 AND type = 'post_comment' AND data->>'postId' = $2 AND data->>'actorId' = $3
        AND created_at > now() - interval '10 minutes'
      LIMIT 1`,
    [post.author_user_id, String(post.id), String(commenter.id)],
  );
  if (rows[0]) return;
  await notifications.create({
    userId: post.author_user_id,
    type: 'post_comment',
    title: `${displayName(commenter)} commented on your post`,
    body: body.length > 140 ? `${body.slice(0, 137)}…` : body,
    data: { postId: Number(post.id), actorId: Number(commenter.id) },
  });
}

/**
 * Soft-deletes the caller's own post. Author-only: there is no moderation
 * path here — an admin removing someone else's post goes through the report
 * queue, not this endpoint.
 */
router.delete(
  '/:postId',
  validate(z.object({ postId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `UPDATE posts SET status = $1
        WHERE id = $2 AND author_user_id = $3 AND status = $4
        RETURNING id, media_path`,
      [POST_STATUS.REMOVED, req.params.postId, req.user.id, POST_STATUS.ACTIVE],
    );

    if (!rows[0]) {
      const { rows: existing } = await query(
        'SELECT author_user_id, status FROM posts WHERE id = $1',
        [req.params.postId],
      );
      if (!existing[0]) throw notFound('Post');
      // Someone else's post reads as "not found" rather than "forbidden":
      // a post id must not be confirmable by probing this endpoint.
      if (Number(existing[0].author_user_id) !== Number(req.user.id)) throw notFound('Post');
      // Own post, already removed — deleting twice is a success, not an error.
      return res.json({ ok: true, postId: Number(req.params.postId) });
    }

    // The row is already hidden; losing the object is a cost, not a bug.
    await feedStorage.remove(rows[0].media_path);

    res.json({ ok: true, postId: rows[0].id });
  }),
);

module.exports = router;

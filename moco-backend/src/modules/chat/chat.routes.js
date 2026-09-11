'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const callEvents = require('../../realtime/call.events');
const chatStorage = require('../../integrations/chat.storage');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { forbidden, notFound, badRequest } = require('../../utils/errors');
const { MESSAGE_TYPE, CHAT_MEDIA } = require('../../utils/constants');

const router = express.Router();
router.use(authenticate);

/** Conversations store the pair in ascending id order, so callers must normalise. */
const pairKey = (a, b) => (Number(a) < Number(b) ? [Number(a), Number(b)] : [Number(b), Number(a)]);

async function assertNotBlocked(userId, otherId) {
  const { rows } = await query(
    `SELECT 1 FROM blocks
      WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)`,
    [userId, otherId],
  );
  if (rows.length > 0) throw forbidden('This user is not available');
}

/** Attaches each message's reactions (`[{ userId, emoji }]`) in one extra query. */
async function attachReactions(messages) {
  if (messages.length === 0) return messages;

  const { rows } = await query(
    `SELECT message_id, user_id, emoji FROM message_reactions WHERE message_id = ANY($1::bigint[])`,
    [messages.map((m) => m.id)],
  );

  const byMessage = new Map();
  for (const row of rows) {
    const list = byMessage.get(row.message_id) ?? [];
    list.push({ userId: row.user_id, emoji: row.emoji });
    byMessage.set(row.message_id, list);
  }

  return Promise.all(
    messages.map(async (m) => ({
      id: m.id,
      senderId: m.sender_id,
      type: m.type,
      body: m.body,
      mediaUrl: m.media_path ? await chatStorage.createViewUrl(m.media_path) : null,
      readAt: m.read_at,
      createdAt: m.created_at,
      reactions: byMessage.get(m.id) ?? [],
    })),
  );
}

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT c.id, c.last_message_at,
              other.id AS other_id, other.display_name, other.avatar_url,
              m.body AS last_body, m.type AS last_type, m.sender_id AS last_sender_id,
              (SELECT count(*)::int FROM messages um
                WHERE um.conversation_id = c.id AND um.sender_id <> $1 AND um.read_at IS NULL
              ) AS unread_count
         FROM conversations c
         JOIN users other
           ON other.id = CASE WHEN c.user_a = $1 THEN c.user_b ELSE c.user_a END
         LEFT JOIN LATERAL (
              SELECT body, type, sender_id FROM messages
               WHERE conversation_id = c.id ORDER BY id DESC LIMIT 1
         ) m ON TRUE
        WHERE c.user_a = $1 OR c.user_b = $1
        ORDER BY c.last_message_at DESC NULLS LAST
        LIMIT 50`,
      [req.user.id],
    );

    res.json({
      conversations: rows.map((row) => ({
        id: row.id,
        counterparty: {
          id: row.other_id,
          name: row.display_name,
          avatarUrl: row.avatar_url,
        },
        // A photo message has no body — the list shows a fixed label rather
        // than a blank preview, without fetching or signing the image itself.
        lastMessage: row.last_type === MESSAGE_TYPE.IMAGE ? 'Photo' : row.last_body,
        lastMessageAt: row.last_message_at,
        unreadCount: row.unread_count,
      })),
    });
  }),
);

router.get(
  '/:userId/messages',
  validate(
    z.object({ userId: z.coerce.number().int().positive() }),
    'params',
  ),
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(100).default(50),
      before: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const [a, b] = pairKey(req.user.id, req.params.userId);

    const { rows: convRows } = await query(
      'SELECT id FROM conversations WHERE user_a = $1 AND user_b = $2',
      [a, b],
    );

    if (!convRows[0]) return res.json({ messages: [], nextCursor: null });

    const { rows } = await query(
      `SELECT id, sender_id, type, body, media_path, read_at, created_at
         FROM messages
        WHERE conversation_id = $1 AND ($2::bigint IS NULL OR id < $2)
        ORDER BY id DESC LIMIT $3`,
      [convRows[0].id, req.query.before ?? null, req.query.limit],
    );

    // Mark the other side's messages read now that they have been fetched.
    await query(
      `UPDATE messages SET read_at = now()
        WHERE conversation_id = $1 AND sender_id <> $2 AND read_at IS NULL`,
      [convRows[0].id, req.user.id],
    );

    const messages = await attachReactions(rows.reverse());

    return res.json({
      messages,
      nextCursor: rows.length > 0 ? rows[0].id : null,
    });
  }),
);

const sendBodySchema = z.union([
  z.object({ body: z.string().min(1).max(2000) }),
  z.object({ type: z.literal(MESSAGE_TYPE.IMAGE), mediaPath: z.string().min(1) }),
]);

router.post(
  '/:userId/messages',
  rateLimit({ windowSeconds: 60, max: 60, keyPrefix: 'chat_send' }),
  validate(z.object({ userId: z.coerce.number().int().positive() }), 'params'),
  validate(sendBodySchema),
  asyncHandler(async (req, res) => {
    const otherId = req.params.userId;
    if (Number(otherId) === Number(req.user.id)) {
      throw forbidden('You cannot message yourself');
    }

    await assertNotBlocked(req.user.id, otherId);

    const { rows: exists } = await query(`SELECT 1 FROM users WHERE id = $1 AND status = 'active'`, [
      otherId,
    ]);
    if (!exists[0]) throw notFound('User');

    const isImage = req.body.type === MESSAGE_TYPE.IMAGE;
    if (isImage && !chatStorage.pathBelongsToUser(req.body.mediaPath, req.user.id)) {
      // The signed upload URL was already scoped to this user's own path;
      // this rejects a client that tries to reference someone else's upload.
      throw forbidden('This media does not belong to you');
    }

    const [a, b] = pairKey(req.user.id, otherId);

    const message = await withTransaction(async (client) => {
      const { rows: conv } = await client.query(
        `INSERT INTO conversations (user_a, user_b, last_message_at)
         VALUES ($1, $2, now())
         ON CONFLICT (user_a, user_b) DO UPDATE SET last_message_at = now()
         RETURNING id`,
        [a, b],
      );

      const { rows } = await client.query(
        `INSERT INTO messages (conversation_id, sender_id, type, body, media_path)
         VALUES ($1, $2, $3, $4, $5) RETURNING *`,
        [
          conv[0].id,
          req.user.id,
          isImage ? MESSAGE_TYPE.IMAGE : MESSAGE_TYPE.TEXT,
          isImage ? null : req.body.body,
          isImage ? req.body.mediaPath : null,
        ],
      );
      return rows[0];
    });

    const mediaUrl = isImage ? await chatStorage.createViewUrl(message.media_path) : null;

    await callEvents.chatMessage(otherId, {
      conversationId: message.conversation_id,
      messageId: message.id,
      senderId: req.user.id,
      type: message.type,
      body: message.body,
      mediaUrl,
      createdAt: message.created_at,
    });

    res.status(201).json({
      message: {
        id: message.id,
        conversationId: message.conversation_id,
        senderId: message.sender_id,
        type: message.type,
        body: message.body,
        mediaUrl,
        readAt: message.read_at,
        createdAt: message.created_at,
        reactions: [],
      },
    });
  }),
);

/**
 * Authorizes a photo-message upload: the client PUTs the image directly to
 * Supabase Storage with the returned URL, then sends the message referencing
 * `path`. This endpoint never sees the image bytes.
 */
router.post(
  '/media/upload-url',
  rateLimit({ windowSeconds: 60, max: 20, keyPrefix: 'chat_media_upload' }),
  validate(z.object({ mimeType: z.enum(CHAT_MEDIA.allowedMimeTypes) })),
  asyncHandler(async (req, res) => {
    if (!chatStorage.isConfigured()) {
      throw badRequest('storage_not_configured', 'Photo messages are not available right now');
    }

    const { path, uploadUrl, token } = await chatStorage.createUploadUrl({
      userId: req.user.id,
      mimeType: req.body.mimeType,
    });

    res.json({ path, uploadUrl, token, maxBytes: CHAT_MEDIA.maxBytes });
  }),
);

/** Sets or changes the caller's reaction to one message. Idempotent. */
router.put(
  '/messages/:messageId/reaction',
  validate(z.object({ messageId: z.coerce.number().int().positive() }), 'params'),
  validate(z.object({ emoji: z.string().min(1).max(8) })),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT m.id, c.user_a, c.user_b, c.id AS conversation_id
         FROM messages m JOIN conversations c ON c.id = m.conversation_id
        WHERE m.id = $1`,
      [req.params.messageId],
    );
    const message = rows[0];
    if (!message) throw notFound('Message');
    if (Number(message.user_a) !== Number(req.user.id) && Number(message.user_b) !== Number(req.user.id)) {
      throw forbidden('You are not part of this conversation');
    }

    await query(
      `INSERT INTO message_reactions (message_id, user_id, emoji)
       VALUES ($1, $2, $3)
       ON CONFLICT (message_id, user_id) DO UPDATE SET emoji = EXCLUDED.emoji, created_at = now()`,
      [req.params.messageId, req.user.id, req.body.emoji],
    );

    const otherId = Number(message.user_a) === Number(req.user.id) ? message.user_b : message.user_a;
    await callEvents.chatReaction(otherId, {
      conversationId: message.conversation_id,
      messageId: message.id,
      userId: req.user.id,
      emoji: req.body.emoji,
    });

    res.json({ messageId: message.id, userId: req.user.id, emoji: req.body.emoji });
  }),
);

/** Removes the caller's reaction to one message. Idempotent. */
router.delete(
  '/messages/:messageId/reaction',
  validate(z.object({ messageId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT m.id, c.user_a, c.user_b, c.id AS conversation_id
         FROM messages m JOIN conversations c ON c.id = m.conversation_id
        WHERE m.id = $1`,
      [req.params.messageId],
    );
    const message = rows[0];
    if (!message) throw notFound('Message');
    if (Number(message.user_a) !== Number(req.user.id) && Number(message.user_b) !== Number(req.user.id)) {
      throw forbidden('You are not part of this conversation');
    }

    await query('DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2', [
      req.params.messageId,
      req.user.id,
    ]);

    const otherId = Number(message.user_a) === Number(req.user.id) ? message.user_b : message.user_a;
    await callEvents.chatReaction(otherId, {
      conversationId: message.conversation_id,
      messageId: message.id,
      userId: req.user.id,
      emoji: null,
    });

    res.json({ messageId: message.id, userId: req.user.id, emoji: null });
  }),
);

module.exports = router;

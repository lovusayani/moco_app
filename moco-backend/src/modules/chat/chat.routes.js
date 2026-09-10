'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const callEvents = require('../../realtime/call.events');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { forbidden, notFound } = require('../../utils/errors');

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

router.get(
  '/',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT c.id, c.last_message_at,
              other.id AS other_id, other.display_name, other.avatar_url,
              m.body AS last_body, m.sender_id AS last_sender_id,
              (SELECT count(*)::int FROM messages um
                WHERE um.conversation_id = c.id AND um.sender_id <> $1 AND um.read_at IS NULL
              ) AS unread_count
         FROM conversations c
         JOIN users other
           ON other.id = CASE WHEN c.user_a = $1 THEN c.user_b ELSE c.user_a END
         LEFT JOIN LATERAL (
              SELECT body, sender_id FROM messages
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
        lastMessage: row.last_body,
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
      `SELECT id, sender_id, body, read_at, created_at
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

    return res.json({
      messages: rows.reverse(),
      nextCursor: rows.length > 0 ? rows[0].id : null,
    });
  }),
);

router.post(
  '/:userId/messages',
  rateLimit({ windowSeconds: 60, max: 60, keyPrefix: 'chat_send' }),
  validate(z.object({ userId: z.coerce.number().int().positive() }), 'params'),
  validate(z.object({ body: z.string().min(1).max(2000) })),
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
        `INSERT INTO messages (conversation_id, sender_id, body)
         VALUES ($1, $2, $3) RETURNING *`,
        [conv[0].id, req.user.id, req.body.body],
      );
      return rows[0];
    });

    await callEvents.chatMessage(otherId, {
      conversationId: message.conversation_id,
      messageId: message.id,
      senderId: req.user.id,
      body: message.body,
      createdAt: message.created_at,
    });

    res.status(201).json({ message });
  }),
);

module.exports = router;

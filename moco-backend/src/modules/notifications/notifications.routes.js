'use strict';

const express = require('express');
const { z } = require('zod');
const notifications = require('./notifications.service');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { notFound } = require('../../utils/errors');

const router = express.Router();
router.use(authenticate);

function serialize(row) {
  return {
    id: row.id,
    type: row.type,
    title: row.title,
    body: row.body,
    data: row.data ?? {},
    read: row.read_at !== null,
    createdAt: row.created_at,
  };
}

/** Newest-first, keyset-paginated, exactly like the feed and both ledgers. */
router.get(
  '/',
  validate(
    z.object({
      limit: z.coerce.number().int().min(1).max(50).default(30),
      before: z.coerce.number().int().positive().optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const [rows, unreadCount] = await Promise.all([
      notifications.list(req.user.id, { limit: req.query.limit, before: req.query.before }),
      notifications.unreadCount(req.user.id),
    ]);

    res.json({
      notifications: rows.map(serialize),
      nextCursor: rows.length === req.query.limit ? rows[rows.length - 1].id : null,
      unreadCount,
    });
  }),
);

router.post(
  '/:id/read',
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const found = await notifications.markRead(req.user.id, req.params.id);
    if (!found) throw notFound('Notification');
    res.json({ ok: true });
  }),
);

router.post(
  '/read-all',
  asyncHandler(async (req, res) => {
    await notifications.markAllRead(req.user.id);
    res.json({ ok: true });
  }),
);

router.delete(
  '/:id',
  validate(z.object({ id: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const found = await notifications.remove(req.user.id, req.params.id);
    if (!found) throw notFound('Notification');
    res.json({ ok: true });
  }),
);

module.exports = router;

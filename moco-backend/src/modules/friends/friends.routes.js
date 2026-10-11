'use strict';

const express = require('express');
const { z } = require('zod');
const { query } = require('../../config/db');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { rateLimit } = require('../../middleware/rateLimit');
const { notFound, badRequest, forbidden } = require('../../utils/errors');
const notifications = require('../notifications/notifications.service');
const fcm = require('../../integrations/fcm');

const router = express.Router();
router.use(authenticate);

/**
 * Sends a friend request to another user.
 *
 * Rules:
 * - Cannot send to yourself
 * - Cannot send if blocked in either direction
 * - Cannot send if there is already a pending request between the pair
 * - Cannot send if already accepted friends
 * - CAN re-request after a rejection (the old rejected row is replaced)
 */
router.post(
  '/request/:userId',
  rateLimit({ windowSeconds: 60, max: 30, keyPrefix: 'friend_request' }),
  validate(z.object({ userId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const targetId = Number(req.params.userId);
    if (targetId === Number(req.user.id)) {
      throw badRequest('self_request', 'You cannot send a friend request to yourself');
    }

    // Block check
    const { rows: blocked } = await query(
      `SELECT 1 FROM blocks
        WHERE (blocker_id = $1 AND blocked_id = $2) OR (blocker_id = $2 AND blocked_id = $1)`,
      [req.user.id, targetId],
    );
    if (blocked.length > 0) throw forbidden('This user is not available');

    // Target must be an active user
    const { rows: targetUser } = await query(
      `SELECT id, display_name, fcm_token FROM users WHERE id = $1 AND status = 'active'`,
      [targetId],
    );
    if (!targetUser[0]) throw notFound('User');

    // Check existing relationship between pair
    const lo = Math.min(req.user.id, targetId);
    const hi = Math.max(req.user.id, targetId);

    const { rows: existing } = await query(
      `SELECT id, status, requester_id, target_id FROM friend_requests
        WHERE LEAST(requester_id, target_id) = $1
          AND GREATEST(requester_id, target_id) = $2
          AND status IN ('pending', 'accepted')
        LIMIT 1`,
      [lo, hi],
    );

    if (existing[0]) {
      if (existing[0].status === 'accepted') {
        throw badRequest('already_friends', 'You are already friends');
      }
      throw badRequest('request_pending', 'A friend request is already pending');
    }

    // Remove any old rejected row for this pair, then insert fresh
    await query(
      `DELETE FROM friend_requests
        WHERE LEAST(requester_id, target_id) = $1
          AND GREATEST(requester_id, target_id) = $2
          AND status = 'rejected'`,
      [lo, hi],
    );

    const { rows: inserted } = await query(
      `INSERT INTO friend_requests (requester_id, target_id, status)
       VALUES ($1, $2, 'pending')
       RETURNING id, status, created_at`,
      [req.user.id, targetId],
    );

    // Notify the target
    const senderName = req.user.display_name || 'Someone';
    await notifications.create({
      userId: targetId,
      type: 'friend_request',
      title: `${senderName} sent you a friend request`,
      data: { requestId: inserted[0].id, actorId: Number(req.user.id) },
    });

    if (targetUser[0].fcm_token) {
      await fcm.send({
        token: targetUser[0].fcm_token,
        title: 'New Friend Request',
        body: `${senderName} wants to be friends`,
        data: { type: 'friend_request', requestId: String(inserted[0].id) },
      });
    }

    res.status(201).json({
      requestId: inserted[0].id,
      status: 'pending',
      createdAt: inserted[0].created_at,
    });
  }),
);

/**
 * Respond to a friend request (accept or reject).
 * Only the TARGET of the request may respond.
 */
router.post(
  '/respond/:requestId',
  validate(z.object({ requestId: z.coerce.number().int().positive() }), 'params'),
  validate(z.object({ accept: z.boolean() })),
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT id, requester_id, target_id, status FROM friend_requests WHERE id = $1`,
      [req.params.requestId],
    );

    const request = rows[0];
    if (!request) throw notFound('Friend request');

    if (Number(request.target_id) !== Number(req.user.id)) {
      throw forbidden('You can only respond to requests sent to you');
    }

    if (request.status !== 'pending') {
      throw badRequest('already_responded', 'This request has already been responded to');
    }

    const newStatus = req.body.accept ? 'accepted' : 'rejected';

    await query(
      `UPDATE friend_requests SET status = $2, responded_at = now() WHERE id = $1`,
      [request.id, newStatus],
    );

    // Notify the requester
    const responderName = req.user.display_name || 'Someone';
    if (req.body.accept) {
      await notifications.create({
        userId: Number(request.requester_id),
        type: 'friend_accepted',
        title: `${responderName} accepted your friend request`,
        data: { actorId: Number(req.user.id) },
      });

      // Best-effort push
      const { rows: requester } = await query(
        `SELECT fcm_token FROM users WHERE id = $1`,
        [request.requester_id],
      );
      if (requester[0]?.fcm_token) {
        await fcm.send({
          token: requester[0].fcm_token,
          title: 'Friend Request Accepted',
          body: `${responderName} accepted your friend request!`,
          data: { type: 'friend_accepted', actorId: String(req.user.id) },
        });
      }
    }

    res.json({ requestId: request.id, status: newStatus });
  }),
);

/**
 * Get the friendship status between the signed-in user and another user.
 */
router.get(
  '/status/:userId',
  validate(z.object({ userId: z.coerce.number().int().positive() }), 'params'),
  asyncHandler(async (req, res) => {
    const otherId = Number(req.params.userId);
    const lo = Math.min(req.user.id, otherId);
    const hi = Math.max(req.user.id, otherId);

    const { rows } = await query(
      `SELECT id, requester_id, target_id, status, created_at, responded_at
         FROM friend_requests
        WHERE LEAST(requester_id, target_id) = $1
          AND GREATEST(requester_id, target_id) = $2
          AND status IN ('pending', 'accepted')
        ORDER BY created_at DESC LIMIT 1`,
      [lo, hi],
    );

    if (!rows[0]) {
      return res.json({ status: 'none', requestId: null });
    }

    const row = rows[0];
    res.json({
      status: row.status,
      requestId: row.id,
      requesterId: row.requester_id,
      targetId: row.target_id,
      createdAt: row.created_at,
      respondedAt: row.responded_at,
    });
  }),
);

/**
 * List pending friend requests that the signed-in user has RECEIVED.
 * Creators use this to see who wants to be their friend.
 */
router.get(
  '/requests',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT fr.id, fr.requester_id, fr.created_at,
              u.display_name, u.avatar_url
         FROM friend_requests fr
         JOIN users u ON u.id = fr.requester_id
        WHERE fr.target_id = $1 AND fr.status = 'pending'
        ORDER BY fr.created_at DESC
        LIMIT 50`,
      [req.user.id],
    );

    res.json({
      requests: rows.map((r) => ({
        requestId: r.id,
        requester: {
          id: r.requester_id,
          name: r.display_name,
          avatarUrl: r.avatar_url,
        },
        createdAt: r.created_at,
      })),
    });
  }),
);

module.exports = router;

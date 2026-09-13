'use strict';

const { query } = require('../../config/db');

/**
 * Persisted, in-app notifications — the durable counterpart to the
 * fire-and-forget FCM push in src/integrations/fcm.js. Called from wherever
 * an event is already worth pushing (an incoming call, a KYC decision, a
 * payout decision), so a user who missed the push (no token, device
 * offline, FCM unconfigured in dev) can still see it the next time they open
 * the app.
 *
 * `create` never throws into its caller's transaction: a notification is a
 * side effect of a real state change, and a failure to record it must never
 * roll back the change itself (an approved payout must stay approved even if
 * writing its notification row fails).
 */
async function create({ userId, type, title, body = null, data = {} }) {
  try {
    await query(
      `INSERT INTO notifications (user_id, type, title, body, data)
       VALUES ($1, $2, $3, $4, $5)`,
      [userId, type, title, body, JSON.stringify(data)],
    );
  } catch (err) {
    // eslint-disable-next-line global-require
    require('../../utils/logger').error({ err, userId, type }, 'failed to record notification');
  }
}

async function list(userId, { limit = 30, before } = {}) {
  const { rows } = await query(
    `SELECT id, type, title, body, data, read_at, created_at
       FROM notifications
      WHERE user_id = $1 AND ($2::bigint IS NULL OR id < $2)
      ORDER BY id DESC
      LIMIT $3`,
    [userId, before ?? null, limit],
  );
  return rows;
}

async function unreadCount(userId) {
  const { rows } = await query(
    `SELECT count(*)::int AS c FROM notifications WHERE user_id = $1 AND read_at IS NULL`,
    [userId],
  );
  return rows[0].c;
}

/** Marks one notification read. Idempotent; a no-op if already read. */
async function markRead(userId, notificationId) {
  const { rows } = await query(
    `UPDATE notifications SET read_at = COALESCE(read_at, now())
      WHERE id = $1 AND user_id = $2
      RETURNING id`,
    [notificationId, userId],
  );
  return rows.length > 0;
}

async function markAllRead(userId) {
  await query(
    `UPDATE notifications SET read_at = now() WHERE user_id = $1 AND read_at IS NULL`,
    [userId],
  );
}

/** Deletes one notification. Returns false if it did not exist or belonged
 * to someone else — the route treats both the same, as a 404. */
async function remove(userId, notificationId) {
  const { rowCount } = await query(
    `DELETE FROM notifications WHERE id = $1 AND user_id = $2`,
    [notificationId, userId],
  );
  return rowCount > 0;
}

module.exports = { create, list, unreadCount, markRead, markAllRead, remove };

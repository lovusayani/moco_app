'use strict';

const { query } = require('../../config/db');

/**
 * Writes one admin audit entry.
 *
 * Pass the transaction `client` whenever the action itself runs in one, so the
 * action and its audit row commit or roll back together — an action that
 * happened without a record, or a record of an action that rolled back, are
 * both worse than no audit at all. Returns the new row's id.
 */
async function record(client, { admin, action, targetType, targetId, reason, metadata }) {
  const run = client ? client.query.bind(client) : query;
  const { rows } = await run(
    `INSERT INTO admin_audit_log
       (admin_user_id, admin_phone, action, target_type, target_id, reason, metadata)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     RETURNING id`,
    [
      admin.id,
      admin.phone,
      action,
      targetType,
      targetId == null ? null : String(targetId),
      reason ?? null,
      JSON.stringify(metadata ?? {}),
    ],
  );
  return rows[0].id;
}

/** Most recent audit entries for one target — used by detail pages to show
 * "what has been done to this, by whom". */
async function historyFor(targetType, targetId, limit = 25) {
  const { rows } = await query(
    `SELECT id, admin_phone, action, reason, metadata, created_at
       FROM admin_audit_log
      WHERE target_type = $1 AND target_id = $2
      ORDER BY created_at DESC, id DESC
      LIMIT $3`,
    [targetType, String(targetId), limit],
  );
  return rows;
}

module.exports = { record, historyFor };

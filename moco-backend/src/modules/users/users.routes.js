'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { authenticate } = require('../../middleware/auth');
const { notFound } = require('../../utils/errors');
const { USER_ROLE, KYC_STATUS } = require('../../utils/constants');

/**
 * The canonical public shape of a user.
 *
 * GET and PATCH previously returned different shapes for the same resource —
 * GET camelCase, PATCH the raw snake_case database row — which forced clients
 * to parse a resource two ways. Both now go through here.
 */
function serializeUser(row) {
  return {
    id: row.id,
    phone: row.phone,
    displayName: row.display_name,
    avatarUrl: row.avatar_url,
    language: row.language,
    gender: row.gender,
    role: row.role,
    coinBalance: row.coin_balance ?? 0,
    freeTrialAvailable: !row.free_trial_used,
    createdAt: row.created_at,
    listener: row.kyc_status
      ? {
          isOnline: row.is_online,
          kycStatus: row.kyc_status,
          earningsBalance: row.earnings_balance,
          rating: Number(row.rating),
          totalCalls: row.total_calls,
        }
      : null,
  };
}

/** Columns serializeUser needs, shared by every query that returns a user. */
const USER_SELECT = `
  u.id, u.phone, u.display_name, u.avatar_url, u.language, u.gender, u.role,
  u.free_trial_used, u.created_at,
  COALESCE(w.coin_balance, 0) AS coin_balance,
  lp.is_online, lp.kyc_status, lp.earnings_balance, lp.rating, lp.total_calls`;

const USER_JOINS = `
  FROM users u
  LEFT JOIN wallets w ON w.user_id = u.id
  LEFT JOIN listener_profiles lp ON lp.user_id = u.id`;

const router = express.Router();
router.use(authenticate);

const profileSchema = z.object({
  displayName: z.string().min(2).max(40).optional(),
  avatarUrl: z.string().url().max(500).optional(),
  // The three languages the app ships in.
  language: z.enum(['en', 'hi', 'te']).optional(),
  gender: z.enum(['male', 'female', 'other']).optional(),
});

/** The signed-in user's own profile, including wallet and listener state. */
router.get(
  '/me',
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      `SELECT ${USER_SELECT} ${USER_JOINS} WHERE u.id = $1`,
      [req.user.id],
    );

    const row = rows[0];
    if (!row) throw notFound('User');

    res.json(serializeUser(row));
  }),
);

router.patch(
  '/me',
  validate(profileSchema),
  asyncHandler(async (req, res) => {
    const { displayName, avatarUrl, language, gender } = req.body;

    // COALESCE leaves untouched fields alone, so a partial update cannot blank
    // out a field the client simply did not send.
    await query(
      `UPDATE users
          SET display_name = COALESCE($2, display_name),
              avatar_url   = COALESCE($3, avatar_url),
              language     = COALESCE($4, language),
              gender       = COALESCE($5, gender),
              updated_at   = now()
        WHERE id = $1`,
      [req.user.id, displayName ?? null, avatarUrl ?? null, language ?? null, gender ?? null],
    );

    // Re-read through the same projection as GET so the two cannot diverge.
    const { rows } = await query(
      `SELECT ${USER_SELECT} ${USER_JOINS} WHERE u.id = $1`,
      [req.user.id],
    );

    res.json(serializeUser(rows[0]));
  }),
);

/**
 * Opts the account into listener mode.
 *
 * Creates the listener profile in the same transaction as the role change; the
 * profile starts unverified, so becoming a listener does not by itself make
 * someone discoverable — KYC approval does.
 */
router.post(
  '/me/become-listener',
  asyncHandler(async (req, res) => {
    const result = await withTransaction(async (client) => {
      const nextRole = req.user.role === USER_ROLE.USER ? USER_ROLE.BOTH : req.user.role;

      await client.query('UPDATE users SET role = $2, updated_at = now() WHERE id = $1', [
        req.user.id,
        nextRole,
      ]);

      const { rows } = await client.query(
        `INSERT INTO listener_profiles (user_id) VALUES ($1)
         ON CONFLICT (user_id) DO UPDATE SET updated_at = now()
         RETURNING user_id, kyc_status, audio_rate, video_rate`,
        [req.user.id],
      );

      return { role: nextRole, profile: rows[0] };
    });

    res.json({
      role: result.role,
      kycStatus: result.profile.kyc_status,
      // The client routes to the KYC screen while this is true.
      kycRequired: result.profile.kyc_status !== KYC_STATUS.APPROVED,
    });
  }),
);

/** Registers the device push token used for incoming-call notifications. */
router.post(
  '/me/fcm-token',
  validate(z.object({ token: z.string().min(10).max(500) })),
  asyncHandler(async (req, res) => {
    await query('UPDATE users SET fcm_token = $2, updated_at = now() WHERE id = $1', [
      req.user.id,
      req.body.token,
    ]);
    res.json({ ok: true });
  }),
);

/**
 * Account deletion. Play Store policy requires an in-app path to this.
 *
 * Soft delete: the row is retained because coin_ledger and listener_earnings
 * reference it and financial history must stay reconstructable. Personal
 * fields are cleared, which is what the policy actually requires.
 */
router.delete(
  '/me',
  asyncHandler(async (req, res) => {
    await withTransaction(async (client) => {
      await client.query(
        `UPDATE users
            SET status = 'deleted', display_name = NULL, avatar_url = NULL,
                fcm_token = NULL, phone = 'deleted_' || id, updated_at = now()
          WHERE id = $1`,
        [req.user.id],
      );
      await client.query(
        `UPDATE listener_profiles SET is_online = FALSE, bio = NULL, kyc_doc_url = NULL,
                kyc_name = NULL, upi_id = NULL WHERE user_id = $1`,
        [req.user.id],
      );
    });
    res.json({ ok: true });
  }),
);

module.exports = router;

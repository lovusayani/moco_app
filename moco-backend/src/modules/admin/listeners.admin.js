'use strict';

const express = require('express');
const { z } = require('zod');
const { query, withTransaction } = require('../../config/db');
const listenerStorage = require('../../integrations/listener.storage');
const notifications = require('../notifications/notifications.service');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { notFound, badRequest, conflict } = require('../../utils/errors');
const {
  KYC_STATUS,
  USER_ROLE,
  USER_STATUS,
  LISTENER_PHOTOS,
  listenerEligibleSql,
  listenerBlockers,
} = require('../../utils/constants');
const audit = require('./audit.service');
const { listSchema, Where, orderBy, limitOffset, pageOf, likeTerm } = require('./admin.list');

/**
 * Admin: creators/listeners and the KYC (application) queue. Mounted under
 * /api/admin behind authenticate + requireAdmin. KYC documents and UPI ids
 * are only ever returned from here — no public endpoint exposes them.
 */
const router = express.Router();

const ELIGIBLE = listenerEligibleSql('lp');
const PHONE = z.string().trim().regex(/^\+[1-9]\d{7,14}$/, 'Use international format, e.g. +919876543210');
const idParam = z.object({ id: z.coerce.number().int().positive() });

/**
 * The application lifecycle as one label: draft (not submitted) → submitted
 * (in the KYC queue) → approved / rejected; "active" is approved AND eligible.
 * KYC review IS the application review — there is deliberately no second,
 * contradictory "application approved" flag.
 */
function applicationStatus(kycStatus, eligible) {
  if (kycStatus === KYC_STATUS.APPROVED) return eligible ? 'active' : 'approved_incomplete';
  if (kycStatus === KYC_STATUS.PENDING) return 'submitted';
  if (kycStatus === KYC_STATUS.REJECTED) return 'rejected';
  return 'draft';
}

/** Photos for many listeners in two round trips total (one SQL, one Storage
 * batch-sign) — never one request per listener or per photo. */
async function photosByListener(listenerIds) {
  if (listenerIds.length === 0) return new Map();
  const { rows } = await query(
    `SELECT id, listener_id, storage_path, mime_type, size_bytes, created_at
       FROM listener_photos WHERE listener_id = ANY($1::bigint[])
      ORDER BY created_at, id`,
    [listenerIds],
  );
  const urls = await listenerStorage.createViewUrls(rows.map((r) => r.storage_path));
  const grouped = new Map();
  for (const r of rows) {
    if (!grouped.has(r.listener_id)) grouped.set(r.listener_id, []);
    grouped.get(r.listener_id).push({
      id: r.id,
      url: urls.get(r.storage_path) ?? null,
      mimeType: r.mime_type,
      sizeBytes: r.size_bytes,
      createdAt: r.created_at,
    });
  }
  return grouped;
}

// ---------------------------------------------------------------- listeners

const LISTENER_SORT = {
  name: 'lower(u.display_name)',
  created: 'lp.created_at',
  submitted: 'lp.kyc_submitted_at',
  photos: 'lp.photo_count',
  earnings: 'lp.lifetime_earnings',
  calls: 'lp.total_calls',
  rating: 'lp.rating',
  kyc: 'lp.kyc_status',
};

router.get(
  '/listeners',
  validate(
    listSchema(Object.keys(LISTENER_SORT), {
      kyc: z.enum(['unsubmitted', 'pending', 'approved', 'rejected']).optional(),
      online: z.enum(['true', 'false']).optional(),
      capability: z.enum(['audio', 'video']).optional(),
      language: z.enum(['en', 'hi', 'te']).optional(),
      photos: z.enum(['complete', 'incomplete']).optional(),
      eligible: z.enum(['true', 'false']).optional(),
      accountStatus: z.enum(['active', 'suspended', 'deleted']).optional(),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, kyc, online, capability, language, photos, eligible, accountStatus, from, to, sort, dir } =
      req.query;
    const where = new Where()
      .maybe(kyc, 'lp.kyc_status = ?')
      .maybe(online, 'lp.is_online = ?', online === 'true')
      .maybe(language, '? = ANY(lp.languages)')
      .maybe(accountStatus, 'u.status = ?')
      .dateRange('lp.created_at', from, to);

    // Permanently deleted accounts keep an anonymised creator row for the
    // earnings ledger; they are listed only when asked for explicitly.
    if (!accountStatus) where.add("u.status <> 'deleted'");
    if (capability === 'audio') where.add('lp.accepts_audio');
    if (capability === 'video') where.add('lp.accepts_video');
    if (photos === 'complete') where.add('lp.photo_count >= ?', LISTENER_PHOTOS.minCount);
    if (photos === 'incomplete') where.add('lp.photo_count < ?', LISTENER_PHOTOS.minCount);
    if (eligible === 'true') where.add(ELIGIBLE);
    if (eligible === 'false') where.add(`NOT ${ELIGIBLE}`);
    if (q) {
      const term = likeTerm(q);
      where.add(
        '(u.display_name ILIKE ? OR u.phone ILIKE ? OR lp.kyc_name ILIKE ? OR u.id::text = ?)',
        term,
        term,
        term,
        q,
      );
    }

    const { rows } = await query(
      `SELECT u.id, u.display_name, u.phone, u.status AS account_status,
              lp.kyc_status, lp.photo_count, lp.is_online, lp.is_busy,
              lp.accepts_audio, lp.accepts_video, lp.languages, lp.audio_rate, lp.video_rate,
              lp.lifetime_earnings, lp.earnings_balance, lp.total_calls, lp.rating,
              lp.created_at, lp.kyc_submitted_at, ${ELIGIBLE} AS eligible,
              count(*) OVER () AS total_count
         FROM listener_profiles lp
         JOIN users u ON u.id = lp.user_id
         ${where.sql}
         ${orderBy(LISTENER_SORT, sort, dir, 'created', 'u.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );

    res.json(
      pageOf(rows, req.query, (r) => ({
        id: r.id,
        name: r.display_name,
        phone: r.phone,
        accountStatus: r.account_status,
        kycStatus: r.kyc_status,
        applicationStatus: applicationStatus(r.kyc_status, r.eligible),
        verified: r.kyc_status === KYC_STATUS.APPROVED,
        eligible: r.eligible,
        photoCount: r.photo_count,
        minPhotos: LISTENER_PHOTOS.minCount,
        isOnline: r.is_online,
        isBusy: r.is_busy,
        acceptsAudio: r.accepts_audio,
        acceptsVideo: r.accepts_video,
        languages: r.languages,
        audioRate: r.audio_rate,
        videoRate: r.video_rate,
        lifetimeEarnings: Number(r.lifetime_earnings),
        earningsBalance: Number(r.earnings_balance),
        totalCalls: r.total_calls,
        rating: Number(r.rating),
        createdAt: r.created_at,
        kycSubmittedAt: r.kyc_submitted_at,
      })),
    );
  }),
);

router.get(
  '/listeners/:id',
  validate(idParam, 'params'),
  asyncHandler(async (req, res) => {
    const id = req.params.id;
    const { rows } = await query(
      `SELECT u.id, u.display_name, u.phone, u.email, u.status AS account_status, u.avatar_url, u.gender,
              u.created_at AS user_created_at, lp.*, ${ELIGIBLE} AS eligible,
              reviewer.phone AS reviewer_phone
         FROM listener_profiles lp
         JOIN users u ON u.id = lp.user_id
         LEFT JOIN users reviewer ON reviewer.id = lp.kyc_reviewed_by
        WHERE lp.user_id = $1`,
      [id],
    );
    const l = rows[0];
    if (!l) throw notFound('Listener');

    const [photos, callStats, reports, earnings, history] = await Promise.all([
      photosByListener([l.id]),
      query(
        `SELECT count(*)::int AS total,
                count(*) FILTER (WHERE status = 'ended' AND billed_minutes > 0)::int AS completed,
                COALESCE(SUM(billed_minutes), 0)::int AS billed_minutes,
                COALESCE(SUM(listener_earned), 0)::bigint AS earned,
                count(*) FILTER (WHERE type = 'audio')::int AS audio,
                count(*) FILTER (WHERE type = 'video')::int AS video,
                max(created_at) AS last_call_at
           FROM calls WHERE listener_id = $1`,
        [id],
      ),
      query(
        `SELECT r.id, r.reason, r.status, r.created_at, r.call_id, reporter.display_name AS reporter_name,
                count(*) OVER () AS total
           FROM reports r JOIN users reporter ON reporter.id = r.reporter_id
          WHERE r.reported_id = $1
          ORDER BY r.created_at DESC LIMIT 20`,
        [id],
      ),
      query(
        `SELECT id, delta, reason, ref_id, balance_after, created_at
           FROM listener_earnings WHERE listener_id = $1
          ORDER BY created_at DESC, id DESC LIMIT 20`,
        [id],
      ),
      query(
        `SELECT id, admin_phone, action, reason, metadata, created_at FROM admin_audit_log
          WHERE (target_type = 'listener' OR target_type = 'user') AND target_id = $1
          ORDER BY created_at DESC, id DESC LIMIT 30`,
        [String(id)],
      ),
    ]);

    res.json({
      id: l.id,
      name: l.display_name,
      phone: l.phone,
      email: l.email,
      avatarUrl: l.avatar_url,
      gender: l.gender,
      accountStatus: l.account_status,
      userCreatedAt: l.user_created_at,
      bio: l.bio,
      languages: l.languages,
      applicationStatus: applicationStatus(l.kyc_status, l.eligible),
      eligible: l.eligible,
      blockers: listenerBlockers({ kycStatus: l.kyc_status, photoCount: l.photo_count }),
      photos: photos.get(l.id) ?? [],
      photoCount: l.photo_count,
      minPhotos: LISTENER_PHOTOS.minCount,
      maxPhotos: LISTENER_PHOTOS.maxCount,
      kyc: {
        status: l.kyc_status,
        name: l.kyc_name,
        docUrl: l.kyc_doc_url,
        upiId: l.upi_id,
        submittedAt: l.kyc_submitted_at,
        reviewedAt: l.kyc_reviewed_at,
        reviewedBy: l.reviewer_phone,
        reviewNote: l.kyc_review_note,
      },
      availability: { isOnline: l.is_online, isBusy: l.is_busy },
      capabilities: {
        acceptsAudio: l.accepts_audio,
        acceptsVideo: l.accepts_video,
        audioRate: l.audio_rate,
        videoRate: l.video_rate,
      },
      earnings: {
        balance: Number(l.earnings_balance),
        lifetime: Number(l.lifetime_earnings),
        recent: earnings.rows,
      },
      rating: Number(l.rating),
      ratingCount: l.rating_count,
      callStats: callStats.rows[0],
      reports: {
        total: reports.rows[0] ? Number(reports.rows[0].total) : 0,
        recent: reports.rows.map(({ total: _t, ...r }) => r),
      },
      history: history.rows,
      createdAt: l.created_at,
    });
  }),
);

/**
 * Admin-created creator/listener. Creates (or reuses) the phone-identified
 * account and a DRAFT listener profile. It does NOT approve anything: the
 * listener must still sign in, upload the minimum photos and submit KYC, and
 * an admin must then approve the application — the same gates every
 * self-registered listener passes through.
 */
router.post(
  '/listeners',
  validate(
    z.object({
      phone: PHONE,
      displayName: z.string().trim().min(2).max(40),
      bio: z.string().trim().max(300).optional(),
      languages: z.array(z.enum(['en', 'hi', 'te'])).min(1).max(3).optional(),
      acceptsAudio: z.boolean().default(true),
      acceptsVideo: z.boolean().default(true),
      reason: z.string().trim().max(500).optional(),
    }),
  ),
  asyncHandler(async (req, res) => {
    const { phone, displayName, bio, languages, acceptsAudio, acceptsVideo, reason } = req.body;
    if (!acceptsAudio && !acceptsVideo) {
      throw badRequest('no_capability', 'A listener must accept audio, video, or both');
    }

    const created = await withTransaction(async (client) => {
      const { rows: existing } = await client.query(
        `SELECT u.id, u.status, u.role, lp.user_id AS has_profile
           FROM users u LEFT JOIN listener_profiles lp ON lp.user_id = u.id
          WHERE u.phone = $1 FOR UPDATE OF u`,
        [phone],
      );
      let userId;
      let newAccount = false;
      if (existing[0]) {
        if (existing[0].status !== USER_STATUS.ACTIVE) {
          throw conflict('account_not_active', `The account for ${phone} is ${existing[0].status}`);
        }
        if (existing[0].has_profile) {
          throw conflict('already_listener', `User #${existing[0].id} already has a listener profile`);
        }
        userId = existing[0].id;
        await client.query(
          `UPDATE users SET role = CASE WHEN role = 'user' THEN 'both'::user_role ELSE role END,
                            display_name = COALESCE(display_name, $2), updated_at = now()
            WHERE id = $1`,
          [userId, displayName],
        );
      } else {
        const { rows } = await client.query(
          `INSERT INTO users (phone, display_name, role) VALUES ($1, $2, $3) RETURNING id`,
          [phone, displayName, USER_ROLE.LISTENER],
        );
        userId = rows[0].id;
        newAccount = true;
        await client.query('INSERT INTO wallets (user_id, coin_balance) VALUES ($1, 0)', [userId]);
      }

      await client.query(
        `INSERT INTO listener_profiles (user_id, bio, languages, accepts_audio, accepts_video)
         VALUES ($1, $2, COALESCE($3, ARRAY['en']), $4, $5)`,
        [userId, bio ?? null, languages ?? null, acceptsAudio, acceptsVideo],
      );

      await audit.record(client, {
        admin: req.user,
        action: 'listener.create',
        targetType: 'listener',
        targetId: userId,
        reason,
        metadata: { phone, displayName, newAccount, acceptsAudio, acceptsVideo },
      });
      return { userId, newAccount };
    });

    res.status(201).json({
      id: created.userId,
      newAccount: created.newAccount,
      applicationStatus: 'draft',
      blockers: listenerBlockers({ kycStatus: KYC_STATUS.UNSUBMITTED, photoCount: 0 }),
      next:
        `The creator signs in with ${phone}, uploads at least ${LISTENER_PHOTOS.minCount} photos ` +
        'and submits verification; approve the application from the KYC queue after that.',
    });
  }),
);

// ---------------------------------------------------------------------- KYC

const KYC_SORT = {
  submitted: 'lp.kyc_submitted_at',
  reviewed: 'lp.kyc_reviewed_at',
  photos: 'lp.photo_count',
  name: 'lower(u.display_name)',
};

router.get(
  '/kyc',
  validate(
    listSchema(Object.keys(KYC_SORT), {
      status: z.enum(['pending', 'approved', 'rejected', 'unsubmitted', 'all']).default('pending'),
    }),
    'query',
  ),
  asyncHandler(async (req, res) => {
    const { q, status, from, to, sort, dir } = req.query;
    const where = new Where().dateRange('lp.kyc_submitted_at', from, to);
    // A deleted account's KYC data is wiped — nothing left to review.
    where.add("u.status <> 'deleted'");
    if (status !== 'all') where.add('lp.kyc_status = ?', status);
    if (q) {
      const term = likeTerm(q);
      where.add('(u.display_name ILIKE ? OR u.phone ILIKE ? OR lp.kyc_name ILIKE ?)', term, term, term);
    }
    // The pending queue reads oldest-first by default: first in, first reviewed.
    const effectiveDir = !sort && status === 'pending' ? 'asc' : dir;

    const { rows } = await query(
      `SELECT u.id, u.display_name, u.phone, u.status AS account_status,
              lp.kyc_status, lp.kyc_name, lp.kyc_doc_url, lp.upi_id, lp.bio, lp.languages,
              lp.photo_count, lp.kyc_submitted_at, lp.kyc_reviewed_at, lp.kyc_review_note,
              reviewer.phone AS reviewer_phone,
              count(*) OVER () AS total_count
         FROM listener_profiles lp
         JOIN users u ON u.id = lp.user_id
         LEFT JOIN users reviewer ON reviewer.id = lp.kyc_reviewed_by
         ${where.sql}
         ${orderBy(KYC_SORT, sort, effectiveDir, 'submitted', 'u.id')}
         ${limitOffset(where, req.query)}`,
      where.params,
    );

    const photos = await photosByListener(rows.map((r) => r.id));
    res.json(
      pageOf(rows, req.query, (r) => ({
        id: r.id,
        name: r.display_name,
        phone: r.phone,
        accountStatus: r.account_status,
        kycStatus: r.kyc_status,
        kycName: r.kyc_name,
        docUrl: r.kyc_doc_url,
        upiId: r.upi_id,
        bio: r.bio,
        languages: r.languages,
        photoCount: r.photo_count,
        minPhotos: LISTENER_PHOTOS.minCount,
        photos: photos.get(r.id) ?? [],
        submittedAt: r.kyc_submitted_at,
        reviewedAt: r.kyc_reviewed_at,
        reviewedBy: r.reviewer_phone,
        reviewNote: r.kyc_review_note,
        approvalBlockers: approvalBlockers(r),
      })),
    );
  }),
);

/** Why an application cannot be approved yet ([] = approvable). The same
 * conditions are enforced again inside the approval UPDATE itself. */
function approvalBlockers(r) {
  const blockers = [];
  if (r.kyc_status !== KYC_STATUS.PENDING) blockers.push('not_submitted');
  if (r.photo_count < LISTENER_PHOTOS.minCount) blockers.push('photos');
  if (!r.display_name || !r.display_name.trim()) blockers.push('display_name');
  if (!r.kyc_name || !r.kyc_doc_url) blockers.push('kyc_documents');
  if (r.account_status !== USER_STATUS.ACTIVE) blockers.push('account_not_active');
  return blockers;
}

router.post(
  '/kyc/:id',
  validate(idParam, 'params'),
  validate(
    z
      .object({
        approve: z.boolean(),
        reason: z.string().trim().max(500).optional(),
        note: z.string().trim().max(1000).optional(),
      })
      .refine((b) => b.approve || (b.reason && b.reason.length >= 3), {
        message: 'A rejection reason is required',
        path: ['reason'],
      }),
  ),
  asyncHandler(async (req, res) => {
    const id = Number(req.params.id);
    const { approve, reason, note } = req.body;
    const nextStatus = approve ? KYC_STATUS.APPROVED : KYC_STATUS.REJECTED;

    const outcome = await withTransaction(async (client) => {
      const { rows: found } = await client.query(
        `SELECT lp.kyc_status, lp.photo_count, lp.kyc_name, lp.kyc_doc_url,
                u.display_name, u.status AS account_status
           FROM listener_profiles lp JOIN users u ON u.id = lp.user_id
          WHERE lp.user_id = $1 FOR UPDATE OF lp`,
        [id],
      );
      const current = found[0];
      if (!current) throw notFound('Listener profile');

      if (approve) {
        // The row is locked, so these checks and the update below see the
        // same state — a concurrent photo delete cannot slip through.
        const blockers = approvalBlockers(current);
        if (blockers.length) {
          const code = blockers.includes('photos') ? 'photos_required' : 'not_approvable';
          throw badRequest(code, `Cannot approve yet: ${blockers.join(', ')}`, { blockers });
        }
      } else if (![KYC_STATUS.PENDING, KYC_STATUS.APPROVED].includes(current.kyc_status)) {
        throw badRequest('not_reviewable', `Nothing to reject — this application is ${current.kyc_status}`);
      }

      await client.query(
        `UPDATE listener_profiles
            SET kyc_status = $2, kyc_reviewed_at = now(), kyc_reviewed_by = $3,
                kyc_review_note = $4, updated_at = now(),
                -- Rejecting (including revoking an approval) takes them offline.
                is_online = CASE WHEN $2 = 'approved'::kyc_status THEN is_online ELSE FALSE END
          WHERE user_id = $1`,
        [id, nextStatus, req.user.id, approve ? note ?? null : reason],
      );

      await audit.record(client, {
        admin: req.user,
        action: approve ? 'kyc.approve' : 'kyc.reject',
        targetType: 'listener',
        targetId: id,
        reason: approve ? note : reason,
        metadata: { from: current.kyc_status, to: nextStatus, photoCount: current.photo_count, note: note ?? null },
      });
      return { from: current.kyc_status };
    });

    await notifications.create({
      userId: id,
      type: approve ? 'kyc_approved' : 'kyc_rejected',
      title: approve ? 'You are verified!' : 'Verification was not approved',
      body: approve ? 'You can now go online and take calls.' : reason,
    });

    res.json({ userId: id, kycStatus: nextStatus, previousStatus: outcome.from });
  }),
);

module.exports = router;

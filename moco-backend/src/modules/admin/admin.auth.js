'use strict';

const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const env = require('../../config/env');
const { query, withTransaction } = require('../../config/db');
const { rateLimit } = require('../../middleware/rateLimit');
const { validate } = require('../../middleware/validate');
const { asyncHandler } = require('../../middleware/error');
const { badRequest, unauthorized, forbidden, conflict } = require('../../utils/errors');
const audit = require('./audit.service');
const { z } = require('zod');
const express = require('express');

const BCRYPT_ROUNDS = 12;
const ADMIN_TOKEN_PREFIX = 'adm';

const emailSchema = z.string().trim().min(3).max(254).email();
const passwordSchema = z.string().min(8).max(128);

function signAdminToken(admin) {
  return jwt.sign(
    { sub: String(admin.id), role: admin.role, adm: true },
    env.jwt.secret,
    { expiresIn: '24h' },
  );
}

function verifyAdminToken(token) {
  try {
    const payload = jwt.verify(token, env.jwt.secret);
    if (!payload.adm) throw unauthorized('Not an admin token');
    return payload;
  } catch {
    throw unauthorized('Invalid or expired admin token');
  }
}

async function authenticateAdmin(req, res, next) {
  try {
    const header = req.headers.authorization;
    if (!header || !header.startsWith('Bearer ')) throw unauthorized();
    const payload = verifyAdminToken(header.slice(7).trim());
    const { rows } = await query(
      'SELECT id, email, display_name, role FROM admin_accounts WHERE id = $1',
      [payload.sub],
    );
    if (!rows[0]) throw unauthorized('Admin account no longer exists');
    req.admin = rows[0];
    // Compatibility: existing admin modules read req.user for audit records.
    req.user = { id: rows[0].id, phone: null, email: rows[0].email, display_name: rows[0].display_name, role: rows[0].role };
    return next();
  } catch (err) {
    return next(err);
  }
}

function requireSuperAdmin(req, res, next) {
  if (req.admin?.role !== 'super_admin') {
    return next(forbidden('Super admin access required'));
  }
  return next();
}

const router = express.Router();

// ── Bootstrap: first admin registration ─────────────────────────────
const bootstrapSchema = z.object({
  email: emailSchema,
  password: passwordSchema,
  confirmPassword: z.string(),
  displayName: z.string().trim().max(100).optional(),
}).refine(d => d.password === d.confirmPassword, {
  message: 'Passwords do not match',
  path: ['confirmPassword'],
});

const bootstrapLimit = rateLimit({
  windowSeconds: 300, max: 5, keyPrefix: 'admin_bootstrap', by: (req) => req.ip,
});

router.post(
  '/bootstrap',
  bootstrapLimit,
  validate(bootstrapSchema),
  asyncHandler(async (req, res) => {
    const { email, password, displayName } = req.body;
    const normalEmail = email.toLowerCase().trim();
    const hash = await bcrypt.hash(password, BCRYPT_ROUNDS);

    const admin = await withTransaction(async (client) => {
      const { rows: [{ n }] } = await client.query(
        'SELECT count(*)::int AS n FROM admin_accounts',
      );
      if (n > 0) throw conflict('An admin account already exists. Use the login page.');

      const { rows: [row] } = await client.query(
        `INSERT INTO admin_accounts (email, password, display_name, role)
         VALUES ($1, $2, $3, 'super_admin')
         RETURNING id, email, display_name, role`,
        [normalEmail, hash, displayName || null],
      );

      await audit.record(client, {
        admin: { id: row.id, phone: null, email: row.email },
        action: 'admin_bootstrap',
        targetType: 'admin_account',
        targetId: row.id,
        metadata: { role: 'super_admin' },
      });

      return row;
    });

    const token = signAdminToken(admin);
    res.status(201).json({
      token,
      admin: { id: admin.id, email: admin.email, displayName: admin.display_name, role: admin.role },
    });
  }),
);

// ── Status: does an admin exist? ────────────────────────────────────
router.get(
  '/status',
  asyncHandler(async (req, res) => {
    const { rows: [{ n }] } = await query('SELECT count(*)::int AS n FROM admin_accounts');
    res.json({ hasAdmin: n > 0 });
  }),
);

// ── Login ────────────────────────────────────────────────────────────
const loginSchema = z.object({
  email: emailSchema,
  password: z.string().min(1),
});

const loginLimit = rateLimit({
  windowSeconds: 300, max: 10, keyPrefix: 'admin_login', by: (req) => req.ip,
});

router.post(
  '/login',
  loginLimit,
  validate(loginSchema),
  asyncHandler(async (req, res) => {
    const { email, password } = req.body;
    const normalEmail = email.toLowerCase().trim();
    const { rows } = await query(
      'SELECT id, email, password, display_name, role FROM admin_accounts WHERE email = $1',
      [normalEmail],
    );
    const admin = rows[0];
    if (!admin || !(await bcrypt.compare(password, admin.password))) {
      throw unauthorized('Invalid email or password');
    }

    const token = signAdminToken(admin);
    res.json({
      token,
      admin: { id: admin.id, email: admin.email, displayName: admin.display_name, role: admin.role },
    });
  }),
);

// ── Authenticated routes below ──────────────────────────────────────
router.use(authenticateAdmin);

router.get('/me', (req, res) => {
  res.json({
    id: req.admin.id,
    email: req.admin.email,
    displayName: req.admin.display_name,
    role: req.admin.role,
    isAdmin: true,
  });
});

// ── Change own password ─────────────────────────────────────────────
const changePasswordSchema = z.object({
  currentPassword: z.string().min(1),
  newPassword: passwordSchema,
  confirmPassword: z.string(),
}).refine(d => d.newPassword === d.confirmPassword, {
  message: 'Passwords do not match',
  path: ['confirmPassword'],
});

router.post(
  '/change-password',
  validate(changePasswordSchema),
  asyncHandler(async (req, res) => {
    const { currentPassword, newPassword } = req.body;
    const { rows } = await query('SELECT password FROM admin_accounts WHERE id = $1', [req.admin.id]);
    if (!rows[0] || !(await bcrypt.compare(currentPassword, rows[0].password))) {
      throw unauthorized('Current password is incorrect');
    }
    const hash = await bcrypt.hash(newPassword, BCRYPT_ROUNDS);
    await query(
      'UPDATE admin_accounts SET password = $1, updated_at = now() WHERE id = $2',
      [hash, req.admin.id],
    );
    await audit.record(null, {
      admin: { id: req.admin.id, phone: null, email: req.admin.email },
      action: 'admin_password_changed',
      targetType: 'admin_account',
      targetId: req.admin.id,
    });
    res.json({ ok: true });
  }),
);

// ── Change own email ────────────────────────────────────────────────
const changeEmailSchema = z.object({
  currentPassword: z.string().min(1),
  newEmail: emailSchema,
});

router.post(
  '/change-email',
  validate(changeEmailSchema),
  asyncHandler(async (req, res) => {
    const { currentPassword, newEmail } = req.body;
    const normalEmail = newEmail.toLowerCase().trim();

    const { rows } = await query('SELECT password FROM admin_accounts WHERE id = $1', [req.admin.id]);
    if (!rows[0] || !(await bcrypt.compare(currentPassword, rows[0].password))) {
      throw unauthorized('Current password is incorrect');
    }

    const { rows: existing } = await query(
      'SELECT id FROM admin_accounts WHERE email = $1 AND id <> $2',
      [normalEmail, req.admin.id],
    );
    if (existing.length) throw conflict('That email is already in use by another admin');

    const oldEmail = req.admin.email;
    await query(
      'UPDATE admin_accounts SET email = $1, updated_at = now() WHERE id = $2',
      [normalEmail, req.admin.id],
    );
    await audit.record(null, {
      admin: { id: req.admin.id, phone: null, email: normalEmail },
      action: 'admin_email_changed',
      targetType: 'admin_account',
      targetId: req.admin.id,
      metadata: { oldEmail, newEmail: normalEmail },
    });
    res.json({ ok: true, email: normalEmail });
  }),
);

// ── Add sub admin (super_admin only) ────────────────────────────────
const addSubAdminSchema = z.object({
  email: emailSchema,
  password: passwordSchema,
  displayName: z.string().trim().max(100).optional(),
});

router.post(
  '/sub-admins',
  requireSuperAdmin,
  validate(addSubAdminSchema),
  asyncHandler(async (req, res) => {
    const { email, password, displayName } = req.body;
    const normalEmail = email.toLowerCase().trim();

    const { rows: existing } = await query(
      'SELECT id FROM admin_accounts WHERE email = $1', [normalEmail],
    );
    if (existing.length) throw conflict('An admin with that email already exists');

    const hash = await bcrypt.hash(password, BCRYPT_ROUNDS);
    const { rows: [admin] } = await query(
      `INSERT INTO admin_accounts (email, password, display_name, role)
       VALUES ($1, $2, $3, 'sub_admin')
       RETURNING id, email, display_name, role`,
      [normalEmail, hash, displayName || null],
    );

    await audit.record(null, {
      admin: { id: req.admin.id, phone: null, email: req.admin.email },
      action: 'sub_admin_created',
      targetType: 'admin_account',
      targetId: admin.id,
      metadata: { email: normalEmail, role: 'sub_admin' },
    });

    res.status(201).json({
      admin: { id: admin.id, email: admin.email, displayName: admin.display_name, role: admin.role },
    });
  }),
);

// ── List admins (super_admin only) ──────────────────────────────────
router.get(
  '/sub-admins',
  requireSuperAdmin,
  asyncHandler(async (req, res) => {
    const { rows } = await query(
      'SELECT id, email, display_name, role, created_at FROM admin_accounts ORDER BY id',
    );
    res.json({ admins: rows });
  }),
);

module.exports = { router, authenticateAdmin, requireSuperAdmin, signAdminToken };

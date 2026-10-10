-- 016_admin_accounts.sql — Dedicated admin accounts with email+password auth.
--
-- Admins are a separate entity from normal users. They do NOT live in the
-- users table and do NOT use the OTP sign-in flow. The first admin created
-- through the bootstrap endpoint becomes super_admin; subsequent admins are
-- created by a super_admin as sub_admin.
--
-- Passwords are stored as bcrypt hashes (cost 12).

CREATE TABLE IF NOT EXISTS admin_accounts (
  id           BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email        VARCHAR(254) NOT NULL,
  password     VARCHAR(255) NOT NULL,
  display_name VARCHAR(100),
  role         VARCHAR(20)  NOT NULL DEFAULT 'sub_admin'
                            CHECK (role IN ('super_admin', 'sub_admin')),
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT admin_accounts_email_unique UNIQUE (email)
);

-- Update admin_audit_log to reference admin_accounts instead of users.
-- The old admin_user_id / admin_phone / admin_email columns stay (nullable)
-- for historical rows; add a new column for the new admin identity.
ALTER TABLE admin_audit_log
  ADD COLUMN IF NOT EXISTS admin_account_id BIGINT REFERENCES admin_accounts(id) ON DELETE SET NULL;

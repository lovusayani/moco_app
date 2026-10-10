-- 012_app_settings.sql — small admin-managed app settings (key → JSON).
--
-- The first setting is the login screen background ('login_background'). A
-- generic key/value table rather than a column per setting, so future admin
-- settings need no schema change. Purely additive: no existing table changes.

CREATE TABLE IF NOT EXISTS app_settings (
  key        VARCHAR(64) PRIMARY KEY,
  value      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- The admin who last changed it; the full history is in admin_audit_log.
  updated_by BIGINT REFERENCES users(id) ON DELETE SET NULL
);

-- Email as a sign-in identity (multi-channel OTP).
--
-- A user is now identified by a verified phone number, a verified email
-- address, or both. Existing users all have a phone and keep it; nothing
-- about them changes. New users who sign in by email OTP have an email and
-- no phone until they add one.
--
-- Emails are stored normalized (trimmed, lower-cased) by the application, so
-- a plain UNIQUE constraint is enough; NULLs do not collide.

ALTER TABLE users ALTER COLUMN phone DROP NOT NULL;
ALTER TABLE users ADD COLUMN email VARCHAR(254);
ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);
ALTER TABLE users ADD CONSTRAINT users_identity_present
  CHECK (phone IS NOT NULL OR email IS NOT NULL);

-- The audit log snapshots the acting admin's identity. An admin who signs in
-- by email has no phone, so record whichever identity they have.
ALTER TABLE admin_audit_log ALTER COLUMN admin_phone DROP NOT NULL;
ALTER TABLE admin_audit_log ADD COLUMN admin_email VARCHAR(254);

-- Sign-in history records whichever identity was used.
ALTER TABLE auth_events ADD COLUMN email VARCHAR(254);

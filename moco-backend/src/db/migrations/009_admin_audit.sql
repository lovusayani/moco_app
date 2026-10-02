-- 009_admin_audit.sql
--
-- Admin operations foundation: an append-only audit trail of every sensitive
-- admin action, plus the review metadata the KYC and report queues need.
--
-- Append-only is enforced by the database, not by convention: UPDATE, DELETE
-- and TRUNCATE on admin_audit_log raise. An admin with API access therefore
-- cannot rewrite history through any route, and neither can a buggy one.

CREATE TABLE admin_audit_log (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  -- The admin's user row. Kept nullable + ON DELETE SET NULL only so a hard
  -- delete elsewhere can never be blocked by the audit; admin_phone below is
  -- the durable identity snapshot.
  admin_user_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
  admin_phone   VARCHAR(20) NOT NULL,
  action        VARCHAR(60) NOT NULL,
  target_type   VARCHAR(30) NOT NULL,
  target_id     TEXT,
  reason        TEXT,
  metadata      JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_admin_audit_created ON admin_audit_log (created_at DESC, id DESC);
CREATE INDEX idx_admin_audit_target ON admin_audit_log (target_type, target_id, created_at DESC);
CREATE INDEX idx_admin_audit_action ON admin_audit_log (action, created_at DESC);

CREATE FUNCTION admin_audit_log_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'admin_audit_log is append-only (% refused)', TG_OP;
END;
$$;

CREATE TRIGGER trg_admin_audit_no_update_delete
  BEFORE UPDATE OR DELETE ON admin_audit_log
  FOR EACH ROW EXECUTE FUNCTION admin_audit_log_immutable();

CREATE TRIGGER trg_admin_audit_no_truncate
  BEFORE TRUNCATE ON admin_audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION admin_audit_log_immutable();

-- KYC review metadata. kyc_submitted_at is when the application entered the
-- queue — updated_at cannot stand in for it, since photo changes bump it.
ALTER TABLE listener_profiles
  ADD COLUMN kyc_submitted_at TIMESTAMPTZ,
  ADD COLUMN kyc_reviewed_at  TIMESTAMPTZ,
  ADD COLUMN kyc_reviewed_by  BIGINT REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN kyc_review_note  TEXT;

-- Best available history for applications already in the system.
UPDATE listener_profiles
   SET kyc_submitted_at = updated_at
 WHERE kyc_status IN ('pending', 'approved', 'rejected') AND kyc_submitted_at IS NULL;

CREATE INDEX idx_listener_kyc_queue ON listener_profiles (kyc_status, kyc_submitted_at);

-- Report moderation metadata. The full action history lives in the audit log
-- (target_type = 'report'); these columns hold the current resolution.
ALTER TABLE reports
  ADD COLUMN resolved_by     BIGINT REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN resolution_note TEXT;

CREATE INDEX IF NOT EXISTS idx_reports_status_created ON reports (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auth_events_user_created ON auth_events (user_id, created_at DESC);

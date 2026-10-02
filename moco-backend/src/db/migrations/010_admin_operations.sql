-- 010_admin_operations.sql
--
-- Admin operations: manual coin adjustments, feed moderation metadata, payout
-- review metadata, and indexes for the admin call/ledger tables.

-- A manual adjustment is an ordinary, append-only ledger row with its own
-- reason, so it is never confused with a purchase, a call, a refund or a
-- promotional bonus — and old rows are never edited to "fix" a balance.
-- (Not used in this migration, so ADD VALUE is safe inside its transaction.)
ALTER TYPE ledger_reason ADD VALUE IF NOT EXISTS 'admin_adjustment';

-- Feed moderation. A post an ADMIN removes keeps its stored media (unlike an
-- author's own delete, which removes it), which is what makes restore
-- possible. removed_by distinguishes the two.
ALTER TABLE posts
  ADD COLUMN removed_at     TIMESTAMPTZ,
  ADD COLUMN removed_by     BIGINT REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN removal_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_posts_status_created ON posts (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_author_created ON posts (author_user_id, created_at DESC);

-- Payout review metadata (who approved/rejected, when).
ALTER TABLE payouts
  ADD COLUMN reviewed_by BIGINT REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN reviewed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_payouts_status_created ON payouts (status, created_at DESC);

-- Admin call history filters by party and by time.
CREATE INDEX IF NOT EXISTS idx_calls_created ON calls (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_calls_caller_created ON calls (caller_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_calls_listener_created ON calls (listener_id, created_at DESC);

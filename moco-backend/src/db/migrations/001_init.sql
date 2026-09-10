-- 001_init.sql — core schema (Project Summary §4).
--
-- Money invariants encoded here rather than left to application discipline:
--   * coin_ledger and listener_earnings are append-only; an UPDATE or DELETE on
--     either is rejected by a trigger.
--   * every ledger row carries balance_after, so a balance can always be
--     reconstructed from history and reconciled against the wallets table.
--   * balances are CHECKed non-negative, so no code path can overdraw a wallet
--     even if an application guard is missed.

CREATE TYPE user_role AS ENUM ('user', 'listener', 'both');
CREATE TYPE user_status AS ENUM ('active', 'suspended', 'deleted');
CREATE TYPE call_type AS ENUM ('audio', 'video');
CREATE TYPE call_status AS ENUM ('ringing', 'active', 'ended', 'failed');
CREATE TYPE ledger_reason AS ENUM ('topup', 'call_debit', 'refund', 'bonus');
CREATE TYPE earning_reason AS ENUM ('call_credit', 'payout');
CREATE TYPE kyc_status AS ENUM ('unsubmitted', 'pending', 'approved', 'rejected');
CREATE TYPE payout_status AS ENUM ('requested', 'approved', 'paid', 'rejected');

CREATE TABLE users (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  phone         VARCHAR(20)  NOT NULL UNIQUE,
  display_name  VARCHAR(80),
  avatar_url    TEXT,
  language      VARCHAR(8)   NOT NULL DEFAULT 'en',
  gender        VARCHAR(16),
  role          user_role    NOT NULL DEFAULT 'user',
  status        user_status  NOT NULL DEFAULT 'active',
  -- The 60-second new-user bonus is first-call-only, so it needs a flag that
  -- survives app reinstall; it lives on the account, not the device.
  free_trial_used BOOLEAN    NOT NULL DEFAULT FALSE,
  fcm_token     TEXT,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE wallets (
  user_id      BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  coin_balance BIGINT NOT NULL DEFAULT 0 CHECK (coin_balance >= 0),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE coin_ledger (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  delta         BIGINT NOT NULL,
  reason        ledger_reason NOT NULL,
  -- ref_id points at whatever caused the movement: a call id for call_debit, a
  -- payment order id for topup. Text so it can hold either.
  ref_id        TEXT,
  balance_after BIGINT NOT NULL CHECK (balance_after >= 0),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_coin_ledger_user_created ON coin_ledger (user_id, created_at DESC);
-- Guards topup replay: a payment webhook delivered twice must credit only once.
CREATE UNIQUE INDEX uniq_coin_ledger_topup_ref
  ON coin_ledger (ref_id) WHERE reason = 'topup' AND ref_id IS NOT NULL;

CREATE TABLE listener_profiles (
  user_id     BIGINT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  bio         TEXT,
  languages   TEXT[] NOT NULL DEFAULT ARRAY['en'],
  -- Rates are per-listener so a future premium tier is a data change, but they
  -- default to the platform rates in constants.js.
  audio_rate  INTEGER NOT NULL DEFAULT 6  CHECK (audio_rate > 0),
  video_rate  INTEGER NOT NULL DEFAULT 12 CHECK (video_rate > 0),
  is_online   BOOLEAN NOT NULL DEFAULT FALSE,
  is_busy     BOOLEAN NOT NULL DEFAULT FALSE,
  rating      NUMERIC(3,2) NOT NULL DEFAULT 0 CHECK (rating >= 0 AND rating <= 5),
  rating_count INTEGER NOT NULL DEFAULT 0,
  total_calls  INTEGER NOT NULL DEFAULT 0,
  -- Mirror of the listener_earnings tail, kept for the same reason wallets
  -- mirrors coin_ledger: the dashboard must not sum the whole history to
  -- render one number. Only ever written alongside an earnings row.
  earnings_balance BIGINT NOT NULL DEFAULT 0 CHECK (earnings_balance >= 0),
  lifetime_earnings BIGINT NOT NULL DEFAULT 0,
  kyc_status  kyc_status NOT NULL DEFAULT 'unsubmitted',
  kyc_name    VARCHAR(120),
  kyc_doc_url TEXT,
  upi_id      VARCHAR(120),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Discovery lists online, non-busy, KYC-approved listeners first; this partial
-- index keeps that query off a sequential scan as the table grows.
CREATE INDEX idx_listener_discovery ON listener_profiles (is_online, is_busy, rating DESC)
  WHERE kyc_status = 'approved';

CREATE TABLE listener_earnings (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listener_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  delta         BIGINT NOT NULL,
  reason        earning_reason NOT NULL,
  ref_id        TEXT,
  balance_after BIGINT NOT NULL CHECK (balance_after >= 0),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_listener_earnings_listener ON listener_earnings (listener_id, created_at DESC);

CREATE TABLE calls (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  caller_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  listener_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  type           call_type   NOT NULL,
  status         call_status NOT NULL DEFAULT 'ringing',
  agora_channel  VARCHAR(64) NOT NULL UNIQUE,
  rate_per_minute      INTEGER NOT NULL,
  listener_rate_per_minute INTEGER NOT NULL,
  -- Denormalised running totals. Authoritative history stays in call_ticks;
  -- these exist so the call-ended summary screen is a single row read.
  billed_minutes   INTEGER NOT NULL DEFAULT 0,
  coins_spent      BIGINT  NOT NULL DEFAULT 0,
  listener_earned  BIGINT  NOT NULL DEFAULT 0,
  free_seconds_granted INTEGER NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at     TIMESTAMPTZ,
  ended_at       TIMESTAMPTZ,
  end_reason     VARCHAR(32),
  CHECK (caller_id <> listener_id)
);

CREATE INDEX idx_calls_caller ON calls (caller_id, created_at DESC);
CREATE INDEX idx_calls_listener ON calls (listener_id, created_at DESC);
-- The tick worker and the stale-call sweeper both scan for live calls.
CREATE INDEX idx_calls_live ON calls (status) WHERE status IN ('ringing', 'active');

CREATE TABLE call_ticks (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  call_id        BIGINT NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
  minute_index   INTEGER NOT NULL,
  coins_debited  BIGINT NOT NULL,
  listener_share BIGINT NOT NULL,
  platform_share BIGINT NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- The real double-billing guard. The Redis lock prevents concurrent ticks;
  -- this constraint makes a duplicate impossible even if Redis is lost, since a
  -- retried job for minute N cannot insert a second row for minute N.
  UNIQUE (call_id, minute_index)
);

CREATE TABLE payouts (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listener_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  amount       BIGINT NOT NULL CHECK (amount > 0),
  status       payout_status NOT NULL DEFAULT 'requested',
  upi_ref      VARCHAR(120),
  note         TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at TIMESTAMPTZ
);

CREATE INDEX idx_payouts_listener ON payouts (listener_id, created_at DESC);
CREATE INDEX idx_payouts_pending ON payouts (status) WHERE status IN ('requested', 'approved');

-- Append-only enforcement. Correcting a bad ledger row means writing a
-- compensating row, never editing history.
CREATE OR REPLACE FUNCTION reject_mutation() RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION '% is append-only; write a compensating row instead', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER coin_ledger_append_only
  BEFORE UPDATE OR DELETE ON coin_ledger
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();

CREATE TRIGGER listener_earnings_append_only
  BEFORE UPDATE OR DELETE ON listener_earnings
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();

CREATE TRIGGER call_ticks_append_only
  BEFORE UPDATE OR DELETE ON call_ticks
  FOR EACH ROW EXECUTE FUNCTION reject_mutation();

-- 007_purchases.sql
--
-- Phase 7: the record of a real-money coin purchase verified against Google
-- Play, and the thing that makes a retried or duplicated verify request safe.
--
-- The purchase token itself is not stored — only its SHA-256 hash. A Play
-- purchase token is a bearer credential that can be replayed against Google's
-- own purchase-status API, so keeping the raw value around forever is
-- unnecessary exposure; the hash is all idempotency needs; here the raw token
-- is used to check status once and returned to the client for nothing further.
--
-- UNIQUE (token_hash) is the actual correctness guarantee, the same role
-- `uniq_coin_ledger_topup_ref` plays for the payment-gateway topup path: two
-- concurrent verify calls for the same purchase (a retried request, a
-- duplicated purchase-update event) can both attempt to insert, but only one
-- can succeed, so a purchase is credited exactly once regardless of how many
-- times its token is submitted.

CREATE TYPE purchase_provider AS ENUM ('google_play');
CREATE TYPE purchase_status AS ENUM ('verified', 'invalid');

CREATE TABLE purchases (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id        BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider       purchase_provider NOT NULL DEFAULT 'google_play',
  -- SHA-256 hex digest of the purchase token, not the token itself.
  token_hash     CHAR(64) NOT NULL,
  product_id     VARCHAR(60) NOT NULL,
  order_id       TEXT,
  status         purchase_status NOT NULL,
  coins_granted  INT NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  verified_at    TIMESTAMPTZ,

  CONSTRAINT purchases_token_hash_unique UNIQUE (token_hash)
);

CREATE INDEX idx_purchases_user ON purchases (user_id, created_at DESC);

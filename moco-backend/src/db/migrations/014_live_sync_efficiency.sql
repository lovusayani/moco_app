-- 014_live_sync_efficiency.sql — Moco Live sync without rewriting the catalog.
--
-- The provider's full online list (~12k models, ~36 MB) arrives every 30 s.
-- Almost every model's rank, viewer count and snapshot URL changes between
-- fetches, but the snapshot URL differs only by one timestamp shared by the
-- whole response. So:
--
--   live_models.content_hash   hash of the fields that matter (identity,
--                              images with the timestamp templated out, tags,
--                              status, geobans, goal text…). A row is only
--                              rewritten when this changes.
--   live_provider_state.live_snapshot
--                              the fast-changing values of every online model
--                              (rank, viewers, favorites, goal progress), as
--                              one compact JSON document written once per
--                              sync. Its keys are also the "online now" set.
--   live_provider_state.snapshot_ts
--                              the response-wide image timestamp the stored
--                              '{ts}' placeholders are filled with.
--   live_provider_state.last_ok_sync_at
--                              last successful sync; the listing shows nothing
--                              when it is stale (provider down = no stale list).
--
-- Purely additive; existing rows get a NULL hash and are rewritten once.

ALTER TABLE live_models ADD COLUMN IF NOT EXISTS content_hash VARCHAR(40);

ALTER TABLE live_provider_state ADD COLUMN IF NOT EXISTS live_snapshot JSONB;
ALTER TABLE live_provider_state ADD COLUMN IF NOT EXISTS snapshot_ts BIGINT;
ALTER TABLE live_provider_state ADD COLUMN IF NOT EXISTS last_ok_sync_at TIMESTAMPTZ;

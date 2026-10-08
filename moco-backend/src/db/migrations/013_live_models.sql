-- 013_live_models.sql — external live models (Moco Live), synced from a
-- provider's aggregator API (first provider: Stripcash).
--
-- Deliberately separate from users / listener_profiles: these are not Moco
-- accounts, they are a mirror of a third party's online-model list. Only
-- metadata is stored — image fields are the provider's URLs, never image
-- data. Rows are removed when the provider reports a model deleted, or after
-- 30 consecutive days without the model appearing in the API (provider
-- terms; src/modules/live/live.cleanup.js). Purely additive.

CREATE TABLE IF NOT EXISTS live_models (
  id                    BIGSERIAL    PRIMARY KEY,
  provider              VARCHAR(32)  NOT NULL,
  external_id           BIGINT,
  username              VARCHAR(128) NOT NULL,

  -- Provider-hosted image URLs (used directly by clients, never downloaded).
  avatar_url            TEXT,
  snapshot_url          TEXT,
  popular_snapshot_url  TEXT,
  thumb_url             TEXT,
  -- Provider stream/affiliate link. Server-side only for now.
  click_url             TEXT,

  country               VARCHAR(8),
  languages             TEXT[]       NOT NULL DEFAULT '{}',
  gender                VARCHAR(32),
  broadcast_gender      VARCHAR(32),
  tags                  TEXT[]       NOT NULL DEFAULT '{}',
  viewers_count         INTEGER      NOT NULL DEFAULT 0,
  favorited_count       INTEGER      NOT NULL DEFAULT 0,
  is_hd                 BOOLEAN      NOT NULL DEFAULT FALSE,
  is_vr                 BOOLEAN      NOT NULL DEFAULT FALSE,
  status                VARCHAR(32)  NOT NULL,

  -- Geobans as received, plus flattened, lower-case copies the listing query
  -- filters on: countries ('ua'), regions ('us.tx'), the countries that have
  -- any regional ban ('us'), and languages ('uk').
  geobans                    JSONB   NOT NULL DEFAULT '{}'::jsonb,
  blocked_countries          TEXT[]  NOT NULL DEFAULT '{}',
  blocked_regions            TEXT[]  NOT NULL DEFAULT '{}',
  blocked_region_countries   TEXT[]  NOT NULL DEFAULT '{}',
  blocked_languages          TEXT[]  NOT NULL DEFAULT '{}',

  goal_message          TEXT,
  goal_needed           INTEGER,
  goal_earned           INTEGER,

  -- Position in the last API response: the provider sorts by its own rating,
  -- so this is the "provider order".
  provider_rank         INTEGER,
  -- Any other provider fields, kept for later use without a schema change.
  metadata              JSONB        NOT NULL DEFAULT '{}'::jsonb,

  -- Last time the model was in the provider's online list / last sync that
  -- wrote this row.
  last_seen_at          TIMESTAMPTZ  NOT NULL,
  last_synced_at        TIMESTAMPTZ  NOT NULL,
  created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),

  CONSTRAINT live_models_provider_username_key UNIQUE (provider, username)
);

CREATE INDEX IF NOT EXISTS idx_live_models_seen
  ON live_models (provider, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_live_models_external
  ON live_models (provider, external_id);
CREATE INDEX IF NOT EXISTS idx_live_models_tags
  ON live_models USING GIN (tags);
CREATE INDEX IF NOT EXISTS idx_live_models_languages
  ON live_models USING GIN (languages);

-- One row per provider: sync health and the deleted-models polling cursor.
CREATE TABLE IF NOT EXISTS live_provider_state (
  provider                VARCHAR(32)  PRIMARY KEY,
  last_sync_at            TIMESTAMPTZ,
  last_sync_ok            BOOLEAN,
  last_sync_error         TEXT,
  last_count              INTEGER,
  last_total              INTEGER,
  -- deletedAt of the newest deleted-model record already processed.
  deleted_cursor          TIMESTAMPTZ,
  last_cleanup_at         TIMESTAMPTZ,
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

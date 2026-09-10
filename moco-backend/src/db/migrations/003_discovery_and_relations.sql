-- 003_discovery_and_relations.sql
--
-- Phase 1.1 hardening. Three things the client needed but the API could not
-- express, so the Flutter app was faking or omitting them:
--   * per-listener call capability, so the Callers/Video toggle can really filter
--   * favourite/follow, so those buttons can persist instead of being disabled
--   * a searchable name, so discovery search can run server-side over the whole
--     table rather than client-side over one loaded page

-- Capability. Defaults to TRUE for both so every existing listener keeps
-- exactly the behaviour they have today: the migration changes no visible
-- state, it only makes the distinction expressible.
ALTER TABLE listener_profiles
  ADD COLUMN accepts_audio BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN accepts_video BOOLEAN NOT NULL DEFAULT TRUE;

-- A listener who accepts neither call type is not a listener; the client has
-- no way to render them and discovery would surface an uncallable card.
ALTER TABLE listener_profiles
  ADD CONSTRAINT listener_accepts_a_call_type
  CHECK (accepts_audio OR accepts_video);

-- Discovery's ordering/filter index has to know about capability now, or every
-- capability-filtered query falls back to a scan.
DROP INDEX IF EXISTS idx_listener_discovery;
CREATE INDEX idx_listener_discovery
  ON listener_profiles (is_online, is_busy, accepts_audio, accepts_video, rating DESC)
  WHERE kyc_status = 'approved';

-- Favourite and follow are the same shape — a (viewer, listener) pair — so they
-- share one table with a kind, rather than two near-identical tables. The
-- primary key makes every write idempotent: repeating a favourite is a no-op,
-- not a duplicate row or an error.
CREATE TYPE listener_relation_kind AS ENUM ('favorite', 'follow');

CREATE TABLE listener_relations (
  user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  listener_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        listener_relation_kind NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, listener_id, kind),
  -- Following yourself is meaningless and would pollute counts.
  CHECK (user_id <> listener_id)
);

-- "Who follows this listener" (for a follower count) reads the other way round
-- from the primary key, so it needs its own index.
CREATE INDEX idx_listener_relations_listener
  ON listener_relations (listener_id, kind);

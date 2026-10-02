-- 008_listener_photos.sql
--
-- Listener profile photos, and the hard rule that comes with them: a listener
-- is only an active, discoverable, callable listener once BOTH their KYC is
-- approved AND they have at least 3 photos on file (LISTENER_PHOTOS.minCount
-- in constants.js).
--
-- Rows here only ever reference objects in the private `listener-media`
-- bucket at paths the backend minted itself (`<user-id>/<random>.<ext>`) and
-- has verified exist and fit the size cap — the client never chooses a path.
--
-- photo_count on listener_profiles mirrors count(*) of this table per
-- listener, for the same reason wallets mirrors coin_ledger: discovery, the
-- online toggle, and call claiming all need it in a WHERE clause, and they
-- must not run a correlated count on every listener row to get it. It is kept
-- exact by the trigger below rather than by application code, so no code path
-- (a route, a seed script, a manual SQL fix) can ever let it drift.

CREATE TABLE listener_photos (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  listener_id  BIGINT NOT NULL REFERENCES listener_profiles(user_id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL UNIQUE,
  mime_type    VARCHAR(40) NOT NULL,
  size_bytes   INTEGER CHECK (size_bytes IS NULL OR size_bytes > 0),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_listener_photos_listener ON listener_photos (listener_id, created_at, id);

ALTER TABLE listener_profiles
  ADD COLUMN photo_count INTEGER NOT NULL DEFAULT 0 CHECK (photo_count >= 0);

CREATE FUNCTION sync_listener_photo_count() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE listener_profiles
       SET photo_count = photo_count + 1, updated_at = now()
     WHERE user_id = NEW.listener_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE listener_profiles
       SET photo_count = GREATEST(photo_count - 1, 0), updated_at = now()
     WHERE user_id = OLD.listener_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_listener_photo_count
  AFTER INSERT OR DELETE ON listener_photos
  FOR EACH ROW EXECUTE FUNCTION sync_listener_photo_count();

-- Discovery's partial index now covers the full eligibility predicate, so the
-- discovery query (which filters on both) stays an index scan.
DROP INDEX IF EXISTS idx_listener_discovery;
CREATE INDEX idx_listener_discovery ON listener_profiles (is_online, is_busy, rating DESC)
  WHERE kyc_status = 'approved' AND photo_count >= 3;

-- Anyone approved before this rule existed has zero photos. They are NOT
-- demoted (their KYC approval stands), but they are no longer eligible, so
-- take them offline now rather than leave them advertising availability they
-- can no longer act on. They become eligible again automatically the moment
-- their third photo lands — no re-review needed.
UPDATE listener_profiles
   SET is_online = FALSE, updated_at = now()
 WHERE is_online = TRUE AND photo_count < 3;

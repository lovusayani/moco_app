-- 005_feed_posts.sql
--
-- Phase 4: the Feed. One table, because the approved product is one thing —
-- a newest-first vertical feed of image and short-video posts with a caption.
-- No likes, no comments, no follows-graph fan-out table: none of those are in
-- the approved design, and inventing schema for them now would guess wrong
-- about their shape. `posts` is the smallest model that serves the feed and
-- still leaves room for those to be added as their own tables later.

CREATE TYPE post_media_type AS ENUM ('image', 'video');

-- Soft delete rather than DELETE: a post that was reported must still resolve
-- to a row when an admin opens the report, and re-using the storage path of a
-- hard-deleted post would be a correctness hazard.
CREATE TYPE post_status AS ENUM ('active', 'removed');

CREATE TABLE posts (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  author_user_id BIGINT          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  media_type     post_media_type NOT NULL,
  -- The object path inside the private `feed-media` Supabase Storage bucket,
  -- NOT a public URL. Media bytes never live in Postgres; the API mints a
  -- short-lived signed URL on read, exactly as chat photo messages do.
  -- The path is always one this backend minted and prefixed with the author's
  -- own user id, so ownership is verifiable without a second lookup.
  media_path     TEXT            NOT NULL,
  caption        VARCHAR(500),
  status         post_status     NOT NULL DEFAULT 'active',
  created_at     TIMESTAMPTZ     NOT NULL DEFAULT now(),

  -- A blank caption and no caption are the same thing; storing '' would make
  -- the client render an empty line. Force one representation.
  CONSTRAINT posts_caption_not_blank CHECK (caption IS NULL OR length(btrim(caption)) > 0),
  CONSTRAINT posts_media_path_not_blank CHECK (length(btrim(media_path)) > 0),
  -- One post per uploaded object. Makes a retried create idempotent-ish at
  -- the schema level: a double-tap on Publish with the same upload cannot
  -- produce two posts of the same video.
  CONSTRAINT posts_media_path_unique UNIQUE (media_path)
);

-- The feed query: active posts, newest first, keyset-paginated on id.
-- Partial on status so removed posts cost nothing to skip, and DESC so the
-- index order is the scan order — no sort step for page one or any page after.
CREATE INDEX idx_posts_feed ON posts (id DESC) WHERE status = 'active';

-- "This author's posts", for a profile grid and for the author's own manage
-- view. Same partial predicate for the same reason.
CREATE INDEX idx_posts_author ON posts (author_user_id, id DESC) WHERE status = 'active';

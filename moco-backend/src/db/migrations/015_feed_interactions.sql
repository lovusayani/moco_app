-- 015_feed_interactions.sql — likes, comments and a share counter for Feed
-- posts. Purely additive.
--
-- Follows are NOT here: the Feed's Follow button uses the existing
-- listener_relations ('follow') table and API. Notifications for likes,
-- comments and follows use the existing notifications table.

-- One row per (post, user): the primary key makes a repeated like a no-op,
-- so a double tap or a retried request can never double-count.
CREATE TABLE IF NOT EXISTS post_likes (
  post_id    BIGINT      NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  user_id    BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (post_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_post_likes_user ON post_likes (user_id);

CREATE TABLE IF NOT EXISTS post_comments (
  id             BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  post_id        BIGINT       NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  author_user_id BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body           VARCHAR(500) NOT NULL,
  created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT post_comments_body_not_blank CHECK (length(btrim(body)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_post_comments_post ON post_comments (post_id, id DESC);

-- Shares are not per-user rows (a share is an action, not a state); the
-- counter is bumped at most once per user per post per hour (Redis guard in
-- the route), so repeated taps cannot inflate it.
ALTER TABLE posts ADD COLUMN IF NOT EXISTS share_count INTEGER NOT NULL DEFAULT 0;

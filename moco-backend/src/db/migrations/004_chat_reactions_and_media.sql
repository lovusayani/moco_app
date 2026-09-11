-- 004_chat_reactions_and_media.sql
--
-- Phase 3: reactions and photo messages, the two approved Chat Thread
-- features the schema had no way to express yet. Smallest extension over the
-- existing conversations/messages tables from 002_chat_and_safety.sql —
-- no new module, no duplicate messaging path.

-- One reaction per (message, user): reacting again just changes the emoji,
-- which is the approved design's add/change/remove behaviour without a
-- second write path for "change". Removing is a plain DELETE.
CREATE TABLE message_reactions (
  message_id BIGINT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji      VARCHAR(8) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- A message is either text or a photo, never both and never neither. Media
-- lives in Supabase Storage (private bucket); this column is the object path,
-- not a public URL — the API mints a short-lived signed URL on read, the same
-- way it already never trusts a client-supplied balance.
CREATE TYPE message_type AS ENUM ('text', 'image');

ALTER TABLE messages
  ALTER COLUMN body DROP NOT NULL,
  ADD COLUMN type message_type NOT NULL DEFAULT 'text',
  ADD COLUMN media_path TEXT,
  ADD CONSTRAINT messages_content_shape CHECK (
    (type = 'text'  AND body IS NOT NULL AND media_path IS NULL) OR
    (type = 'image' AND media_path IS NOT NULL)
  );

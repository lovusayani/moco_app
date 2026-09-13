-- 006_notifications.sql
--
-- Phase 6: the smallest backend subsystem needed for an in-app Notifications
-- screen. Push (FCM) already exists and is fire-and-forget — this is its
-- durable counterpart: a notification a user can open the app and still see,
-- mark read, or delete, independent of whether the push itself was ever
-- delivered (no token registered, device offline, FCM not configured in dev).
--
-- One table. `type` and `data` are deliberately loose (free text + jsonb)
-- rather than a table per notification kind: every kind so far is "here is a
-- short message and a place to navigate", and a rigid per-kind schema would
-- have to be migrated again for the next kind. `data` carries only what the
-- client needs to route a tap (e.g. {"conversationId": 5}) — never anything
-- sensitive, since it is returned verbatim over the API.

CREATE TABLE notifications (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type       VARCHAR(40) NOT NULL,
  title      VARCHAR(120) NOT NULL,
  body       VARCHAR(300),
  data       JSONB NOT NULL DEFAULT '{}',
  read_at    TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- The list query: this user's notifications, newest first, keyset-paginated.
CREATE INDEX idx_notifications_user ON notifications (user_id, id DESC);

-- The unread-count query, used for a badge — partial so a heavy user with a
-- long read history costs nothing to check.
CREATE INDEX idx_notifications_unread ON notifications (user_id) WHERE read_at IS NULL;

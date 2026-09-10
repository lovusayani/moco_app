-- 002_chat_and_safety.sql — chat, plus the reporting/blocking tables behind the
-- Batch 4 safety screens. Play Store policy requires an in-app report and block
-- path for user-to-user communication, so these are not optional extras.

CREATE TYPE report_status AS ENUM ('open', 'reviewing', 'actioned', 'dismissed');

CREATE TABLE conversations (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_a     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  user_b     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  last_message_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Store the pair in a canonical order so (a,b) and (b,a) cannot both exist.
  CHECK (user_a < user_b),
  UNIQUE (user_a, user_b)
);

CREATE TABLE messages (
  id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id BIGINT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  body            TEXT NOT NULL,
  read_at         TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_messages_conversation ON messages (conversation_id, created_at DESC);

CREATE TABLE blocks (
  blocker_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id),
  CHECK (blocker_id <> blocked_id)
);

CREATE TABLE reports (
  id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reporter_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reported_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  call_id      BIGINT REFERENCES calls(id) ON DELETE SET NULL,
  reason       VARCHAR(64) NOT NULL,
  details      TEXT,
  status       report_status NOT NULL DEFAULT 'open',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at  TIMESTAMPTZ,
  CHECK (reporter_id <> reported_id)
);

CREATE INDEX idx_reports_open ON reports (status, created_at DESC) WHERE status IN ('open', 'reviewing');

CREATE TABLE call_ratings (
  call_id    BIGINT PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
  rater_id   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  rating     SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment    TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- OTP attempts live in Redis, but a durable audit of auth events helps with
-- fraud review and with Play Store account-deletion requests.
CREATE TABLE auth_events (
  id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    BIGINT REFERENCES users(id) ON DELETE SET NULL,
  phone      VARCHAR(20),
  event      VARCHAR(32) NOT NULL,
  ip         INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_auth_events_phone ON auth_events (phone, created_at DESC);

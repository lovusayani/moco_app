-- Friend requests: a bidirectional, approval-gated relationship separate from
-- the unidirectional favorite/follow in listener_relations.

CREATE TYPE friend_request_status AS ENUM ('pending', 'accepted', 'rejected');

CREATE TABLE friend_requests (
  id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  requester_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  target_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  status        friend_request_status NOT NULL DEFAULT 'pending',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  responded_at  TIMESTAMPTZ,
  CHECK (requester_id <> target_id)
);

-- Only one pending request per ordered pair at a time.
CREATE UNIQUE INDEX uq_friend_request_pending
  ON friend_requests (LEAST(requester_id, target_id), GREATEST(requester_id, target_id))
  WHERE status = 'pending';

-- Fast lookup of accepted friendships for chat permission checks.
CREATE INDEX idx_friend_requests_accepted
  ON friend_requests (LEAST(requester_id, target_id), GREATEST(requester_id, target_id))
  WHERE status = 'accepted';

-- A user's incoming pending requests (for the notification/inbox).
CREATE INDEX idx_friend_requests_target_pending
  ON friend_requests (target_id)
  WHERE status = 'pending';

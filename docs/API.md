# Moco API Contract

Base path `/api`. All authenticated endpoints take `Authorization: Bearer <jwt>`.

Errors share one shape. Clients should switch on `error.code`, never on the message:

```json
{ "error": { "code": "insufficient_balance", "message": "Not enough coins", "details": null } }
```

| Status | Meaning |
| --- | --- |
| 400 | Validation or bad request (`validation_failed`, `self_call`, `kyc_required`) |
| 401 | Missing/invalid token, wrong OTP |
| 402 | `insufficient_balance` — the wallet cannot fund the action |
| 403 | Authenticated but not allowed (suspended, not a listener, not admin) |
| 404 | `not_found` |
| 409 | Conflict (`listener_unavailable`, `call_not_ringing`, `topup_already_applied`) |
| 429 | `rate_limited` |

---

## Public

### `GET /health`
Liveness probe. `{ "ok": true, "uptime": 1234 }`

### `GET /api/config`
Client bootstrap — rates, packs, languages, minimum app version. Call on launch.

---

## Auth

### `POST /api/auth/otp/request`
`{ "phone": "+919876543210" }` → `{ "sent": true, "expiresIn": 300 }`

Rate limited to 5 per phone per hour and 10 per IP per 5 minutes. Outside
production the code is fixed (`OTP_FIXED_CODE`, default `123456`).

### `POST /api/auth/otp/verify`
`{ "phone": "+919876543210", "code": "123456" }` →
```json
{ "token": "<jwt>", "isNew": true,
  "user": { "id": 1, "phone": "...", "displayName": null, "role": "user",
            "language": "en", "profileComplete": false } }
```
Codes are single-use. The account and its wallet are created on first verify.

---

## Users

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/users/me` | Profile, wallet balance, listener state |
| `PATCH` | `/api/users/me` | Update name, avatar, language, gender |

`GET` and `PATCH` return the **same canonical shape** — camelCase, at the top
level, including wallet balance and listener state. (Before Phase 1.1, `PATCH`
returned raw snake_case columns wrapped in `{ user: ... }`; clients that parsed
that shape must be updated.)
| `POST` | `/api/users/me/become-listener` | Opt into listener mode (creates an unverified profile) |
| `POST` | `/api/users/me/fcm-token` | Register the device push token |
| `DELETE` | `/api/users/me` | Account deletion (Play Store requirement) |

Deletion is a soft delete: personal fields are cleared but the row is retained,
because the financial ledgers reference it and history must stay reconstructable.

---

## Listeners

### `GET /api/listeners`
Discovery grid.

| Query param | Values | Effect |
| --- | --- | --- |
| `language` | `en` `hi` `te` | Listener speaks it |
| `gender` | `male` `female` `other` | |
| `online` | `true` | Online only (omit for no preference) |
| `q` | 1–60 chars | Server-side search over display name and bio, case-insensitive |
| `callType` | `audio` `video` | Only listeners who accept that call type |
| `limit` | 1–50, default 20 | |
| `offset` | default 0 | |

All filters compose. Only KYC-approved, active, non-blocked listeners are
returned. `isOnline` reflects both the listener's toggle *and* a live socket, so
a listener whose app was killed is not shown as callable.

Each listener carries `verified` (a plain boolean — KYC internals are never
exposed), plus `acceptsAudio` / `acceptsVideo` so a client can render capability
without a second call.

### `GET /api/listeners/:id`
Full listener profile. Adds `ratingCount`, and the viewer's own relation state:
`isFavorited`, `isFollowing`, `followerCount`.

### `PUT /api/listeners/:id/:kind` · `DELETE /api/listeners/:id/:kind`
`kind` is `favorite` or `follow`. Both are **idempotent**: repeating a PUT or a
DELETE returns the same result rather than duplicating or erroring, so a client
may retry safely after a dropped connection. Returns
`{ listenerId, kind, active, followerCount }`.

Only approved listeners can be followed. Following yourself is a 400
(`self_relation`).

### `PATCH /api/listeners/status`
`{ "isOnline": true }` — listener only. Refused with `kyc_required` until approved.

### `PATCH /api/listeners/me`
Update `bio` and `languages`. Rates stay admin-controlled.

### `POST /api/listeners/kyc`
`{ "fullName", "docUrl", "upiId" }` → status becomes `pending`. Resubmitting
after approval does not knock the listener back to pending.

---

## Wallet

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/wallet/packs` | Coin packs and rates (public) |
| `GET` | `/api/wallet` | Balance plus affordable audio/video minutes |
| `GET` | `/api/wallet/ledger` | Paginated coin history (`limit`, `before`) |
| `POST` | `/api/wallet/topup` | Create a gateway order — **credits nothing** |
| `POST` | `/api/wallet/webhook` | Gateway callback — the only path that credits coins |

Coins are credited exclusively in the webhook, because a client can claim a
payment succeeded but cannot forge a signed webhook. A repeated delivery is
absorbed by a unique index on the payment reference and returns
`{ ok: true, duplicate: true }`.

---

## Calls

### `POST /api/calls/initiate`
`{ "listenerId": 2, "type": "audio" | "video" }` →
```json
{ "callId": 7, "status": "ringing",
  "agora": { "channel": "moco_...", "token": "...", "uid": 1 },
  "ratePerMinute": 6, "freeSeconds": 0, "balance": 104 }
```
Runs the pre-flight balance check and claims the listener atomically. A second
caller racing for the same listener gets `409 listener_unavailable`.

### `POST /api/calls/:id/accept`
Listener answers. **This starts the meter.** Minute 1 is billed immediately
(full-minute billing); a caller on the free trial is billed from second 61.

### `POST /api/calls/:id/end`
Either participant ends the call. Idempotent — the first end reason stands.
Returns the summary for the call-ended screen, including `callerBalance` — the
caller's coin balance read fresh from the wallet after settlement.

### `GET /api/calls/:id`
Call state, including live minute index, for restoring the UI after an app restart.

### `GET /api/calls`
Call history for either role. A caller sees coins spent; a listener sees earned.

### `POST /api/calls/webhook/agora`
Agora Notification Center callback. Settles a call when a participant drops
without hanging up, so a call can never sit `active` indefinitely.

---

## Chat

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/chat` | Conversation list with unread counts |
| `GET` | `/api/chat/:userId/messages` | Message history (marks incoming as read) |
| `POST` | `/api/chat/:userId/messages` | Send a message |
| `POST` | `/api/chat/media/upload-url` | Authorize a photo-message upload |
| `PUT` | `/api/chat/messages/:messageId/reaction` | Set/change the caller's reaction |
| `DELETE` | `/api/chat/messages/:messageId/reaction` | Remove the caller's reaction |

A message is `{ id, conversationId, senderId, type, body, mediaUrl, readAt,
createdAt, reactions }`. `type` is `text` or `image`; a text message has
`body` and `mediaUrl: null`, an image message has `body: null` and a
short-lived signed `mediaUrl` (never a stored public URL — see the wallet
section's "server is the only source of truth" principle applied to media:
a client never holds long-lived access to another user's private bucket
path). `reactions` is `[{ userId, emoji }]`, at most one entry per user.

### `POST /api/chat/:userId/messages`
Either `{ "body": "..." }` (text, 1–2000 chars) or
`{ "type": "image", "mediaPath": "..." }` (photo — `mediaPath` must be one
this caller was issued by `/media/upload-url`; referencing someone else's
path is a 403). Blocked in either direction is a 403, same as before.

### `POST /api/chat/media/upload-url`
`{ "mimeType": "image/jpeg" | "image/png" | "image/webp" }` →
`{ path, uploadUrl, token, maxBytes }`. The client `PUT`s the raw image bytes
to `uploadUrl` directly (Supabase Storage's signed-upload-URL protocol; the
`token` is part of that protocol, not a bearer credential for this API), then
sends the message referencing `path`. Requires the backend's
`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` to be configured; without them
this returns `400 storage_not_configured` — photo messages are honestly
unavailable rather than faked.

### `PUT/DELETE /api/chat/messages/:messageId/reaction`
`PUT` takes `{ "emoji": "❤️" }`. Both are idempotent and restricted to the
message's two conversation participants (403 otherwise).

---

## Feed

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/feed` | Newest-first page of posts |
| `POST` | `/api/feed/media/upload-url` | Authorize a post media upload |
| `POST` | `/api/feed` | Publish a post for already-uploaded media |
| `DELETE` | `/api/feed/:postId` | Soft-delete the caller's own post |

A post is `{ id, mediaType, mediaUrl, caption, createdAt, author }` with
`author` = `{ id, name, avatarUrl, isListener, verified }`. `mediaType` is
`image` or `video`. `mediaUrl` is a short-lived **signed** URL into a private
bucket, minted per read — the same rule as chat photo messages, so a client
never holds durable access to stored media. `caption` is `null` or non-blank,
never `""`.

`author.isListener` tells the client whether tapping the author has a
destination: the only profile screen that exists is the listener profile, so a
non-listener author is rendered without a link rather than navigating to a
dead route. `verified` is the same derived KYC boolean discovery publishes —
raw KYC status is never sent to clients.

**No ranking.** Ordering is `id DESC`, which for an identity column is
creation order. There is deliberately no recommendation, scoring or
personalization here, and no likes or comments: none of those are in the
approved design, so no schema or endpoint guesses at their shape.

### `GET /api/feed`
`?limit=1..30` (default 10) `&cursor=<post id>` →
`{ posts: [...], nextCursor }`.

Keyset pagination, not `OFFSET`: `cursor` is the id of the last post the
client already holds and the server returns strictly older ones. That is what
makes paging stable when someone posts mid-scroll — an `OFFSET` page would
skip or repeat a post in that window. `nextCursor` is `null` only when the
page came back short, which is the one reliable end-of-feed signal.

Filtered server-side: only `active` posts by `active` users, and never a post
by a user blocked in **either** direction. That is the existing `blocks`
table with the same both-directions predicate discovery and chat already use
— there is no second block system.

### `POST /api/feed/media/upload-url`
`{ "mimeType": "image/jpeg" | "image/png" | "image/webp" | "video/mp4" | "video/quicktime" }`
→ `{ path, uploadUrl, token, mediaType, maxBytes, maxVideoSeconds }`.

The client `PUT`s the raw bytes to `uploadUrl` directly — media never travels
through this API, which is the point: a 64MB video must not pass through the
droplet's Node process. `maxBytes` is 8MB for images and 64MB for video.
Returns `400 storage_not_configured` when `SUPABASE_URL` /
`SUPABASE_SERVICE_ROLE_KEY` are unset, so posting is honestly unavailable
rather than faked.

### `POST /api/feed`
`{ "mediaPath": "...", "caption": "..."? }` → `201 { post }`.

Five things are verified, none taken on trust from the request body:

1. **Ownership** — `mediaPath` must start with the caller's own user id, the
   prefix every minted path carries. Checked *before* the storage-configured
   check, so config state can never widen access.
2. **Media type** — derived from the path's extension, never read from the
   body. The extension was chosen server-side from the MIME type the upload
   authorization already validated, so a client cannot upload a video and
   register it as an image.
3. **Existence** — the object must actually be in the bucket
   (`400 media_not_uploaded` otherwise), so a post can never reference media
   that was never uploaded and render as a broken feed item.
4. **Size** — the object's real size against its type's cap
   (`400 media_too_large`). A signed upload URL cannot carry a size limit, so
   this is enforced after the upload and before any row references it.
5. **Uniqueness** — `UNIQUE (media_path)`, so a double-tapped Publish is
   `400 already_posted` rather than two posts of the same video.

`403` if the path is not the caller's. Caption is 0–500 chars, trimmed;
blank becomes `null`.

### `DELETE /api/feed/:postId`
Author-only soft delete → `{ ok: true, postId }`. The row is marked `removed`
rather than deleted so a report filed against the post still resolves to
something; the stored object is then removed best-effort. Deleting an
already-deleted own post is a success (idempotent). Someone else's post is a
`404`, not a `403` — a post id must not be confirmable by probing.

Admin removal of another user's post is not this endpoint; that goes through
the existing report queue.

---

## Payouts (listener)

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/payouts/earnings` | Balance, lifetime, today, this month |
| `GET` | `/api/payouts/earnings/ledger` | Earnings history |
| `POST` | `/api/payouts` | Request a withdrawal (min ₹100) |
| `GET` | `/api/payouts` | Withdrawal history |

Requesting does not debit. The earnings balance is debited by the payout worker
once an admin approves, and pending requests are counted against the balance so
a listener cannot stack requests beyond what they have earned.

---

## Safety

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/safety/report` | Report a user |
| `POST` | `/api/safety/block` | Block a user (ends any live call between them) |
| `DELETE` | `/api/safety/block/:userId` | Unblock |
| `GET` | `/api/safety/blocks` | Blocked list |
| `POST` | `/api/safety/calls/:callId/rate` | Rate a finished call (caller only, once) |

---

## Notifications

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/notifications` | Newest-first page, with an unread count |
| `POST` | `/api/notifications/:id/read` | Mark one read (idempotent) |
| `POST` | `/api/notifications/read-all` | Mark everything read |
| `DELETE` | `/api/notifications/:id` | Remove one |

The durable counterpart to the fire-and-forget FCM push in
`src/integrations/fcm.js`: a user who missed the push (no token registered,
device offline, FCM unconfigured in dev) can still see the notification the
next time they open the app.

A notification is `{ id, type, title, body, data, read, createdAt }`. `data`
is a small object carrying only what the client needs to route a tap (e.g.
`{ "payoutId": 12 }`) — never anything sensitive, since it is returned
verbatim. `type` is a free-text tag, not an enum: `kyc_approved`,
`kyc_rejected`, `payout_approved`, `payout_rejected` today. Deliberately not
persisted here: incoming calls and chat messages, which already have their
own live delivery (Socket.IO + push) and would only accumulate as stale
"incoming call" entries after the call ends.

### `GET /api/notifications`
`?limit=1..50` (default 30) `&cursor=<id>` → same keyset-pagination shape as
the feed and both ledgers: `nextCursor` is the id to pass back for the next
page, `null` only when the page came back short.

### `POST /api/notifications/:id/read`
Marks one of the caller's own notifications read. A 404 for a notification
that doesn't exist or belongs to someone else — indistinguishable, so a
notification id can't be probed. Marking an already-read notification read
again is a no-op, not an error.

### `DELETE /api/notifications/:id`
Same ownership rule as read. Permanent — there is no undo/archive state.

---

## Admin

Gated by an allow-list of phone numbers in `ADMIN_PHONES`, not a database role,
so a compromised user row cannot escalate.

A web console for these endpoints is served at `/admin` (see the backend
README). It is static HTML/CSS/JS with no build step; every request it makes is
authenticated and re-checked against the allow-list server-side.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/admin/kyc` | Pending KYC queue |
| `POST` | `/api/admin/kyc/:userId` | Approve or reject |
| `GET` | `/api/admin/payouts` | Pending withdrawals |
| `POST` | `/api/admin/payouts/:id` | Approve (enqueues payment) or reject |
| `GET` | `/api/admin/reports` | Open reports, worst offenders first |
| `POST` | `/api/admin/reports/:id` | Dismiss or suspend |
| `GET` | `/api/admin/stats` | Platform metrics |
| `GET` | `/api/admin/reconcile` | Wallets vs. ledger — must always be `balanced: true` |

---

## WebSocket

Connect to the same origin with Socket.IO, passing the JWT:

```js
io(BASE_URL, { auth: { token } });
```

Each socket joins a private `user:<id>` room. Emit `heartbeat` with `{ callId }`
during a call to keep presence alive.

| Event | Sent to | Payload |
| --- | --- | --- |
| `call:incoming` | listener | `callId`, `callType`, `caller`, `agoraChannel`, `agoraToken` |
| `call:accepted` | caller | `callId`, `startedAt`, `freeSeconds` |
| `listener:presence` | all clients | `listenerId`, `isOnline`, `isBusy` — broadcast when a listener toggles availability or their socket drops |
| `call:tick` | both | `minuteIndex`, `coinsCharged`/`earned`, `balance`, `minutesRemaining` |
| `call:low_balance` | caller | `balance`, `minutesRemaining`, `coinsPerMinute` |
| `call:forced_end` | both | `reason: "insufficient_balance"`, `billedMinutes`, `coinsSpent` |
| `call:ended` | both | `reason`, `billedMinutes`, `coinsSpent`, `durationSeconds`, `callerBalance` (listener payload also adds `earned`) |
| `chat:message` | recipient | `conversationId`, `messageId`, `senderId`, `type`, `body`, `mediaUrl`, `createdAt` |
| `chat:reaction` | the message's other participant | `conversationId`, `messageId`, `userId`, `emoji` (`null` means removed) |

`call:low_balance` fires at roughly one minute of runway and is **non-blocking** —
the call continues while the client shows the inline recharge overlay.

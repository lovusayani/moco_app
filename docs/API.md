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
| `POST` | `/api/users/me/become-listener` | Opt into listener mode (creates an unverified profile) |
| `POST` | `/api/users/me/fcm-token` | Register the device push token |
| `DELETE` | `/api/users/me` | Account deletion (Play Store requirement) |

Deletion is a soft delete: personal fields are cleared but the row is retained,
because the financial ledgers reference it and history must stay reconstructable.

---

## Listeners

### `GET /api/listeners`
Discovery grid. Query: `language`, `gender`, `online`, `limit`, `offset`.

Only KYC-approved, active, non-blocked listeners are returned. `isOnline`
reflects both the listener's toggle *and* a live socket, so a listener whose app
was killed is not shown as callable.

### `GET /api/listeners/:id`
Full listener profile.

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
Returns the summary for the call-ended screen.

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
| `call:tick` | both | `minuteIndex`, `coinsCharged`/`earned`, `balance`, `minutesRemaining` |
| `call:low_balance` | caller | `balance`, `minutesRemaining`, `coinsPerMinute` |
| `call:forced_end` | both | `reason: "insufficient_balance"`, `billedMinutes`, `coinsSpent` |
| `call:ended` | both | `reason`, `billedMinutes`, `coinsSpent`, `durationSeconds` |
| `chat:message` | recipient | `conversationId`, `messageId`, `senderId`, `body` |

`call:low_balance` fires at roughly one minute of runway and is **non-blocking** —
the call continues while the client shows the inline recharge overlay.

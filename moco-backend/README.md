# Moco Backend

Per-minute paid social calling backend for the Indian market. Node.js modular
monolith on PostgreSQL + Redis, deployed to a DigitalOcean droplet under PM2.

- **API contract:** [`../docs/API.md`](../docs/API.md)
- **Economy:** [`src/utils/constants.js`](src/utils/constants.js) is the single
  source of truth for every rate and pack price. Nothing else hardcodes them.

## The economy

| | Caller pays | Listener earns | Platform keeps |
| --- | --- | --- | --- |
| Audio | 6 coins/min | ₹2/min | ₹4/min |
| Video | 12 coins/min | ₹4/min | ₹8/min |

1 coin = ₹1. Billing is **full-minute** — the started minute is billed in full.
New users get 60 free seconds on their first call only. Coin packs: ₹49, ₹99
(+5), ₹299 (+25), ₹599 (+75), ₹999 (+150).

## Running locally

```bash
cp .env.example .env          # fill in secrets; defaults work for local dev
docker compose up -d          # Postgres 16 + Redis 7
npm install
npm run migrate               # apply the schema
npm run seed                  # sample callers and listeners
npm start                     # API on :3000
npm run worker:tick           # billing worker, in a second terminal
```

Sign in without an SMS gateway: `SMS_PROVIDER=log` prints the OTP to the log,
and outside production any account accepts `OTP_FIXED_CODE` (default `123456`).

### Running against Supabase instead of local Postgres

Supabase is used here **only as hosted Postgres** — not Supabase Auth, not the
Supabase client SDK, not the Data API. This backend is the only thing that
holds database credentials; Flutter never talks to Supabase directly (it only
ever calls this API, exactly as with local Postgres). Everything else —
custom OTP auth, Redis, Socket.IO, BullMQ, Agora, the billing engine — is
unchanged.

```bash
DATABASE_URL=postgresql://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres
PGSSL=true
```

Use the **session pooler** connection string (Supabase dashboard: Project
Settings → Database → Connection string → "Session pooler"), or a direct
connection — not the transaction pooler. `withTransaction()` in
`src/config/db.js` holds one `BEGIN..COMMIT` open per call on a single checked-
out client, which the transaction pooler does not reliably support alongside
node-pg's parameterized queries. `npm run migrate` and `npm run seed` both go
through the same `src/config/db.js` pool, so they pick up `DATABASE_URL`
automatically — no separate Supabase-specific tooling.

### Supabase Storage (chat photos and feed media)

A separate concern from `DATABASE_URL` above — may be the same Supabase
project or a different one, doesn't matter — and likewise entirely
backend-mediated: the service-role key never reaches the Flutter client, and
Flutter never talks to Supabase directly. `src/integrations/chat.storage.js`
mints short-lived signed upload/view URLs; the client PUTs the image bytes
straight to Supabase Storage with one of those, never through this API.

`src/integrations/storage.js` is the single Supabase Storage client — one
SDK client for every bucket. `chat.storage.js` and `feed.storage.js` wrap it
with their own path scheme and authorization; nothing else in the codebase
touches the Supabase client, and the service-role key exists only in that one
file.

To enable it:
1. In the Supabase dashboard (Storage → New bucket), create **two private
   buckets** — leave "Public bucket" **off** for both:
   - `chat-media` (must match `CHAT_MEDIA.bucket` in `src/utils/constants.js`)
   - `feed-media` (must match `FEED_MEDIA.bucket` in the same file)
2. Set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in `.env` (Project
   Settings → API — the service-role key, **not** the anon key).

   `SUPABASE_URL` is the **project URL** — `https://<project-ref>.supabase.co`
   — not the REST endpoint the dashboard shows more prominently
   (`.../rest/v1`). The SDK appends its own `/storage/v1/...`, so a REST URL
   produces a doubled path and the unhelpful error *"Invalid path specified in
   request URL"*. `storage.js` normalises this rather than letting you debug
   it, but the project URL is what belongs there.
3. Restart the server.

No bucket policies are needed. The buckets stay private and every read and
write goes through a signed URL this backend mints with the service-role key,
so there is no anonymous or authenticated-role access to configure — and
nothing for a misconfigured policy to expose.

Both env vars unset is a deliberately valid state, not a boot failure:
`POST /api/chat/media/upload-url` and `POST /api/feed/media/upload-url`
return `400 storage_not_configured`, and the Flutter photo-attach button and
post composer surface that honestly rather than faking an upload. Everything
else works identically either way — chat text and reactions, and the feed
itself (posts are still listed; a post whose signed URL cannot be minted
shows a media error state rather than failing the whole page).

Both media paths are scoped to the uploader: `<user-id>/<random>.<ext>`, a
path this backend mints and the client never chooses. Authorizing "is this
the caller's own upload" is therefore a prefix check, and it runs **before**
the storage-configured check, so config state can never widen access.

Feed posting adds two checks a signed upload URL cannot carry itself: after
the client uploads, the server confirms the object actually exists in the
bucket and that its real size is within the cap for its type (8MB image,
64MB video) before any row references it. Media never passes through this
API — a 64MB video going through the droplet's Node process is exactly what
the direct-to-storage upload avoids.

**Do not run `npm test` against a Supabase dev database with real seed data**
— `resetDb()` in `tests/helpers.js` truncates every table, and Supabase
doesn't support a second database per project (only schemas), so there's no
config-only way to point the test suite at an isolated database the way
`createdb moco_test` gives you locally. `npm run smoke` instead exercises the
real, running server end to end (OTP login, discovery, listener profile,
follow/favorite, a full call including a real billing tick from the tick
worker, wallet debit, ledger reconciliation) without truncating anything, and
is safe to run against Supabase; re-run `npm run seed` afterward to restore
the sample balances it spends.

`npm run smoke` also covers the feed (pagination shape, ordering, upload
authorization, ownership refusal) and, **once the two buckets above exist**,
switches on a live storage round trip it otherwise skips: real image and video
uploads straight to Supabase Storage, publishing, fetching the signed URL
back, author-only delete, and the Phase 3 chat photo-message path end to end.
It cleans up every post it creates. Video *playback* is not something a script
can assert — that stays device QA (see `../mobile/README.md`).

## Admin console

A dependency-free web console is served by the API itself at
**`http://localhost:3000/admin`** — no build step and no second deployment.

Grant yourself access by putting your phone number in `ADMIN_PHONES`, then sign
in with the ordinary OTP flow:

```bash
ADMIN_PHONES=+919876543210 npm start
```

It covers the KYC queue, withdrawal approvals, the report queue, live platform
stats, and the wallet-vs-ledger reconciliation check. Serving the page grants
nothing on its own — every request it makes is re-checked server-side against
the allow-list, so a non-admin who loads it simply gets refused.

In production nginx serves `/admin` through the same proxy; restrict it by IP
in `nginx/moco.conf` if you want it off the public internet entirely.

### Tests

```bash
createdb moco_test && NODE_ENV=test PGDATABASE=moco_test npm run migrate
NODE_ENV=test PGDATABASE=moco_test REDIS_DB=1 npm test
```

Tests run against real Postgres and Redis rather than mocks — the guarantees
that matter here (atomic debits, unique tick rows, lock behaviour under
concurrency) only exist in the database, so mocking them would test nothing.
They share one database and truncate between cases, hence `--test-concurrency=1`.

## How billing works

The highest-risk part of the system: real-time state, money, and unreliable
mobile networks intersecting. Five independent guards, so no single failure
causes a mis-bill:

1. **Pre-flight.** A call cannot connect unless the caller can fund one full
   minute at the relevant rate.
2. **Per-call Redis lock** (`SET NX PX`) serialises ticks, so a retried job
   cannot bill concurrently. Released via a Lua compare-and-delete so a holder
   can never delete a lock it no longer owns.
3. **Guarded debit.** `UPDATE wallets SET coin_balance = coin_balance - $1
   WHERE user_id = $2 AND coin_balance >= $1` — two concurrent debits read the
   same balance, but only one satisfies the predicate at write time.
4. **`UNIQUE (call_id, minute_index)`** on `call_ticks`. This is the actual
   correctness guarantee: a duplicate minute is impossible even if Redis is
   wiped and every lock is lost. The lock is only an optimisation.
5. **`CHECK (coin_balance >= 0)`** on the wallet. A balance cannot go negative
   even if every application guard above were bypassed.

Each tick's debit, ledger row, tick row and listener credit commit in **one
transaction** — they cannot partially apply.

**Ticks are chained, not scheduled.** Each tick enqueues the next only if the
call is still active. A repeatable job would need explicit cancellation on every
end path (hang-up, forced end, disconnect, sweep), and one missed path would
leave a schedule billing a dead call. Chaining makes ending a call *the absence
of an action*, which is much harder to get wrong.

**When the caller runs out:** the tick fails on insufficient balance, the call
is ended server-side, and the Agora channel is terminated over Agora's REST API
— the client is told, not asked. `end_reason` is recorded as
`insufficient_balance`.

**When someone drops:** an Agora webhook settles the call. If that never
arrives, a sweeper running every 60s ends any call that has stopped ticking.
A stuck call costs the caller nothing (only ticks bill), but it would keep a
listener marked busy, so it still has to be cleaned up.

### Auditability

`coin_ledger` and `listener_earnings` are append-only, enforced by a trigger
that rejects `UPDATE` and `DELETE`. Correcting a bad row means writing a
compensating row, never editing history. Every row carries `balance_after`, so
a balance is always reconstructable — `GET /api/admin/reconcile` checks every
wallet against its ledger sum and must always return `balanced: true`.

## Layout

```
src/
├── config/      env, db (pool + withTransaction), redis (+ lock script)
├── modules/
│   ├── auth/        OTP request/verify, JWT issue
│   ├── users/       profile, role switch, account deletion
│   ├── wallet/      wallet.service.js is the ONLY code that moves coins
│   ├── listeners/   discovery, online state, KYC submission
│   ├── calls/       lifecycle, Agora tokens, billing.engine.js
│   ├── chat/        conversations and messages
│   ├── feed/        posts (image + short video), cursor-paginated
│   ├── payouts/     withdrawal requests
│   ├── safety/      report, block, call rating
│   └── admin/       KYC/payout/report queues, stats, reconciliation
├── db/          migrations/, migrate.js, seed.js
├── realtime/    socket.server.js, call.events.js, presence.js
├── workers/     tick, payout, notification (separate PM2 processes)
├── integrations/agora, sms, fcm, payment.gateway, storage (one Supabase client)
├── middleware/  auth, error, rateLimit, validate
└── utils/       constants.js (single source of truth), logger, errors

public/admin/    the admin console (plain HTML/CSS/JS, no build step)
```

Workers run as separate PM2 processes so a slow job never blocks an API
request, and the API can be restarted without interrupting billing mid-call.
They hold no sockets, so they publish events over a Redis pub/sub channel that
the API process forwards to the right socket.

## Deploying to DigitalOcean

Start on a 2GB / 1 vCPU droplet (~$12/mo) running Node, Postgres and Redis
together.

```bash
sudo apt update && sudo apt install -y nodejs npm postgresql redis nginx certbot python3-certbot-nginx
sudo npm install -g pm2

git clone <repo> && cd moco_app/moco-backend
npm ci --omit=dev
cp .env.example .env         # set JWT_SECRET, Agora, SMS, payment keys
npm run migrate

mkdir -p logs
pm2 start ecosystem.config.js
pm2 save && pm2 startup

sudo cp nginx/moco.conf /etc/nginx/sites-available/moco
sudo ln -s /etc/nginx/sites-available/moco /etc/nginx/sites-enabled/moco
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d api.yourdomain.com
```

**Before real wallets exist on it:** turn on weekly droplet snapshots.

**When call traffic starts:** move Postgres and Redis to DigitalOcean managed
add-ons so an API spike cannot starve the database. Every host and port is read
from env, so this is a config change and a data migration — not a rewrite. Set
`PGSSL=true` and `REDIS_TLS=true`, which managed instances require.

## Production checklist

- [ ] `JWT_SECRET` set to a long random value (the process refuses to boot in
      production without it)
- [ ] `SMS_PROVIDER=msg91` with credits loaded — `log` never sends an SMS
- [ ] `OTP_FIXED_CODE` has no effect in production; verify real codes arrive
- [ ] Agora app ID, certificate **and** `AGORA_CUSTOMER_KEY`/`SECRET` — without
      the REST credentials a forced end cannot terminate the channel
- [ ] `AGORA_WEBHOOK_SECRET` and `PAYMENT_WEBHOOK_SECRET` set; unsigned
      webhooks are rejected in production
- [ ] `ADMIN_PHONES` set to the real admin numbers
- [ ] Weekly droplet snapshots enabled
- [ ] `GET /api/admin/reconcile` monitored — a discrepancy means money moved
      without a ledger row

## Open items

- Wire a real UPI disbursement API in `payout.worker.js` (currently marks
  approved payouts paid and records the reference manually)
- Google Play Billing purchase-token verification for Play Store builds
- The Flutter client (Batches 2–4 of the design system are still to be built)

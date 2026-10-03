# Deploying Moco on Vercel

Everything application-side runs on Vercel: three projects deploy from this
one repo, all with production branch `main`. There is no VPS, nginx or PM2.
The managed services are Supabase (Postgres and Storage) and Upstash (Redis),
plus Agora, FCM, the SMS gateway and the payment providers.

| | `moco-web` | `moco-admin` | `moco-api` |
|---|---|---|---|
| Domain | `lovcamx.online` (+ `www` → 308 to apex) | `admin.lovcamx.online` | `api.lovcamx.online` |
| What | Flutter PWA | Admin console (static) | Node API, WebSockets, background jobs |
| Root Directory | `mobile` | `admin-web` | `moco-backend` |
| Framework Preset | Other | Other | Other |
| Install | `node tool/vercel/install_flutter.mjs` | *(skipped)* | `npm install` (default) |
| Build | `node tool/vercel/build_web.mjs` | `node build.mjs` | `npm run build:vercel` |
| Output | `build/web` | `dist` | `vercel-static` (robots.txt only) |
| Functions | none | none | `api/index.mjs` + `api/queues/*` + `api/cron/sweep.mjs`, region **`icn1`** |
| Node.js | 22.x | 22.x | 22.x |
| Env vars | none | none | backend secrets (section 4) |
| Config | [`mobile/vercel.json`](../mobile/vercel.json) | [`admin-web/vercel.json`](../admin-web/vercel.json) | [`moco-backend/vercel.json`](../moco-backend/vercel.json) |

Every project has **previews disabled** and an Ignored Build Step that builds
production only. A feature-branch push deploys nothing.

---

## 1. Architecture

```
 browser ──▶ lovcamx.online        (moco-web, static PWA)  ─┐
 browser ──▶ admin.lovcamx.online  (moco-admin, static)    ─┤ HTTPS /api/* (CORS)
 Android ───────────────────────────────────────────────────┤ WSS  /socket.io/
                                                            ▼
                         api.lovcamx.online  (moco-api, Vercel Functions, icn1)
                           api/index.mjs ── Express + Socket.IO (one http.Server)
                           api/queues/*  ── Vercel Queues consumers
                           api/cron/sweep ─ daily backstop (Vercel Cron)
                                │
          Supabase Postgres (Seoul, session pooler) · Upstash Redis · Supabase Storage
          Agora · FCM · SMS gateway · payment providers
```

### The API (`moco-backend/api/index.mjs`)

`vercel.json` rewrites every path to `api/index.mjs`, which exports the Node
`http.Server` that Express and Socket.IO share. Express sees the original URL,
so every route in `docs/API.md` is unchanged.

**WebSockets (Vercel, public beta, all plans).** A socket stays pinned to the
function instance that accepted it until the function's `maxDuration` (300 s,
the Hobby maximum). Then it closes and `socket_io_client` reconnects within a
second or two. These parts make that safe:

- **Fan-out through Redis pub/sub.** Every instance subscribes to the
  `moco:events` channel, and every event (ticks, chat, presence, forced end) is
  published there. Whichever instance holds the recipient's socket delivers it.
- **Presence survives reconnects.** A socket closing does not mark the user
  offline straight away. The disconnect handler decrements a per-user
  connection count, and a `moco-presence` job 15 s later clears presence and
  announces the listener offline only if no socket came back.
- **Presence while idle.** Socket.IO's own ping/pong refreshes the presence key.
  Previously only in-call heartbeats did, so an idle listener vanished from
  discovery after 90 s. That was a pre-existing bug, fixed in this change.
- **WebSocket transport only.** The server sets `transports: ['websocket']`;
  the Flutter client already used only that transport.

**CORS.** The three sites are separate origins, so the API allows exactly
`CORS_ORIGINS` (`https://lovcamx.online,https://www.lovcamx.online,https://admin.lovcamx.online`).
There is no `*` and no credentials. Auth is a bearer token in `Authorization`,
never a cookie, so a cross-site request carries no session and CSRF does not
apply.
- **Preflights:** an allowed origin gets a 204 with the requested headers. Any
  other origin gets a 403.
- **No `Origin` header:** the Android app, webhooks and server-to-server calls
  are not affected.
- **WebSockets:** checked the same way (`allowRequest`). Browsers from other
  origins are refused; native clients without an `Origin` are allowed and
  still need their token.
- **CORP:** Helmet's Cross-Origin-Resource-Policy is `cross-origin`, so
  responses stay readable by the allowed sites.

**Client IP.** Vercel sets `X-Forwarded-For` to the real client IP, overwriting
anything the client sent. Express trusts one proxy hop, so per-IP rate limits,
OTP limits included, see the real IP.

**Postgres.** Supabase's **session** pooler (the transactions in this code need
it). `PG_POOL_MAX=3` per instance, and `attachDatabasePool()` lets Fluid compute
release idle connections before an instance suspends.

### Background jobs: Vercel Queues (replacing BullMQ workers)

There are no worker processes. A job is a message on a Vercel Queues topic, and
Vercel invokes the matching consumer in `api/queues/` (push mode,
at-least-once, retried on failure). The handlers are the same code as before.

| Topic | Consumer | Producer | Notes |
|---|---|---|---|
| `moco-tick` | `api/queues/tick.mjs` → `workers/tick.worker.js` | call accept, then each tick (delay 60 s) | Bills one minute and chains the next. Idempotency key `tick-<call>-<minute>`, and the DB's per-call lock plus `UNIQUE(call_id, minute_index)` make re-delivery safe. |
| `moco-sweep` | `api/queues/sweep.mjs` → `workers/sweep.worker.js` | call start, every tick, itself | Ends calls whose chain died and ringing calls nobody answered. Re-schedules itself every minute **only while a call is ringing or active**. Key `sweep-<minute>` collapses duplicates. |
| `moco-notification` | `api/queues/notification.mjs` | incoming call, payout | FCM push |
| `moco-payout` | `api/queues/payout.mjs` | admin approval | Key `payout-<id>`; the handler only pays an `approved` payout |
| `moco-presence` | `api/queues/presence.mjs` | socket disconnect (delay 15 s) | See above |

Plus **Vercel Cron**: a daily `/api/cron/sweep` (protected by `CRON_SECRET`)
re-arms the sweep chain as a backstop. Daily is the Hobby maximum, and the
per-minute chain does not depend on Cron.

Queues pins messages to the deployment that published them. A call that starts
on one deployment keeps billing on that deployment's consumers after a new
deploy, until the call ends. **Do not delete a recent production deployment
while calls are live**, or their remaining ticks are dropped; the sweep on the
new deployment then ends those calls.

Locally, `JOBS_MODE=inline` (the default off Vercel) runs the same handlers in
the API process after the same delays. The test suite uses `record`.

The admin console's system-health page shows when a billing tick last ran
(it fails only if a call is active and no tick ran for 3 minutes). Queue depth
is in Vercel → moco-api → Observability → Queues.

### Web (`mobile/`)

A static PWA. `build_web.mjs` installs the pinned Flutter (3.47.3) on the build
machine and builds with:

```
--dart-define=FLAVOR=production
--dart-define=API_BASE_URL=https://api.lovcamx.online/api
--dart-define=SOCKET_URL=https://api.lovcamx.online
```

It fails if PWA files are missing, if `<base href="/">` is wrong, or if any
server secret's value is in the output. `vercel.json` behaviour:
- Deep links (`/chat/12`) return `index.html`, so refresh works.
- Missing files with an extension (`/x.js`) return a real 404.
- `/api`, `/socket.io`, `/admin` and `/health` return 404 on this domain.
- Every response gets `no-cache` (Flutter output is not content-hashed),
  `nosniff`, a referrer policy and `X-Frame-Options: DENY`.
- The service worker is network-first and ignores cross-origin requests, so
  API calls are never cached.

### Admin (`admin-web/`)

The console's source stays in `moco-backend/public/admin` (one copy).
`build.mjs` copies it to `dist/` and replaces the single `const API = '/api'`
with `https://api.lovcamx.online/api`. The headers match what helmet sent
before:
- CSP with `connect-src 'self' https://api.lovcamx.online`, and images/media
  allowed from `https://*.supabase.co` for signed KYC and post previews.
- `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `nosniff`, `no-referrer`
  and `noindex`.

`/admin` redirects to `/`, and any other unknown path returns 404. The API no
longer serves `/admin` in production. "Include files outside the root
directory" must stay **on**.

---

## 2. Environment variables

**moco-web / moco-admin:** none. Neither has secrets, and both bake in only the
public API origin. (`MOCO_API_ORIGIN` and `MOCO_FLAVOR` are optional
overrides.)

**moco-api** (Production scope; secrets marked **Sensitive**):

| Variable | Value / source | Sensitive |
|---|---|---|
| `NODE_ENV` | `production` | |
| `LOG_LEVEL` | `info` | |
| `DATABASE_URL` | Supabase session-pooler URI | ✔ |
| `PGSSL` / `PG_POOL_MAX` | `true` / `3` | |
| `REDIS_HOST` / `REDIS_PASSWORD` | Upstash | ✔ |
| `REDIS_PORT` / `REDIS_TLS` / `REDIS_DB` | `6379` / `true` / `0` | |
| `JWT_SECRET` | random, production-only (not the dev one) | ✔ |
| `JWT_ACCESS_TTL`, `OTP_TTL`, `OTP_MAX_ATTEMPTS` | as in dev | |
| `CORS_ORIGINS` | the three site origins | |
| `CRON_SECRET` | random | ✔ |
| `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` | Supabase Storage | ✔ (key) |
| `ADMIN_PHONES` | admin numbers | ✔ |
| `MIN_APP_VERSION`, `AGORA_TOKEN_TTL`, `SMS_SENDER_ID` | as in dev | |
| `SMS_PROVIDER` + `SMS_API_KEY` | **`msg91` + key needed** — with `log`, production OTPs are never delivered and nobody can sign in | ✔ (key) |
| `PAYMENT_PROVIDER` + keys + `PAYMENT_WEBHOOK_SECRET` | currently `mock` (production refuses mock webhooks, so no coins can be credited) | ✔ |
| `AGORA_APP_ID`, `AGORA_APP_CERTIFICATE`, `AGORA_WEBHOOK_SECRET`, `AGORA_CUSTOMER_KEY/SECRET` | **needed for calls** (Android) | ✔ |
| `FCM_SERVER_KEY` | **needed for push** | ✔ |
| `GOOGLE_PLAY_PACKAGE_NAME` / `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Play Billing verification | ✔ |

`npm run build:vercel` fails the deployment if a required variable is missing.
It warns, without failing, when SMS is still `log` in production. Never put
backend variables in moco-web or moco-admin.

---

## 3. DNS (Cloudflare zone `lovcamx.online`)

Use these exact records, which are Vercel's project-specific recommendations.
Set them to **DNS only** (grey cloud) so Vercel issues and renews the
certificates:

| Name | Type | Value | Project |
|---|---|---|---|
| `@` | A | `216.198.79.1` | moco-web |
| `@` | A | `64.29.17.1` | moco-web |
| `www` | CNAME | `dc208919096474bc.vercel-dns-017.com` | moco-web (redirects to apex) |
| `admin` | CNAME | `1149b9429c0403d6.vercel-dns-017.com` | moco-admin |
| `api` | CNAME | `9f296ff4478d5419.vercel-dns-017.com` | moco-api |

If the zone has a CAA record, it must allow `letsencrypt.org`. Vercel serves
HTTP → HTTPS redirects and HSTS automatically.

---

## 4. Auto-deploy flow

```
feature branch → local checks → merge to main → git push upstream main
                                                  ├─▶ moco-web   (mobile/)
                                                  ├─▶ moco-admin (admin-web/ + moco-backend/public/admin)
                                                  └─▶ moco-api   (moco-backend/)
```

Local checks before merging:
- `mobile/`: `flutter analyze`, `flutter test`, `node tool/vercel/build_web.mjs`
- Admin: `node admin-web/build.mjs`
- `moco-backend/`: `npm test` against a **local** Postgres and Redis
  (`docker compose up -d`). The guard refuses Supabase and Upstash.

GitHub Actions (`.github/workflows/ci.yml`) runs the same checks, but only when
the account's Actions billing is active.

Database migrations are **not** run by Vercel. Before merging a change that
adds one, run `npm run migrate` from `moco-backend/` with the production
`DATABASE_URL`. Migrations are additive and the code tolerates them.

---

## 5. Rollback

- **Fastest:** Vercel → project → Deployments → the last good deployment →
  **Instant Rollback**. Each project rolls back independently.
- **Durable:** `git revert` on `main` and push. Do this after an instant
  rollback, or the next push re-deploys the bad code.
- **API rollbacks and Queues:** messages stay with the deployment that
  published them. The rolled-back-from deployment keeps billing its live calls
  until they end. Don't delete it while calls are live.
- **PWA:** network-first service worker with `no-cache` files, so users get the
  rolled-back version on their next load.

---

## 6. Plan limits (Vercel Hobby vs Pro)

The code runs on Hobby, but **production on Hobby is not appropriate**:

1. **Commercial use.** Hobby is "non-commercial, personal use only" under
   Vercel's fair-use guidelines. Moco sells coins and pays listeners.
2. **Provisioned memory.** Hobby includes 360 GB-hrs a month, and every Hobby
   instance is 2 GB. While any user holds a socket, at least one instance
   stays up: about 1,440 GB-hrs a month for one instance around the clock.
   When an included limit is exceeded, Hobby pauses the feature for up to 30
   days.
3. **Cron:** daily only on Hobby. The design does not rely on it.
4. **Socket lifetime:** 300 s on Hobby (forced reconnects). Pro allows 800 s,
   so reconnects happen less often.

Pro is $20 per seat per month plus usage.

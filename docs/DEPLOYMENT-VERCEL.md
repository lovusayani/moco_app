# Deploying Moco web + admin on Vercel

Two Vercel projects deploy two static frontends from this one repo. Both deploy
automatically from `main`. The Node backend and its workers are **not** on
Vercel. They keep running on the persistent server (PM2 + nginx, see
`moco-backend/ecosystem.config.js` and `moco-backend/nginx/moco.conf`).

| | Project A: `moco-web` | Project B: `moco-admin` |
|---|---|---|
| Domain | `lovcamx.online` (+ `www` → apex) | `admin.lovcamx.online` |
| What | Flutter PWA (`mobile/`) | Admin console (`moco-backend/public/admin`) |
| Root Directory | `mobile` | `admin-web` |
| Framework Preset | Other | Other |
| Install Command | `node tool/vercel/install_flutter.mjs` | *(skipped)* |
| Build Command | `node tool/vercel/build_web.mjs` | `node build.mjs` |
| Output Directory | `build/web` | `dist` |
| Production Branch | `main` | `main` |
| Config file | [`mobile/vercel.json`](../mobile/vercel.json) | [`admin-web/vercel.json`](../admin-web/vercel.json) |

The install, build and output values are already set in each `vercel.json`,
which overrides the dashboard. If you fill in the dashboard, use the same
values.

---

## 1. Architecture

```
                   ┌────────────── Vercel ──────────────┐
 browser ──HTTPS──▶│ lovcamx.online        (moco-web)   │
                   │   /            → Flutter PWA files │
                   │   /api/*       → proxy ────────────┼──┐
                   │                                    │  │
 browser ──HTTPS──▶│ admin.lovcamx.online  (moco-admin) │  │
                   │   /            → admin console     │  │
                   │   /api/auth/*  → proxy ────────────┼──┤
                   │   /api/admin/* → proxy ────────────┼──┤
                   └────────────────────────────────────┘  │
                                                           ▼
 browser (PWA) ──WSS /socket.io──────────────▶ api.lovcamx.online  (nginx → Node :3000)
 Android app  ──HTTPS /api + WSS /socket.io──▶   ├─ moco-api (PM2 cluster)
                                                 ├─ tick / payout / notification workers
                                                 └─ Postgres (Supabase) · Redis · Agora · Storage
```

- **REST API: same-origin through Vercel.** Each frontend calls relative
  `/api/...` URLs, and Vercel proxies them to `MOCO_BACKEND_ORIGIN`. The
  browser only ever talks to its own origin, so the backend needs **no CORS
  policy** and no app or backend code changed. The web app already defaults to
  `<origin>/api` (`mobile/lib/core/config/env.dart`). The admin console already
  uses `const API = '/api'`.
- **Socket.IO goes direct to the backend.** Vercel's edge proxy does not
  carry WebSocket upgrades. The web build bakes in
  `SOCKET_URL=MOCO_BACKEND_ORIGIN`, so the PWA opens
  `wss://api.lovcamx.online/socket.io/` itself. This works cross-origin as is:
  the client uses the WebSocket transport only, authenticates with the token in
  the handshake (no cookies), and the server allows any origin
  (`socket.server.js`). Calling is disabled on web, so the socket only carries
  presence, chat and notification events there.
- **Admin is proxied narrowly.** `admin.lovcamx.online` forwards only
  `/api/auth/*` (OTP sign-in) and `/api/admin/*`. Every other `/api` path
  returns 404 at the edge. Admin authorization is still enforced server-side on
  every `/api/admin` request (`ADMIN_PHONES`).
- **Nothing moves to Vercel** except static files and edge routing. Workers,
  realtime, billing, KYC and call logic are unchanged and stay on the server.

### The real client IP: `MOCO_EDGE_PROXY_SECRET`

Proxied requests reach nginx from Vercel's edge IPs. Without extra handling,
every web user would share a few IPs, so the per-IP OTP limits (nginx
`moco_auth_limit` 1 r/s, and the app's `otp_req` 10 per 5 min) would lock all
web users out together. The setup works like this:

1. Vercel sets `X-Forwarded-For` to the real client IP. It overwrites any value
   the client sent.
2. Both `vercel.json` files add `X-Moco-Edge-Secret: $MOCO_EDGE_PROXY_SECRET` to
   proxied requests.
3. `moco-backend/nginx/moco.conf` trusts `X-Forwarded-For` **only** when that
   secret matches. It passes a single, verified client IP to Express (which
   trusts one proxy hop) and strips the secret header before it reaches Node.
   Anyone calling `api.lovcamx.online` directly cannot spoof their IP.

The secret is never bundled into a frontend. Vercel uses it only at the edge,
and `build_web.mjs` fails the build if its value appears in `build/web`.

---

## 2. Project A: `moco-web` → `lovcamx.online`

**Settings**

- Git repository: `lovusayani/moco_app` · Production Branch: `main`
- Root Directory: `mobile`
- Framework Preset: **Other**
- Install / Build / Output: taken from `mobile/vercel.json` (table above)
- Node.js version: 20.x or 22.x (default is fine)

**How the build works.** Vercel's build image has no Flutter.
`install_flutter.mjs` downloads the **pinned** Flutter SDK (3.47.3, which
matches local development) and precaches the web engine. Then `build_web.mjs`
runs:

```
flutter build web --release --no-wasm-dry-run \
  --dart-define=FLAVOR=production \
  --dart-define=SOCKET_URL=$MOCO_BACKEND_ORIGIN
```

After the build, the script checks the output. All PWA files must be present
(manifest, `sw.js`, icons, CanvasKit), `<base href="/">` must be set, and no
server-secret value may appear anywhere in `build/web`. Downloading Flutter
adds about 2–4 min to each build. To upgrade Flutter, set `FLUTTER_VERSION` (env
var) or bump the default in `install_flutter.mjs`.

**Routing (`mobile/vercel.json`, in order)**

| Request | Result |
|---|---|
| `/api/*` | proxied to `$MOCO_BACKEND_ORIGIN/api/*`, never cached (`no-store`) |
| `/socket.io/*`, `/admin*`, `/health` | 404 (these do not belong on the web domain) |
| an existing file (`/main.dart.js`, `/icons/…`) | served, `Cache-Control: no-cache` (Flutter output is not content-hashed) |
| a missing path **with** a file extension (`/foo.png`) | 404, so a missing asset never comes back as HTML |
| any other path (`/chat/12`, `/listener/7`, `/feed`) | `index.html`. Deep links and refresh work, and GoRouter shows its own "Page not found" for unknown routes |

Every response also gets `nosniff`, `Referrer-Policy:
strict-origin-when-cross-origin` and `X-Frame-Options: DENY`.
`/sw.js` gets `Service-Worker-Allowed: /`, and `/manifest.json` is served as
`application/manifest+json`. HTTPS and HSTS are automatic on Vercel domains.
HTTPS is required: the service worker, install prompt and WebCrypto session
storage only work in a secure context.

## 3. Project B: `moco-admin` → `admin.lovcamx.online`

**Where the admin console comes from.** It is three static files in
`moco-backend/public/admin` (`index.html`, `admin.css`, `admin.js`). The UI has
no build step and uses hash routing (`#/users`). Today Express serves the same
files at `/admin`. The production nginx (`location / { return 404; }`) never
exposed that path publicly, so this Vercel project is now how the console is
served. The files were **not** moved or copied in git. `admin-web/build.mjs`
copies them into `admin-web/dist` at build time, so there is still one source
of truth, and the Express route keeps working for local development.

**Settings**

- Git repository: `lovusayani/moco_app` · Production Branch: `main`
- Root Directory: `admin-web`
- **"Include files outside the root directory in the Build Step": Enabled**
  (default on). The build reads `../moco-backend/public/admin`.
- Framework Preset: **Other**
- Install: skipped · Build: `node build.mjs` · Output: `dist`

**Routing (`admin-web/vercel.json`)**

| Request | Result |
|---|---|
| `/api/auth/*`, `/api/admin/*` | proxied to `$MOCO_BACKEND_ORIGIN/api/...`, `no-store` |
| any other `/api/*`, `/socket.io/*`, `/health` | 404 |
| `/admin`, `/admin/` | 308 → `/` (old bookmarks) |
| `/`, `/admin.css`, `/admin.js` | served, `no-cache` |
| anything else | 404 |

The security headers match what Express/helmet sends for `/admin` today: the
same CSP (`script-src 'self'`, images and media from `'self'`, `data:` and
`https://*.supabase.co` for signed KYC/post previews),
`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `nosniff`,
`Referrer-Policy: no-referrer`, and `X-Robots-Tag: noindex`. If Supabase
Storage moves to a custom domain, add it to `img-src`/`media-src` in
`admin-web/vercel.json`.

---

## 4. Environment variables

### WEB PUBLIC ENV: Vercel project `moco-web`

| Name | Environment | Value | Notes |
|---|---|---|---|
| `MOCO_BACKEND_ORIGIN` | Production | `https://api.lovcamx.online` | Required. Proxy target for `/api/*` and baked in as the Socket.IO URL. Public (visible in the bundle). Origin only, no path. |
| `MOCO_EDGE_PROXY_SECRET` | Production | 64 hex chars (`openssl rand -hex 32`) | Required. Mark **Sensitive**. Edge-only header for nginx, never bundled. Same value as moco-admin and `/etc/nginx/moco-edge-secret.conf`. |
| `MOCO_FLAVOR` | — | `production` (default) | Optional. The build refuses anything else for the production deployment. |
| `MOCO_SOCKET_URL` | — | — | Optional. Only if Socket.IO is ever hosted on a different origin from the API. |
| `FLUTTER_VERSION` | — | `3.47.3` (default) | Optional. Flutter SDK upgrade. |

### ADMIN PUBLIC ENV: Vercel project `moco-admin`

| Name | Environment | Value | Notes |
|---|---|---|---|
| `MOCO_BACKEND_ORIGIN` | Production | `https://api.lovcamx.online` | Required. Proxy target. |
| `MOCO_EDGE_PROXY_SECRET` | Production | same value as moco-web | Required. Sensitive, edge-only. |

The admin console has no build-time config. It uses relative `/api` URLs.

### BACKEND PRIVATE ENV: the server only (`moco-backend/.env`), never Vercel

| Group | Variables |
|---|---|
| Runtime | `NODE_ENV=production`, `PORT=3000`, `LOG_LEVEL=info` |
| Postgres | `DATABASE_URL` (Supabase **session** pooler), `PGSSL=true`, `PG_POOL_MAX` |
| Redis | `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `REDIS_TLS`, `REDIS_DB` |
| Auth | `JWT_SECRET` (**required**: boot fails without it in production), `JWT_ACCESS_TTL`, `OTP_TTL`, `OTP_MAX_ATTEMPTS`. `OTP_FIXED_CODE` is ignored in production. |
| Agora | `AGORA_APP_ID`, `AGORA_APP_CERTIFICATE`, `AGORA_TOKEN_TTL`, `AGORA_WEBHOOK_SECRET`, `AGORA_CUSTOMER_KEY`, `AGORA_CUSTOMER_SECRET` |
| SMS | `SMS_PROVIDER=msg91`, `SMS_API_KEY`, `SMS_SENDER_ID` |
| Push | `FCM_SERVER_KEY` |
| Payments | `PAYMENT_PROVIDER`, `PAYMENT_KEY_ID`, `PAYMENT_KEY_SECRET`, `PAYMENT_WEBHOOK_SECRET` |
| Storage | `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` |
| Admin | `ADMIN_PHONES` |
| App | `MIN_APP_VERSION` |
| nginx | `/etc/nginx/moco-edge-secret.conf` holds `MOCO_EDGE_PROXY_SECRET` (template: `moco-backend/nginx/moco-edge-secret.conf.example`) |

**Never add these to a Vercel project:** `DATABASE_URL`, any `PG*`/`REDIS*`
credential, `JWT_SECRET`, `SUPABASE_SERVICE_ROLE_KEY`,
`AGORA_APP_CERTIFICATE`, `AGORA_CUSTOMER_SECRET`, `AGORA_WEBHOOK_SECRET`,
payment secrets, `SMS_API_KEY`, `FCM_SERVER_KEY` or `ADMIN_PHONES`. Neither
frontend needs them. As a backstop, `build_web.mjs` fails if any of these values
is present in the build environment **and** appears in the output.

---

## 5. Domains and DNS

At the DNS provider for `lovcamx.online`:

| Host | Type | Value | Points to |
|---|---|---|---|
| `@` (apex) | A | `76.76.21.21`, or the value Vercel shows when you add the domain | Vercel (moco-web) |
| `www` | CNAME | `cname.vercel-dns.com` (or as Vercel shows) | Vercel (moco-web), redirect to apex |
| `admin` | CNAME | `cname.vercel-dns.com` (or as Vercel shows) | Vercel (moco-admin) |
| `api` | A | the droplet's public IPv4 | backend server, **not** Vercel |

- Use the exact record values in each project's **Settings → Domains**
  panel. Vercel sometimes issues project-specific targets.
- If DNS is on Cloudflare: set `@`, `www` and `admin` to **DNS only** (grey
  cloud) so Vercel can issue certificates. `api` may be DNS only or proxied.
  If proxied, keep the WebSocket setting on.
- `api.lovcamx.online` needs its own certificate on the server:
  `sudo certbot --nginx -d api.lovcamx.online`.
- If a CAA record exists, it must allow `letsencrypt.org` (both Vercel and
  certbot use it).

---

## 6. Backend dependency (do this before the first Vercel deploy)

The frontends are useless without `https://api.lovcamx.online` serving the
API. On the server:

1. DNS `api` → droplet. Then `sudo certbot --nginx -d api.lovcamx.online`.
2. Install the updated `moco-backend/nginx/moco.conf`. It now uses the domain
   and handles the edge secret.
3. Create `/etc/nginx/moco-edge-secret.conf` from the `.example` with the real
   secret. Run `chmod 600` on it, then `sudo nginx -t && sudo systemctl reload nginx`.
   nginx will not start without this file, by design.
4. Production `.env` (section 4), then `npm ci --omit=dev`, `npm run migrate`,
   and `pm2 start ecosystem.config.js && pm2 save`.
5. Check: `curl https://api.lovcamx.online/health` returns `{"ok":true,…}`.

Point the Android release build at the same backend:
`--dart-define=API_BASE_URL=https://api.lovcamx.online/api --dart-define=SOCKET_URL=https://api.lovcamx.online`.

---

## 7. Auto-deploy flow

```
feature branch ──▶ local checks (flutter analyze / test / build web,
                    node admin-web/build.mjs, npm test on a local DB)
              ──▶ PR → CI (.github/workflows/ci.yml)
              ──▶ merge to main ──▶ GitHub push
                                      ├─▶ Vercel moco-web   builds mobile/    → lovcamx.online
                                      └─▶ Vercel moco-admin builds admin-web/ → admin.lovcamx.online
```

- Both projects use **`main`** as the production branch. Do not configure any
  other branch as production.
- Every push to `main` deploys **both** projects, even if only one side
  changed. This is cheap for admin and costs a few minutes for web.
- The backend is **not** deployed by this flow. Ship backend changes to the
  server (`git pull && npm ci && npm run migrate && pm2 reload ecosystem.config.js`)
  **before** merging any frontend change that depends on them.
- **Preview deployments:** the required env vars are set for **Production
  only**, so a preview build (any non-`main` push) fails fast. It cannot point
  at the production backend by accident. Recommended: set **Settings → Git →
  Ignored Build Step → "Only build production"** on both projects so previews
  are skipped instead of failing. To get previews later, add Preview-scoped
  env vars that point at a staging backend (`MOCO_FLAVOR=staging`).

---

## 8. Rollback

- **Fastest:** Vercel → project → Deployments → pick the last good production
  deployment → **Instant Rollback** (or *Promote to Production*). There is no
  rebuild, and it takes effect in seconds. Do it per project. Web and admin
  roll back independently.
- **Durable:** `git revert` the bad commit on `main` and push. Both projects
  redeploy from the reverted tree. Do this after an instant rollback, or the
  next push re-ships the bad code. An instant rollback also pauses automatic
  production promotion until you promote again.
- **PWA caching:** the service worker is network-first and every file is
  `no-cache`, so users get the rolled-back version on their next load. No
  cache purge is needed.
- **Backend:** Vercel rollbacks do not touch the server. Roll back backend
  code with git + `pm2 reload`, and database changes with `npm run migrate:down`
  (only if the migration is reversible).

---

## 9. Manual setup still needed in the Vercel dashboard

1. **Import the repo twice** (Add New → Project → `lovusayani/moco_app`):
   - `moco-web`: Root Directory `mobile`, Framework **Other**.
   - `moco-admin`: Root Directory `admin-web`, Framework **Other**. Keep
     "Include files outside the root directory" **enabled**.
   - Leave the build/install/output fields empty or matching the table. `vercel.json` wins.
2. **Env vars** (section 4) in each project, **Production** scope. Mark
   `MOCO_EDGE_PROXY_SECRET` **Sensitive**.
3. **Production Branch** = `main` in both (Settings → Git). It is the default.
4. **Ignored Build Step** → "Only build production" in both (recommended).
5. **Domains:** `moco-web` gets `lovcamx.online` plus `www.lovcamx.online`
   (redirect to apex). `moco-admin` gets `admin.lovcamx.online`. Then create the
   DNS records Vercel shows (section 5).
6. **Deployment Protection:** Vercel Authentication on preview URLs is
   optional. Production stays public: the admin is protected by OTP plus
   `ADMIN_PHONES` server-side.
7. **Trigger the first deploy:** Deployments → Redeploy, or push to `main`.
   Then verify:
   - `https://lovcamx.online/chat/1`: refresh loads the app (deep link).
   - `https://lovcamx.online/nope`: the app's "Page not found".
     `https://lovcamx.online/nope.js` returns 404.
   - `https://lovcamx.online/api/config` returns JSON from the backend.
   - Sign in on web. DevTools → Network shows `wss://api.lovcamx.online/socket.io/` connected.
   - `https://admin.lovcamx.online`: sign in with an `ADMIN_PHONES` number, and stats load.
   - `https://admin.lovcamx.online/api/users/me` returns 404 (only auth and admin are proxied).
   - On the server, `tail /var/log/nginx/moco-access.log` shows that `/api`
     requests from the web carry real client IPs to Node. Check with an OTP
     request: the app's rate-limit key uses `req.ip`.

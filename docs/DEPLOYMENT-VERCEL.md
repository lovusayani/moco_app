# Deploying Moco web + admin on Vercel

Two Vercel projects deploy two frontends from this one repo. Both deploy
automatically from `main`. Each project is static files plus one small
server-side **proxy function** for `/api`. The Node backend and its workers are
**not** on Vercel. They keep running on the persistent server (PM2 + nginx,
see `moco-backend/ecosystem.config.js` and `moco-backend/nginx/moco.conf`).

| | Project A: `moco-web` | Project B: `moco-admin` |
|---|---|---|
| Domain | `lovcamx.online` (+ `www` → apex) | `admin.lovcamx.online` |
| What | Flutter PWA (`mobile/`) | Admin console (`moco-backend/public/admin`) |
| Root Directory | `mobile` | `admin-web` |
| Framework Preset | Other | Other |
| Install Command | `node tool/vercel/install_flutter.mjs` | *(skipped)* |
| Build Command | `node tool/vercel/build_web.mjs` | `node build.mjs` |
| Output Directory | `build/web` | `dist` |
| Function | `mobile/api/moco-proxy.mjs` | `admin-web/api/moco-proxy.mjs` |
| Function region | `bom1` (Mumbai) | `bom1` (Mumbai) |
| Production Branch | `main` | `main` |
| Config file | [`mobile/vercel.json`](../mobile/vercel.json) | [`admin-web/vercel.json`](../admin-web/vercel.json) |

The install, build, output, region and function settings are all in each
`vercel.json`, which overrides the dashboard.

---

## 1. Architecture

```
                   ┌──────────────────── Vercel ───────────────────────┐
 browser ──HTTPS──▶│ lovcamx.online (moco-web)                         │
                   │   /, deep links → Flutter PWA files (CDN)         │
                   │   /api/*        → fn api/moco-proxy.mjs (bom1) ───┼──┐
                   │                                                   │  │ HTTPS
 browser ──HTTPS──▶│ admin.lovcamx.online (moco-admin)                 │  │ + X-Moco-Edge-Secret
                   │   /             → admin console files (CDN)       │  │ + X-Forwarded-For
                   │   /api/auth/*, /api/admin/* → fn moco-proxy ──────┼──┤
                   └───────────────────────────────────────────────────┘  ▼
 browser (PWA) ──WSS /socket.io────────────────▶ api.lovcamx.online (nginx → Node :3000)
 Android app  ──HTTPS /api + WSS /socket.io────▶   ├─ moco-api (PM2 cluster)
                                                   ├─ tick / payout / notification workers
                                                   └─ Postgres (Supabase) · Redis · Agora · Storage
```

### `/api`: a server-side proxy function

`vercel.json` has a plain rewrite: `/api/:__moco_path(.+)` → `/api/moco-proxy`.
Vercel passes the named capture to the function as `?__moco_path=<path>` and
merges in the original query string. The function (`api/moco-proxy.mjs` +
`api/_lib/moco_proxy.mjs`) forwards each request to
**`https://api.lovcamx.online/api/<path>`**. That origin is hardcoded: it is
public, and the Android app ships it too. The function:

- **preserves** the method, the exact body bytes, the query string (minus
  `__moco_path`), cookies, `Authorization` and every other end-to-end header,
  and the original path, decoded exactly once and re-encoded;
- **sets** `X-Forwarded-For` / `X-Real-IP` to the client IP Vercel reports.
  Vercel overwrites client-sent `X-Forwarded-For`, and any client-sent copies
  are dropped before forwarding;
- **injects** `X-Moco-Edge-Secret` from the runtime env var
  `MOCO_EDGE_PROXY_SECRET` (`process.env`, read per request);
- **returns** the backend's status, headers (every `Set-Cookie`) and body as
  is. Redirects are passed back, not followed. Compression is decoded once.
  `Cache-Control: no-store` is added when the backend sets none;
- **refuses** with 404 a missing or duplicated `__moco_path`, `..` segments,
  and (on admin) anything outside `auth/` and `admin/`. It returns 503 if the
  secret is missing, 502 if the backend is unreachable, and 504 after 30 s.
  Error bodies use the API's own `{ "error": { code, message } }` shape.

Nothing in `vercel.json` uses environment-variable substitution, and neither
`vercel.json` names the secret. The browser only talks to its own origin, so the
backend needs **no CORS policy**. No app, admin or backend code changed: the web
app already defaults to `<origin>/api` (`mobile/lib/core/config/env.dart`), and
the admin console uses `const API = '/api'`.

The two `_lib/moco_proxy.mjs` copies must stay byte-identical, because each
Vercel project bundles only its own root directory.
`mobile/tool/vercel/test_proxy.mjs` enforces this.

### Socket.IO goes direct to the backend

Vercel cannot carry WebSocket upgrades. The web build bakes in
`SOCKET_URL=https://api.lovcamx.online`, so the PWA opens
`wss://api.lovcamx.online/socket.io/` itself. This works cross-origin as is:
WebSocket-only transport, the token goes in the handshake (no cookies), and the
server allows any origin (`socket.server.js`). Calling is disabled on web.

### The real client IP: `MOCO_EDGE_PROXY_SECRET`

Proxied requests reach nginx from the function's IP, which many users share.
Without extra handling, the per-IP OTP limits (nginx `moco_auth_limit` 1 r/s,
and the app's `otp_req` 10 per 5 min) would lock all web users out together.
`moco-backend/nginx/moco.conf` trusts the function's `X-Forwarded-For` **only**
when `X-Moco-Edge-Secret` matches the secret in
`/etc/nginx/moco-edge-secret.conf`. It then passes a single verified client IP
to Express (which trusts one proxy hop) and strips the secret header before it
reaches Node. Anyone calling `api.lovcamx.online` directly cannot spoof an IP.

Where the secret lives: **Vercel env (Production, Sensitive)** for both
projects, and **`/etc/nginx/moco-edge-secret.conf`** on the server. It is never
in git, `vercel.json`, the static output (both build scripts fail if its value
appears there) or any response.

### Function region

The function runs in **`bom1` (Mumbai)**, next to Indian users and close to an
Indian droplet. Vercel's default, `iad1` (US East), would add a round trip to
the US on every API call. If the droplet is not in India, change `regions` in
both `vercel.json` files to the Vercel region nearest to it.

---

## 2. Project A: `moco-web` → `lovcamx.online`

**Settings:** repo `lovusayani/moco_app` · Production Branch `main` · Root
Directory `mobile` · Framework **Other** · Node.js 22.x or newer (the function
runs on the project's Node version; the local build used Node 24).

**Build:** Vercel's build image has no Flutter. `install_flutter.mjs` downloads
the **pinned** Flutter SDK (3.47.3, which matches local development). Then
`build_web.mjs` runs:

```
flutter build web --release --no-wasm-dry-run \
  --dart-define=FLAVOR=production \
  --dart-define=SOCKET_URL=https://api.lovcamx.online
```

After the build, the script checks that all PWA files are present (manifest,
`sw.js`, icons, CanvasKit), that `<base href="/">` is set, and that no
server-secret value appears in `build/web`. Downloading Flutter adds about
2–4 min per build.

**Routing (`mobile/vercel.json`)**

| Request | Result |
|---|---|
| `/api/<anything>` | proxy function → `https://api.lovcamx.online/api/<anything>` |
| an existing file (`/main.dart.js`, `/icons/…`) | served, `Cache-Control: no-cache` (Flutter output is not content-hashed) |
| `/socket.io/*`, `/admin*`, `/health`, bare `/api` | 404 |
| a missing path **with** a file extension (`/foo.png`) | 404, so a missing asset never comes back as HTML |
| any other path (`/chat/12`, `/listener/7`, `/feed`) | `index.html`. Deep links and refresh work, and GoRouter shows its own "Page not found" for unknown routes |

Every non-API response also gets `nosniff`, `Referrer-Policy:
strict-origin-when-cross-origin` and `X-Frame-Options: DENY`.
`/sw.js` gets `Service-Worker-Allowed: /`, and `/manifest.json` is served as
`application/manifest+json`. HTTPS and HSTS are automatic on Vercel domains.

## 3. Project B: `moco-admin` → `admin.lovcamx.online`

The console is the three static files in `moco-backend/public/admin`
(`index.html`, `admin.css`, `admin.js`). It has no build step and uses hash
routing (`#/users`). Express also serves them at `/admin`, but the production
nginx never exposed that path publicly, so this project is now how the console
is served. `admin-web/build.mjs` copies the files into `dist/` at build time,
so there is still only one copy in git.

**Settings:** repo `lovusayani/moco_app` · Production Branch `main` · Root
Directory `admin-web` · **"Include files outside the root directory in the
Build Step": Enabled** (default) · Framework **Other** · Node.js 22.x or newer.

**Routing (`admin-web/vercel.json`)**

| Request | Result |
|---|---|
| `/api/auth/<…>`, `/api/admin/<…>` | proxy function → `https://api.lovcamx.online/api/...` (the function re-checks the prefix) |
| any other `/api/*`, `/socket.io/*`, `/health` | 404 |
| `/admin`, `/admin/`, `/admin/index.html` | 308 → `/` |
| `/`, `/admin.css`, `/admin.js` | served, `no-cache` |
| anything else | 404 |

The headers match helmet's for `/admin` today: the same CSP (`script-src
'self'`, images and media from `'self'`, `data:` and `https://*.supabase.co` for
signed KYC/post previews), `frame-ancestors 'none'`, `X-Frame-Options: DENY`,
`nosniff`, `Referrer-Policy: no-referrer`, and `X-Robots-Tag: noindex`.

---

## 4. Environment variables

### WEB: Vercel project `moco-web`

| Name | Scope | Value | Notes |
|---|---|---|---|
| `MOCO_EDGE_PROXY_SECRET` | Production | 64 hex chars (`openssl rand -hex 32`) | **Required. Mark Sensitive.** Read only by the proxy function at runtime. The build checks it is set and that its value is not in the output. Same value as moco-admin and nginx. |
| `MOCO_FLAVOR` | — | `production` (default) | Optional. The build refuses anything else for production. |
| `MOCO_SOCKET_URL` | — | default `https://api.lovcamx.online` | Optional. Only if Socket.IO moves to another origin. |
| `FLUTTER_VERSION` | — | `3.47.3` (default) | Optional. Flutter SDK upgrade. |

No public frontend env vars are needed: the backend origin is in code.

### ADMIN: Vercel project `moco-admin`

| Name | Scope | Value | Notes |
|---|---|---|---|
| `MOCO_EDGE_PROXY_SECRET` | Production | same value as moco-web | **Required. Sensitive.** Runtime-only, read by the proxy function. |

### BACKEND PRIVATE ENV: the server only (`moco-backend/.env`), never Vercel

| Group | Variables |
|---|---|
| Runtime | `NODE_ENV=production`, `PORT=3000`, `LOG_LEVEL=info` |
| Postgres | `DATABASE_URL` (Supabase **session** pooler), `PGSSL=true`, `PG_POOL_MAX` |
| Redis | `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`, `REDIS_TLS`, `REDIS_DB` |
| Auth | `JWT_SECRET` (**required**: boot fails without it in production), `JWT_ACCESS_TTL`, `OTP_TTL`, `OTP_MAX_ATTEMPTS` |
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
payment secrets, `SMS_API_KEY`, `FCM_SERVER_KEY` or `ADMIN_PHONES`. The only
secret on Vercel is `MOCO_EDGE_PROXY_SECRET`, and it is server-side only.

---

## 5. Domains and DNS

| Host | Type | Value | Points to |
|---|---|---|---|
| `@` (apex) | A | `76.76.21.21`, or the value Vercel shows | Vercel (moco-web) |
| `www` | CNAME | `cname.vercel-dns.com` (or as Vercel shows) | Vercel (moco-web), redirect to apex |
| `admin` | CNAME | `cname.vercel-dns.com` (or as Vercel shows) | Vercel (moco-admin) |
| `api` | A | the droplet's public IPv4 | backend server, **not** Vercel |

- Use the exact values shown in each project's **Settings → Domains** panel.
- On Cloudflare: set `@`, `www` and `admin` to **DNS only**. `api` may be
  proxied, but keep WebSockets on. If it is proxied, nginx sees Cloudflare IPs
  for direct (Android/WebSocket) traffic; configure `real_ip` for Cloudflare
  first.
- `api.lovcamx.online` gets its own certificate on the server:
  `sudo certbot --nginx -d api.lovcamx.online`.
- If a CAA record exists, it must allow `letsencrypt.org`.

---

## 6. Backend dependency (before the first Vercel deploy)

1. DNS `api` → droplet. Then `sudo certbot --nginx -d api.lovcamx.online`.
2. Install the updated `moco-backend/nginx/moco.conf`.
3. Create `/etc/nginx/moco-edge-secret.conf` from the `.example` with the real
   secret. Run `chmod 600` on it, then `sudo nginx -t && sudo systemctl reload nginx`.
   nginx will not start without this file, by design.
4. Production `.env` (section 4), then `npm ci --omit=dev`, `npm run migrate`,
   and `pm2 start ecosystem.config.js && pm2 save`.
5. Check: `curl https://api.lovcamx.online/health` returns `{"ok":true,…}`.

Android release builds use the same backend:
`--dart-define=API_BASE_URL=https://api.lovcamx.online/api --dart-define=SOCKET_URL=https://api.lovcamx.online`.

---

## 7. Auto-deploy flow

```
feature branch ──▶ local checks
                     mobile:    flutter analyze · flutter test · node tool/vercel/build_web.mjs
                     proxy:     node --test tool/vercel/test_proxy.mjs   (from mobile/)
                     admin:     node admin-web/build.mjs
                     backend:   npm test on a LOCAL database only
              ──▶ PR → CI (.github/workflows/ci.yml)
              ──▶ merge to main ──▶ GitHub push
                                      ├─▶ Vercel moco-web   builds mobile/    → lovcamx.online
                                      └─▶ Vercel moco-admin builds admin-web/ → admin.lovcamx.online
```

- Both projects use **`main`** as the production branch. Do not configure any
  other branch as production.
- Every push to `main` deploys **both** projects.
- The backend is **not** deployed by this flow. Ship backend changes to the
  server first (`git pull && npm ci && npm run migrate && pm2 reload ecosystem.config.js`).
- **Preview deployments would hit the production backend:** the origin is
  hardcoded. `MOCO_EDGE_PROXY_SECRET` is Production-scoped only, so a preview
  build fails at the build step. Also set **Settings → Git → Ignored Build Step
  → "Only build production"** on both projects so previews are skipped
  instead of failing.

---

## 8. Rollback

- **Fastest:** Vercel → project → Deployments → last good production deployment →
  **Instant Rollback**. There is no rebuild. Do it per project: web and admin roll
  back independently. The proxy function rolls back with the deployment.
- **Durable:** `git revert` on `main` and push. Do this after an instant
  rollback, or the next push re-ships the bad code. An instant rollback also
  pauses automatic promotion until you promote again.
- **PWA caching:** the service worker is network-first and files are
  `no-cache`, so users get the rolled-back version on their next load.
- **Secret rotation:** add the new value as a second line in
  `moco-edge-secret.conf` and reload nginx. Then update the env var in both
  projects and redeploy them. Finally remove the old line. Env changes only
  take effect on a new deployment.
- **Backend:** Vercel rollbacks do not touch the server. Use git +
  `pm2 reload`, and `npm run migrate:down` only for reversible migrations.

---

## 9. Manual setup in the Vercel dashboard

1. **Import the repo twice** (Add New → Project → `lovusayani/moco_app`):
   - `moco-web`: Root Directory `mobile`, Framework **Other**.
   - `moco-admin`: Root Directory `admin-web`, Framework **Other**. Keep
     "Include files outside the root directory" **enabled**.
2. **Env var** `MOCO_EDGE_PROXY_SECRET` in each project: **Production**
   scope only, marked **Sensitive**, with the same value as the nginx file.
3. **Production Branch** = `main` in both (Settings → Git).
4. **Ignored Build Step** → "Only build production" in both.
5. **Node.js version** 22.x or newer in both (Settings → Build and Deployment).
6. **Domains:** `moco-web` gets `lovcamx.online` and `www.lovcamx.online`
   (redirect to apex). `moco-admin` gets `admin.lovcamx.online`. Then add the
   DNS records Vercel shows.
7. **Deploy**, by merging to `main`, then verify:
   - `https://lovcamx.online/chat/1`: refresh loads the app.
     `https://lovcamx.online/nope.js` returns 404.
   - `https://lovcamx.online/api/config` returns backend JSON. Check the
     response headers: `x-vercel-id` should show `bom1`.
   - Sign in on web (OTP). DevTools shows `wss://api.lovcamx.online/socket.io/` connected.
   - `https://admin.lovcamx.online`: admin sign-in works and stats load.
     `https://admin.lovcamx.online/api/users/me` returns 404.
   - On the server, `/var/log/nginx/moco-access.log` shows web `/api`
     requests arriving from Vercel IPs. Confirm Node sees the **client's** IP:
     temporarily log `req.ip` on `/api/config`, or check that the OTP rate
     limit is per user, not global.
   - Vercel → moco-web → Logs: no `[moco-proxy]` errors.

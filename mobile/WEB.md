# Moco on the web (PWA)

The same Flutter codebase builds as an installable, mobile-first Progressive
Web App. This document covers how to build, serve and deploy it, and exactly
which native features exist on web and which deliberately do not.

## Build

```bash
flutter build web --release --dart-define=FLAVOR=production
# development flavor (dev OTP, backend mock top-up):
flutter build web --release --dart-define=FLAVOR=development
```

Output is `build/web/`. The build is JavaScript (dart2js + CanvasKit, served
from the same origin — no Google CDN). It is **not** Wasm-compatible yet:
`flutter_secure_storage_web` 1.x uses `dart:html`, which the Wasm dry run
reports. Pass `--no-wasm-dry-run` to silence that warning.

`API_BASE_URL` / `SOCKET_URL` defines are optional on web: by default the app
talks to **its own origin** (`https://<host>/api`, Socket.IO on `<host>`).

## Run locally

```bash
flutter build web --release --dart-define=FLAVOR=development
node tool/serve_web.mjs            # http://localhost:8080, API -> localhost:3000
```

`tool/serve_web.mjs` (no dependencies) mirrors production: static files with
SPA fallback, `no-cache` revalidation, and `/api` + `/socket.io` (incl.
WebSocket upgrade) proxied to the backend. `localhost` is a secure context, so
the service worker, install prompt and session storage all work without HTTPS.
Options: `--port`, `--backend`, `--root <build dir>`.

`flutter run -d chrome` also works for development, but it serves from a
random port with no `/api` proxy — pass
`--dart-define=API_BASE_URL=... --dart-define=SOCKET_URL=...` and expect the
browser to need CORS from the backend (it has none; the deployed layout does
not need it).

## Deploy

See [`web_deploy/nginx-moco-web.conf`](web_deploy/nginx-moco-web.conf): one
nginx server block serves `build/web` at `/` and proxies `/api` and
`/socket.io` to the backend, so the PWA and API are **same-origin**.

Requirements:

- **HTTPS is mandatory.** Service workers, installability and the WebCrypto
  used by `flutter_secure_storage` on web only exist in a secure context.
  Over plain `http://<LAN-IP>` the session cannot be stored and sign-in fails.
- **Site root.** The app is built for `/` (`<base href>`); path-based routing
  and the service worker scope assume it.
- **SPA fallback.** Unknown paths must return `index.html` (`try_files`), or a
  refresh on `/chat/12` would 404.
- **No long-lived caching.** Flutter's output is not content-hashed; every file
  is served `Cache-Control: no-cache`.

## PWA pieces

| Piece | Where | Notes |
|---|---|---|
| Manifest | `web/manifest.json` | `display: standalone`, `id`/`scope`/`start_url` `/`, theme `#120A12`, any + maskable icons |
| Icons | `web/icons/`, `web/favicon.png` | **Placeholder mark** ("m" on the brand gradient) — no Moco logo exists in the repo yet; replace before launch |
| Service worker | `web/sw.js` | Network-first; precaches the app shell; never touches `/api`, `/socket.io`, `/admin` or cross-origin media |
| Loader | `web/flutter_bootstrap.js` | Registers `sw.js`, loads CanvasKit locally, removes the splash after the first frame. Flutter's own deprecated service worker is deliberately not used — it unregisters itself and would remove `sw.js` |
| Splash | `web/index.html` | Dark background + icon until the first Flutter frame, so there is no white flash |

Offline behaviour: an installed app opens its shell offline (all routes fall
back to the cached `index.html`). Data screens show their normal error states;
balances, chats and media are never served from cache.

## Routing, refresh and deep links

- Path URLs (`/discovery`, `/chat/12`, `/listener/7`) via `usePathUrlStrategy()`.
- `GoRouter.optionURLReflectsImperativeAPIs = true`, so pushed screens are in
  the address bar too and survive a refresh.
- The launch URL is captured before `runApp` (`initialLocationProvider`):
  the bootstrap screen shown while the session is restored would otherwise
  overwrite it with `/`.
- A screen opened directly by URL has nothing underneath it; its back/close
  actions go to a sensible tab instead of popping to a blank page
  (`lib/core/routing/pop_or_go.dart`).
- Signed-out deep links go to login (then Discovery), as on Android.

## Layout

Phone widths render exactly like Android. Wider than 600px (tablet/desktop),
the app is a centred 600px column over the app background (`MocoAppFrame`),
with dialogs, sheets and snackbars inside it. Mouse and trackpad can
drag-scroll (snap feed, carousels).

## Platform audit

| Feature / plugin | Web status | What the web build does |
|---|---|---|
| **Agora calling** (`agora_rtc_engine` 6.6) | **Not supported — isolated** | Agora's web target is alpha, tested by Agora on desktop browsers only, needs an external `iris-web` script, and returns -4 for APIs `AgoraCallService` uses (speakerphone routing, camera switch). Calling is off on web: call buttons explain calls are in the Android app, `CallController` refuses to initiate/accept (no listener is claimed, no billing starts), `/call/*` URLs redirect to Discovery, an incoming call shows a "answer it in the Android app" notice instead of a dead Accept button, and an approved listener cannot go **online** from web (going offline still works). The plugin still compiles into the bundle but its engine is never created. |
| **Google Play Billing** (`in_app_purchase`) | **Not used — by design** | Non-development web builds get `UnsupportedPlatformPurchaseProvider`: packs and prices are shown, purchasing is disabled with a message to buy in the Android app. The billing client is never constructed on web. (Development builds keep the backend mock top-up, which is not Play Billing.) |
| `permission_handler` | Unused on web | Only `AgoraCallService` requests permissions, and it is never reached on web. |
| `flutter_secure_storage` | Works (HTTPS only) | On web the token is AES-GCM encrypted in `localStorage` with a key also kept in `localStorage` — equivalent to `localStorage` against script on the page, not a hardware keystore. Requires a secure context. |
| `shared_preferences` | Works | `localStorage`. |
| `image_picker` | Works | Browser file chooser (`accept="image/*"`, `video/*`). Image downscale/quality is applied in the browser. No camera capture source is offered (the app only uses the gallery). |
| Uploads (chat photo, feed media) | Works | Bytes go browser → Supabase signed upload URL directly (Supabase allows cross-origin), exactly as on Android. |
| `video_player` | Works | HTML `<video>`. Feed videos start muted, which is what browser autoplay policies require. |
| `cached_network_image` | Works | Browser HTTP cache; no on-disk cache manager. |
| `socket_io_client` | Works | WebSocket transport, same-origin via the proxy. |
| `google_fonts` | Works | Inter is fetched from Google Fonts at runtime (not available offline on first launch). |
| `SystemChrome` status/nav bar styling | No-op | Status bar colour comes from `theme_color` in the manifest/`index.html`. |
| Push notifications | Not implemented | The app has no push client on any platform yet (`UsersApi.registerPushToken` exists but nothing calls it). Web Push would need its own service-worker work. |

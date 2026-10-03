# Integration — pre-QA status

Branch: `claude/integration-pre-qa` (on `upstream`, github.com/lovusayani/moco_app).
This is the single branch for Phase 8 real-device QA. It contains every
feature branch below, the listener photo/KYC app flow, and the fixes found
during emulator and browser QA. Date: 2026-10-03.

## Branch heads

`claude/integration-pre-qa` was started from `claude/admin-operations` and has
`claude/web-pwa` merged in. That merge had no conflicts. Every other feature
branch was already in the history of one of those two.

| Upstream branch | Head | In integration |
|---|---|---|
| `claude/admin-operations` | `d77213e` | base |
| `claude/admin-foundation` | `e4fa215` | yes (via admin-operations) |
| `claude/web-pwa` | `cb804ce` | yes (merge `252d42e`) |
| `claude/app-settings-listener-requirements` | `fbc9d96` | yes |
| `claude/phase8-visual-parity` | `1ffe549` | yes |
| `claude/phase7-payments-production` | `fb0939a` | yes |
| `claude/phase6-safety-notifications` | `5afc607` | yes |
| `claude/phase5-profile-account` | `ac75d53` | yes |
| `claude/phase4-feed` | `7eb124d` | yes |
| `claude/phase3-chat` | `3836fae` | yes |
| `claude/phase2-calls-wallet` | `a994188` | yes |

Commits added on top of the merge:

- `e2db5cf` Complete the listener photo and KYC flow in the app
- `67a82e4` Fix runtime issues found in emulator and browser QA
- the commit that adds this document

Things checked after the merge:

- Bottom nav order is Discovery, Wallet, Feed, Chat, Profile. Feed is in the
  centre and Chat sits beside Profile.
- The admin ledger label is correct.
- `PlatformCapabilities` turns off calling and Play Billing on web.

## Migrations

`001_init` through `010_admin_operations` are all applied on the shared
Supabase dev database. There are 10 files and 0 pending.

Nothing was renumbered, reset or truncated. This pass added no new
migrations.

## Tests

| Suite | Result |
|---|---|
| `flutter analyze` | No issues |
| `flutter test` | 346 passed |
| Backend smoke (`scripts/supabase_smoke_test.js`, non-destructive) | 184 passed, 0 failed |
| Admin console in headless Chrome: foundation | All functional checks pass |
| Admin console in headless Chrome: operations | 22/22; all 11 modules render |
| Android debug APK build | OK |
| Web release build (development flavor) | OK |

`npm test` was **not** run. It truncates tables, and `tests/guard.js` blocks it
against the shared database.

## Listener photo / KYC flow

The flow, as it works now:

- Becoming a listener (Edit profile or Profile setup) opens **Listener
  application** (`/profile/listener-application`).
- On that screen the listener adds 3–6 photos (JPEG/PNG/WebP), with upload
  progress, and can remove them.
- They then submit verification (full name, ID document link, optional UPI).
- The screen shows the review state: not submitted, under review (with the
  submitted date), approved, or rejected (with the reviewer's reason and
  resubmit).

The server decides eligibility. The app shows `blockers` from `/users/me`:

- Profile shows the online switch only when KYC is approved **and** the
  listener has at least 3 photos.
- Otherwise Profile shows the reasons and a "Complete your application"
  button.
- The backend refuses to go online for anyone else, whatever the app shows.

Profile re-reads `/users/me` when the Listening section opens, so an approval
made in the admin console shows without restarting the app.

Checked on the Android emulator (Pixel 8a), signed in as a fresh listener:

1. Became a listener and was sent to the application screen.
2. Uploaded 3 photos through the system picker. Submit stayed disabled until
   the third photo.
3. Submitted KYC → "Under review".
4. Admin rejected it → the device showed the reason, and the listener
   resubmitted.
5. Admin approved it → Profile showed "Verified listener" and the switch.
6. Went online, then offline again, and the server accepted both.

The internal approval note is never sent to the app. Only a rejection reason
is.

**Known limitation:** the ID document is a **URL field**, because that is
what the backend model accepts. There is no private document upload yet.

## Admin console

The console is at `/admin`. Access is decided on the server by `ADMIN_PHONES`.

It has 11 modules: Overview, Users, Creators, KYC, Content, Calls,
Wallet/Ledger, Payouts, Reports, Audit, System/Reconcile. Every admin write is
recorded in the append-only audit log.

Test1 content: user #11's two video posts (#2, #3) were hidden through the
normal moderation action (`remove`). That action is audited and can be
undone. The image post (#1) was left up. No audit history was touched.

## Web / PWA

Served with `node mobile/tool/serve_web.mjs`, the same layout as production
nginx. Checked in headless Chrome at 390×844:

- Sign-in with OTP works.
- Refreshing stays signed in.
- Opening `/discovery`, `/wallet`, `/feed`, `/chats`, `/profile`,
  `/listener/:id` and `/profile/listener-application` directly by URL renders
  the right screen.
- Unknown paths show "Page not found — back to Discovery".
- The manifest (standalone, 4 icons) and the service worker are served.
- **Calling is disabled.** The listener page says "Calls are available in the
  Moco Android app".
- **Listeners cannot go online from web.** Profile and the application screen
  say to go online from the Android app.
- **Play Billing is never used on web.** The production flavor has no purchase
  provider on web. The development flavor uses the backend mock top-up, which
  the backend environment gates.
- Media upload works: a photo was uploaded and then removed through the
  browser file picker.

## Notification worker

`npm run worker:notification` runs and processes the queue. All jobs complete,
including the backlog and the KYC events created during QA.

**Real push delivery is not set up.** `FCM_SERVER_KEY` is empty and no device
has registered an FCM token. Every job logs "no fcm token registered, skipping
push". In-app notifications (the bell, `/api/notifications`) work.

## Security

- `.env` is git-ignored.
- A scan for secret values found none in tracked files, git history, the web
  bundle or the APK assets. The only pattern hits are `<password>`
  placeholders in `.env.example` and `moco-backend/README.md`.
- The Flutter app and the web build contain no service-role key, database URL,
  Redis credentials or Agora certificate.
- KYC fields are returned only to admins and to the user themself. The public
  listener endpoints don't include them.
- No secret scanner (for example gitleaks) is installed. The scan was a
  scripted value and pattern check.

## Deferred integrations (not configured in dev)

| Integration | State |
|---|---|
| Agora (real call media) | `AGORA_APP_ID` / `AGORA_APP_CERTIFICATE` empty. The call lifecycle and billing run, but media shows "Media unavailable (dev mode)". |
| FCM push | Not configured (see above). |
| SMS OTP | `SMS_PROVIDER=log`, with a fixed dev code outside production. |
| Google Play Billing verification | `GOOGLE_PLAY_PACKAGE_NAME` / service account empty. Real purchases can't be verified. |
| KYC document upload | URL field only (see above). |

## Manual QA still needed (Phase 8)

- Two physical Android devices: audio and video calls with real Agora
  credentials, ringing, accept/decline, billing ticks, low-balance end,
  summary.
- Two-device chat: live delivery, reconnect, reactions, block, photo
  messages. See `mobile/README.md`.
- A real Play Billing purchase on an internal test track.
- FCM push on a real device after keys are configured.
- PWA install on a real phone (Android Chrome, iOS Safari) over HTTPS.
- Listener flow on a real camera roll, including large and HEIC photos.
- Admin console review of real content and KYC applications.

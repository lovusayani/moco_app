# Moco — Flutter client

Phase 1 foundation for the Moco mobile app. Talks to the existing Node backend
in [`../moco-backend`](../moco-backend) using the contract in
[`../docs/API.md`](../docs/API.md).

## Phase 1 scope

The real journey, end to end, against the live backend:

**Launch → Onboarding → OTP login → Profile setup → App shell → Discovery →
Listener profile**

## Phase 2 scope

Real calling and wallet, built on the existing backend billing engine — the
client never decides a rate, a balance, or when billing starts:

**Listener profile → Audio/Video call → Outgoing → Incoming (other device) →
Accept → Active call → server-driven billing/low-balance → End → Call summary**

The server remains authoritative for balance, call status, billed
minutes/ticks, listener earnings, call termination and rates; see
[`lib/core/calling/`](lib/core/calling/) and
[`lib/features/calling/`](lib/features/calling/).

Everything else in the app is deliberately out of scope and marked as such.

## Prerequisites

- Flutter **3.35+** (developed against 3.47.3, Dart 3.13 — `pubspec.yaml` pins
  `sdk: ^3.13.0`; run `flutter upgrade` if `flutter pub get` complains about the
  SDK version)
- Android SDK / Android Studio for the emulator
- The backend running locally — see [`../moco-backend/README.md`](../moco-backend/README.md)
- For real calling: an Agora project (App ID + certificate) set on the
  **backend** (`AGORA_APP_ID`/`AGORA_APP_CERTIFICATE` in `moco-backend/.env`).
  Without it the backend still runs the full call lifecycle and billing, but
  issues no real Agora token — see "Calling without Agora configured" below.

## Setup

```bash
flutter pub get
```

That is the whole setup — there is no code generation step.

### Why no freezed / json_serializable

The Phase 1 brief specified `freezed` + `json_serializable`. They were set up
and then **deliberately removed**: `build_runner` could not complete a first
build reliably in the development environment, and a client that cannot be
analyzed or tested without a fragile 15-minute build step fails the brief's own
"keep setup reproducible" requirement more seriously than hand-written models do.

The models in `lib/shared/models/` are therefore plain Dart with the same shape
codegen would have produced — immutable fields, `const` constructors, explicit
`fromJson`, `copyWith`, and value equality. The trade-off is that adding a field
means editing `fromJson` by hand.

Reinstating codegen is a contained change if `build_runner` behaves on your
machines: re-add the four dependencies, annotate the three model files, and drop
the hand-written `fromJson`/`copyWith`/`==` bodies. The CI workflow has the
generate step commented out ready for that.

## Running

Configuration is supplied with `--dart-define`; nothing environment-specific is
committed and there are no secrets in the client.

```bash
# Android emulator against a local backend.
# 10.0.2.2 is how the emulator reaches the host's localhost.
flutter run \
  --dart-define=FLAVOR=development \
  --dart-define=API_BASE_URL=http://10.0.2.2:3000/api \
  --dart-define=SOCKET_URL=http://10.0.2.2:3000

# Physical Android device on the same network (use your machine's LAN IP).
flutter run \
  --dart-define=FLAVOR=development \
  --dart-define=API_BASE_URL=http://192.168.1.10:3000/api \
  --dart-define=SOCKET_URL=http://192.168.1.10:3000

# Staging
flutter run \
  --dart-define=FLAVOR=staging \
  --dart-define=API_BASE_URL=https://staging.example.com/api \
  --dart-define=SOCKET_URL=https://staging.example.com

# Production release build
flutter build apk --release \
  --dart-define=FLAVOR=production \
  --dart-define=API_BASE_URL=https://api.example.com/api \
  --dart-define=SOCKET_URL=https://api.example.com
```

| Define | Default | Purpose |
| --- | --- | --- |
| `FLAVOR` | `development` | `development` · `staging` · `production` |
| `API_BASE_URL` | `http://10.0.2.2:3000/api` | REST base, including `/api` |
| `SOCKET_URL` | `http://10.0.2.2:3000` | Socket.IO origin (no `/api`) |
| `AGORA_APP_ID` | empty | Passed to the Agora engine's `RtcEngineContext`. The App ID is a public client identifier — only the certificate (server-side) is secret. |
| `HTTP_LOGGING` | `true` | Method/path logging; forced off in production |

`FLAVOR=production` is load-bearing, not cosmetic: it disables HTTP logging and
hides every development placeholder.

### Signing in locally

The backend's dev OTP is fixed (`OTP_FIXED_CODE`, default `123456`), so no SMS
gateway is needed. Codes are single-use and rate limited — 5 per phone per hour
— exactly as in production. The client does not bypass either rule.

### Two-device call testing

Calling needs two accounts — a caller and a listener — so use two emulators (or
one emulator plus one physical device) against the same backend.

```bash
# Device A — caller. A fresh phone number signs up as a plain user.
flutter run -d <deviceA-id> \
  --dart-define=FLAVOR=development \
  --dart-define=API_BASE_URL=http://10.0.2.2:3000/api \
  --dart-define=SOCKET_URL=http://10.0.2.2:3000

# Device B — listener. Use a second phone number, opt into listener mode from
# Profile setup, then toggle "online" (PATCH /api/listeners/status) once KYC
# shows approved — the dev seed/admin console can approve it instantly.
# A physical device on the same LAN uses your machine's IP instead of 10.0.2.2
# (see the LAN example above) for both API_BASE_URL and SOCKET_URL.
flutter run -d <deviceB-id> \
  --dart-define=FLAVOR=development \
  --dart-define=API_BASE_URL=http://192.168.1.10:3000/api \
  --dart-define=SOCKET_URL=http://192.168.1.10:3000
```

Test flow: on Device A, open a listener's profile (Device B's account) from
Discovery and tap Audio or Video. Device B should show the Incoming Call screen
within a second or two (delivered over the socket B is already connected on);
Accept moves both devices to the active call screen, where `call:tick` events
update the caller's balance and the listener's running "earned" total live.
Ending from either side ends both.

### Calling without Agora configured

If the backend has no `AGORA_APP_ID`/`AGORA_APP_CERTIFICATE`, the call
lifecycle (initiate → ring → accept → billing ticks → end) still runs for
real — only the media never connects. The active call screen shows "Media
unavailable (dev mode)" instead of pretending a connection exists, which is
enough to test the state machine, billing display and screens without a real
Agora project.

### Two-device chat testing

Same two-device setup as calling above (Device A / Device B, same
`flutter run` commands). Chat doesn't need the listener role — any two
signed-in accounts can message each other.

Test flow:
1. On **Device A**, open Device B's listener profile from Discovery and go
   to the Chats tab, or navigate directly to `/chat/<deviceB-userId>` —
   either way opens (or creates) the conversation.
2. Send a text message from A. It should appear immediately in A's thread
   (server-confirmed, not optimistic-before-response).
3. **Device B**: open the Chats tab. The conversation should already show
   the new message and an unread badge (delivered live over the socket B is
   already connected on — no manual refresh needed). Open the thread; the
   badge clears.
4. Reply from B. A's thread should show the reply live if A's thread is
   still open, or bump to the top of A's Chats list with an unread badge if
   A has navigated away.
5. **Reconnect check**: turn on Airplane Mode on Device B for ~10 seconds
   with B's thread open, send a message from A during that window, then turn
   Airplane Mode back off. B's thread should show A's message once
   reconnected (via the reconnect-refetch, not require a manual pull down)
   without duplicating any earlier messages.
6. **Reaction**: long-press a message bubble on either device, pick an
   emoji. It should appear under the bubble on both devices within a second
   or two. Tap the same emoji again to remove it.
7. **Block check**: from Device A's side, block Device B (via Listener
   Profile or the safety endpoints — there is no dedicated block button in
   Chat yet). Sending from either device afterward should show an inline
   error rather than appear to send.
8. **Photo message**: only testable once the backend has
   `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` configured and a private
   `chat-media` bucket created in that Supabase project — without them, the
   photo-attach button correctly surfaces "Photo messages are not available
   right now" rather than failing silently or faking an upload. With storage
   configured: tap the photo icon, pick an image from the gallery, confirm it
   appears in both devices' threads.

## Tests

```bash
flutter analyze
flutter test
```

### Contract check against a live backend

`test/contract/api_contract.dart` parses **real** backend responses through the
client's models. It is not part of `flutter test` because it needs a running
server; run it deliberately:

```bash
# with the backend running on :3210
dart run test/contract/api_contract.dart
```

This is what catches API drift — a rename on the server that hand-written
fixtures would happily keep passing.

## Project structure

```
lib/
├── core/
│   ├── api/         Dio client, auth/users/listeners/config/calls/chat/feed/safety
│   ├── auth/        AuthController + AuthState (the session's single owner)
│   ├── calling/      CallController (state machine), AgoraCallService
│   ├── config/      env.dart — all --dart-define reading
│   ├── media/       FeedVideoPlayback — the only video_player import
│   ├── errors/      ApiException + status → message mapping
│   ├── realtime/    Socket.IO service
│   ├── routing/     go_router config and the startup redirect
│   ├── storage/     secure token storage, local preferences
│   ├── theme/       design tokens, Material 3 overrides
│   ├── widgets/     background, glass surfaces, avatars, states
│   └── providers.dart
├── features/
│   ├── onboarding/  carousel + local completion
│   ├── auth/        phone + OTP
│   ├── profile_setup/
│   ├── app_shell/   bottom nav, Profile placeholder, global incoming-call listener
│   ├── discovery/   grid, filters, pagination
│   ├── listener_profile/  real Audio/Video CTAs
│   ├── calling/     outgoing/incoming/active audio/active video/summary screens
│   ├── chats/ + chat_thread/  conversation list and thread
│   └── feed/        snap feed, video lifecycle, post composer
├── shared/models/   plain Dart models mirroring docs/API.md
└── main.dart
```

## Architecture notes

**One shell, both roles.** Listener capability is modelled as state on the user
(`role`, `listener.kycStatus`), not as a second navigation tree. The role-switch
question is left open deliberately — nothing here assumes a caller-only app, so
resolving it later does not mean restructuring.

**One token, no refresh.** The backend issues a single long-lived JWT and
defines no refresh endpoint, so the client implements none. A 401 on an
authenticated request means the session is over: the interceptor clears the
token and routing falls back to login.

**The server is authoritative.** Rates, balances and eligibility are rendered
from API responses and never computed client-side. `constants.js` stays the
single source of truth — a hardcoded 6/12 in the client would misprice any
listener on a custom rate.

**Startup is deterministic.** One redirect function evaluates onboarding, then
authentication, then profile completeness. While the stored session is being
verified the app holds on a neutral loading surface rather than flashing through
login on its way to Discovery.

## API gaps — status after Phase 1.1

Most of the Phase 1 gaps are now closed with real backend support.

### Closed

| Was | Now |
| --- | --- |
| Discovery search filtered the loaded page client-side | **Real `q` parameter**, searched server-side over display name and bio, composing with filters and pagination. Debounced 350ms client-side. |
| Callers/Video toggle only changed the displayed rate | **Real `callType` filter**, backed by `accepts_audio` / `accepts_video`. The toggle refetches. |
| Verified badge was hardcoded `true` | **Published `verified` boolean.** KYC status itself is still never sent to clients. |
| Favourite / Follow were disabled | **Real, idempotent, backend-persisted.** Optimistic in the UI with full rollback on failure. |
| `listener:presence` declared but never emitted | **Emitted** on the listener's online toggle and on socket disconnect, broadcast to all clients. Discovery updates in place. |
| `PATCH /users/me` returned snake_case | **Canonical camelCase**, identical to `GET`. The client's extra re-read is gone. |

### Still open

| Design feature | Backend status | What the client does |
| --- | --- | --- |
| Listener age | Not exposed | Omitted. |
| Similar listeners | No similarity endpoint | Client-side heuristic over real discovery data: same primary language, self excluded. |
| Shots / Posts / Photos / Voice | No content endpoints | Tabs render honest empty states. Deliberately out of scope for Phase 1.1. |
| Profile interests / preferences | `PATCH /users/me` accepts only `displayName`, `avatarUrl`, `language`, `gender` | Only the supported fields are collected. |

### Known scale note

Discovery search uses unanchored `ILIKE`, which cannot use a btree index. It is
scoped to KYC-approved listeners so it is fine at current volume; a `pg_trgm`
GIN index on `(display_name, bio)` is the scale-up path, and the query carries a
comment saying so.

## Phase 2 status

Complete: calling (audio + video) with realtime billing display, the low-
balance banner's "Add coins" action, the Wallet tab (real balance, real
backend-published coin packs, recent ledger activity), and app
background/foreground + socket-reconnect reconciliation (`GET /calls/:id`,
so a missed `call:ended`/`call:forced_end` while backgrounded cannot leave
the UI stuck showing a call as live). All against the real backend — see the
scope line above.

Real-money purchase is intentionally not implemented: `PurchaseProvider`
(`core/payments/purchase_provider.dart`) is the interface the wallet screen
purchases through, with a `MockPurchaseProvider` that exercises the real
topup → webhook → credited-balance path for local testing only (gated by
`Env.isDevelopment` client-side and by the backend's `PAYMENT_PROVIDER=mock`
non-production check server-side — a release build never shows the option,
and the server refuses the request regardless of what a client sends).
Google Play Billing is documented as the production path at that same
interface but needs Play Console credentials this project doesn't have yet.

Chat, Feed, Posts/Shots/Voice, payouts — unchanged, still out of scope for
this phase.

Listener profile content tabs (Shots/Posts/Photos/Voice) have no backend and
show empty states; media upload is explicitly not part of this phase.

The Socket.IO service connects after auth and tears down on sign-out. It now
subscribes to the full call event surface (`call:incoming`, `call:accepted`,
`call:tick`, `call:low_balance`, `call:forced_end`, `call:ended`,
`listener:presence`) via `CallController`, which lives for the app's lifetime
so an incoming call is caught regardless of which screen is open.

## Phase 3 status

Complete: the Chats list and Chat Thread, both against the real backend —
send/receive text, realtime delivery and unread badges (`chat:message`),
reactions (`chat:reaction`, a new backend feature this phase added), and a
photo-message path (upload-authorize → direct-to-storage PUT → send). Block
is enforced server-side exactly as before; the client only surfaces the 403
honestly. Reconnect handling merges by message id everywhere (history pages,
live events, and the reconnect refetch), so a dropped-and-restored socket
cannot duplicate a message.

Photo messages need the backend's `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`
configured against a private `chat-media` bucket — without them the
photo-attach button reports itself unavailable rather than failing silently.
This is the one part of Phase 3 not yet exercised against a real bucket; see
the backend README's Supabase Storage section.

Chats sits inside the tab shell; Chat Thread is a full-screen route outside
it (same pattern as Listener Profile and the call screens), so the Chats
list stays mounted — and keeps receiving `chat:message` live — underneath an
open thread.

## Phase 4 status

Complete: the Feed — a vertical, full-screen, snapping page view of image and
short-video posts, plus the composer that publishes them.

**Feed → post (image or video) → author → existing listener profile**, and
**Compose → pick media → optional caption → upload → publish**.

Pagination is keyset, on the same post id the server orders by, so publishing
mid-scroll cannot make a page skip or repeat a post. The controller also
merges by id, so a duplicate could not survive even if one arrived.

**Video lifecycle** is the part most worth understanding, and it is driven by
exactly two facts the feed screen owns — which page is current, and whether
the app is in the foreground. Their `&&` is handed to one item as `isActive`,
so "only the visible video plays" and "background pauses playback" are one
rule rather than two mechanisms that can drift apart. An inactive item holds
**no controller at all** rather than a paused one: on a mid-range Android
device the decoder ceiling matters more than the swipe latency that costs.
Audio starts muted with a visible toggle — a tab switch that suddenly plays
sound out loud, in an app whose purpose is paid voice calls, is the wrong
default.

`video_player` is imported in exactly one file
([`lib/core/media/feed_video_playback.dart`](lib/core/media/feed_video_playback.dart)).
Every platform call it makes is unavailable in a widget test, so without that
seam the lifecycle rules could only be checked on a device; behind it they are
ordinary tests (see `test/widget/feed_video_test.dart`).

**Media never passes through the Moco API.** The client asks the backend to
authorize an upload, PUTs the bytes straight to Supabase Storage with the
signed URL it gets back, and only then asks the backend to record the post.
The upload uses its own Dio client rather than the app's `ApiClient`, because
the signed URL points at a third-party host and carries its own one-time
token — sending the Moco session token there would leak it. A post exists only
when all three steps succeed; a failure at any step keeps the chosen media so
Retry is one tap.

Posting needs the backend's `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` and a
private `feed-media` bucket. Without them the compose flow reports itself
unavailable rather than faking an upload, and the feed itself still works —
a post whose signed URL could not be minted renders a media error state
instead of vanishing or breaking the page.

Tapping an author opens the **existing** `/listener/:id` route; no second
profile screen was built. A non-listener author has no profile screen at all,
so the server publishes `author.isListener` and the name renders as plain text
rather than as a control that goes nowhere.

Report and block go to the existing `/api/safety` endpoints — the same system
discovery and chat already rely on. This is the first Flutter client for them;
the safety model itself is unchanged and there is no second block list.

**Deliberately not built** (no approved design and no backend support — they
were not invented here): likes, comments, shares, follower-only feeds, and any
kind of ranking or recommendation. Feed ordering is newest-first, full stop.
The Feed also needs no realtime, so it opens no socket subscription — pull to
refresh and pagination are the whole update model.

### Feed manual QA (needs a real device)

The tests cover the lifecycle rules against a fake player; they cannot cover
decoding, and no phase has yet been verified on real hardware.

1. Configure the backend's Supabase Storage and create the private
   `feed-media` bucket (backend README), then restart the API.
2. Compose → choose a photo → caption → Publish. It should appear at the top
   of the feed immediately.
3. Compose → choose a video over 60s. The picker should refuse to hand back
   more than 60 seconds.
4. Compose → start a large upload → background the app → return. The progress
   bar must reflect the real transfer, not a fake animation.
5. Scroll a feed containing several videos: exactly one should have audio
   available at a time, and scrolling away must stop the previous one.
6. Background the app while a video plays. Audio must stop immediately, not
   continue behind the launcher.
7. Scroll ~30 posts and watch memory. Controllers must not accumulate.
8. Receive a call while the feed is open — the incoming-call screen must take
   over and feed audio must not play under it.
9. Block an author from a post, then refresh: none of their posts should
   return.

## Phase 5 status

Complete: Own Profile, editing, the role switch, listener availability,
earnings, and both ledgers (coin + earnings), plus account settings and
account deletion.

The role switch (`lib/features/profile/profile_controller.dart`'s
`ActiveRoleController`) is **purely local display state** — the backend has
no "active mode" concept, since a `both`-role account can always do both.
Switching never calls the server; it only changes which sections of the one
Profile screen render, matching the product rule of one account and one
shell.

Gender has no backend lock (`PATCH /users/me` accepts a change
unconditionally at any time), so none was invented client-side either — a
widget test changes it away and back in one session to prove the point.

Account deletion is the existing backend soft-delete (personal fields
cleared, phone scrambled, financial history retained) with a confirmation
dialog naming exactly that, then the same session-clearing path an ordinary
sign-out uses.

## Phase 6 status

Complete: the Notifications inbox (reached from a bell on Discovery — the
five bottom-nav tabs are fixed) and report/block wired into the two surfaces
that previously had no safety control at all: Listener Profile and Chat
Thread. The Feed's own report/block (Phase 4) is unchanged.

Notifications are a new, small backend subsystem (no in-app inbox existed
before — only fire-and-forget FCM push) — see the backend README. Nothing
about the block/report model itself changed: every surface (Discovery, chat
send, call initiation, the feed) already enforced the same `blocks` table in
both directions before this phase, and still does.

## Phase 7 status

Complete: the full Google Play Billing **architecture** — client purchase
flow, backend verification, idempotent credit, purchase history — built and
tested against a mock verifier throughout.

**Not live-verified.** This environment has no Play Console app listing, no
service account, and no signed release build, so:
- The real platform channel (`package:in_app_purchase` talking to Play
  Billing on a device) has never run.
- The real HTTP call from `src/integrations/google_play.js` to Google's Play
  Developer API has never run.

Everything else has: the purchase state machine (11 cases against a fake
billing client), the backend's credit/idempotency logic (against a fake
verifier, in both `tests/purchases.test.js` and `npm run smoke`), and the
mutual-exclusion boundary between the mock provider (development only) and
Google Play Billing (everywhere else).

**To complete Phase 7 for real**, someone with Play Console access needs to:
1. Create the app listing and enable **Financial data** access for a service
   account (Setup → API access), matching the backend README's Google Play
   Billing section.
2. Create one in-app product per coin pack with the product id set to the
   pack id exactly (`pack_49`, `pack_99`, …).
3. Set `GOOGLE_PLAY_PACKAGE_NAME` / `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` on the
   backend.
4. Build a signed release (or internal testing track) APK/AAB and run a real
   test purchase against it — see the Payments section of the QA matrix
   below.

## Phase 8 readiness — real-device QA matrix

No phase has been verified on real hardware yet. Everything below is a
PASS/FAIL checklist for two Android devices (one caller, one listener, unless
noted). Run through it top to bottom; note the device/Android version used.

### Auth
- [ ] Onboarding carousel completes and does not reappear after reinstall-free restart
- [ ] OTP request → real SMS arrives (production `SMS_PROVIDER`) or the dev fixed code works
- [ ] Wrong OTP is rejected with a clear message; correct one signs in
- [ ] Profile setup: name validation, language, gender, optional listener application
- [ ] App resume after being backgrounded overnight still shows a valid session

### Discovery
- [ ] Grid loads real listeners; pull-to-refresh works
- [ ] Search reaches the backend (not just a local filter)
- [ ] Language/gender/online filters change results
- [ ] Follow/favorite persists across app restart
- [ ] The notifications bell badge reflects real unread state and clears after opening

### Listener Profile
- [ ] Real bio/languages/rating render; verified badge only for approved listeners
- [ ] Report and Block (new in Phase 6) both reach the backend and show a result
- [ ] A blocked listener's profile can no longer be reached from anywhere in the app

### Calls
- [ ] Audio call: outgoing → the OTHER device rings → accept → both sides connect
- [ ] Video call: camera/mic both work both directions
- [ ] Reject on the listener device ends the outgoing screen honestly
- [ ] Caller cancels before accept — no charge, no stuck ring
- [ ] A fresh account's first call crosses 60 seconds and visibly switches from free trial to billed
- [ ] Billed minutes and balance shown match `GET /wallet` afterward
- [ ] Low-balance overlay appears before the balance actually can't afford another minute
- [ ] Forced end when balance hits zero mid-call — both sides see it end
- [ ] Kill and reopen the app mid-call — call state reconciles correctly (not stuck "active")
- [ ] Backgrounding one device mid-call and returning doesn't drop or duplicate billing

### Chat
- [ ] Text messages arrive on the other device in real time (Socket.IO, not polling)
- [ ] Unread badge on Chats list updates live and clears on opening the thread
- [ ] Kill the socket (airplane mode toggle) and restore — no duplicated messages
- [ ] Reactions appear live on the other device
- [ ] Photo message: pick → upload progress → both sides see the image (needs `chat-media` bucket)
- [ ] Report/Block (new in Phase 6) from the thread header work and a blocked send is refused

### Feed
- [ ] Image and video posts render; only the on-screen video has audio
- [ ] Scrolling past a video releases its player (watch memory over ~30 posts)
- [ ] Backgrounding the app while a video plays stops its audio immediately
- [ ] Create an image post: pick → optional caption → publish → appears at the top
- [ ] Create a video post (≤60s) the same way
- [ ] Tapping a listener author opens their real profile; a non-listener author is not a link
- [ ] Blocking a feed author (via the post's "more" menu) removes their posts on next refresh

### Profile (new in Phase 5)
- [ ] Edit name/language/gender persists and survives app restart
- [ ] Role switch (Calling/Listening) shows/hides the right sections instantly, no network call
- [ ] Listener availability toggle actually changes Discovery visibility on the OTHER device
- [ ] Earnings figures match the admin console / database after a real billed call
- [ ] Coin ledger and earnings ledger both paginate (scroll to the bottom, more loads)
- [ ] Account deletion: confirm → signed out → the account cannot sign back in and shows as deleted server-side

### Notifications (new in Phase 6)
- [ ] A real KYC approval/rejection (via the admin console) produces a notification
- [ ] A real payout approval/rejection/paid transition produces a notification
- [ ] Swipe-to-delete removes a notification; "Mark all read" clears the badge
- [ ] Tapping a KYC notification opens Profile; tapping a payout notification opens the earnings ledger

### Payments (new in Phase 7)
- [ ] **Development build only:** the mock top-up path still works end to end
- [ ] **Only if Play Console credentials exist:** a real Google Play test purchase
      completes, credits the correct coin amount, and appears in purchase history
- [ ] **Only if Play Console credentials exist:** the SAME purchase token replayed
      (e.g. by force-closing mid-flow and reopening) does not double-credit
- [ ] A release build never shows the development top-up option

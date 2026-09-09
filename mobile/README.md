# Moco — Flutter client

Phase 1 foundation for the Moco mobile app. Talks to the existing Node backend
in [`../moco-backend`](../moco-backend) using the contract in
[`../docs/API.md`](../docs/API.md).

## Phase 1 scope

The real journey, end to end, against the live backend:

**Launch → Onboarding → OTP login → Profile setup → App shell → Discovery →
Listener profile**

Everything else in the app is deliberately out of scope and marked as such.

## Prerequisites

- Flutter **3.27+** (developed against 3.47.2, Dart 3.13)
- Android SDK / Android Studio for the emulator
- The backend running locally — see [`../moco-backend/README.md`](../moco-backend/README.md)

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
| `AGORA_APP_ID` | empty | Not used until calling ships in Phase 2 |
| `HTTP_LOGGING` | `true` | Method/path logging; forced off in production |

`FLAVOR=production` is load-bearing, not cosmetic: it disables HTTP logging and
hides every development placeholder.

### Signing in locally

The backend's dev OTP is fixed (`OTP_FIXED_CODE`, default `123456`), so no SMS
gateway is needed. Codes are single-use and rate limited — 5 per phone per hour
— exactly as in production. The client does not bypass either rule.

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
│   ├── api/         Dio client, auth/users/listeners/config endpoints
│   ├── auth/        AuthController + AuthState (the session's single owner)
│   ├── config/      env.dart — all --dart-define reading
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
│   ├── app_shell/   bottom nav, placeholder tabs
│   ├── discovery/   grid, filters, pagination
│   └── listener_profile/
├── shared/models/   freezed models mirroring docs/API.md
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

## API gaps found during Phase 1

Design features with no backend support. None are faked client-side.

| Design feature | Backend status | What the client does |
| --- | --- | --- |
| Discovery search | `GET /listeners` has no search param | Filters the **already-loaded page** client-side. Labelled "Search loaded listeners", not presented as a full search. |
| Callers/Video toggle | No per-listener capability flag; every listener has both rates | Switches which **rate is displayed**. It is not a filter. |
| Verified badge | No `verified` field | Discovery only ever returns KYC-approved listeners, so every visible listener is verified by construction. Badge shown on that basis. |
| Listener age | Not exposed | Omitted. |
| Favourite / Follow | No endpoints | Buttons visible but **disabled** with a tooltip. Nothing is stored locally to fake a like. |
| Similar listeners | No similarity endpoint | Client-side heuristic over real discovery data: same primary language, self excluded. |
| Shots / Posts / Photos / Voice | No content endpoints | Tabs render an honest empty state. |
| Profile interests / preferences | `PATCH /users/me` accepts only `displayName`, `avatarUrl`, `language`, `gender` | Only the supported fields are collected. |
| Live presence | `listener:presence` is declared in `constants.js` but **never emitted** | Online state comes from the HTTP response. Pull-to-refresh updates it; there is no live stream to subscribe to. |
| `PATCH /users/me` response shape | Returns snake_case (`display_name`) while `GET /users/me` returns camelCase (`displayName`) | Client re-reads `GET /users/me` after a patch rather than parsing two shapes for one resource. **No backend change was made.** |

## Phase 2+ placeholders

Tabs that exist so the bottom nav matches the design, each showing an explicit
development placeholder rather than invented feature UI:

- **Wallet** — Phase 2
- **Profile** — Phase 2
- **Chats** — Phase 3 (backend endpoints exist; no UI yet)
- **Feed** — later phase (no backend at all)

Call CTAs on the listener profile are real UI showing the real backend rate, but
the calling stack is not built. Outside production they surface "Calling arrives
in Phase 2"; in production they are simply disabled. **No fake call connection
is ever attempted.**

The Socket.IO service connects after auth and tears down on sign-out, but
subscribes to no events yet — see the presence row in the gaps table.

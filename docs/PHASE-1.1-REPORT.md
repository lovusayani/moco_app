# Phase 1.1 — Validation and Integration Hardening

Branch: `claude/project-build-planning-p46mj8`
Range: `0508f9b..ec80e49` (9 commits)
Scope: close the gaps between the Flutter client and the backend before calling is built. No Agora, no Wallet/Chats/Feed/Notifications/account screens, no billing-architecture change.

---

## 1. Runtime validation result

**No emulator or physical device was used. None was available.**

`flutter devices` in this container reports only the Linux desktop target — there is no Android SDK, no AVD, and no attached device. `libgtk-3-dev` was installed but no desktop target was built, so **the app has never been launched as a running application in this environment**. Production readiness is therefore not claimed.

What was done instead, because "it compiles" is not validation:

- **Layout validation under real constraints.** `mobile/test/widget/layout_test.dart` pumps five screens (Onboarding, Login, Profile Setup, Discovery, Listener Profile) at **360×800, 390×844 and 430×932** logical pixels and fails on any `RenderFlex` overflow, via an `expectNoOverflow()` helper that captures `FlutterError.onError`. 360 is the budget-Android floor and the tightest case; 390 and 430 are current iPhone sizes.
- **Live contract validation against a real server.** `mobile/test/contract/api_contract.dart` runs **25 checks** against a booted backend (port 3210, database `moco_e2e`, real Postgres + Redis), parsing genuine responses through the client's own models. **25/25 pass.** This is what catches a server-side field rename; hand-written fixtures would not.

### Bugs this actually found

The layout pass found **three real overflows** that reading the code did not:

| Screen | Bug | Fix |
|---|---|---|
| Discovery card | Rating row overflowed 15px at 360 | `MainAxisAlignment.spaceBetween` + `Flexible` |
| Listener Profile | Hero stats overflowed once follower counts reached 4 digits | Flexible stat cells |
| Shared buttons | Labels carrying a rate overflowed | Labels wrapped in `Flexible` with ellipsis |

It also found a bug **in the tests themselves**, which is the more important finding: a second `discover()` stub declared with `limit: any(named:)` shadowed the discovery stub — mocktail applies default named arguments — so every discovery layout assertion had been passing **against an empty grid**. Scoping that stub to `limit: 10` made the coverage real, and the 360px card overflow surfaced immediately. Coverage that passes for the wrong reason is worse than no coverage; it is worth stating plainly that this existed.

---

## 2. Database migration changes

One new migration: `moco-backend/src/db/migrations/003_discovery_and_relations.sql`.

- `listener_profiles` gains `accepts_audio` and `accepts_video` (`BOOLEAN NOT NULL DEFAULT TRUE`), with a table constraint `listener_accepts_a_call_type CHECK (accepts_audio OR accepts_video)` — a listener who accepts neither call type is not a representable state.
- New enum `listener_relation_kind` (`'favorite' | 'follow'`).
- New table `listener_relations (user_id, listener_id, kind)`, primary key on all three so a relation is idempotent by construction, `ON DELETE CASCADE` on both user references, and `CHECK (user_id <> listener_id)` so nobody can follow themselves.

No change to the billing schema, the append-only ledger trigger, or the `CHECK (coin_balance >= 0)` / `UNIQUE(call_id, minute_index)` guards.

---

## 3. API changes

Documented in `docs/API.md`.

- **`GET /listeners`** — real server-side search (`q`, ILIKE over `display_name` and `bio`), capability filter (`callType=audio|video` against the new columns), `verified` in the projection, and per-caller relation state (`isFavorited`, `isFollowing`) as correlated subqueries so the client never has to reconcile two lists.
- **`PUT /listeners/:id/:kind`** and **`DELETE /listeners/:id/:kind`** — set/clear a favourite or follow. `ON CONFLICT DO NOTHING` makes the write idempotent, so a retry after a dropped response is safe.
- **`PATCH /users/me`** — now re-reads through the same `USER_SELECT`/`USER_JOINS` projection as `GET /users/me` and returns the identical canonical camelCase shape. Previously it returned raw snake_case wrapped in `{user: ...}`, which forced the client into a GET-after-PATCH round trip. That workaround is now deleted rather than papered over.
- **Presence over the existing Socket.IO/Redis bridge** — sockets join a `discovery` room; `listener.presence` is published on connect and on disconnect for online listeners. Announcement is best-effort (wrapped in try/catch): presence is a nicety and must never be able to fail a login. `presence.setOnline` now returns `is_busy` and lazily requires `call.events` to break a require cycle.

Rates, coin packs and balances remain server-authoritative. Nothing added here lets the client assert a rate or a balance.

---

## 4. Flutter changes

- `shared/models/listener.dart` — `acceptsAudio`, `acceptsVideo`, `verified`, `withPresence()`; detail model gains `isFavorited`, `isFollowing`, `followerCount`.
- `core/api/listeners_api.dart` — `DiscoveryFilters` rewritten around `query`/`callType` with `hasQuery`, `clearQuery`, `clearCallType`; new `setRelation()` returning a `RelationResult`.
- `core/api/users_api.dart` — `updateProfile` parses the PATCH response directly; the GET re-read is gone.
- `core/utils/ws_events.dart` (new) — mirrors the backend `WS_EVENTS` names in one place instead of scattering string literals.
- `features/discovery/discovery_controller.dart` — 350ms debounce on search, a `_requestId` guard so a slow earlier response cannot overwrite a newer one, and `applyPresence({listenerId, isOnline, isBusy})` so a presence event updates one card in place with no refetch.
- `features/listener_profile/listener_profile_controller.dart` — `ListenerRelationsController` does an optimistic update with **full rollback on failure**, and holds a `_pending` set so a double-tap cannot fire two writes.
- Layout fixes listed in §1.

Design note carried forward: freezed / json_serializable / build_runner remain removed (build_runner stalled indefinitely at ~2% CPU); models are hand-written plain Dart. This is documented in `mobile/README.md` and in CI so it is a decision, not a drift.

---

## 5. Test results

| Suite | Result |
|---|---|
| Backend (`node --test`) | **88 / 88 pass**, 0 fail |
| Flutter `analyze` | **No issues found** |
| Flutter `test` | **86 / 86 pass** |
| Live API contract (real server) | **25 / 25 pass** |

New backend tests this phase: `discovery.test.js` (10), `relations.test.js` (12), `presence.test.js` (5), plus additions to `api.test.js`.

One test was rewritten after I got it wrong: my first relations-cascade test asserted that hard-deleting a user removes their relations. Hard-deleting a user who has ledger rows is blocked by the append-only trigger **by design**, and the app soft-deletes. It is now two tests asserting both real behaviours instead of one asserting a behaviour the system correctly refuses to have.

---

## 6. CI status — still blocked, and not by this code

CI is **red, and has never executed a single step.**

| Run | SHA | Event | Duration | Steps run |
|---|---|---|---|---|
| 5 | `ec80e49` | pull_request | ~4s | 0 |
| 4 | `3af4ac8` | pull_request | ~4s | 0 |
| 3 | `0508f9b` | push | ~3s | 0 |
| 2 | `0508f9b` | pull_request | ~3s | 0 |
| 1 | `0508f9b` | push | ~4s | 0 |

Every run dies in 2–4 seconds with zero steps and empty output, and log download returns 404. These are the first Actions runs ever in this repository. That signature is a **repository/account-level block — Actions disabled, or a billing/spending limit — not a workflow or code defect.** Re-running will not change it. This is posted on [PR #1](https://github.com/lovusayani/moco_app/pull/1).

The one CI change made this phase **is verified working**: the workflow previously fired on both `push` (all branches) and `pull_request`, so PR branches ran twice for the same commit (runs 1 and 2 above — same SHA, same second). Push now covers `main` only. Runs 4 and 5 each fired exactly once. The fix is confirmed by observation, not assumption.

**Action required from you:** GitHub → repo Settings → Actions → General (and account billing). Nothing in the codebase can unblock this.

---

## 7. Remaining known gaps

1. **No emulator/device run, ever.** The single largest gap. Layout is validated by widget tests at three widths, not by a human looking at a screen. Real-device validation is still owed.
2. **CI has never run.** Every number in §5 was produced locally in this container. Until Actions is unblocked there is no independent verification.
3. **Discovery search uses `ILIKE`.** Correct, and fine at current scale; it will not hold as the listener table grows. A trigram or full-text index is the follow-up. Noted in `mobile/README.md` rather than left to be discovered under load.
4. **Media is honestly empty.** Shots, Posts, Photos and Voice have no upload path or backend support — deliberately out of scope for this phase. The screens show honest empty states; they do not fake content.
5. **Stray `probe-ci-fix` branch.** I created this while diagnosing the push credential failure and could not delete it: the git delete refspec returns "Everything up-to-date" from this container and no branch-delete tool is available. **This is my mistake and needs manual deletion** — it currently carries run 3 above.
6. **Not built, by instruction:** Agora calling, Wallet, Chats, Feed, Notifications, account screens.

---

## 8. Commit SHAs

| SHA | Subject |
|---|---|
| `3af4ac8f52bf89dcc1781aca45e2e1a64931a5fa` | Stop CI running twice on every PR push |
| `fa4271b325b842e841e2e6102607674e4ce8c9e2` | Make PATCH /users/me return the canonical user shape |
| `44e07d9aa2c79bc8f150111695ce84ddb6f89b7e` | Add real discovery search, capability filtering and listener relations |
| `b3a8a54d3f1f34988f678977aebddaf07fdfd245` | Emit listener presence over the existing Socket.IO Redis bridge |
| `9b37652ce62286fc19a400e23272ea5432e578d5` | Document the Phase 1.1 API changes |
| `f35c00a9f08009fe8a1f42201e5f4841038adff9` | Consume the Phase 1.1 API surface in the client |
| `dd9f71e8d78ca0bebc5894afd2e4e13bd54ec069` | Make discovery search, filtering and presence real |
| `c5843e0121673d8696b8249b4f3053d264a6f3ba` | Persist favourite and follow, with rollback on failure |
| `ec80e498158ab2535514b12d4c594b06688cf55a` | Add layout tests at 360/390/430 and update client docs |

Diff across the phase: 29 files, +2254 / −225.

---

Phase 1.1 ends here. Phase 2 (Agora calling) has not been started.

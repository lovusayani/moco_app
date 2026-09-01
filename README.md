# Moco

Per-minute paid social calling app for the Indian market. Users buy coins and
pay to call; listeners take calls and earn a share of the coin spend. Both roles
live in a single Flutter codebase.

**SPRS INFOTECH**

## Repository layout

| Path | Contents | Status |
| --- | --- | --- |
| [`moco-backend/`](moco-backend/) | Node.js API, billing engine, workers | Built |
| [`moco-backend/public/admin/`](moco-backend/public/admin/) | Admin console, served at `/admin` | Built |
| [`docs/API.md`](docs/API.md) | Full API and WebSocket contract | Built |
| `moco-app/` | Flutter client (GetX) | Not started |

## The economy

1 coin = ₹1. Billing is full-minute — the started minute is billed in full.

| | Caller pays | Listener earns | Platform keeps |
| --- | --- | --- | --- |
| Audio | 6 coins/min | ₹2/min | ₹4/min |
| Video | 12 coins/min | ₹4/min | ₹8/min |

New users get 60 free seconds on their first call only. Coin packs: ₹49, ₹99
(+5 bonus), ₹299 (+25), ₹599 (+75), ₹999 (+150).

Every rate lives in
[`moco-backend/src/utils/constants.js`](moco-backend/src/utils/constants.js) and
nowhere else.

## Stack

Flutter + GetX · Node.js · PostgreSQL · Redis · Agora (audio/video) ·
BullMQ · DigitalOcean droplet with PM2 and nginx.

## Getting started

See [`moco-backend/README.md`](moco-backend/README.md) for local setup, how the
billing engine's guarantees work, and the DigitalOcean deployment steps.

```bash
cd moco-backend
cp .env.example .env
docker compose up -d
npm install && npm run migrate && npm run seed
npm start
```

## Status

**Backend — built and tested.** Auth, users, wallet, discovery, call lifecycle,
billing engine, chat, payouts, safety and admin. 58 tests run against real
Postgres and Redis, covering concurrent billing, replayed payments and
overdraft prevention.

**Admin console — built.** KYC approvals, withdrawals, reports, live stats and
the wallet-vs-ledger reconciliation check, served by the API at `/admin`.

**Design (Claude Design).** Batch 1 (onboarding & discovery) complete. Batches
2–4 — calling & wallet, listener mode & chat, safety & system states — still to
be built.

**Flutter client.** Not started; waiting on the remaining design batches.

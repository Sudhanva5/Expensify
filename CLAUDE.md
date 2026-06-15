# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal expense tracker for a single user. Three deployable units in one repo:

- **Node/TypeScript backend** (`src/`) deployed to Railway as a Fastify server. Ingests HDFC transaction emails + merchant receipts via Gmail → Pub/Sub, categorizes them, persists to Postgres, sends APNs pushes.
- **SwiftUI iOS app** (`Expensify/`) talks to the backend over HTTPS through a Cloudflare Worker reverse proxy (`cloudflare-worker/`). Round-trips GPS via silent APNs pushes.
- **MCP server** (`src/mcp/`) deployed as a second Railway service. Read-only Streamable HTTP MCP that exposes the Postgres data to Claude (Desktop / Code / web) over a single bearer-authed endpoint. See `src/mcp/README.md`.

Database is PostgreSQL on Railway, accessed exclusively through Prisma. There's no Groq / Brave Search despite the older spec mentioning them — the categorization stack that actually ships is alias-table + VPA-shape + user rules + Google Places. See "Categorization tier chain" below.

## Common commands

```bash
# Dev loop
npm run typecheck                                  # tsc --noEmit, run before commits
npm run test:run                                   # vitest, one-shot
npx vitest run test/parsers/hdfc.test.ts           # single test file
npm start                                          # tsx src/server.ts (local)
PORT=3001 MCP_TOKEN=dev npm run start:mcp          # local MCP server, separate process from npm start

# Database (DATABASE_URL in .env points at Railway prod; local Postgres is unused now)
npm run db:migrate                                 # prisma migrate dev — generates + applies a new migration when schema.prisma changes
npm run db:migrate:deploy                          # prisma migrate deploy — applies pending migrations without prompts (used by Railway start.sh)
npm run db:seed                                    # idempotent: categories, ROUTING_PREFIXES, alias rows
npm run db:reset                                   # nuke + re-migrate + re-seed (DESTRUCTIVE on whatever DATABASE_URL points at)
npx prisma studio                                  # GUI on the linked DB

# Gmail OAuth + watch (rare; needed when refresh token expires or scopes change)
npx tsx scripts/gmail-auth.ts                      # one-time browser OAuth dance, writes refresh token to GmailOauth row
npx tsx scripts/gmail-watch.ts                     # registers Gmail push notification subscription; expires every 7 days, in-process cron refreshes automatically

# Recovery / backfill (all take Prisma-shaped DATABASE_URL, ALL hit whatever DB is configured)
npx tsx scripts/replay-gmail-history.ts            # replays missed Gmail history from last saved historyId — use after outages / Pub/Sub drops
npx tsx scripts/replay-gmail-history.ts --from N   # replay from an explicit historyId
GOOGLE_PLACES_API_KEY=... npx tsx scripts/refresh-places-by-vpa.ts --all      # re-queries Places (currently 30m strict radius) for every tx with GPS, persists top-5 suggestions
npx tsx scripts/google-contacts-sync.ts            # rebuilds GoogleContact cache via People API
npx tsx scripts/unbind-mismatched-receipts.ts      # sweeps EmailReceipt rows; unbinds any where source/merchant alignment fails or the tx is a P2P VPA
npx tsx scripts/backfill-rules.ts                  # walks every tx with GPS, applies enabled user rules at auto-tag confidence (dry-run unless --apply)

# Cloudflare Worker reverse proxy (deploys independently from the backend)
cd cloudflare-worker && npx wrangler deploy        # prints the *.workers.dev URL; iOS Constants.swift baseURL points at it

# Railway CLI (when linked)
RAILWAY_CALLER="skill:use-railway@1.2.0" RAILWAY_AGENT_SESSION="$(date +%s)" railway logs --service Expensify --lines 100
```

Test suite is fully offline — parser, categorizer, Gmail body extractor, receipt parsers. No env vars or network calls required to run `npm test`.

## High-level architecture

### Backend (`src/`)

```
src/
├── server.ts                          # Fastify entrypoint, registers all routes
├── server/
│   ├── routes/                        # gmailWebhook, devices, transactions, budgets, rules, contacts, health
│   ├── middleware/auth.ts             # Bearer-token check (single static API_TOKEN)
│   └── cron.ts                        # in-process 24h scheduler — refreshes Gmail watch
├── gmail/                             # OAuth dance, Pub/Sub message decoder, history walker, MIME body extractor
├── parsers/hdfc/                      # Per-template parsers (6 templates), all dispatched from index.ts
│   ├── templates/
│   │   ├── cc-autopay.ts              # Template C — "set up through E-mandate"
│   │   ├── cc-autopay-upcoming.ts     # Heads-up email; returns `not_a_transaction`
│   │   ├── cc-debit.ts                # Template B — "debited from your HDFC Bank Credit Card ending NNNN towards X"
│   │   ├── cc-upi-debit.ts            # Template E — RuPay CC + UPI (older "has been debited")
│   │   ├── cc-upi-debit-v2.ts         # Template E v2 — May-2026 reword ("is debited / ending NNNN / DD Mon, YYYY")
│   │   ├── upi-credit.ts              # Template A — inbound UPI to account
│   │   └── upi-debit.ts               # Template D — outbound UPI to a VPA
│   └── index.ts                       # Tries templates in order; specific markers BEFORE general ones (v2 before v1; ccUpiDebit before ccDebit; etc.)
├── categorize/                        # Pure logic — no DB
│   ├── index.ts                       # Orchestrator: VPA-pattern → merchant-pattern → autopay-alias → alias → VPA-shape → user-rule
│   ├── aliases.ts, rules.ts, vpaShape.ts, onlineMerchant.ts
│   └── types.ts                       # CATEGORIES (7-item const), confidence threshold, RuleConditions JSONB shape
├── receipts/extractors.ts             # Per-source parsers: Swiggy, Instamart, redBus, MakeMyTrip + universal fallback. pickExtractor() routes by from-address.
├── pipeline/
│   ├── processGmailMessage.ts         # HDFC ingest: parser → categorize → upsertTransaction → optional silent-push → budget check
│   ├── processReceiptEmail.ts         # Receipt ingest: pickExtractor → tryBindToTransaction (amount + ±90min window + source-keyword + P2P guard)
│   ├── recategorizeWithLocation.ts    # Runs after iOS uploads GPS: P2P + online guards → user-rule eval → Places lookup → persist suggestions
│   └── budgetAlerts.ts                # MTD recompute; fires push only once per (month, threshold) key
├── services/
│   ├── apns.ts                        # sendVisiblePush, sendSilentLocationPush, sendParserMissedAlert
│   ├── places.ts                      # Google Places (New) wrapper, STRICT_DISTANCE_M = 30
│   ├── placesTypeMapper.ts            # `restaurant` → Food, etc.
│   └── googleContacts.ts              # People API sync + lookupByVpa (phone-tail first, then strict-token name match)
└── db/                                # Pure data-access (Prisma calls only, no business logic)
    ├── client.ts, transactions.ts, emailMessages.ts, aliases.ts
    ├── userRules.ts, merchantPatterns.ts, vpaPatterns.ts
    └── categorizeContext.ts           # Builds CategorizeContext from DB rows for the orchestrator at request time
```

### iOS app (`Expensify/`)

SwiftUI, iOS 17+ (uses `@Observable`, `@AppStorage`, `ScrollViewReader`). All UI talks to backend via `APIClient` (which goes through HTTPClient with retry/backoff).

- `Models/` — wire types (`Transaction`, `Category`, `UserRule`, `Budget`, `PlaceSuggestion`, `ReceiptDetails`).
- `Services/`
  - `TransactionStore` — single source of truth, `@Observable`; `refresh()`, `retag()`, `applyPlace()` (the "claim a Places suggestion" + "rename merchant" backend).
  - `ContactsService` — privacy-critical: iOS Contacts NEVER leaves the device. Phone-tail match (UPI VPA `9876543210@ybl` → CN phone) is preferred; strict token-overlap fallback. Google-contacts lookup is a separate path that DOES go to the server but only ever sees a VPA.
  - `BudgetStore`, `LocationService` (CLLocationManager + Significant Location Changes), `PushService` (APNs token registration).
- `Theme/Tokens.swift` — single source of color truth. Every token is `Color.dynamic(light:dark:)`. `AppColor.tap` is the accent (blue); when used as a *background* (Maps button, selected instrument-dock chip), the foreground MUST be `AppColor.canvas`, never `.white` literal — `.white` literal on tap turns invisible in dark mode.
- `Theme/ThemePreference.swift` — system/light/dark override stored in `@AppStorage`. Wired through `.preferredColorScheme(...)` at the root.
- `Views/` — by tab: `Home/`, `Categories/`, `Activity/` (review queue) + `Settings/` + reusable `Components/`.

### Cloudflare Worker (`cloudflare-worker/`)

20-line reverse proxy that fronts Railway. iOS hits `https://expensify-proxy.<account>.workers.dev`; the Worker rewrites the URL to `https://expensify-production.up.railway.app` and replays method/headers/body. Exists because Indian carriers (Jio specifically) DPI-throttled both `*.up.railway.app` and our custom `expensify.sudhanva.space`; `*.workers.dev` is a shared CF platform domain that's much harder to single out.

### MCP server (`src/mcp/`)

Standalone Fastify process that exposes Postgres data to Claude clients over the Model Context Protocol (Streamable HTTP transport, stateless). 13 read-only tools across four buckets — spend queries, budget status, rule/pattern inspection, and pipeline-debug. Bearer-authed against `MCP_TOKEN` (separate from `API_TOKEN` so they rotate independently). Deployed as a *second* Railway service in the same project (start command `bash scripts/start-mcp.sh`, healthcheck `/health`); the main backend owns the schema and the MCP service is a pure Prisma read client. Detailed deploy + client-config instructions in `src/mcp/README.md`.

## Core data flow

Inbound HDFC email:

1. Gmail watch (renewed every 24h) publishes a Pub/Sub notification on inbox change.
2. Pub/Sub PUSHes to `POST /webhooks/gmail` on Railway with a signed JWT.
3. Handler calls `users.history.list(startHistoryId=lastHistoryId)` to enumerate new message IDs, then `users.messages.get` for each.
4. `isLikelyHdfcAlert(fromAddress, subject)` filters: from address must match HDFC patterns AND the subject must NOT match the marketing blacklist (loan, EMI, voucher, "Update:", etc.).
5. `processGmailMessage()` runs: dispatch to HDFC parser → `categorize()` → `upsertTransaction()` (idempotent on `gmailMessageId`).
6. If the row is an outflow on `account_*`/`card_*` and not autopay / not online merchant, `locationStatus = 'awaiting'` and a silent APNs push fires to the iPhone.
7. iPhone wakes via the silent push, captures GPS (`LocationService.fetchOnce`), POSTs to `/transactions/:id/location`.
8. `recategorizeWithLocation()` then: skips if alias / merchant_pattern / user_rule / places / autopay_alias already resolved → P2P guard → online-merchant guard → tries enabled location-aware user rules at auto-tag confidence → Google Places lookup (30m strict radius) → persists top-5 suggestions on the row.

Inbound receipt email (Swiggy / Zomato / Amazon / redBus / MakeMyTrip / Uber / Ola / Rapido / etc.):

1. Same Gmail → Pub/Sub → webhook path.
2. `isReceiptSender(fromAddress)` → `pickExtractor()` routes to a per-source parser.
3. `processReceiptEmail()` extracts amount/items/fees/meta, then `tryBindToTransaction()`:
   - same amount + `direction='out'`
   - `occurredAt` within ±90 min of receipt arrival (relaxed fallback: same amount, any time)
   - source-keyword alignment (Swiggy receipts only bind to txs whose merchantRaw contains `swiggy|bundl`; etc.)
   - non-P2P guard (`classifyVpa(vpa) !== 'personal'`)
4. Receipt row persisted; if exactly one aligned candidate found, `transactionId` is set.

## Categorization tier chain

When the orchestrator runs, signals are pushed in this order; the first one at ≥0.95 confidence auto-tags. All others go to `pending_review`.

1. **VPA pattern** (`VpaPattern`) — 1-hit threshold. User tags one Surendra Shetty row → every row on `q454981412@ybl` flips to that category. Also stores `merchantName` so future debits adopt the renamed display name.
2. **Merchant pattern** (`MerchantPattern`) — 3-hit threshold on `merchantNormalized`. Catches cases where VPA varies but the bank text is stable.
3. **Autopay alias** (`MerchantAlias` tagged `autopay:`) — fires only on `cc_autopay` template emails. Maps "Anthropic" → Subscriptions etc.
4. **Merchant alias** (`MerchantAlias`) — curated seed data (~119 rows). Routing-prefix strip first (`RAZ*`, `PAYU*`, `CCD*`, etc.).
5. **VPA shape** (`classifyVpa`) — `q\d+@ybl` → merchant, `firstname.lastname@oksbi` → personal (auto-tags as Personal Transfer at 0.95). The list of personal/merchant handles is hardcoded in `src/categorize/vpaShape.ts`.
6. **User rules** — JSONB conditions, evaluated by `evaluateRule()`. Conditions include `direction`, `instrument`, `amountBetween`, `timeOfDayBetween` (IST), `dayOfWeek`, `payeeContains`, `payeeRegex`, `payeeNotInAliasTable`, `vpaShape`, `locationWithinRadius`. Location-aware rules only evaluate inside `recategorizeWithLocation()` once GPS is known.

The seven V1 categories (`src/categorize/types.ts:CATEGORIES`): Travel, Food, Entertainment, **Shopping** (formerly "Groceries / Kirana Stores"), Personal Transfer (Peer-to-Peer), Investments, Subscriptions.

## Invariants and gotchas

- **Money is always BigInt minor units** in the backend (`amountMinor`, `amountInrMinor`). Never `Number`. Currency conversion preserves both bank-converted INR and source-currency original.
- **`gmailMessageId` is the idempotency key** for both `Transaction` and `EmailReceipt`. Pub/Sub is at-least-once; every upsert checks this first.
- **`/health` does NOT touch the DB**. It's a liveness probe. `/health/db` is the readiness probe that pings Postgres. If `/health` returns 5xx when Postgres is down, Railway's healthcheck cascades the whole service down even though Fastify is fine. This split is load-bearing — don't merge them back.
- **`scripts/start.sh` is the Railway start command.** It retries `prisma migrate deploy` up to 20×3s with backoff, runs the seed best-effort, then `exec npm start`. The server ALWAYS launches even if migrate fails — otherwise a brief Postgres outage permanently kills the service.
- **Gmail OAuth refresh tokens expire after 7 days while the OAuth app is in "Testing" status.** The app needs to be in "In production" (which doesn't require Google verification for a single-user setup, but does show an "unverified app" consent screen) to get persistent refresh tokens. If `invalid_grant` shows up, re-run `scripts/gmail-auth.ts`.
- **Pub/Sub JWT verification is gated on `GOOGLE_PUBSUB_VERIFICATION_AUDIENCE`.** If unset, the webhook accepts unauthenticated requests with a warning — fine in dev, hardened in prod.
- **Receipt binding has THREE guards layered**: amount equality, source↔merchant keyword alignment, non-P2P. The order matters; relaxing any one of them re-enables the "random Swiggy email bound to Thimmegowda's Paytm-QR" class of bug.
- **`AppColor.textPrimary` is near-white in dark mode.** Using it as a *background* on iOS makes white-text-on-white blobs. The Maps button, instrument-dock selected chip, and tab-bar tint all use `AppColor.tap` instead; foreground for those pairs MUST be `AppColor.canvas` (the dynamic inverse), never `.white`.
- **`isContactOverride` in `TransactionRow`** gates both contact name AND contact photo. It requires the row's category to be nil OR `.personalTransfer` — user-tagged categories win over contact overlay.
- **`MerchantAvatar.brandKey`** decouples the renameable display name from the favicon lookup. Favicon resolves from `transaction.merchantRaw` (or VPA); title resolves from `displayMerchant`/contact/rename. Without this, renaming a row would also change the favicon — wrong because the bank-side identity hasn't changed.
- **Web-domain favicon resolution** runs an "inner brand extraction" pipeline (`MerchantBranding.extractInnerBrand`): strips payment-rail prefixes (`amznpl`, `gpay-`, `paytm-`, etc.), trailing transaction IDs, and corporate suffixes (`pvtltd`, `services`, `india`). Lets `amznplpvrv2033702` resolve to PVR's favicon.

## Deployment + ingest setup

- **Backend**: Railway auto-deploys from `main`. Service uses `railway.json` for build (NIXPACKS, no buildCommand) and start (`bash scripts/start.sh`). Healthcheck timeout 120s, restart policy `ON_FAILURE` max 10.
- **iOS app**: signed with paid Apple Developer Program cert; built from Xcode. `Constants.baseURL` points at the Cloudflare Worker.
- **Cloudflare Worker**: `cd cloudflare-worker && wrangler deploy`. Free tier covers 100k req/day. Worker reads no env vars; the Railway origin is hardcoded.
- **Gmail Pub/Sub** topic: `projects/<gcp-project>/topics/gmail-inbound`. Push subscription `gmail-inbound-push` posts to `https://<host>/webhooks/gmail` with signed JWT audience matching `GOOGLE_PUBSUB_VERIFICATION_AUDIENCE`.
- **Postgres**: Railway-managed via `postgres-ssl:18` template image. Internal hostname `postgres.railway.internal:5432` is reachable from the backend only at runtime — NOT at build time and NOT from outside Railway. Local dev uses the public proxy URL (`viaduct.proxy.rlwy.net:48626`).

## Locked decisions

- **Gmail ingestion**: Gmail API → Google Cloud Pub/Sub → webhook on Railway. Near real-time. Watch must be re-registered weekly (Gmail caps at 7 days); the in-process cron in `src/server/cron.ts` handles this automatically.
- **Location**: iOS app pings backend with GPS *only when triggered by a transaction email* — backend sends a silent APNs push to the phone, phone wakes, posts location, sleeps. Battery is a hard priority.
- **iOS framework**: Swift / SwiftUI. Direct APNs.
- **Auth (V1)**: Single-user, static API token (`API_TOKEN` env on backend, `Constants.apiToken` on iOS). Gmail OAuth tied to one Google account. Multi-user is a V2 migration.
- **Contacts privacy**: iOS Contacts NEVER leave the device. Google-contacts lookups are a separate server-side cache (`GoogleContact` table) populated by an explicit user-triggered sync.
- **No Groq / Brave Search.** Earlier spec mentioned them; the categorization stack actually ships with alias + VPA-shape + user rules + Google Places, in that order. Adding LLM tiers requires re-architecting the orchestrator's tier-chain return type.

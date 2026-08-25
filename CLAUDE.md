# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal expense tracker for a single user. Three deployable units in one repo:

- **Node/TypeScript backend** (`src/`) deployed to Railway as a Fastify server. Ingests HDFC transaction emails + merchant receipts via Gmail → Pub/Sub, categorizes them, persists to Postgres, sends APNs pushes.
- **SwiftUI iOS app** (`Expensify/`) talks to the backend over HTTPS through a Cloudflare Worker reverse proxy (`cloudflare-worker/`). Round-trips GPS via silent APNs pushes.
- **MCP server** (`src/mcp/`) deployed as a second Railway service. Read-only Streamable HTTP MCP that exposes the Postgres data to Claude (Desktop / Code / web). Accepts both a static bearer (`MCP_TOKEN`) and OAuth-issued tokens (`/authorize` → `/token` flow, with `.well-known` discovery). See `src/mcp/README.md`.

Database is PostgreSQL on Railway, accessed exclusively through Prisma. There's no Groq / Brave Search despite the older spec mentioning them — the categorization stack that actually ships is alias-table + VPA-shape + user rules + Google Places. See "Categorization tier chain" below.

`.impeccable.md` at the repo root is the iOS **design context** (users, brand personality, color/typography/spacing rules, component inventory). Read it before touching SwiftUI views — it's the reasoning behind `Theme/Tokens.swift`, not decoration. `docs/UI_MOCKUPS.md` holds screen mockups.

## Common commands

```bash
# Dev loop
npm run typecheck                                  # tsc --noEmit, run before commits
npm run test:run                                   # vitest, one-shot
npm test                                           # vitest watch mode
npx vitest run test/parsers/hdfc.test.ts           # single test file
npx vitest run -t "cc_upi_debit"                   # single test by name
npm start                                          # tsx src/server.ts (local)
PORT=3001 MCP_TOKEN=dev npm run start:mcp          # local MCP server, separate process from npm start

# Database (DATABASE_URL in .env points at Railway prod; local Postgres is unused now)
npm run db:migrate                                 # prisma migrate dev — generates + applies a new migration when schema.prisma changes
npm run db:migrate:deploy                          # prisma migrate deploy — applies pending migrations without prompts (used by Railway start.sh)
npm run db:seed                                    # idempotent: categories, ROUTING_PREFIXES, alias rows
npm run db:reset                                   # nuke + re-migrate + re-seed (DESTRUCTIVE on whatever DATABASE_URL points at)
npm run db:generate                                # prisma generate (also runs on postinstall)
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
npx tsx scripts/rebind-orphan-receipts.ts          # the inverse: binds orphan receipts whose transaction arrived AFTER them (dry-run unless --apply)
npx tsx scripts/prune-marketing-receipts.ts        # DELETES unbound EmailReceipt rows classified as marketing/feedback/OTP (dry-run unless --apply)
npx tsx scripts/reextract-receipts.ts              # re-runs today's extractors over stored EmailReceipt rows, then re-binds (dry-run unless --apply; --all includes bound rows).
                                                   #   MUST be re-run after any edit to src/receipts/extractors.ts — extraction is persisted and the body is NOT stored
npx tsx scripts/backfill-rules.ts                  # walks every tx with GPS, applies enabled user rules at auto-tag confidence (dry-run unless --apply)
npx tsx scripts/backfill-vpa-merchants.ts          # re-decodes Transaction.vpaGateway/vpaMerchant from the VPA (dry-run unless --apply).
                                                   #   MUST be re-run after any edit to src/categorize/vpaMerchant.ts — the decode is persisted, not derived on read

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
│   ├── routes/                        # gmailWebhook, devices, transactions, budgets, rules, contacts,
│   │                                  #   accountBalances, mcpAdmin, health
│   ├── middleware/auth.ts             # Bearer-token check (single static API_TOKEN)
│   └── cron.ts                        # two in-process timers: 24h Gmail-watch refresh, hourly stale-`awaiting` location sweep
├── gmail/                             # OAuth dance, Pub/Sub message decoder, history walker, MIME body extractor
├── parsers/hdfc/                      # Per-template parsers (11 templates), all dispatched from index.ts
│   ├── templates/
│   │   ├── cc-autopay.ts              # Template C — "set up through E-mandate"
│   │   ├── cc-autopay-upcoming.ts     # Heads-up email; returns `not_a_transaction`
│   │   ├── cc-debit.ts                # Template B — "debited from your HDFC Bank Credit Card ending NNNN towards X"
│   │   ├── cc-thanks.ts               # Template F — "Thank you for using your HDFC Bank Credit Card ending in NNNN" (positive-tone CC charge)
│   │   ├── cc-upi-debit.ts            # Template E — RuPay CC + UPI (older "has been debited")
│   │   ├── cc-upi-debit-v2.ts         # Template E v2 — May-2026 reword ("is debited / ending NNNN / DD Mon, YYYY")
│   │   ├── cc-upi-debit-v3.ts         # Template E v3 — June-2026 reword ("❗ You have done a UPI txn" / RuPay CC UPI)
│   │   ├── debit-card.ts              # Template G — "Thank you for using your HDFC Bank Debit Card ending NNNN for ATM withdrawal / purchase"
│   │   ├── deposit-credit.ts          # Template H — inbound NEFT/IMPS/RTGS credit ("You have received a credit in your HDFC Bank account")
│   │   ├── upi-credit.ts              # Template A — inbound UPI to account
│   │   └── upi-debit.ts               # Template D — outbound UPI to a VPA, or to a masked account ("to account *******")
│   ├── balance.ts                     # NOT a transaction — daily balance alert + low-balance threshold alert
│   ├── dateMoney.ts                   # shared `parseMinorUnits` / `parseDdMmmYy` used by every template
│   └── index.ts                       # Tries templates in order; specific markers BEFORE general ones (v3/v2 before v1; ccThanks/ccUpiDebit before ccDebit; etc.)
├── categorize/                        # Pure logic — no DB
│   ├── index.ts                       # Orchestrator: VPA-pattern → merchant-pattern → autopay-alias → alias → VPA-shape → user-rule
│   ├── aliases.ts, rules.ts, vpaShape.ts, onlineMerchant.ts
│   ├── vpaMerchant.ts                 # `decodeVpaMerchant()` — pulls merchant + aggregator out of a VPA
│   │                                  #   ("netflixupi.payu@hdfcbank" → Netflix / PayU). Gated behind classifyVpa
│   │                                  #   so a personal VPA is never renamed. NOT a categorization tier — see below
│   ├── seed.ts                        # ROUTING_PREFIXES + ~138 curated MerchantAlias rows + autopay aliases (source of truth, copied into DB by prisma/seed.ts)
│   └── types.ts                       # CATEGORIES (9-item const), confidence threshold, RuleConditions JSONB shape
├── receipts/
│   ├── extractors.ts                  # Per-source parsers: Swiggy, Instamart, redBus, MakeMyTrip + universal fallback. pickExtractor() routes by from-address.
│   └── binding.ts                     # Pure receipt↔transaction alignment rules (amount, window, source keyword, P2P).
│                                      #   Shared by BOTH binding directions so they can't drift apart.
├── pipeline/
│   ├── processGmailMessage.ts         # HDFC ingest: parser → categorize → upsertTransaction → optional silent-push → budget check
│   ├── processReceiptEmail.ts         # Receipt ingest: pickExtractor → tryBindToTransaction (binds when the transaction already exists)
│   ├── bindOrphanReceipts.ts          # The reverse: after a transaction insert, sweep back for receipts that beat the bank alert
│   ├── recategorizeWithLocation.ts    # Runs after iOS uploads GPS: P2P + online guards → user-rule eval → Places lookup → persist suggestions
│   ├── budgetAlerts.ts                # MTD recompute; fires push only once per (month, threshold) key
│   └── locationLifecycle.ts           # pure policy: which rows want GPS (`initialLocationStatus`) + how long one may sit `awaiting` (24h)
├── services/
│   ├── apns.ts                        # sendVisiblePush, sendSilentLocationPush, sendParserMissedAlert
│   ├── places.ts                      # Google Places (New) wrapper. Radius is a caller arg (default 100m); the 30m
│   │                                  #   STRICT_DISTANCE_M haversine filter lives in recategorizeWithLocation.ts
│   ├── placesTypeMapper.ts            # `restaurant` → Food, etc.
│   └── googleContacts.ts              # People API sync + lookupByVpa (phone-tail first, then strict-token name match)
└── db/                                # Pure data-access (Prisma calls only, no business logic)
    ├── client.ts, transactions.ts, emailMessages.ts, aliases.ts
    ├── userRules.ts, merchantPatterns.ts, vpaPatterns.ts, accountBalances.ts
    └── categorizeContext.ts           # Builds CategorizeContext from DB rows for the orchestrator at request time
```

### iOS app (`Expensify/`)

SwiftUI, iOS 17+ (uses `@Observable`, `@AppStorage`, `ScrollViewReader`). All UI talks to backend via `APIClient` (which goes through HTTPClient with retry/backoff).

- `Models/` — wire types (`Transaction`, `Category`, `UserRule`, `Budget`, `PlaceSuggestion`, `ReceiptDetails`, `AccountBalance`, `MCPDiagnostics`, `ReviewItem`, `DateRange`).
- `Services/`
  - `TransactionStore` — single source of truth, `@Observable`; `refresh()`, `retag()`, `applyPlace()` (the "claim a Places suggestion" + "rename merchant" backend).
  - `ContactsService` — privacy-critical: iOS Contacts NEVER leaves the device. Phone-tail match (UPI VPA `9876543210@ybl` → CN phone) is preferred; strict token-overlap fallback. Google-contacts lookup is a separate path that DOES go to the server but only ever sees a VPA.
  - `LocationService` — CLLocationManager + Significant Location Changes, plus a **spend-time buffer**: recent fixes are retained so a transaction can be matched to where the user was *when they spent*, not where they are when the app wakes. SLC only fires on ~500m of movement, so `captureIntoBufferIfNeeded()` also warms the buffer on foreground (debounced on the same clock as the opportunistic SLC capture) — sitting still in a café would otherwise leave the buffer with nothing near the spend.
  - `BackfillService` — runs on `applicationDidBecomeActive`; catches up `awaiting_location` rows when the silent push never woke the app (Low Power Mode, APNs throttling). Prefers `LocationService.closestEntry(to: occurredAt)` over a fresh fix.
  - `NetworkMonitor` — NWPathMonitor; `HTTPClient` subscribes and drops stale TCP connections after a Wi-Fi↔cellular handoff (the usual cause of "first request after coming back online fails").
  - `BudgetStore`, `PushService` (APNs token registration), `ProfilePhotoStore` (on-device avatar JPEG, never uploaded), `CurrentUser` (hardcoded single-user name/email), `MerchantBranding` (favicon/brand-key resolution), `MockData`.
- `Theme/Tokens.swift` — single source of color truth. Every token is `Color.dynamic(light:dark:)`. Neutral tokens (canvas, surface, text*, hairline, avatarFill) are **achromatic — R == G == B**; they were warm-tinted until the brown cast read as sepia, and the neutral values sit at the same perceptual luminance so AA contrast is unchanged. Unequal channels on a non-accent token is a bug. Only `inflow`, `tap`, and `AnalyticsView.overColor` carry hue. `AppColor.tap` is the accent (blue); when used as a *background* (Maps button, selected instrument-dock chip), the foreground MUST be `AppColor.canvas`, never `.white` literal — `.white` literal on tap turns invisible in dark mode.
- `Theme/ThemePreference.swift` — system/light/dark override stored in `@AppStorage`. Wired through `.preferredColorScheme(...)` at the root.
- `Theme/LiquidGlass.swift` — `.glassControl(shape:tint:)`. Use this for custom controls (icon buttons, filter FAB) instead of hand-painting `AppColor` fills; it uses the iOS 26 `glassEffect` material with a tinted-surface fallback on older iOS.
- `Views/` — by tab: `Home/`, `Categories/`, `Activity/` (review queue) + `Settings/` (incl. `DiagnosticsView` — MCP health + OAuth token revocation, backed by `/mcp-admin`) + reusable `Components/`.

### Cloudflare Worker (`cloudflare-worker/`)

20-line reverse proxy that fronts Railway. iOS hits `https://expensify-proxy.<account>.workers.dev`; the Worker rewrites the URL to `https://expensify-production.up.railway.app` and replays method/headers/body. Exists because Indian carriers (Jio specifically) DPI-throttled both `*.up.railway.app` and our custom `expensify.sudhanva.space`; `*.workers.dev` is a shared CF platform domain that's much harder to single out.

### MCP server (`src/mcp/`)

Standalone Fastify process that exposes Postgres data to Claude clients over the Model Context Protocol (Streamable HTTP transport, **stateless** — every POST builds a fresh `McpServer` + transport pair, closed when the response ends). 18 read-only tools registered from `src/mcp/handlers/`:

| Handler | Tools |
| --- | --- |
| `spend.ts` | `list_transactions`, `monthly_summary`, `top_merchants`, `total_by_category`, `search_merchant` |
| `budgets.ts` | `current_budget_status`, `budget_history` |
| `rules.ts` | `list_user_rules`, `list_vpa_patterns`, `list_merchant_patterns` |
| `details.ts` | `get_transaction`, `recent_receipts`, `list_tags`, `list_goals`, `get_account_balances`, `list_instruments` |
| `debug.ts` | `unparsed_hdfc_emails`, `unbound_receipts`, `recent_email_messages` |

`expand.ts` implements the opt-in `expand` argument on transaction-returning tools (`receipt` / `places` / `location` / `fx` / `email`) so the default shape stays lightweight; `formatters.ts` does the minor-units → rupee rendering. `list_transactions` also takes a `gateway` filter (closed vocabulary from `vpaMerchant.ts`, matched `equals`-insensitive — a `contains` match could only ever add false positives), and `search_merchant` searches `vpaMerchant` alongside `merchantRaw`/`merchantNormalized`/`vpa` because for aggregator rows the searchable name exists *only* in the decoded column.

Dual auth (`src/mcp/oauth/`): a static bearer (`MCP_TOKEN`, separate from `API_TOKEN` so they rotate independently) for paste-a-token clients, and an OAuth `/authorize` → `/token` flow whose issued tokens are checked against `McpAccessToken`. Unauthenticated `/mcp` requests get a 401 with an RFC 9728 `WWW-Authenticate` pointing at `/.well-known/oauth-protected-resource`. Deployed as a *second* Railway service in the same project (started by the dispatcher when `RAILWAY_SERVICE_NAME=Expensify-MCP`, healthcheck `/health`); the main backend owns the schema and the MCP service is a pure Prisma read client. Token administration is the **main backend's** job, not the MCP service's — `/mcp-admin/*` (API_TOKEN-authed) reads/revokes `McpAccessToken` rows directly and pings `MCP_PUBLIC_URL/health` for the iOS Diagnostics screen. Detailed deploy + client-config instructions in `src/mcp/README.md`.

## Core data flow

Inbound HDFC email:

1. Gmail watch (renewed every 24h) publishes a Pub/Sub notification on inbox change.
2. Pub/Sub PUSHes to `POST /webhooks/gmail` on Railway with a signed JWT.
3. Handler calls `users.history.list(startHistoryId=lastHistoryId)` to enumerate new message IDs, then `users.messages.get` for each.
4. `isLikelyHdfcAlert(fromAddress, subject)` filters: from address must match HDFC patterns AND the subject must NOT match the marketing blacklist (loan, EMI, voucher, "Update:", etc.).
5. `processGmailMessage()` runs: dispatch to HDFC parser → `categorize()` → `upsertTransaction()` (idempotent on `gmailMessageId`).
6. If the row is an outflow and not autopay, `locationStatus = 'awaiting'` and a silent APNs push fires to the iPhone. Policy lives in `initialLocationStatus()` (`src/pipeline/locationLifecycle.ts`) — **every** outflow asks; the only exclusions are inflow and autopay, both structural. The online-merchant detector used to veto this and no longer does (see "Invariants").
7. iPhone wakes via the silent push, captures GPS (`LocationService.fetchOnce`), POSTs to `/transactions/:id/location`.
8. `recategorizeWithLocation()` then: Google Places lookup (30m strict radius) → persists top-5 suggestions on the row → skips the auto-tag if alias / merchant_pattern / user_rule / places / autopay_alias already resolved → online-merchant guard → P2P guard → tries enabled location-aware user rules at auto-tag confidence → auto-tags from a single strong Places match. Note the ordering: **suggestions are persisted before every guard**, so even a row we refuse to auto-rename still offers the iOS picker something to tap.

`locationStatus = 'awaiting'` has exactly **two** exits: a successful GPS upload from iOS, or the hourly cron sweep (`scheduleLocationSweep` → `expireStaleAwaitingLocations`) flipping rows older than `AWAITING_GRACE_MS` (24h) to `missed`. Without the sweep, every dropped silent push (force-quit, Low Power Mode, APNs throttling) stranded a row rendering "locating…" forever, and — because `GET /transactions/awaiting` is `take: 50` ordered by `occurredAt desc` — the backlog pushed still-recoverable rows out of the list so the iOS foreground backfill could never see them. The sweep deliberately does not *guess* a location; `missed` is honest, "wherever the user was when the app next opened" is not.

Inbound receipt email (Swiggy / Zomato / Amazon / redBus / MakeMyTrip / Uber / Ola / Rapido / etc.):

1. Same Gmail → Pub/Sub → webhook path.
2. `isReceiptSender(fromAddress)` → `detectMarketingReceipt()` drops ads/feedback/OTP mail → `pickExtractor()` routes to a per-source parser.
3. `processReceiptEmail()` extracts amount/items/fees/meta, then `tryBindToTransaction()`:
   - same amount + `direction='out'`
   - `occurredAt` within ±90 min of receipt arrival (`MATCH_WINDOW_MS`), or within ±24h (`RELAXED_WINDOW_MS`) via the fallback that only runs when the 90-min pass found no same-amount candidate at all
   - source-keyword alignment (Swiggy receipts only bind to txs whose merchantRaw contains `swiggy|bundl`; etc.)
   - non-P2P guard (`classifyVpa(vpa) !== 'personal'`)
4. Receipt row persisted; if exactly one aligned candidate found, `transactionId` is set.

Inbound HDFC **balance** alert (third path — not a transaction):

1. Same Gmail → Pub/Sub → webhook path; same shared subject as the debit-card alert.
2. `parseBalance()` (`src/parsers/hdfc/balance.ts`) keys on the body marker `balance in your account ending` — deliberately NOT matching the debit-card alert's "available balance **on your card**", which must fall through to the transaction parser chain.
3. Upserts `AccountBalance` (`instrument` shaped like `account_5264`, `balanceInrMinor`, `asOf`).
4. iOS reads it via `GET /account-balance` (plural wire shape, single-account V1) and renders the Home balance card.

## Categorization tier chain

When the orchestrator runs, signals are pushed in this order; the first one at ≥0.95 confidence auto-tags. All others go to `pending_review`.

1. **VPA pattern** (`VpaPattern`) — 1-hit threshold. User tags one Surendra Shetty row → every row on `q454981412@ybl` flips to that category. Also stores `merchantName` so future debits adopt the renamed display name.
2. **Merchant pattern** (`MerchantPattern`) — 3-hit threshold on `merchantNormalized`. Catches cases where VPA varies but the bank text is stable.
3. **Autopay alias** (`MerchantAlias` tagged `autopay:`) — fires only on `cc_autopay` template emails. Maps "Anthropic" → Subscriptions etc.
4. **Merchant alias** (`MerchantAlias`) — curated seed data (~138 rows in `src/categorize/seed.ts`). Routing-prefix strip first (`RAZ*`, `PAYU*`, `CCD*`, etc.).
5. **VPA shape** (`classifyVpa`) — `q\d+@ybl` → merchant, `firstname.lastname@oksbi` → personal (auto-tags as Personal Transfer at 0.95). The list of personal/merchant handles is hardcoded in `src/categorize/vpaShape.ts`.
6. **User rules** — JSONB conditions, evaluated by `evaluateRule()`. Conditions include `direction`, `instrument`, `amountBetween`, `timeOfDayBetween` (IST), `dayOfWeek`, `payeeContains`, `payeeRegex`, `payeeNotInAliasTable`, `vpaShape`, `locationWithinRadius`. Location-aware rules only evaluate inside `recategorizeWithLocation()` once GPS is known.

There is deliberately **no "alias via decoded VPA merchant" tier**. It was built and measured against the full history and rescued zero rows: the alias table matches by substring, so `netflixupi.payu` already hits the NETFLIX pattern in tier 4. The rows tier 4 misses (Snitch, Swish, District) miss because they have no alias row at all — a seed-data gap. Fix those by adding the alias row, not by adding a tier. (The comment in `src/categorize/index.ts` says the same; don't re-derive it.)

The nine categories (`src/categorize/types.ts:CATEGORIES`): Travel, Food, Entertainment, Shopping, Groceries, Personal Transfer (Peer-to-Peer), Investments, Subscriptions, Health. Shopping and Groceries are now **separate** (Shopping was briefly the merged bucket). Adding a category means touching three places in lockstep: `CATEGORIES` in `src/categorize/types.ts`, the `Category` enum in `Expensify/Expensify/Models/Category.swift` (raw values must match the strings exactly — they're the wire format), and a re-run of `npm run db:seed`.

## Invariants and gotchas

- **Money is always BigInt minor units** in the backend (`amountMinor`, `amountInrMinor`). Never `Number`. Currency conversion preserves both bank-converted INR and source-currency original.
- **`gmailMessageId` is the idempotency key** for both `Transaction` and `EmailReceipt`. Pub/Sub is at-least-once; every upsert checks this first.
- **`/health` does NOT touch the DB**. It's a liveness probe. `/health/db` is the readiness probe that pings Postgres. If `/health` returns 5xx when Postgres is down, Railway's healthcheck cascades the whole service down even though Fastify is fine. This split is load-bearing — don't merge them back.
- **`scripts/start-dispatcher.sh` is the single Railway start command** (in `railway.json`). It branches on `RAILWAY_SERVICE_NAME`: `Expensify-MCP` → `start-mcp.sh`, everything else → `start.sh`. Both services run the same code/image; the dispatcher keeps per-service startup version-controlled instead of relying on dashboard overrides.
- **`scripts/start.sh` is the backend startup (invoked by the dispatcher).** It retries `prisma migrate deploy` up to 20×3s with backoff, runs the seed best-effort, then `exec npm start`. The server ALWAYS launches even if migrate fails — otherwise a brief Postgres outage permanently kills the service.
- **Gmail OAuth refresh tokens expire after 7 days while the OAuth app is in "Testing" status.** The app needs to be in "In production" (which doesn't require Google verification for a single-user setup, but does show an "unverified app" consent screen) to get persistent refresh tokens. If `invalid_grant` shows up, re-run `scripts/gmail-auth.ts`.
- **Pub/Sub JWT verification is gated on `GOOGLE_PUBSUB_VERIFICATION_AUDIENCE`.** If unset, the webhook accepts unauthenticated requests with a warning — fine in dev, hardened in prod.
- **`"View: Account update for your HDFC Bank A/c"` is a shared subject.** HDFC uses that exact subject for the daily balance alert, the low-balance threshold alert, the debit-card ATM/POS alert, NetBanking security notices, AND e-mandate registrations. Never add it to `MARKETING_SUBJECT_PATTERNS` — the debit-card one is real money. Only the body marker can discriminate. Correspondingly, `balance.ts` keys on "balance in your account ending", which the debit-card alert ("available balance **on your card**") deliberately does not match.
- **HDFC subject lines contain non-breaking spaces (U+00A0).** `isLikelyHdfcAlert` normalizes whitespace before testing `MARKETING_SUBJECT_PATTERNS` — without that, any pattern written with a literal space silently fails to match (this is why the "Scheduled Downtime" mailer leaked for months while `\s+`-based patterns worked fine). Prefer `\s+` or rely on the normalizer; never assume the space is ASCII.
- **Receipt binding has FOUR guards layered**: amount equality, a bounded time window, source↔merchant keyword alignment, non-P2P — plus the caller-side rule that *exactly one* candidate must align. All of it lives in one place, `receiptAlignsWithTransaction()` in `src/receipts/binding.ts`, precisely so the two binding directions cannot drift apart. Relaxing any guard re-enables the "random Swiggy email bound to Thimmegowda's Paytm-QR" class of bug.
- **Binding runs in BOTH directions, and must.** `processReceiptEmail` binds at receipt-ingest time, which only works when the bank alert arrived first. Merchants routinely beat HDFC — a redBus ticket landed 21s before its ₹1355 debit alert — so `bindOrphanReceiptsNear()` (`src/pipeline/bindOrphanReceipts.ts`) runs after every transaction insert and sweeps back for receipts that were orphaned by the race. `schema.prisma` had listed that race as a reason `transactionId` is nullable for months before anything closed it.
- **`isReceiptSender` matches the DOMAIN only, so `detectMarketingReceipt` is what keeps ads out of `EmailReceipt`.** Merchants send far more marketing than receipts from the same domain, and before the gate existed 331 of 404 rows were unbound perfume ads, price-drop blasts, feedback surveys and OTPs. It is not merely untidy: the universal extractor pulls a number out of ad copy, so "Here's how you can get a FREE bus ticket! 👇" was stored holding ₹850 — a figure invented by marketing, one coincidence away from binding to a real ₹850 debit. Structure of `src/receipts/marketing.ts`, in precedence order: (1) `TRANSACTIONAL_SUBJECT_PATTERNS` **win over everything** — a receipt may legitimately say "₹120 off", so anything carrying an unambiguous marker (order delivered/shipped, receipt, tax invoice, `Ticket - ABC123`, booking voucher) is kept outright rather than tuning each marketing pattern to thread that needle; (2) a sender **local-part** denylist (`feedback`, `research`, `otp`, `discover`, …) so `no_reply_feedback@redbus.in` is dropped while `no-reply@redbus.in` — same domain, sends the actual tickets — is not; (3) subject patterns. Two traps: **normalise whitespace first** (bulk senders emit U+00A0/U+202F/U+200B inside subjects — same lesson as the HDFC subject patterns), and **never write `\b` before `₹`** — it is not a word character, so the boundary can never match and "We just got you ₹75 off" slips through. Validate any change against the corpus: **zero bound receipts may classify as marketing** (`prune-marketing-receipts.ts` aborts if any do).
- **AI classification of receipt emails is deliberately deferred to V2.** The regex gate above is the V1 stopgap. An LLM is a genuinely better fit for the *classification* half (receipt vs. marketing is a judgement call, and being wrong costs one dropped ad or one extra row). It is a much worse fit for *amount extraction* unless constrained: money must be exact, and a hallucinated ₹1,231.65 where the card was charged ₹1,181.65 is precisely the bug class the redBus tickets already demonstrated. If/when this lands, have the model return the exact substring it read the total from, verify that substring appears in the body, and parse the number in code. Note it would also break the "test suite is fully offline" property unless mocked.
- **Receipt extraction is persisted at ingest and the email body is NOT stored.** So an extractor fix is not retroactive, and replaying it means re-fetching from Gmail — that is what `scripts/reextract-receipts.ts` is for, and it must be re-run after any edit to `src/receipts/extractors.ts`. Three redBus tickets sat unbound for a month holding the GROSS ticket price, ingested before `extractRedbus` learned to read "Ticket Price" across a line break and subtract the coupon; today's parser got all three right the moment it was asked again. `parserVersion` on the row is the fingerprint — a `generic.v1` on a "redBus Ticket - …" subject means the dedicated parser returned null and fell through. Both the live pipeline and the replay script call `extractReceiptFields()` so the two cannot drift.
- **The `redbus` source keyword list includes `makemytrip|mmt`, and the asymmetry with `travel` is deliberate.** MakeMyTrip owns redBus and settles some bookings through its own acquirer, so a real bus ticket arrives against a payee of `CAS*MAKEMYTRIP INDIA P`. Ticket TV8Q64078508 could not bind for that reason, and TV8K93604197 only bound because the merchant had been hand-renamed "Redbus" — the guard was leaning on a user edit. The reverse is NOT allowed: a `travel` (MMT hotel/flight) receipt must not match a REDBUS payee, or two unrelated travel bookings of the same amount would pair up.
- **The relaxed fallback is time-bounded at 24h, and was NOT always.** It used to be "same amount, any time", which is only safe if amounts are near-unique — they are not, since a ₹238 Swiggy order is indistinguishable from every other ₹238 Swiggy order. Measured against real history it paired receipts with transactions 11 to 163 days apart. The reverse sweep and the backfill pass `allowRelaxed: false` and accept only `amount_and_window` matches; they already select receipts sitting beside a transaction in time, so a relaxed hit there would be coincidence, not evidence.
- **`detectOnlineMerchant` does NOT gate GPS collection — only the Places auto-rename.** It used to decide whether to ask iOS for a location at all, and it was wrong in both directions on real payee text: `paytm-57338997` (a petrol pump reached through a Paytm terminal) matched the `PAYTM` rail prefix and was suppressed, while `PHP*REDBUS` (a bus booked from the sofa) did *not* match because the pattern was `^`-anchored and HDFC put the acquirer prefix first. **A payment rail is not a signal** — Paytm/PhonePe/Razorpay/PayU/GPay/CRED/Amazon Pay all route in-person QR terminals as happily as web checkouts, so rail prefixes are deliberately absent from `ONLINE_BRANDS`; adding one back re-breaks every pump, kirana and café behind that rail. `CRED\s*CLUB` is listed but bare `CRED` is not — the app paying your card bill has no storefront, a shop reached through the CRED rail does. Brand tokens now match anywhere in the string with `[^A-Za-z]`-or-edge boundaries on both sides, which is what lets `PHP*REDBUS` and `PTM*SWIGGY` resolve while still refusing `SRI CREDIT SOCIETY`, `UBERTO FASHIONS` and `OLAVAKKOT STORES`. Delivery/marketplace brands stay flagged on purpose: renaming a Swiggy order to the restaurant across the road is the same class of bug as the original `NAME-CHEAP.COM*` → "Vishal Mega Mart".
- **`AppColor.textPrimary` is near-white in dark mode.** Using it as a *background* on iOS makes white-text-on-white blobs. The Maps button, instrument-dock selected chip, and tab-bar tint all use `AppColor.tap` instead; foreground for those pairs MUST be `AppColor.canvas` (the dynamic inverse), never `.white`.
- **`isContactOverride` in `TransactionRow`** gates both contact name AND contact photo. It requires the row's category to be nil OR `.personalTransfer` — user-tagged categories win over contact overlay.
- **`MerchantAvatar.brandKey`** decouples the renameable display name from the favicon lookup. Every call site passes `Transaction.brandKey` (`vpaMerchant` → `merchantRaw` → `vpa`) — never `merchantRaw` inline; title resolves separately from `displayMerchant`/contact/rename. Without this split, renaming a row would also change the favicon — wrong because the bank-side identity hasn't changed. The gateway-decoded `vpaMerchant` is allowed in `brandKey` (a user rename is not) precisely because it *is* bank-side: it comes out of the VPA HDFC sent, and it comes first because a bare VPA echo resolves no favicon while "Snitch" resolves the real one.
- **`LocationService.allowsBackgroundLocationUpdates` MUST stay `true`.** `fetchOnce` drives `startUpdatingLocation()` and its most important caller is the silent-push handler, which runs backgrounded by definition; with `false`, that wake routinely timed out `.noLocation`. This is not continuous tracking — `fetchOnce` stops the stream on the first accurate-enough reading and nothing else starts one. `pausesLocationUpdatesAutomatically` is correspondingly `false`: auto-pause targets navigation-length sessions and just starves a 6–15s burst. The `location` UIBackgroundModes entry this requires is already in Info.plist (setting the flag without it traps at runtime).
- **VPA merchant/gateway: persisted at ingest, *displayed* by policy at read time.** `upsertTransaction` freezes `decodeVpaMerchant(vpa)` into `Transaction.vpaGateway` / `vpaMerchant` — persisted (not derived on read) because MCP filters on gateway in SQL alongside `take: limit`, and a post-fetch filter would silently return fewer rows than asked. Consequences: (a) decoder changes are **not** retroactive — run `scripts/backfill-vpa-merchants.ts --apply`; (b) `vpaMerchant` is stored raw and `GET /transactions` only emits it when `isMerchantRawAnEchoOfVpa(merchantRaw, vpa)`, so a real bank-sent trading name always wins and the policy is tunable without a backfill. iOS never arbitrates — `displayMerchant` treats a populated `vpa_merchant` as already-safe. The decoder never invents a name: opaque ids (`paytm.d15687920262`, `q385969427`) return a gateway with a `null` merchant. UPI carries no referrer or URL, so this is a registered merchant name, never a website.
- **Custom iOS controls use `.glassControl(...)`, not hand-painted `AppColor` fills.** Standard iOS styling is a project rule; `Theme/LiquidGlass.swift` is the one place that branches on iOS 26 availability.
- **`/mcp-admin/*` is authed with `API_TOKEN`, not `MCP_TOKEN`.** It lives on the main backend so iOS keeps one bearer for everything, and it writes the MCP token tables directly rather than proxying through the MCP service.
- **Web-domain favicon resolution** runs an "inner brand extraction" pipeline (`MerchantBranding.extractInnerBrand`): strips payment-rail prefixes (`amznpl`, `gpay-`, `paytm-`, etc.), trailing transaction IDs, and corporate suffixes (`pvtltd`, `services`, `india`). Lets `amznplpvrv2033702` resolve to PVR's favicon.

## Deployment + ingest setup

- **Backend**: Railway auto-deploys from `main`. Service uses `railway.json` for build (NIXPACKS, no buildCommand) and start (`bash scripts/start-dispatcher.sh`, which routes to `start.sh`/`start-mcp.sh` by service name). Healthcheck timeout 120s, restart policy `ON_FAILURE` max 10.
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

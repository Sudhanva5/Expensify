# Expense Solver

> Personal expense tracker. Working name TBD.

## Problem

I don't know where my money goes. Bank statements show merchant names with zero context. I want to fix this permanently.

## The Three Things That Matter Most

1. **Location tagging on every transaction.** Without location, half the categorization fails.
2. **Real merchant intelligence.** UPI VPAs leak the proprietor's name, not the shop's. The system must figure out *what kind of place* a payment went to — using location + Maps lookups, not just the raw payee string. "Sent ₹50,000 to people" is a useless category; "Groceries" is the answer.
3. **Live budget alerts.** Per-category monthly budgets with proactive push notifications when spend approaches or breaches the limit. Not end-of-month review — real-time guardrails.

## Stack

- **Backend:** Node.js on Railway (Pro account)
- **Database:** PostgreSQL on Railway
- **AI:** Groq API (Llama 3 8B) for categorization
- **iOS app:** Swift / Expo (TBD) with push notifications
- **Email ingestion:** Gmail API watching two streams

## Core Pipeline

1. Gmail watcher on Railway polls every 5 minutes
2. Two streams:
   - HDFC transaction alerts
   - Merchant receipt emails (Amazon, Swiggy, Zomato, Netflix, etc.)
3. Match transactions to receipts by amount + timestamp (10-minute window)
4. Groq categorizes anything unmatched
5. Confidence scoring:
   - High confidence → auto-tag
   - Low confidence → queue for evening review
6. 7 PM push notification — "X transactions need your input"
7. User resolves the queue in ~5 minutes

## Smart Tagging Rules

- **Never trust merchant name alone** — use name + amount range + location + time + frequency
- **Pattern learning** — if the user tags the same merchant 3x, auto-tag forever
- **Location** logged at the time the Gmail notification arrives (close enough)
- **Ask only** for genuinely ambiguous transactions

## Goals Tracker

- User sets a goal: name + target amount + deadline
- App tracks monthly savings rate
- Shows runway: "at current pace you'll have ₹X by deadline, you need ₹Y/month more"

## Critical Monitoring

- Alert if no HDFC emails parsed in 24 hours (silent parser failure risk)

## V1 Scope (strict)

- HDFC email parsing (4 known templates — see below)
- **User rule engine** for contextual transaction tagging (the Uber-cab pattern)
- Merchant intelligence pipeline (tiered: alias → VPA shape → Groq → Brave+Groq → review)
- Strict confidence threshold (**≥ 0.95 for auto-tag**)
- iOS silent-push location round-trip (only for outbound spend)
- Evening reminder + **Tinder-style swipe review UI** with "create rule from this transaction" wizard
- Goals tracker
- Per-category budgets with live alerts (warn at 80%, breach at 100%, 110% over)
- Currency conversion via ExchangeRate-API (free tier) — store both bank-converted INR and market-rate INR to surface FX markup

## Categories (V1, fixed)

- Travel
- Food
- Entertainment
- Groceries / Kirana Stores
- Personal Transfer (Peer-to-Peer)
- Investments
- Subscriptions *(SaaS / streaming / Claude / Netflix / etc.)*

## Tags (cross-cutting, not categories)

- `international` — any transaction in non-INR currency, regardless of category
- More tags can be added later (e.g., `business`, `reimbursable`)

## HDFC Email Templates (observed)

Four stable templates from samples. Regex-first parsing per template; Groq is the fallback for any email that doesn't match a known template (and that itself is a signal — log + alert when a new template appears).

| Template | Marker phrase | Direction | Instrument |
|---|---|---|---|
| **A. UPI Credit** | "has been successfully credited to your HDFC Bank account ending in" | IN | Account |
| **B. CC Debit (merchant)** | "has been debited from your HDFC Bank Credit Card ending NNNN towards X" | OUT | Credit Card |
| **C. CC Autopay (E-mandate)** | "set up through E-mandate (Auto payment)" — may include foreign currency `USD X.XX (₹Y.YY)` | OUT | Credit Card |
| **D. UPI Debit** | "has been debited from account NNNN to VPA xxx" | OUT | Account |

Two HDFC credit cards and one account observed: account ending **5264**, cards ending **3328** and **3803**.

## Categorization: Two Parallel Signals

Every new transaction gets two independent reads, then we combine them:

**Signal A — Merchant Identity** (who is the payee really?) → tiered pipeline below.

**Signal B — User Rule Engine** (what is *this* transaction likely to be, based on contextual patterns the user has taught the system?). Rules see the *whole* transaction — amount, time, day-of-week, location, instrument, VPA shape — not just the payee name.

**Combination logic:**
1. If Signal A returns confidence ≥ 0.95 *or* a `merchant_patterns` row exists with hit_count ≥ 3 → auto-tag, skip review.
2. Else surface both signals in the review queue with their confidences. User confirms or overrides; their choice trains `merchant_patterns`.
3. Rules intentionally produce **low confidence (0.4–0.7)** so they suggest rather than autopilot, until the underlying merchant has been confirmed 3× and graduates to auto-tag.

This keeps the user in the loop on uncertain calls while still letting the system get smarter every week.

## User Rule Engine

Rules encode contextual knowledge only the user has. Stored in `user_rules` table, JSONB conditions for flexibility.

**Example rule (the Uber case):**

```json
{
  "name": "Probable cab fare",
  "priority": 100,
  "enabled": true,
  "conditions": {
    "direction": "out",
    "instrument": "upi",
    "amount_between": [200, 350],
    "time_of_day_between": ["08:00", "10:30"],
    "day_of_week": ["Mon", "Tue", "Wed", "Thu", "Fri"],
    "payee_not_in_alias_table": true,
    "vpa_shape": "personal"
  },
  "action": {
    "suggest_category": "Travel",
    "confidence": 0.6
  }
}
```

**Supported conditions (V1):**
- `direction` (in/out)
- `instrument` (account/card_3328/card_3803)
- `amount_between` ([low, high])
- `time_of_day_between` (HH:MM range)
- `day_of_week` (subset of Mon-Sun)
- `payee_matches` (substring/regex)
- `payee_not_in_alias_table` (boolean)
- `vpa_shape` (personal/merchant)
- `location_within_radius` ({lat, lng, meters})

**Killer-feature UX:** "Create a rule from this transaction" button in the review UI. After the user tags a transaction, offer a wizard that pre-fills conditions from the transaction (amount ±20%, time ±1hr, same instrument, same VPA shape) — one tap, rule saved. Reduces rule authoring from "writing JSON" to "confirm a few sliders."

## Merchant Intelligence Pipeline (cost-conscious, tiered)

Each tier runs only if the previous tier returns low confidence. Stop at first high-confidence answer.

| Tier | Source | Cost | Catches |
|---|---|---|---|
| 1 | **Alias table** + routing-prefix strip (`RAZ*`, `PAYU*`, `CCD*`) | Free | Known parents: `BUNDL TECHNOLOGIES`→Swiggy, `ANI TECHNOLOGIES`→Ola, etc. |
| 2 | **VPA shape heuristics** | Free | `q*@ybl`→merchant; `firstname.lastname@oksbi`→P2P |
| 3 | **Groq alone** (Llama 3 8B) with payee + city + amount + time | Free tier | Recognizable national brands; reasoning over name patterns |
| 4 | **Brave Search → Groq synthesis** | Free up to 2000/mo | Local shops, kiranas, lesser-known businesses |
| 5 | **Review queue** | User time | Genuinely ambiguous |

**Pattern learning:** every user confirmation in Tier 5 writes/increments a `merchant_patterns` row keyed on normalized payee. 3+ confirmations → auto-tag forever (skip directly to Tier 0 next time). This is how the review queue shrinks toward zero over weeks.

**Escape hatch:** if Tier 5 grows too noisy, swap in Google Places Nearby Search as Tier 4.5 (single env var, no code change — design the resolver as a tier chain from day one).

**Autopay shortcut:** Template C emails (E-mandate) bypass the pipeline entirely. Extract the noun from "Your X bill" and look up `X` in a small `autopay_aliases` table (Railway→Travel, Claude→Subscriptions, etc.). Never enters review queue.

## Daily Review UX (Tinder-style swipe)

The review queue is the only UI the user touches daily — it must be fast, satisfying, and finishable in ~5 minutes.

**Card stack model.** Each pending transaction is one card. Front of card shows:
- Amount (large, prominent)
- Raw merchant + resolved guess (e.g., "RAJESH KUMAR → Probable cab fare")
- Suggested category with confidence badge
- Time + tiny location chip (or "no location" badge if missed)
- Source signal (alias / rule / Groq) — surfaces *why* the suggestion was made

**Gestures:**
- **Swipe right** → confirm. Card flies off, next card slides up. Brief undo toast (3s) in case of misfire.
- **Swipe left** → reject. Card slides aside, category picker sheet rises with all 8 categories + recent picks at top. Tap one → confirm and advance.
- **Tap card** → detail view: full email body, all extracted fields, location on a mini map, change anything, see which rule matched.
- **Swipe up (or long-press)** → "Create a rule from this" wizard, pre-filled from current transaction.

**Done-for-the-day state.** After last card: a clean summary — "You reviewed 7 transactions, ₹3,420 categorized today." Single CTA: "View this month's spending."

**Stale queue policy.** If a transaction sits unreviewed for 7 days, auto-finalize at the system's best-guess category and mark `auto_finalized = true`. User can still re-tag retroactively from the transactions list. Prevents the queue from growing unbounded if the user skips a few days.

**Empty state.** "All caught up. ✓ ₹X spent so far this month, ₹Y remaining across budgets." — informational, not nagging.

## Budget Alerts

- Per-category monthly budget in `budgets` (`category_id`, `monthly_limit_inr`, `alert_thresholds` default `[0.8, 1.0, 1.1]`)
- After every transaction lands as `resolved`, recompute MTD spend in that category
- If a threshold is crossed *for the first time this month*, fire a push
- Track fired alerts in `budget_alert_fired` (keyed on `month + category_id + threshold`) so each level fires at most once per month — prevents post-breach spam
- Three notification levels: 80% warning, 100% breach, 110% over-budget

## V2 (not now)

- Amazon / merchant receipt matching
- Multi-user (Sneha)
- Native iOS refinements

## Build Status

Total: **96 unit tests passing.** All logic (parser, categorization, Gmail decoders) is offline-testable; no external API key is required to run tests. The pipeline glue, server, and OAuth/watch scripts are real implementations against the live Google APIs — they need GCP credentials at runtime, not at test time.

| Layer | Status | Notes |
|---|---|---|
| HDFC parser — 4 templates | ✅ Done | UPI credit/debit, CC debit, CC autopay; IST date math; paise-precise BigInt |
| Tier 0 — Autopay alias shortcut | ✅ Done | 10 seed mappings (Railway, Claude, Netflix, etc.) |
| Tier 1 — Merchant alias table | ✅ Done | 28 seed aliases; routing-prefix strip (RAZ*, PAYU*, etc.) |
| Tier 2 — VPA shape heuristics | ✅ Done | personal / merchant / unknown |
| Tier 3 — Groq Llama 3.1 8B | ✅ Done | mockable interface + HTTP impl; lenient JSON parser |
| Tier 4 — Brave Search → Groq synthesis | ✅ Done | only fires when Tier 3 < 0.85 confidence |
| User rule engine | ✅ Done | direction, amount, time-of-day, day-of-week, payee, VPA shape, alias-not-matched |
| Combination logic + auto-tag threshold (≥0.95) | ✅ Done | |
| Prisma schema (14 models) | ✅ Done | Postgres 15 (Homebrew); Prisma 6.19 |
| Initial migration applied | ✅ Done | `npm run db:migrate` |
| Seed script (categories, aliases, autopay) | ✅ Done | `npm run db:seed` — idempotent, 7 categories + 36 alias rows |
| Repository layer (client, aliases, userRules, transactions, emailMessages) | ✅ Done | `src/db/` — pure data-access; no business logic |
| `buildCategorizeContextFromDb()` bridge | ✅ Done | Worker reads aliases/rules from DB at request time |
| Smoke test (parse → categorize → upsert) | ✅ Done | `scripts/smoke-pipeline.ts`, idempotent on re-run |
| Pub/Sub push decoder | ✅ Done | `src/gmail/pubsubMessage.ts` + 5 tests |
| Gmail message body extractor (MIME walk + HTML strip + base64url) | ✅ Done | `src/gmail/messageBody.ts` + 15 tests |
| Gmail OAuth helpers (CLI + auth client) | ✅ Done | `src/gmail/oauth.ts`, `scripts/gmail-auth.ts` |
| Gmail watch registration | ✅ Done | `src/gmail/watch.ts`, `scripts/gmail-watch.ts` |
| Gmail history.list + messages.get fetcher | ✅ Done | `src/gmail/history.ts` |
| `processGmailMessage()` end-to-end glue | ✅ Done | parser → categorize → DB, with skip/dup/error outcomes |
| Fastify server (/health + /webhooks/gmail) | ✅ Done | `src/server.ts`; verified hitting Postgres |
| Pub/Sub JWT verification | ✅ Done | falls back to "skip with warning" when audience env var unset |
| FX rate / currency conversion | ⏳ Schema ready | ExchangeRate-API call not yet wired |
| Pattern learning (3× confirmations) | ⏳ Schema ready | needs `merchantPatterns.recordConfirmation()` |
| Budget threshold computation | ⏳ Schema ready | pure-logic step, no infra needed |
| Cron: 7 PM digest, 24 h heartbeat | ❌ Not started | |
| Gmail watch auto-refresh (in-process, every 24h) | ✅ Done | `src/server/cron.ts` |
| Live deployment on Railway | ✅ Done | https://expensify-production.up.railway.app |
| End-to-end live test (real HDFC email → DB row) | ✅ Done | V1 + V2 UPI debit templates both verified on real Gmail |
| iOS app shell (SwiftUI) | ❌ Not started | |
| iOS silent-push location round-trip | ❌ Not started | |
| Tinder-style swipe review UI | ❌ Not started | |
| Budgets + live alerts | ❌ Not started | |
| Goals tracker | ❌ Not started | |
| Railway deployment | ❌ Not started | |

## Local Dev Setup

- **Postgres:** native via Homebrew (`brew services start postgresql@15`). Local DB created with `CREATE USER expense WITH SUPERUSER CREATEDB; CREATE DATABASE expense_solver OWNER expense;`. Connection: `postgresql://expense:expense@127.0.0.1:5432/expense_solver?schema=public` (in `.env`).
- **Migrations:** `npm run db:migrate` (creates a new migration if schema changed) or `npm run db:reset` (wipe + re-migrate + re-seed).
- **Seed:** `npm run db:seed` — idempotent, safe to re-run.
- **Smoke test:** `npx tsx scripts/smoke-pipeline.ts` — runs all 5 sample emails through the full pipeline (parser → DB-backed categorize → upsert).
- **Note on Docker/Colima:** initial attempt used Colima but hit a Prisma↔Colima networking issue (P1010). Native Postgres is the supported path.

## Gmail / Google Cloud Setup (one-time)

This is the manual setup needed before the email pipeline runs against real Gmail. Code is already in place — these are the GCP console clicks to plug it in.

**1. Create a Google Cloud project**
- Go to https://console.cloud.google.com/projectcreate
- Name: anything (e.g. `expense-solver`)
- Note the **Project ID** (you'll use it below)

**2. Enable the APIs**
In the project, enable:
- **Gmail API** — https://console.cloud.google.com/apis/library/gmail.googleapis.com
- **Pub/Sub API** — https://console.cloud.google.com/apis/library/pubsub.googleapis.com

**3. Create a Pub/Sub topic and subscription**
- Topic name: `gmail-inbound`. Topic resource path: `projects/<project-id>/topics/gmail-inbound`
- Grant publish rights to Gmail's service account: in topic permissions, add principal `gmail-api-push@system.gserviceaccount.com` with role `Pub/Sub Publisher`
- Create a **push** subscription named `gmail-inbound-push`
  - Push endpoint: `https://<your-deployed-host>/webhooks/gmail` (Railway URL once deployed)
  - Enable authentication; use a service account; **set audience to your endpoint URL** (e.g. `https://<host>/webhooks/gmail`)
  - Save the audience value into `.env` as `GOOGLE_PUBSUB_VERIFICATION_AUDIENCE`

**4. Configure OAuth consent screen**
- https://console.cloud.google.com/apis/credentials/consent
- User type: **External**, status: **Testing** (good enough for a single-user app)
- Add **Test users**: your Gmail address (the one whose inbox you want to watch)
- Scopes: add `gmail.readonly` and `gmail.metadata`

**5. Create OAuth client credentials**
- https://console.cloud.google.com/apis/credentials → Create Credentials → OAuth client ID
- Type: **Web application**
- Authorized redirect URI: `http://127.0.0.1:5176/oauth2callback`
- Save **Client ID** and **Client Secret** into `.env` as `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET`
- Set `GOOGLE_OAUTH_REDIRECT_URI=http://127.0.0.1:5176/oauth2callback`
- Set `GOOGLE_PUBSUB_TOPIC=projects/<project-id>/topics/gmail-inbound`

**6. Run the one-time auth**
```
npx tsx scripts/gmail-auth.ts   # opens browser, you approve, refresh token saved to DB
npx tsx scripts/gmail-watch.ts  # registers Gmail watch against the Pub/Sub topic
```

**7. Verify**
- Trigger a test transaction (or wait for one)
- HDFC sends email
- Gmail publishes to Pub/Sub
- Pub/Sub pushes to `/webhooks/gmail`
- Server fetches, parses, categorizes, inserts row
- Hit `GET /health` to confirm DB is reachable; then query the `Transaction` table

The Gmail watch expires every 7 days — the cron job will re-register it automatically (built later).

## Locked Decisions

- **Gmail ingestion:** Gmail API → Google Cloud Pub/Sub → webhook on Railway. Near real-time. Watch must be re-registered weekly (Gmail caps at 7 days).
- **Location:** iOS app pings backend with GPS *only when triggered by a transaction email* — backend sends a silent APNs push to the phone, phone wakes, posts location, sleeps. Battery is a hard priority.
- **iOS framework:** Swift / SwiftUI. Direct APNs.
- **Auth (V1):** Single-user, static API token. Gmail OAuth tied to one Google account. Multi-user is a V2 migration.

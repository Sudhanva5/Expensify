# Expense Solver MCP server

Remote MCP server that exposes the Expense Solver Postgres database to Claude (Desktop, Code, web) over Streamable HTTP. Read-only. Single-user, single static token. Deployed alongside the main backend on Railway.

## Tools

| Bucket | Tool | Purpose |
|---|---|---|
| Spend | `list_transactions` | filtered list, newest first; optional `include` for rich blocks |
| Spend | `monthly_summary` | per-category breakdown for one IST month |
| Spend | `top_merchants` | top N merchants by outflow over a range |
| Spend | `total_by_category` | per-category totals over a range |
| Spend | `search_merchant` | fuzzy search merchantNormalized + merchantRaw + vpa; optional `include` |
| Detail | `get_transaction` | single row with all joins: receipts, places, location, fx, email |
| Detail | `recent_receipts` | Swiggy / MMT / redBus receipts with full items + fees + meta |
| Detail | `list_instruments` | distinct accounts + cards seen, with usage counts |
| Detail | `list_tags` | user-created tags + usage counts |
| Detail | `list_goals` | savings goals — name, target, deadline |
| Budgets | `current_budget_status` | MTD spend vs limit, fired thresholds |
| Budgets | `budget_history` | historical threshold firings |
| Rules | `list_user_rules` | rules + JSONB conditions, priority order |
| Rules | `list_vpa_patterns` | learned UPI handle → category bindings |
| Rules | `list_merchant_patterns` | learned merchant name → category bindings |
| Debug | `unparsed_hdfc_emails` | HDFC alerts that didn't match any template |
| Debug | `unbound_receipts` | receipt emails that couldn't bind to a transaction |
| Debug | `recent_email_messages` | every Gmail message the pipeline touched |

All amounts surfaced as INR rupees. All dates IST (Asia/Kolkata). BigInt minor units → Number rupees at the tool boundary.

### The `include` flag

`list_transactions` and `search_merchant` take an optional `include: [...]` array — pass any subset of `"receipt"`, `"places"`, `"location"`, `"fx"`, `"email"` to embed those richer blocks on every transaction in the response. Skip the flag for the lightweight default shape.

`get_transaction(id)` always returns every block — it's the drill-down path after a list/search has surfaced a row of interest.

## Run locally

```bash
MCP_TOKEN=$(openssl rand -hex 24)
echo "MCP_TOKEN=$MCP_TOKEN"          # save this, you'll need it for the client
DATABASE_URL=postgres://...          # same one the main backend uses
PORT=3001 MCP_TOKEN=$MCP_TOKEN npm run start:mcp
```

`GET /health` returns `{ok: true}` immediately. `POST /mcp` is the MCP endpoint; everything else 404s.

## Deploy to Railway (second service in the same project)

```bash
railway add --service Expensify-MCP                                          # in the linked project
railway variables --service Expensify-MCP \
  set DATABASE_URL="$(railway variables --service Expensify --json | jq -r '.DATABASE_URL')" \
  set MCP_TOKEN="$(openssl rand -hex 24)" \
  set LOG_LEVEL=info
# Then in the Railway dashboard set the service's Start Command to:
#   bash scripts/start-mcp.sh
# Healthcheck path: /health
# Generate a public domain for the service — the MCP client will hit this URL.
```

After deploy, verify:

```bash
curl https://<mcp-service>.up.railway.app/health
# → {"ok":true,"service":"mcp","time":"..."}
```

## Connect from a Claude client

### Claude Code

```bash
claude mcp add --transport http expense-solver \
  https://<mcp-service>.up.railway.app/mcp \
  --header "Authorization: Bearer $MCP_TOKEN"
```

Then in any Claude Code session:

```
> what did I spend on Food in June?
> top merchants this month
> show me all unbound Swiggy receipts
```

### Claude Desktop

In `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "expense-solver": {
      "url": "https://<mcp-service>.up.railway.app/mcp",
      "transport": "http",
      "headers": {
        "Authorization": "Bearer <MCP_TOKEN>"
      }
    }
  }
}
```

Restart Claude Desktop. The 13 tools show up under the 🔌 menu.

## Why a separate service (not bundled into the main backend)?

- **Auth model is different** — iOS uses `API_TOKEN`, Claude uses `MCP_TOKEN`. Rotating one shouldn't affect the other.
- **Failure modes are independent** — a slow Claude query that holds open a Streamable HTTP connection shouldn't queue up behind the Gmail webhook.
- **Scaling shape is different** — main backend is bursty (Gmail Pub/Sub), MCP is interactive (one user, sub-second responses expected). Splitting lets each tune CPU/RAM independently.
- **Blast radius** — MCP is exposed at a public URL. Keeping it on its own service means the webhook path doesn't share routes with whatever the LLM dreams up.

## Security notes

- Token in URL or query string: NEVER. Only `Authorization: Bearer` header.
- Tools are read-only by design. Any future write tool (e.g. "tag this transaction") must be a separate write-scoped token rotation, not piggyback on this bearer.
- Postgres credentials never leave Railway. The MCP server holds the Prisma connection; Claude never sees the DSN.

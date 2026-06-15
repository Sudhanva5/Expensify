#!/usr/bin/env bash
# Railway start command for the MCP service.
#
# Unlike the main backend (scripts/start.sh), this service does NOT run
# migrations. The main backend owns the schema; the MCP server is a
# read-only Postgres client. If Postgres is briefly unreachable at boot,
# the server still launches — /health is DB-free and the MCP endpoint
# returns errors per request, which is the right failure mode (Railway
# keeps the service up, Postgres recovers, requests succeed again).

set -uo pipefail

echo "[mcp] Node $(node -v), npm $(npm -v)"
echo "[mcp] launching MCP server"

# exec replaces this shell so SIGTERM from Railway propagates correctly.
exec npm run start:mcp

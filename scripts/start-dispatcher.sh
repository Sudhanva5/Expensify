#!/usr/bin/env bash
# Single Railway startCommand for the whole project — routes to the right
# entrypoint based on which service this container is.
#
# Why: railway.json's startCommand applies to every service that doesn't
# override it. We have two services in the same project (Expensify and
# Expensify-MCP) running the same code with different startup needs. The
# alternatives — per-service overrides via dashboard, env-var overrides
# like RAILWAY_RUN_COMMAND, custom config-file-per-service — are either
# unreliable or require dashboard clicks. A 7-line bash dispatcher is
# self-documenting and stays version-controlled with the code.
#
# RAILWAY_SERVICE_NAME is injected by Railway and is the stable identity.

set -uo pipefail

case "${RAILWAY_SERVICE_NAME:-Expensify}" in
  Expensify-MCP)
    exec bash scripts/start-mcp.sh
    ;;
  *)
    exec bash scripts/start.sh
    ;;
esac

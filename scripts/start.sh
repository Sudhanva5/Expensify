#!/usr/bin/env bash
# Production startup. Best-effort migrate + seed, then ALWAYS start the
# server — even if the DB is briefly unreachable. /health doesn't touch
# the DB so Railway's healthcheck passes regardless, the service stays
# up, and the next deploy (or restart) catches up on migrations.
#
# Why this matters: the previous startCommand chained migrate -> seed ->
# start with `&&`. If migrate failed (Postgres warm-up, transient network
# hiccup), the server never started, healthcheck failed, restart loop
# exhausted, service died. One transient blip → full outage. With this
# script, migrate gets 20 retries × 3s, then we move on no matter what.

set -uo pipefail

echo "[start] Node $(node -v), npm $(npm -v)"

echo "[start] migrate-deploy with retry (up to 60s)..."
for i in $(seq 1 20); do
  if npm run db:migrate:deploy; then
    echo "[start] migrate ok on try $i"
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "[start] migrate gave up after 20 tries — proceeding so /health still answers"
    break
  fi
  echo "[start] migrate retry $i — sleeping 3s..."
  sleep 3
done

echo "[start] seed (best-effort)..."
npm run db:seed || echo "[start] seed failed — continuing"

echo "[start] launching server"
# exec replaces this shell with the node process so SIGTERM from Railway
# propagates to the server (graceful shutdown, not a SIGKILL bath).
exec npm start

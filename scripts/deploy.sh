#!/usr/bin/env bash
# deploy.sh — Full deploy sequence cho APISIX standalone
# Usage: cd /opt/apisix/standalone/sandbox && ./scripts/deploy.sh

set -euo pipefail
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${DEPLOY_DIR}"

echo "═══════════════════════════════════════"
echo " APISIX Standalone — Deploy Sequence"
echo " Deploy dir: ${DEPLOY_DIR}"
echo "═══════════════════════════════════════"

echo ""
echo "▶ [1/3] Patch Lua templates..."
./scripts/1-patch-template-lua.sh

echo ""
echo "▶ [2/3] Decrypt certs..."
./scripts/2-decrypt-certs.sh

echo ""
echo "▶ [3/3] Docker Compose up..."
docker compose up -d --force-recreate

echo ""
echo "✅ Deploy done. Checking health..."
sleep 5
docker compose ps
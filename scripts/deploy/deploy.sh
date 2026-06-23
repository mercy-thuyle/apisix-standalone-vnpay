#!/usr/bin/env bash
# scripts/deploy/deploy.sh
# Full deploy sequence cho APISIX standalone
# Usage: cd /opt/apisix/standalone/sandbox && ./scripts/deploy/deploy.sh
#
# Patch Lua gỡ X-Forwarded-Port khỏi APISIX + Inject certs
# 1. Patch X-Forwarded-Port (chỉ chạy 1 lần hoặc khi upgrade APISIX)
# ./scripts/deploy/1-patch-template-lua.sh
# Output: ngx_tpl.lua + init.lua tại thư mục hiện tại
# 2. Decrypt cert từ gitsync/current/cert/ vào ./cert (chỉ chạy 1 lần hoặc khi đổi cert)
# Sửa YAML= trong script nếu cần
# ./scripts/deploy/2-decrypt-certs.sh
# 3. Inject cert vào apisix-dc1.yaml (chỉ chạy 1 lần hoặc khi đổi cert)
# Sửa YAML= trong script nếu cần
# ./scripts/deploy/3-inject-certs.sh

set -euo pipefail
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${DEPLOY_DIR}"

echo "═══════════════════════════════════════"
echo " APISIX Standalone — Deploy Sequence"
echo " Deploy dir: ${DEPLOY_DIR}"
echo "═══════════════════════════════════════"

echo ""
echo "▶ [1/4] Patch Lua templates..."
./scripts/deploy/1-patch-template-lua.sh

echo ""
echo "▶ [2/4] Decrypt certs..."
./scripts/deploy/2-decrypt-certs.sh

echo ""
echo "▶ [3/4] Inject certs..."
./scripts/deploy/3-inject-certs.sh

echo ""
echo "▶ [3/4] Docker Compose up..."
docker compose up -d --force-recreate

echo ""
echo "✅ Deploy done. Checking health..."
sleep 5
docker compose ps

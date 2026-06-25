#!/usr/bin/env bash
# scripts/deploy/1-patch-template-lua.sh
# Gỡ X-Forwarded-Port khỏi APISIX:
#   1. ngx_tpl.lua    — nginx template (proxy_set_header)
#   2. init.lua       — Lua core (set_upstream_headers / upstream_proxy_headers)
# Cloudian HyperStore dùng X-Forwarded-Port trong S3v4 signature → mismatch.
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     ./scripts/1-patch-template-lua.sh
#
### Workflow khi upgrade version APISIX
# 1. Chạy lại patch với image mới
# IMAGE="apache/apisix:3.15.0-debian" bash ./scripts/1-patch-template-lua.sh
# 2. Verify diff đúng
# diff ngx_tpl.lua.orig ngx_tpl.lua
# 3. Copy 2 file mới vào sandbox
# cp ngx_tpl.lua /opt/apisix/standalone/sandbox/
# cp init.lua /opt/apisix/standalone/sandbox/
# 4. Đổi image tag trong docker-compose.yaml
# 5. docker compose up -d --force-recreate

set -euo pipefail

IMAGE="apache/apisix:3.15.0-debian"
TPL="/usr/local/apisix/apisix/cli/ngx_tpl.lua"
INIT="/usr/local/apisix/apisix/init.lua"

# ── Output vào $PWD (nơi caller đang đứng) ───────────────────────────────
# Dùng BASH_SOURCE để resolve đúng dù gọi từ bất kỳ $PWD nào
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "📂 Deploy dir: ${DEPLOY_DIR}"
echo "   (nên là /opt/apisix/standalone/<env>)"
echo ""

# ── 1. Patch ngx_tpl.lua ──────────────────────────────────────────────────
echo "▶ [1/2] Patch ngx_tpl.lua — xóa proxy_set_header X-Forwarded-Port..."
docker run --rm "${IMAGE}" cat "${TPL}" > "${DEPLOY_DIR}/ngx_tpl.lua.orig"
grep -v 'proxy_set_header.*X-Forwarded-Port' "${DEPLOY_DIR}/ngx_tpl.lua.orig" > "${DEPLOY_DIR}/ngx_tpl.lua"
echo "  diff:"
diff "${DEPLOY_DIR}/ngx_tpl.lua.orig" "${DEPLOY_DIR}/ngx_tpl.lua" || true

# ── 2. Patch init.lua ─────────────────────────────────────────────────────
echo ""
echo "▶ [2/2] Patch init.lua — xóa var_x_forwarded_port khỏi upstream_proxy_headers..."
docker run --rm "${IMAGE}" cat "${INIT}" > "${DEPLOY_DIR}/init.lua.orig"
# Xóa dòng set_header X-Forwarded-Port (APISIX 3.16: core.request.set_header)
# Khớp cả 2 pattern: bảng upstream_proxy_headers VÀ set_header trực tiếp
grep -v 'set_header(api_ctx, "X-Forwarded-Port"' "${DEPLOY_DIR}/init.lua.orig" \
  | grep -v "var_x_forwarded_port.*=.*'X-Forwarded-Port'" > "${DEPLOY_DIR}/init.lua"
echo "  diff:"
diff "${DEPLOY_DIR}/init.lua.orig" "${DEPLOY_DIR}/init.lua" || true

# ── 3. Patch vault.lua — KV v2 support ───────────────────────────────────
echo ""
echo "▶ [3/3] Patch vault.lua — Vault KV v2 support..."
docker run --rm "${IMAGE}" cat "${VAULT}" > "${DEPLOY_DIR}/vault.lua.orig"
cp "${DEPLOY_DIR}/vault.lua.orig" "${DEPLOY_DIR}/vault.lua"

# Patch 1: thêm /data/ vào path — match pattern chính xác từ file gốc
sed -i 's|.. conf.prefix .. "/" .. key)|.. conf.prefix .. "/data/" .. key)|' \
    "${DEPLOY_DIR}/vault.lua"

# Patch 2a: check condition thêm ret.data.data
sed -i 's|if not ret or not ret.data then|if not ret or not ret.data or not ret.data.data then|' \
    "${DEPLOY_DIR}/vault.lua"

# Patch 2b: extract từ ret.data.data thay vì ret.data
sed -i 's|return ret.data\[sub_key\]|return ret.data.data[sub_key]|' \
    "${DEPLOY_DIR}/vault.lua"

# Verify
echo "  diff:"
diff "${DEPLOY_DIR}/vault.lua.orig" "${DEPLOY_DIR}/vault.lua" || true

PATCH_OK=0
grep -q '"/data/"' "${DEPLOY_DIR}/vault.lua"          && echo "  ✅ path /data/: OK"          || { echo "  ❌ path /data/: FAILED";          PATCH_OK=1; }
grep -q 'ret.data.data then' "${DEPLOY_DIR}/vault.lua" && echo "  ✅ check ret.data.data: OK"  || { echo "  ❌ check ret.data.data: FAILED";  PATCH_OK=1; }
grep -q 'ret.data.data\[' "${DEPLOY_DIR}/vault.lua"   && echo "  ✅ return ret.data.data: OK" || { echo "  ❌ return ret.data.data: FAILED"; PATCH_OK=1; }

[ "${PATCH_OK}" -eq 0 ] || exit 1

echo ""
echo "✅ Đã tạo file patch tại: ${DEPLOY_DIR}"
echo "   ngx_tpl.lua  ngx_tpl.lua.orig"
echo "   init.lua     init.lua.orig"
echo ""
echo "▶ docker-compose volumes cần có:"
echo '      - ./ngx_tpl.lua:/usr/local/apisix/apisix/cli/ngx_tpl.lua:ro'
echo '      - ./init.lua:/usr/local/apisix/apisix/init.lua:ro'
echo ""
echo "▶ docker compose up -d --force-recreate"

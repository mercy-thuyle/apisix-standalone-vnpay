#!/usr/bin/env bash
# patch-template.sh
# Gỡ X-Forwarded-Port khỏi APISIX:
#   1. ngx_tpl.lua    — nginx template (proxy_set_header)
#   2. init.lua       — Lua core (set_upstream_headers / upstream_proxy_headers)
# Cloudian HyperStore dùng X-Forwarded-Port trong S3v4 signature → mismatch.

### Workflow khi upgrade version APISIX
# 1. Chạy lại patch với image mới
# IMAGE="apache/apisix:3.15.0-debian" bash patch-template.sh
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

# ── 1. Patch ngx_tpl.lua ──────────────────────────────────────────────────
echo "▶ [1/2] Patch ngx_tpl.lua — xóa proxy_set_header X-Forwarded-Port..."
docker run --rm "${IMAGE}" cat "${TPL}" > ngx_tpl.lua.orig
grep -v 'proxy_set_header.*X-Forwarded-Port' ngx_tpl.lua.orig > ngx_tpl.lua
echo "  diff:"
diff ngx_tpl.lua.orig ngx_tpl.lua || true

# ── 2. Patch init.lua ─────────────────────────────────────────────────────
echo ""
echo "▶ [2/2] Patch init.lua — xóa var_x_forwarded_port khỏi upstream_proxy_headers..."
docker run --rm "${IMAGE}" cat "${INIT}" > init.lua.orig
# Xóa dòng set_header X-Forwarded-Port (APISIX 3.16: core.request.set_header)
# Khớp cả 2 pattern: bảng upstream_proxy_headers VÀ set_header trực tiếp
grep -v 'set_header(api_ctx, "X-Forwarded-Port"' init.lua.orig \
  | grep -v "var_x_forwarded_port.*=.*'X-Forwarded-Port'" > init.lua
echo "  diff:"
diff init.lua.orig init.lua || true

echo ""
echo "✅ Đã tạo ngx_tpl.lua + init.lua (đã patch)"
echo ""
echo "▶ docker-compose volumes cần có:"
echo '      - ./ngx_tpl.lua:/usr/local/apisix/apisix/cli/ngx_tpl.lua:ro'
echo '      - ./init.lua:/usr/local/apisix/apisix/init.lua:ro'
echo ""
echo "▶ docker compose up -d --force-recreate"

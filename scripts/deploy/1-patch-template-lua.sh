#!/usr/bin/env bash
# scripts/deploy/1-patch-template-lua.sh
#
# Patch 4 file APISIX core để fix hành vi không mong muốn:
#   1. ngx_tpl.lua      — xóa proxy_set_header X-Forwarded-Port
#   2. init.lua         — xóa var_x_forwarded_port khỏi upstream_proxy_headers
#   3. vault.lua        — KV v2 support (thêm /data/ vào path)
#   4. config_yaml.lua  — đổi warn message "reloaded" thành rõ ràng hơn
#
# Lý do patch từng file:
#   [1][2] Cloudian HyperStore dùng X-Forwarded-Port trong S3v4 signature
#          → mismatch nếu để nguyên → signature verification fail.
#          Gỡ X-Forwarded-Port khỏi APISIX:
#               1. ngx_tpl.lua    — nginx template (proxy_set_header)
#               2. init.lua       — Lua core (set_upstream_headers / upstream_proxy_headers)
#          Cloudian HyperStore dùng X-Forwarded-Port trong S3v4 signature → mismatch.
#
#   [3]    APISIX default dùng Vault KV v1 path (/prefix/key), Vault team
#          dùng KV v2 (/prefix/data/key) → secret không đọc được nếu không patch.
#
#   [4]    Dòng log "config file ... reloaded." của APISIX core dùng level [warn]
#          nhưng không có context → người đọc log không biết đây là hot-reload bình
#          thường từ gitsync hay có vấn đề gì. Patch thêm context + hướng dẫn verify.
#          ⚠ Đây là patch THẨM MỸ (không ảnh hưởng hành vi chức năng) — nếu không
#          muốn maintain qua mỗi lần upgrade, có thể bỏ qua patch [4] và dùng
#          logs/gitsync/gitsync.log để đối chiếu thay thế (xem gitsync.sh).
#

#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     bash ./scripts/deploy/1-patch-template-lua.sh
#
### Workflow khi upgrade version APISIX
# 1. Chạy lại patch với image mới
#       IMAGE="apache/apisix:3.15.0-debian" bash ./scripts/1-patch-template-lua.sh
# hoặc Đổi IMAGE= bên dưới sang tag mới
# 2. Verify diff đúng — đặc biệt patch [4] nhạy cảm với line number thay đổi:
#       diff ngx_tpl.lua.orig ngx_tpl.lua
#       diff config_yaml.lua.orig config_yaml.lua
# 3. Copy 2 file mới vào sandbox
# cp ngx_tpl.lua /opt/apisix/standalone/sandbox/
# cp init.lua /opt/apisix/standalone/sandbox/
# 4. Đổi image tag trong docker-compose.yaml
# 5. docker compose up -d --force-recreate
#
#   ⚠ Nếu patch [4] fail (sed không tìm thấy đúng pattern) → script exit 1,
#     kiểm tra lại dòng warn trong config_yaml.lua.orig rồi cập nhật sed pattern.
# ============================================================================

set -euo pipefail

IMAGE="apache/apisix:3.15.0-debian"
TPL="/usr/local/apisix/apisix/cli/ngx_tpl.lua"
INIT="/usr/local/apisix/apisix/init.lua"
VAULT="/usr/local/apisix/apisix/secret/vault.lua"
CONFIG_YAML="/usr/local/apisix/apisix/core/config_yaml.lua"

# ── Output vào $PWD (nơi caller đang đứng) ───────────────────────────────
# Dùng BASH_SOURCE để resolve đúng dù gọi từ bất kỳ $PWD nào
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "📂 Deploy dir: ${DEPLOY_DIR}"
echo "   (nên là /opt/apisix/standalone/<env>)"
echo ""

# ── 1. Patch ngx_tpl.lua ──────────────────────────────────────────────────
echo "▶ [1/4] Patch ngx_tpl.lua — xóa proxy_set_header X-Forwarded-Port..."
docker run --rm "${IMAGE}" cat "${TPL}" > "${DEPLOY_DIR}/ngx_tpl.lua.orig"
grep -v 'proxy_set_header.*X-Forwarded-Port' "${DEPLOY_DIR}/ngx_tpl.lua.orig" > "${DEPLOY_DIR}/ngx_tpl.lua"
echo "  diff:"
diff "${DEPLOY_DIR}/ngx_tpl.lua.orig" "${DEPLOY_DIR}/ngx_tpl.lua" || true

# ── 2. Patch init.lua ─────────────────────────────────────────────────────
echo ""
echo "▶ [2/4] Patch init.lua — xóa var_x_forwarded_port khỏi upstream_proxy_headers..."
docker run --rm "${IMAGE}" cat "${INIT}" > "${DEPLOY_DIR}/init.lua.orig"
# Xóa dòng set_header X-Forwarded-Port (APISIX 3.16: core.request.set_header)
# Khớp cả 2 pattern: bảng upstream_proxy_headers VÀ set_header trực tiếp
grep -v 'set_header(api_ctx, "X-Forwarded-Port"' "${DEPLOY_DIR}/init.lua.orig" \
  | grep -v "var_x_forwarded_port.*=.*'X-Forwarded-Port'" > "${DEPLOY_DIR}/init.lua"
echo "  diff:"
diff "${DEPLOY_DIR}/init.lua.orig" "${DEPLOY_DIR}/init.lua" || true

# ── 3. Patch vault.lua — KV v2 support ───────────────────────────────────
echo ""
echo "▶ [3/4] Patch vault.lua — Vault KV v2 support... (thêm /data/ vào path)..."
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

# ── 4. Patch config_yaml.lua — warn message rõ ràng hơn ──────────────────
echo ""
echo "▶ [4/4] Patch config_yaml.lua — thêm context vào warn message 'reloaded'..."
echo "  ⚠ Đây là patch thẩm mỹ (không ảnh hưởng chức năng)."
echo "  ⚠ Nhạy cảm với thay đổi source code qua mỗi version — verify diff kỹ."
docker run --rm "${IMAGE}" cat "${CONFIG_YAML}" > "${DEPLOY_DIR}/config_yaml.lua.orig"
cp "${DEPLOY_DIR}/config_yaml.lua.orig" "${DEPLOY_DIR}/config_yaml.lua"

# Pattern gốc (đã verify trên container 3.15.0-debian):
#   log.warn("config file ", config_file.path, " reloaded.")
#
# Đổi thành message rõ context hơn:
#   - Ghi rõ đây là hot-reload từ gitsync (routes/services/upstreams), bình thường
#   - Nhắc rõ config.yaml KHÔNG được reload theo (cần restart container)
#   - Kèm command để verify nếu nghi ngờ
#   - Giữ nguyên level warn — không đổi thành info để không ảnh hưởng log filter
sed -i \
  's|log.warn("config file ", config_file.path, " reloaded.")|log.warn("config file ", config_file.path, " hot-reloaded by gitsync (routes/services/upstreams only -- config.yaml NOT reloaded, requires container restart). Verify: docker logs gitsync --tail 20")|' \
  "${DEPLOY_DIR}/config_yaml.lua"

echo "  diff:"
diff "${DEPLOY_DIR}/config_yaml.lua.orig" "${DEPLOY_DIR}/config_yaml.lua" || true

# Verify patch [4] áp dụng đúng
if grep -q 'hot-reloaded by gitsync' "${DEPLOY_DIR}/config_yaml.lua"; then
  echo "  ✅ config_yaml.lua warn message: OK"
else
  echo "  ❌ config_yaml.lua warn message: FAILED"
  echo "     Pattern gốc có thể đã thay đổi trong version này."
  echo "     Kiểm tra lại:"
  echo "       docker run --rm ${IMAGE} grep -n 'reloaded' ${CONFIG_YAML}"
  echo "     Rồi cập nhật sed pattern trong script này."
  exit 1
fi

# ── Tổng kết ──────────────────────────────────────────────────────────────
echo ""
echo "✅ Đã tạo 4 file patch tại: ${DEPLOY_DIR}"
echo "   ngx_tpl.lua      ngx_tpl.lua.orig"
echo "   init.lua         init.lua.orig"
echo "   vault.lua        vault.lua.orig"
echo "   config_yaml.lua  config_yaml.lua.orig"
echo ""
echo "▶ docker-compose volumes cần thêm (so với bản gốc — chỉ [4] là mới):"
echo '      - ./ngx_tpl.lua:/usr/local/apisix/apisix/cli/ngx_tpl.lua:ro'
echo '      - ./init.lua:/usr/local/apisix/apisix/init.lua:ro'
echo '      - ./vault.lua:/usr/local/apisix/apisix/secret/vault.lua:ro'
echo '      - ./config_yaml.lua:/usr/local/apisix/apisix/core/config_yaml.lua:ro'
echo ""
echo "▶ Sau khi thêm volume mount, áp dụng:"
echo "      docker compose up -d --force-recreate apisix-standalone"
echo ""
echo "▶ Verify warn message mới (sau khi gitsync pull lần đầu):"
echo "      docker logs apisix-standalone --tail 20 | grep 'hot-reloaded'"

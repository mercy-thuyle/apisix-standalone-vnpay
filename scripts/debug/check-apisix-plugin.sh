#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# check-apisix-plugins.sh
#
# Mục đích: Lấy CHÍNH XÁC danh sách plugin built-in của APISIX trực tiếp từ
# container đang chạy (nguồn duy nhất đáng tin — không dựa vào tài liệu/
# search snippet có thể lỗi thời hoặc sai version).
#
# Dùng khi:
#   - Sau mỗi lần update image APISIX lên version mới
#   - Muốn biết plugin nào MỚI xuất hiện / plugin nào bị DEPRECATE/XOÁ
#     so với danh sách đang khai trong config-hcm.yaml / config-hni.yaml
#
# Usage:
#   ./check-apisix-plugins.sh <container_name> [path_to_config_yaml]
#
# Ví dụ:
#   ./check-apisix-plugins.sh apisix-standalone apisix_config/config-hcm.yaml
# ═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

CONTAINER="${1:?Usage: $0 <container_name> [path_to_config_yaml]}"
CONFIG_FILE="${2:-}"

CONFIG_LUA_PATH="/usr/local/apisix/apisix/cli/config.lua"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "════════════════════════════════════════════════════════════════"
echo " APISIX Plugin Audit — container: ${CONTAINER}"
echo "════════════════════════════════════════════════════════════════"

# ── Bước 1: Xác nhận container đang chạy ───────────────────────────────────
if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
    echo "❌ ERROR: Container '${CONTAINER}' không tồn tại hoặc không chạy."
    exit 1
fi

# ── Bước 2: Lấy version APISIX đang chạy (để ghi log, tránh nhầm lẫn version) ──
APISIX_VERSION=$(docker exec "${CONTAINER}" /usr/local/openresty/luajit/bin/luajit \
    /usr/local/apisix/apisix/cli/apisix.lua version 2>/dev/null || echo "unknown")
echo "APISIX version: ${APISIX_VERSION}"
echo ""

# ── Bước 3: Verify đúng path config.lua tồn tại (path có thể đổi giữa các
#    version/cách build image khác nhau — tự dò nếu path mặc định không có) ──
if ! docker exec "${CONTAINER}" test -f "${CONFIG_LUA_PATH}"; then
    echo "⚠ Không tìm thấy ${CONFIG_LUA_PATH}, đang dò đường dẫn khác..."
    FOUND_PATH=$(docker exec "${CONTAINER}" find /usr/local/apisix -name "config.lua" -path "*cli*" 2>/dev/null | head -1)
    if [ -z "${FOUND_PATH}" ]; then
        echo "❌ ERROR: Không tìm thấy file config.lua nào trong container."
        exit 1
    fi
    CONFIG_LUA_PATH="${FOUND_PATH}"
    echo "→ Dùng path: ${CONFIG_LUA_PATH}"
fi
echo ""

# ── Bước 4: Extract danh sách plugin HTTP (block "plugins = { ... }") ──────
# Lấy từ dòng "plugins = {" tới dòng "}" đóng đầu tiên (không lấy nhầm các
# block con phía sau như plugin_attr).
docker exec "${CONTAINER}" awk '
    /^\s*plugins\s*=\s*\{/ { flag=1; next }
    flag && /^\s*\}/ { flag=0 }
    flag { print }
' "${CONFIG_LUA_PATH}" > "${TMP_DIR}/raw_plugins.txt"

# Parse ra tên plugin sạch: bỏ dấu ",", dấu nháy, dòng comment Lua ("--"),
# dòng rỗng, và annotation "deprecated" bị comment.
grep -v '^\s*--' "${TMP_DIR}/raw_plugins.txt" \
    | grep -oP '"\K[^"]+(?=")' \
    | sort -u > "${TMP_DIR}/live_plugins.txt"

LIVE_COUNT=$(wc -l < "${TMP_DIR}/live_plugins.txt")
echo "── Plugin built-in đang có trong image (${LIVE_COUNT} plugin) ──"
cat "${TMP_DIR}/live_plugins.txt"
echo ""

# ── Bước 5: Cảnh báo riêng các plugin bị comment/deprecated trong source ───
DEPRECATED=$(grep -oP '^\s*--\s*"\K[^"]+(?=")' "${TMP_DIR}/raw_plugins.txt" || true)
if [ -n "${DEPRECATED}" ]; then
    echo "── ⚠ Plugin bị comment/deprecated trong source (KHÔNG nên dùng) ──"
    echo "${DEPRECATED}"
    echo ""
fi

# ── Bước 6: Nếu có truyền config file, so sánh diff với danh sách đang khai ─
if [ -n "${CONFIG_FILE}" ]; then
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "⚠ WARN: Không tìm thấy file ${CONFIG_FILE}, bỏ qua bước so sánh."
    else
        echo "════════════════════════════════════════════════════════════════"
        echo " So sánh với: ${CONFIG_FILE}"
        echo "════════════════════════════════════════════════════════════════"

        # Extract danh sách plugin đang khai trong config-hcm.yaml
        # (chỉ lấy dòng dạng "  - plugin-name" nằm trong block "plugins:")
        awk '
            /^plugins:/ { flag=1; next }
            flag && /^[a-zA-Z]/ { flag=0 }
            flag && /^\s*-\s*[a-zA-Z0-9_.-]+/ { print }
        ' "${CONFIG_FILE}" \
            | sed -E 's/^\s*-\s*//; s/\s*#.*//' \
            | grep -v '^\s*$' \
            | sort -u > "${TMP_DIR}/configured_plugins.txt"

        CONFIGURED_COUNT=$(wc -l < "${TMP_DIR}/configured_plugins.txt")
        echo "Plugin đang khai trong config: ${CONFIGURED_COUNT}"
        echo ""

        # Plugin MỚI xuất hiện trong image nhưng CHƯA khai trong config
        # (loại trừ custom.* vì đó là plugin riêng, không thuộc built-in)
        echo "── 🆕 Plugin CÓ trong image nhưng CHƯA khai trong config ──"
        comm -23 "${TMP_DIR}/live_plugins.txt" "${TMP_DIR}/configured_plugins.txt" \
            | grep -v '^custom\.' || echo "  (không có — đã khai đủ)"
        echo ""

        # Plugin đang khai trong config nhưng KHÔNG còn tồn tại trong image
        # (dấu hiệu bị xoá ở version mới — cần xử lý ngay, route dùng plugin
        # này sẽ lỗi sau khi restart với image mới)
        echo "── ❌ Plugin đang khai trong config nhưng KHÔNG CÒN trong image ──"
        echo "     (CẢNH BÁO: route/service dùng plugin này sẽ lỗi sau restart)"
        comm -13 "${TMP_DIR}/live_plugins.txt" "${TMP_DIR}/configured_plugins.txt" \
            | grep -v '^custom\.' || echo "  (không có — an toàn)"
        echo ""
    fi
fi

echo "════════════════════════════════════════════════════════════════"
echo " Hoàn tất. Kết quả đầy đủ tại: ${TMP_DIR}"
echo " (thư mục tạm sẽ tự xoá khi thoát script — copy lại nếu cần lưu)"
echo "════════════════════════════════════════════════════════════════"
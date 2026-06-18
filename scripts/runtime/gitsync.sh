#!/bin/sh
# =============================================================================
# scripts/runtim/gitsync.sh
# APISIX Standalone GitSync exechook test
#
# Được git-sync container gọi tự động sau mỗi lần repo sync thành công.
# GITSYNC_EXECHOOK_COMMAND=/tmp/scripts/runtime/gitsync.sh
#
# Thứ tự thực thi:
#   1. merge fragments      → ./apisix_routes/apisix-${DC_PROFILE}.yaml
#   1a. Detect layout của apisix_routes/ trong repo
#   1b. Layout fragments (upstreams/ routes/ ssls/) → gọi merge-fragments.sh
#   2. cp plugins/          → ./plugins/
#   3. cp scripts/          → ./scripts/
#   4. cp apisix_config/  → ./apisix_config/   ← comment, admin quản lý tay
#
# NOTES:
#     ./scripts → /tmp/scripts, git-sync tự sync repo về gitsync/current/
#     scripts mới có hiệu lực ngay lần trigger tiếp theo qua volume mount
#   - Không dùng find — git-sync container không có find
#   - Nếu merge-fragments.sh exit 1 → KHÔNG ghi output → APISIX dùng file hiện tại
#   - DC_PROFILE đến từ .env (dc1 | dc2 | ...)
# =============================================================================

set -eu

SYNC_SRC="/tmp/sync/current"
ROUTES_SRC="${SYNC_SRC}/apisix_routes"
OUTPUT="/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"
MERGE_SCRIPT="/tmp/scripts/runtime/merge-fragments.sh"

# ── Kiểm tra DC_PROFILE ──────────────────────────────────────────────────────
if [ -z "${DC_PROFILE:-}" ]; then
  echo "[gitsync] ERROR: DC_PROFILE chưa được set trong .env" >&2
  exit 1
fi

echo "[gitsync] START — DC_PROFILE=${DC_PROFILE}"

# ── 1. Merge fragments → apisix-${DC_PROFILE}.yaml ───────────────────────────
if [ -d "${ROUTES_SRC}/upstreams" ] && \
   [ -d "${ROUTES_SRC}/routes" ]   && \
   [ -d "${ROUTES_SRC}/ssls" ]; then

  # ── Layout fragments: merge từ entity files ───────────────────────────────
  echo "[gitsync] Layout: fragments (upstreams/ routes/ ssls/)"

  if [ ! -x "${MERGE_SCRIPT}" ]; then
    echo "[gitsync] ERROR: ${MERGE_SCRIPT} không tồn tại hoặc không executable" >&2
    exit 1
  fi

  # Chạy merge — exit 1 → giữ nguyên output cũ, APISIX không bị ảnh hưởng
  if ! "${MERGE_SCRIPT}" "${ROUTES_SRC}" "${OUTPUT}"; then
    echo "[gitsync] ERROR: merge-fragments.sh thất bại — output không thay đổi" >&2
    exit 1
  fi

  # Cert placeholder còn → nhắc admin inject
  if grep -q "PASTE_CONTENT" "${OUTPUT}" 2>/dev/null; then
    echo "[gitsync] INFO: Output còn PASTE_CONTENT placeholder — cần chạy scripts/deploy/3-inject-certs.sh"
  fi

elif [ -f "${ROUTES_SRC}/apisix-${DC_PROFILE}.yaml" ]; then

  # ── Layout legacy: copy trực tiếp file monolithic ────────────────────────
  echo "[gitsync] Layout: legacy (apisix-${DC_PROFILE}.yaml)"
  SRC_FILE="${ROUTES_SRC}/apisix-${DC_PROFILE}.yaml"

  if grep -q "PASTE_CONTENT" "${OUTPUT}" 2>/dev/null; then
    cp "${SRC_FILE}" "${OUTPUT}"
    echo "[gitsync] Routes updated (cert placeholder còn — cần chạy scripts/deploy/3-inject-certs.sh)"
  elif ! diff -q "${SRC_FILE}" "${OUTPUT}" > /dev/null 2>&1; then
    cp "${SRC_FILE}" "${OUTPUT}"
    echo "[gitsync] WARNING: Route template thay đổi — cần chạy lại scripts/deploy/3-inject-certs.sh"
  else
    echo "[gitsync] Routes không thay đổi, bỏ qua"
  fi

else
  echo "[gitsync] ERROR: Không tìm thấy layout hợp lệ trong ${ROUTES_SRC}" >&2
  echo "[gitsync]   Cần:  upstreams/ + routes/ + ssls/  (fragments)" >&2
  echo "[gitsync]   Hoặc: apisix-${DC_PROFILE}.yaml     (legacy)" >&2
  exit 1
fi

# ── 2. Sync plugins/ ──────────────────────────────────────────────────────────
echo "[gitsync] Syncing plugins/..."
if [ -d "${SYNC_SRC}/plugins" ]; then
  cp -r "${SYNC_SRC}/plugins/." "/tmp/plugins/"
  echo "[gitsync] plugins/ synced"
else
  echo "[gitsync] WARN: ${SYNC_SRC}/plugins/ không tồn tại, bỏ qua" >&2
fi

# ── 3. Sync scripts/ ──────────────────────────────────────────────────────────
echo "[gitsync] Syncing scripts/..."
if [ -d "${SYNC_SRC}/scripts" ]; then
  cp -r "${SYNC_SRC}/scripts/." "/tmp/scripts/"
  echo "[gitsync] scripts/ synced"
else
  echo "[gitsync] WARN: ${SYNC_SRC}/scripts/ không tồn tại, bỏ qua" >&2
fi

# # ── 4. Sync apisix_config/ ─────────────────────────────────────────────────
# Tắt — admin quản lý tay. Bỏ comment khi muốn auto sync.
# echo "[gitsync] Syncing apisix_config/..."
# if [ -d "${SYNC_SRC}/apisix_config" ]; then
#   cp -r "${SYNC_SRC}/apisix_config/." "/tmp/apisix_config/"
#   echo "[gitsync] apisix_config/ synced — cần restart APISIX để apply"
# else
#   echo "[gitsync] WARN: ${SYNC_SRC}/apisix_config/ không tồn tại, bỏ qua" >&2
# fi

# # ── docker-compose ─────────────────────────────────────────────────
# # cp ${SYNC_SRC}docker-compose.yaml /tmp/docker-compose.yaml

# # ── Certs ──────────────────────────────────────────────────
# Chỉ sync .cert (plaintext public) và .key.enc (encrypted private key)
# KHÔNG sync .key (plaintext private key — không tồn tại trong repo)
# certs — gitsync tự quản trong /tmp/sync/current/certs/
# 2-decrypt-certs.sh đọc thẳng từ đó, không cần copy ra ngoài

echo "[gitsync] DONE"
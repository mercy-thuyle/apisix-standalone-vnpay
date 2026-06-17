#!/bin/sh
# =============================================================================
# scripts/runtim/gitsync.sh
# APISIX Standalone GitSync exechook
#
# Được git-sync gọi sau mỗi lần repo sync thành công.
# Thứ tự:
#   1. Detect fragment được commit
#   2. Nếu là các file fragments → chạy merge-routes.sh
#      Nếu file apisix.yaml       → copy trực tiếp apisix-${DC_PROFILE}.yaml
#   3. Self-update scripts
#
# Nếu merge-routes.sh exit 1 → KHÔNG ghi output → APISIX dùng file hiện tại
# DC_PROFILE đến từ .env (dc1 | dc2 | ...)
# =============================================================================

set -eu

SYNC_SRC="/tmp/sync/current"

# ── Kiểm tra DC_PROFILE ──────────────────────────────────────────────────────
if [ -z "${DC_PROFILE:-}" ]; then
  echo "[gitsync] ERROR: DC_PROFILE chưa được set trong .env" >&2
  exit 1
fi

echo "[gitsync] START — DC_PROFILE=${DC_PROFILE}"

# ── Detect fragment ─────────────────────────────────────────────────────────────
if [ -d "${SYNC_SRC}/apisix_routes/upstreams" ] && \
   [ -d "${SYNC_SRC}/apisix_routes/routes" ]   && \
   [ -d "${SYNC_SRC}/apisix_routes/ssls" ]; then

  # ── Merge từ entity files ───────────────────────────────────
  echo "[gitsync] Layout: phương án 3 (upstreams/ routes/ ssls/)"

  if [ ! -x "/tmp/scripts/merge-routes.sh" ]; then
    echo "[gitsync] ERROR: /tmp/scripts/merge-routes.sh không tồn tại hoặc không executable" >&2
    exit 1
  fi

  # Chạy merge — nếu fail thì gitsync cũng fail, giữ nguyên output cũ
  if ! "/tmp/scripts/merge-routes.sh" "${SYNC_SRC}/apisix_routes" "/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"; then
    echo "[gitsync] ERROR: merge-routes.sh thất bại — output không thay đổi" >&2
    exit 1
  fi

  # Info: cert placeholder còn không?
  if grep -q "PASTE_CONTENT" "/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml" 2>/dev/null; then
    echo "[gitsync] INFO: Output còn PASTE_CONTENT placeholder — cần chạy 3-inject-certs.sh"
  fi

elif [ -f "${SYNC_SRC}/apisix_routes/apisix-${DC_PROFILE}.yaml" ]; then

  # ── Legacy: copy trực tiếp file monolithic ───────────────────────────────
  echo "[gitsync] Layout: legacy (apisix-${DC_PROFILE}.yaml)"
  SRC_FILE="${SYNC_SRC}/apisix_routes/apisix-${DC_PROFILE}.yaml"

  if grep -q "PASTE_CONTENT" "/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml" 2>/dev/null; then
    cp "${SRC_FILE}" "/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"
    echo "[gitsync] Routes updated (cert placeholder còn — cần inject)"
  elif ! diff -q "${SRC_FILE}" "/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml" > /dev/null 2>&1; then
    cp "${SRC_FILE}" "/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"
    echo "[gitsync] WARNING: Route template thay đổi — cần chạy lại 3-inject-certs.sh"
  else
    echo "[gitsync] Routes không thay đổi, bỏ qua"
  fi

else
  echo "[gitsync] ERROR: Không tìm thấy layout hợp lệ trong ${SYNC_SRC}/apisix_routes" >&2
  echo "[gitsync]   Cần:  upstreams/ + routes/ + ssls/  (phương án 3)" >&2
  echo "[gitsync]   Hoặc: apisix-${DC_PROFILE}.yaml     (legacy)" >&2
  exit 1
fi

# ── Self-update scripts ───────────────────────────────────────────────────────
for script in gitsync.sh merge-routes.sh; do
  SRC_SCRIPT="${SYNC_SRC}/scripts/runtime/${script}"      # ← repo: scripts/runtime/
  DST_SCRIPT="/tmp/scripts/runtime/${script}"             # ← container: /tmp/scripts/runtime/
  if [ -f "${SRC_SCRIPT}" ]; then
    cp "${SRC_SCRIPT}" "${DST_SCRIPT}"
    chmod +x "${DST_SCRIPT}"
  fi
done
echo "[gitsync] Scripts synced"

echo "[gitsync] DONE"


# # ── docker-compose ─────────────────────────────────────────────────
# # cp ${SYNC_SRC}docker-compose.yaml /tmp/docker-compose.yaml

# # ── Config ─────────────────────────────────────────────────
# # cp ${SYNC_SRC}conf_system/config-${DC_PROFILE}.yaml /tmp/apisix_config/config-${DC_PROFILE}.yaml

# # ── Routes ─────────────────────────────────────────────────
# # cp "${SYNC_SRC}/conf_routes/apisix-${DC_PROFILE}.yaml" "/tmp/sync/apisix_routes/apisix-${DC_PROFILE}.yaml"
# src_route="${SYNC_SRC}/apisix_routes/apisix-${DC_PROFILE}.yaml"
# dst_route="/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"

# if grep -q "PASTE_CONTENT" "${dst_route}" 2>/dev/null; then
#   # dst vẫn là template chưa inject → cp bình thường
#   cp "${src_route}" "${dst_route}"
#   echo "[gitsync] Routes updated (template, pending cert inject)"
# elif ! diff -q "${src_route}" "${dst_route}" > /dev/null 2>&1; then
#   # template trên GitLab thay đổi thật (route mới, config mới...)
#   # cert bị overwrite bởi placeholder → cần admin inject lại
#   cp "${src_route}" "${dst_route}"
#   echo "[gitsync] WARNING: Route template changed — admin cần chạy lại 3-inject-certs.sh"
# else
#   echo "[gitsync] Routes unchanged, skip"
# fi

# # ── Scripts ────────────────────────────────────────────────
# cp "${SYNC_SRC}/scripts/gitsync.sh" "/tmp/scripts/gitsync.sh"

# # ── Certs ──────────────────────────────────────────────────
# Chỉ sync .cert (plaintext public) và .key.enc (encrypted private key)
# KHÔNG sync .key (plaintext private key — không tồn tại trong repo)
# certs — gitsync tự quản trong /tmp/sync/current/certs/
# 2-decrypt-certs.sh đọc thẳng từ đó, không cần copy ra ngoài

# # ── Plugins ────────────────────────────────────────────────
# if [ -d "${SYNC_SRC}/plugins" ]; then
#   cp -r "${SYNC_SRC}/plugins/*.lua" "/tmp/sync/plugins/"
# fi

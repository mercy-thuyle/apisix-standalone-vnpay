#!/bin/sh

set -eu

SYNC_SRC="/tmp/sync/current"
ROUTES_SRC="${SYNC_SRC}/apisix_routes"
OUTPUT="/tmp/apisix_routes/apisix-${DC_PROFILE:-}.yaml"
MERGE_SCRIPT="/tmp/scripts/runtime/merge-fragments.sh"
INJECT_SCRIPT="/tmp/scripts/runtime/inject-certs.sh"

LOG_FILE="/tmp/logs/gitsync.log"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
touch "${LOG_FILE}" 2>/dev/null || true

log() {
  _msg="[gitsync] $*"
  echo "${_msg}"
  echo "$(date -Iseconds) ${_msg}" >> "${LOG_FILE}"
}

log_err() {
  _msg="[gitsync] $*"
  echo "${_msg}" >&2
  echo "$(date -Iseconds) ${_msg}" >> "${LOG_FILE}"
}

run_logged() {
  _rc_file="/tmp/.gitsync-run-logged-rc.$$"
  { "$@"; echo "$?" > "${_rc_file}"; } 2>&1 | tee -a "${LOG_FILE}"
  _rc=$(cat "${_rc_file}" 2>/dev/null || echo 1)
  rm -f "${_rc_file}"
  return "${_rc}"
}

# ── Lock — chặn 2 lần gitsync.sh chạy chồng nhau nếu merge+inject lần trước chưa xong khi chu kỳ 30s tiếp theo tới
LOCK_DIR="/tmp/.gitsync.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log_err "ERROR: lần chạy gitsync.sh trước (PID $(cat "${LOCK_DIR}/pid" 2>/dev/null || echo '?')) chưa xong — SKIP lần này để tránh ghi chồng lên STAGING đang dở"
  exit 1
fi
echo "$$" > "${LOCK_DIR}/pid"
trap 'rm -rf "${LOCK_DIR}"' EXIT


# ── Kiểm tra DC_PROFILE ──────────────────────────────────────────────────────
if [ -z "${DC_PROFILE:-}" ]; then
  log_err "ERROR: DC_PROFILE chưa được set trong .env"
  exit 1
fi

OUTPUT="/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"

COMMIT_HASH="unknown"
COMMIT_MSG="unknown"
#if which git > /dev/null 2>&1; then
if git -C "${SYNC_SRC}" rev-parse HEAD > /dev/null 2>&1; then
  COMMIT_HASH=$(git -C "${SYNC_SRC}" rev-parse HEAD 2>/dev/null || echo "unknown")
  COMMIT_MSG=$(git -C "${SYNC_SRC}" log -1 --pretty=format:"%s" 2>/dev/null || echo "unknown")
fi

log "START — DC_PROFILE=${DC_PROFILE} | commit-id=${COMMIT_HASH} | commit-msg=${COMMIT_MSG}"

if [ -d "${ROUTES_SRC}/upstreams" ] && \
   [ -d "${ROUTES_SRC}/routes" ]   && \
   [ -d "${ROUTES_SRC}/services" ] && \
   [ -d "${ROUTES_SRC}/ssls" ]; then

  log "Layout: fragments (core: upstreams/ routes/ services/ ssls/; tùy chọn: plugin_metadata/ plugin_configs/ global_rules/ consumer_groups/ consumers/)"

  if [ ! -x "${MERGE_SCRIPT}" ]; then
    log_err "ERROR: ${MERGE_SCRIPT} không tồn tại hoặc không executable"
    exit 1
  fi

  MERGE_LOG_START=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)

  STAGING="${OUTPUT}.staging"

  if ! run_logged "${MERGE_SCRIPT}" "${ROUTES_SRC}" "${STAGING}"; then
    MERGE_ERRORS=$(tail -n +"$((MERGE_LOG_START + 1))" "${LOG_FILE}" 2>/dev/null | grep '\[merge-fragments\] ERROR' || true)
    log_err "ERROR: merge-fragments.sh thất bại — output không thay đổi"
    if [ -n "${MERGE_ERRORS}" ]; then
      printf '%s\n' "${MERGE_ERRORS}" | while IFS= read -r eline; do
        log_err "  → nguyên nhân: ${eline}"
      done
    fi
    rm -f "${STAGING}"
    exit 1
  fi

  INJECT_OK=1
  if [ -f "${INJECT_SCRIPT}" ]; then
    if ! OUTPUT="${STAGING}" \
       CERTS_DIR="/tmp/certs" \
       DOMAINS_FILE="/tmp/scripts/libraries/cert-list-domains.txt" \
       run_logged sh "${INJECT_SCRIPT}"; then
      INJECT_OK=0
    fi
  else
    log_err "WARN: ${INJECT_SCRIPT} không tìm thấy — cert sẽ bị mất sau commit"
  fi
  # echo "[gitsync] Cert injection: skipped (using Vault secret provider)"

  if [ "${INJECT_OK}" -eq 0 ]; then
    log_err "ERROR: inject-certs.sh thất bại (placeholder chưa inject hết) — ABORT, KHÔNG promote STAGING vào file live. File live giữ nguyên bản cũ."
    rm -f "${STAGING}"
    exit 1
  fi

  cp "${STAGING}" "${OUTPUT}"
  rm -f "${STAGING}"

  if grep -q "<<THAY" "${OUTPUT}" 2>/dev/null || grep -q "CHANGE_ME" "${OUTPUT}" 2>/dev/null; then
    log "INFO: Output còn credential placeholder — cần inject apikey cho apisix_routes/consumers/ trước khi sử dụng"
  fi

  if grep -q "^plugin_metadata:" "${OUTPUT}" 2>/dev/null; then
    PM_IDS=$(sed -n '/^plugin_metadata:/,/^upstreams:/p' "${OUTPUT}" \
             | grep -E '^\s+-\s+id:' \
             | sed 's/.*id:[[:space:]]*//' \
             | sed 's/[[:space:]]*#.*//' \
             | tr -d '"' \
             | sed 's/[[:space:]]*$//' \
             | tr '\n' ',' | sed 's/,$//')
    log "INFO: plugin_metadata đang active cho plugin: ${PM_IDS:-?} — áp dụng GLOBAL cho mọi route/service dùng plugin đó, không phải chỉ route gắn global_rules."
  else
    log "INFO: Không có plugin_metadata (bỏ qua — tùy chọn, log_format các logger dùng schema mặc định của plugin)"
  fi

elif [ -f "${ROUTES_SRC}/apisix-${DC_PROFILE}.yaml" ]; then

  log "Layout: legacy (apisix-${DC_PROFILE}.yaml)"
  SRC_FILE="${ROUTES_SRC}/apisix-${DC_PROFILE}.yaml"

  if grep -q "PASTE_CONTENT" "${OUTPUT}" 2>/dev/null; then
    cp "${SRC_FILE}" "${OUTPUT}"
    log "Routes updated (cert placeholder còn — cần chạy scripts/runtime/inject-certs.sh)"
  elif ! diff -q "${SRC_FILE}" "${OUTPUT}" > /dev/null 2>&1; then
    cp "${SRC_FILE}" "${OUTPUT}"
    log_err "WARNING: Route template thay đổi — cần chạy lại scripts/runtime/inject-certs.sh"
  else
    log "Routes không thay đổi, bỏ qua"
  fi

  if [ -f "${INJECT_SCRIPT}" ]; then
    OUTPUT="${OUTPUT}" \
    CERTS_DIR="/tmp/certs" \
    DOMAINS_FILE="/tmp/scripts/libraries/cert-list-domains.txt" \
    run_logged sh "${INJECT_SCRIPT}"
  fi
  # echo "[gitsync] Cert injection: skipped (using Vault secret provider)"

else
  log_err "ERROR: Không tìm thấy layout hợp lệ trong ${ROUTES_SRC}"
  log_err "  Cần:  upstreams/ + routes/ + services/ + ssls/  (fragments)"
  log_err "  Hoặc: apisix-${DC_PROFILE}.yaml     (legacy)"
  exit 1
fi

log "Syncing plugins/..."
if [ -d "${SYNC_SRC}/plugins" ]; then
  cp -r "${SYNC_SRC}/plugins/." "/tmp/plugins/"
  log "plugins/ synced"
else
  log_err "WARN: ${SYNC_SRC}/plugins/ không tồn tại, bỏ qua"
fi

log "Syncing scripts/..."
if [ -d "${SYNC_SRC}/scripts" ]; then
  cp -r "${SYNC_SRC}/scripts/." "/tmp/scripts/"
  log "scripts/ synced"
else
  log_err "WARN: ${SYNC_SRC}/scripts/ không tồn tại, bỏ qua"
fi

# # ── 4. Sync apisix_config/ ─────────────────────────────────────────────────
# Tắt — admin quản lý tay. Bỏ comment khi muốn auto sync.
# Lưu ý: config.yaml KHÔNG hot-reload → đổi file này luôn phải restart container.
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

log " >DONE — commit=${COMMIT_HASH}"

echo "[gitsync] $(date -Iseconds) — gitsync đã pull + merge xong (commit-id=${COMMIT_HASH} | commit-msg=${COMMIT_MSG}), APISIX sẽ tự hot-reload routes trong vài giây tới (config_yaml.lua tự detect file đổi). Đối chiếu bằng: docker logs apisix-standalone --tail 30 | grep reloaded" >> "${LOG_FILE}"

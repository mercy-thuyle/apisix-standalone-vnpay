#!/bin/sh

set -eu

# ── Đường dẫn và tham số runtime ────────────────────────────────────────────
SYNC_SRC="/tmp/sync/current"
ROUTES_SRC="${SYNC_SRC}/apisix_routes"
OUTPUT="/tmp/apisix_routes/apisix-${DC_PROFILE:-}.yaml"
# MERGE_SCRIPT="/tmp/scripts/runtime/merge-fragments.sh"
# Dùng script trong đúng commit GitSync vừa pull để đồng nhất với ADC.
MERGE_SCRIPT="${SYNC_SRC}/scripts/runtime/merge-fragments.sh"
INJECT_SCRIPT="/tmp/scripts/runtime/inject-certs.sh"
ADC_DIR="/tmp/adc"
ADC_TIMEOUT="${ADC_TIMEOUT:-90}"
ADC_BLOCKED="${ADC_DIR}/blocked-${DC_PROFILE:-}"

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

# Giữ stdout/stderr trong operational log và trả đúng exit code của lệnh.
run_logged() {
  _rc_file="/tmp/.gitsync-run-logged-rc.$$"
  { "$@"; echo "$?" > "${_rc_file}"; } 2>&1 | tee -a "${LOG_FILE}"
  _rc=$(cat "${_rc_file}" 2>/dev/null || echo 1)
  rm -f "${_rc_file}"
  return "${_rc}"
}

# ── Lock một lần chạy — chặn 2 lần gitsync.sh chạy chồng nhau nếu merge+inject lần trước chưa xong khi chu kỳ 30s tiếp theo tới
# GitSync chạy mỗi 30 giây, ADC validate có thể lâu hơn. Không để hook chạy sau ghi đè staging artifact hoặc ADC request của lần đang chạy.
LOCK_DIR="/tmp/.gitsync.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  log_err "ERROR: lần chạy gitsync.sh trước (PID $(cat "${LOCK_DIR}/pid" 2>/dev/null || echo '?')) chưa xong — SKIP lần này để tránh ghi chồng lên STAGING đang dở"
  exit 1
fi
echo "$$" > "${LOCK_DIR}/pid"
trap 'rm -rf "${LOCK_DIR}"' EXIT


# ── Kiểm tra DC_PROFILE và source revision ──────────────────────────────────────────────────────
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

# Cùng SHA đã bị ADC từ chối: không merge/inject/dry-run lại liên tục.
# GitSync vẫn có thể pull SHA MỚI; SHA mới sẽ đi qua validation bình thường.
if [ -s "${ADC_BLOCKED}" ]; then
  BLOCK_LINE=$(cat "${ADC_BLOCKED}" 2>/dev/null || true)
  BLOCK_COMMIT=$(printf '%s' "${BLOCK_LINE}" | cut -f1)
  BLOCK_STATUS=$(printf '%s' "${BLOCK_LINE}" | cut -f2)
  BLOCK_DETAIL=$(printf '%s' "${BLOCK_LINE}" | cut -f3-)

  if [ "${BLOCK_COMMIT}" = "${COMMIT_HASH}" ]; then
    # Không trả exit 1: git-sync sẽ retry exechook mỗi 5s vô hạn.
    # Exit 0 chỉ xác nhận hook đã xử lý trạng thái BLOCKED; tuyệt đối không
    # merge/inject/promote file live. Chu kỳ poll sau vẫn nhận SHA mới để sửa.
    log "BLOCKED — commit-id=${COMMIT_HASH} | commit-msg=${COMMIT_MSG}: ${BLOCK_STATUS:-FAIL} ${BLOCK_DETAIL}; bỏ qua apply, chờ SHA mới"
    exit 0
  fi
fi

# ── Bố cục fragments: merge → inject → ADC gate → promote ──────────────────
if [ -d "${ROUTES_SRC}/upstreams" ] && \
   [ -d "${ROUTES_SRC}/routes" ] && \
   [ -d "${ROUTES_SRC}/services" ] && \
   [ -d "${ROUTES_SRC}/ssls" ]; then

  log "Layout: fragments (core: upstreams/ routes/ services/ ssls/; tùy chọn: plugin_metadata/ plugin_configs/ global_rules/ consumer_groups/ consumers/)"

  if [ ! -f "${MERGE_SCRIPT}" ]; then
    log_err "ERROR: ${MERGE_SCRIPT} không tồn tại hoặc không executable"
    exit 1
  fi

  MERGE_LOG_START=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)

  STAGING="${OUTPUT}.staging"

  if ! run_logged sh "${MERGE_SCRIPT}" "${ROUTES_SRC}" "${STAGING}"; then
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

  # Inject certificate là một phần của transaction staging, không ghi live.
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

  # ADC validate cùng GitSync checkout nhưng không có Docker socket và không thể
  # ghi bind mount live. Request file được thay thế theo cách atomic.
  ADC_REQUEST="${ADC_DIR}/request-${DC_PROFILE}"
  ADC_RESULT="${ADC_DIR}/result-${DC_PROFILE}"
  # Artifact phải gắn với commit đang chờ validate, không dùng lại file cũ.
  ADC_APPROVED="${ADC_DIR}/approved-${DC_PROFILE}-${COMMIT_HASH}.yaml"

  if [ ! -d "${ADC_DIR}" ]; then
    log_err "ERROR: ADC shared dir missing; live config unchanged"
    rm -f "${STAGING}"
    exit 1
  fi

  # Không xóa artifact cùng SHA ở đây.
  # ADC_RESULT và ADC_APPROVED đều gắn SHA bất biến của checkout; một PASS
  # chỉ hợp lệ khi cả hai cùng tồn tại. Xóa file này trước khi đọc verdict
  # sẽ làm GitSync thấy "PASS" nhưng thiếu chứng thực và không thể promote.
  printf '%s\n' "${COMMIT_HASH}" > "${ADC_REQUEST}.tmp.$$"
  mv "${ADC_REQUEST}.tmp.$$" "${ADC_REQUEST}"
  log "ADC validation requested: commit=${COMMIT_HASH}, timeout=${ADC_TIMEOUT}s"

  ADC_ELAPSED=0
  ADC_STATUS=""
  ADC_DETAIL=""

  while [ "${ADC_ELAPSED}" -lt "${ADC_TIMEOUT}" ]; do
    if [ -f "${ADC_RESULT}" ]; then
      ADC_LINE=$(cat "${ADC_RESULT}" 2>/dev/null || true)
      ADC_COMMIT=$(printf '%s' "${ADC_LINE}" | cut -f1)
      ADC_STATUS=$(printf '%s' "${ADC_LINE}" | cut -f2)
      ADC_DETAIL=$(printf '%s' "${ADC_LINE}" | cut -f3-)

      # Bỏ qua verdict còn sót lại từ commit GitSync trước đó.
      [ "${ADC_COMMIT}" = "${COMMIT_HASH}" ] && break
    fi

    sleep 1
    ADC_ELAPSED=$((ADC_ELAPSED + 1))
  done

  # PASS chỉ hợp lệ khi ADC đã tạo artifact chứng thực cùng SHA.
  # Chuẩn hóa trạng thái để không ghi marker kiểu "PASS nhưng bị block".
  if [ "${ADC_STATUS}" = "PASS" ] && [ ! -s "${ADC_APPROVED}" ]; then
    ADC_STATUS="FAIL"
    ADC_DETAIL="ADC approval artifact missing"
  fi

  if [ "${ADC_STATUS}" != "PASS" ]; then
    ADC_BLOCK_TMP="${ADC_BLOCKED}.tmp.$$"
    printf '%s\t%s\t%s\n' \
      "${COMMIT_HASH}" "${ADC_STATUS:-TIMEOUT}" "${ADC_DETAIL}" \
      > "${ADC_BLOCK_TMP}"
    mv "${ADC_BLOCK_TMP}" "${ADC_BLOCKED}"

     log_err "ERROR: ADC verdict for ${COMMIT_HASH}: ${ADC_STATUS:-TIMEOUT} ${ADC_DETAIL}; live config unchanged"
    log_err "BLOCKED — ghi ${ADC_BLOCKED}; cùng SHA sẽ fail nhanh, SHA mới vẫn được validate"
    rm -f "${STAGING}"
    exit 1
  fi

  # ADC validate source/merge trong network none; không được thay file staging
  # đã inject certificate ở trên.
  log "ADC PASS: promoting injected staging artifact for ${COMMIT_HASH}"
  cp "${STAGING}" "${OUTPUT}"
  rm -f "${STAGING}"
  rm -f "${ADC_BLOCKED}"

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

# ── Legacy layout: giữ nguyên hành vi trước ADC ──────────────────────────────
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

# ── Đồng bộ tài nguyên runtime sau khi promote route ─────────────────────────
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
#   log "apisix_config synced — cần restart APISIX để apply"
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

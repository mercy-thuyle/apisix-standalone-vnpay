#!/bin/sh
# =============================================================================
# scripts/runtime/gitsync.sh
# APISIX Standalone GitSync exechook
#
# Được git-sync container gọi tự động sau mỗi lần repo sync thành công.
# GITSYNC_EXECHOOK_COMMAND=/tmp/scripts/runtime/gitsync.sh
#
# Thứ tự thực thi:
#   1.  merge fragments      → ./apisix_routes/apisix-${DC_PROFILE}.yaml
#   1a. Detect layout của apisix_routes/ trong repo
#   1b. Layout fragments (upstreams/ routes/ ssls/ [+ services/ global_rules/ consumer_groups/ consumers/]) → gọi merge-fragments.sh
#   1c. Inject certs vào output → gọi inject-certs.sh
#   2.  cp plugins/          → ./plugins/
#   3.  cp scripts/          → ./scripts/
#   4.  cp apisix_config/    → ./apisix_config/   ← comment, admin quản lý tay
#
# LƯU Ý CERT INJECTION:
#   - Cert KHÔNG lưu trong repo (security). inject-certs.sh đọc từ /tmp/certs/
#     (mount từ host ./certs/ vào gitsync container).
#   - Mỗi lần có commit mới → merge lại → inject lại → APISIX hot-reload.
#   - Nếu /tmp/certs/ chưa có cert (chưa decrypt) → placeholder còn lại
#     → APISIX SSL fail → chạy 2-decrypt-certs.sh trên host.
#
# LƯU Ý SECTION RATE-LIMIT/QoS (thêm từ v1):
#   - services/ global_rules/ consumer_groups/ consumers/ là TÙY CHỌN và do
#     merge-fragments.sh tự gộp. Chúng KHÔNG tham gia bước detect layout ở 1b
#     (chỉ 3 thư mục core upstreams/routes/ssls quyết định layout) → repo cũ chưa có các section này vẫn chạy bình thường.
#   - Các plugin tương ứng (limit-req/limit-count/limit-conn/api-breaker/key-auth) đã bật sẵn trong config-${DC_PROFILE}.yaml
#     → KHÔNG cần restart khi thêm rate-limit, chỉ hot-reload route/service YAML.
#
# LƯU Ý LOG HOT-RELOAD (thêm — xem cuối file):
#   - Sau khi script này DONE, APISIX core (container apisix-standalone) sẽ tự
#     phát hiện file apisix-${DC_PROFILE}.yaml đổi và tự hot-reload, KHÔNG cần
#     restart container. Dòng log core của APISIX báo việc này có dạng:
#       nginx: [warn] [lua] config_yaml.lua:198: read_apisix_config():
#       config file /usr/local/apisix/conf/apisix-${DC_PROFILE}.yaml reloaded.
#   - Đây là warning VÔ HẠI, chỉ mang tính thông báo — không phải lỗi.
#     KHÔNG sửa trực tiếp message này (nằm trong APISIX core, compiled sẵn
#     trong image, không nằm trong các file mount tùy chỉnh của repo này).
#   - Thay vào đó, script này tự ghi thêm 1 dòng log tường minh ở cuối
#     (xem mục "Log tường minh hot-reload" bên dưới) để dễ đối chiếu 2 phía:
#     git-sync vừa pull xong (log dưới đây) → APISIX tự reload sau đó vài giây
#     (log "[warn] ... reloaded" của apisix-standalone).
#
# LƯU Ý LOG MERGE-FRAGMENTS / INJECT-CERTS (thêm — xem hàm log()/run_logged()):
#   - Toàn bộ output (stdout+stderr) của merge-fragments.sh và inject-certs.sh
#     giờ được ghi (append) vào CÙNG 1 file /tmp/logs/gitsync.log (bind-mount
#     ra host ./logs/gitsync/gitsync.log), thay vì chỉ nằm trong `docker logs
#     gitsync` (có thể mất theo log rotation max-file:3 của Docker).
#   - Dùng run_logged() thay vì gọi script con trực tiếp — vẫn giữ đúng exit
#     code gốc của script con (không dùng pipefail vì /bin/sh/dash không hỗ
#     trợ `set -o pipefail`).
#
# NOTES:
#   - ./scripts → /tmp/scripts, git-sync tự sync repo về gitsync/current/scripts mới có hiệu lực ngay lần trigger tiếp theo qua volume mount
#   - Không dùng find/awk — git-sync container không có các tool này
#   - Nếu merge-fragments.sh exit 1 → KHÔNG ghi output → APISIX dùng file hiện tại
#   - DC_PROFILE đến từ .env (dc1 | dc2 | hcm | hni | ...)
#   - Commit info lấy qua git trực tiếp từ SYNC_SRC
#     GITSYNC_DEPTH=1 (shallow) → git log -1 vẫn hoạt động với shallow clone
# =============================================================================

# ── VAULT INTEGRATION (uncomment khi có thông tin Vault) ─────────────────
# Khi chuyển sang Vault, bỏ comment block inject-certs bên dưới (step 1c)
# và xóa mount ./certs:/tmp/certs trong docker-compose.yaml.
# APISIX tự fetch cert từ Vault qua secret_provider trong config.yaml.
# Xem hướng dẫn trong scripts/runtime/inject-certs.sh

set -eu

SYNC_SRC="/tmp/sync/current"
ROUTES_SRC="${SYNC_SRC}/apisix_routes"
OUTPUT="/tmp/apisix_routes/apisix-${DC_PROFILE:-}.yaml"
MERGE_SCRIPT="/tmp/scripts/runtime/merge-fragments.sh"
INJECT_SCRIPT="/tmp/scripts/runtime/inject-certs.sh"

# ── Log file bền vững (bind-mount ra host ./logs/gitsync/gitsync.log) ───────
LOG_FILE="/tmp/logs/gitsync.log"
mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
touch "${LOG_FILE}" 2>/dev/null || true

# log <msg...>: in ra stdout (GITSYNC_V="6" sẽ show trong `docker logs gitsync`)
#               VÀ append (có timestamp) vào LOG_FILE — đọc lại được sau này,
#               không phụ thuộc Docker log rotation (max-file:3).
log() {
  _msg="[gitsync] $*"
  echo "${_msg}"
  echo "$(date -Iseconds) ${_msg}" >> "${LOG_FILE}"
}

# log_err <msg...>: giống log() nhưng ra stderr — dùng cho các dòng ERROR/WARN.
log_err() {
  _msg="[gitsync] $*"
  echo "${_msg}" >&2
  echo "$(date -Iseconds) ${_msg}" >> "${LOG_FILE}"
}

# run_logged <cmd...>: chạy 1 lệnh (thường là script con merge-fragments.sh /
# inject-certs.sh), tee TOÀN BỘ stdout+stderr của nó ra cả stdout hiện tại lẫn
# LOG_FILE, đồng thời return đúng exit code gốc của lệnh đó.
#
# LƯU Ý: không dùng `cmd 2>&1 | tee -a "${LOG_FILE}"` trực tiếp vì trong
# /bin/sh (dash/busybox) không có `set -o pipefail` → `$?` sau pipe sẽ luôn
# là exit code của `tee` (gần như luôn 0), làm gitsync.sh KHÔNG phát hiện
# được merge-fragments.sh fail → dùng file rc trung gian để lấy đúng exit code.
run_logged() {
  _rc_file="/tmp/.gitsync-run-logged-rc.$$"
  { "$@"; echo "$?" > "${_rc_file}"; } 2>&1 | tee -a "${LOG_FILE}"
  _rc=$(cat "${_rc_file}" 2>/dev/null || echo 1)
  rm -f "${_rc_file}"
  return "${_rc}"
}

# ── Kiểm tra DC_PROFILE ──────────────────────────────────────────────────────
if [ -z "${DC_PROFILE:-}" ]; then
  log_err "ERROR: DC_PROFILE chưa được set trong .env"
  exit 1
fi

# OUTPUT phụ thuộc DC_PROFILE — set lại cho đúng (dòng khởi tạo phía trên chỉ
# để log_err ở bước check DC_PROFILE phía trên hoạt động được ngay cả khi
# DC_PROFILE rỗng, tránh lỗi "unbound variable" do `set -u`).
OUTPUT="/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"

# ── Commit info ───────────────────────────────────────────────────────────────
# Dùng which thay command -v (busybox sh không có command -v)
# GITSYNC_DEPTH=1 shallow clone → git log -1 vẫn có đủ 1 commit để đọc
COMMIT_HASH="unknown"
COMMIT_MSG="unknown"
#if which git > /dev/null 2>&1; then
if git -C "${SYNC_SRC}" rev-parse HEAD > /dev/null 2>&1; then
  COMMIT_HASH=$(git -C "${SYNC_SRC}" rev-parse HEAD 2>/dev/null || echo "unknown")
  COMMIT_MSG=$(git -C "${SYNC_SRC}" log -1 --pretty=format:"%s" 2>/dev/null || echo "unknown")
fi

log "START — DC_PROFILE=${DC_PROFILE} | commit-id=${COMMIT_HASH} | commit-msg=${COMMIT_MSG}"

# ── 1. Merge fragments → apisix-${DC_PROFILE}.yaml ───────────────────────────
# Detect layout CHỈ dựa trên 3 thư mục core. services/global_rules/
# consumer_groups/consumers là tùy chọn, merge-fragments.sh tự phát hiện & gộp.
if [ -d "${ROUTES_SRC}/upstreams" ] && \
   [ -d "${ROUTES_SRC}/routes" ]   && \
   [ -d "${ROUTES_SRC}/ssls" ]; then

  # ── Layout fragments: merge từ entity files ───────────────────────────────
  log "Layout: fragments (core: upstreams/ routes/ ssls/; tùy chọn: services/ global_rules/ consumer_groups/ consumers/)"

  if [ ! -x "${MERGE_SCRIPT}" ]; then
    log_err "ERROR: ${MERGE_SCRIPT} không tồn tại hoặc không executable"
    exit 1
  fi

  # Chạy merge — exit 1 → giữ nguyên output cũ, APISIX không bị ảnh hưởng.
  # run_logged() ghi toàn bộ log Pass 1/2/3 của merge-fragments.sh (validate,
  # warning duplicate id/username, summary counts...) vào LOG_FILE, đọc lại
  # được sau này qua `grep merge-fragments ./logs/gitsync/gitsync.log`.
  if ! run_logged "${MERGE_SCRIPT}" "${ROUTES_SRC}" "${OUTPUT}"; then
    log_err "ERROR: merge-fragments.sh thất bại — output không thay đổi"
    exit 1
  fi

  # ── 1c. Inject certs vào output sau khi merge ──────────────────────────
  # Cert không lưu trong repo — inject từ /tmp/certs/ (mount từ host ./certs/)
  # Comment block này khi chuyển sang Vault (xem comment đầu file)
  if [ -f "${INJECT_SCRIPT}" ]; then
    OUTPUT="${OUTPUT}" \
    CERTS_DIR="/tmp/certs" \
    DOMAINS_FILE="/tmp/scripts/libraries/cert-list-domains.txt" \
    run_logged sh "${INJECT_SCRIPT}"
  else
    log_err "WARN: ${INJECT_SCRIPT} không tìm thấy — cert sẽ bị mất sau commit"
  fi
  # echo "[gitsync] Cert injection: skipped (using Vault secret provider)"

  # Credential placeholder còn → nhắc admin inject secret cho consumers/
  # key-auth KHÔNG nên commit plaintext lên repo. Fragment mẫu dùng marker
  # '<<THAY' (hoặc CHANGE_ME). Đây chỉ là cảnh báo, KHÔNG block deploy.
  if grep -q "<<THAY" "${OUTPUT}" 2>/dev/null || grep -q "CHANGE_ME" "${OUTPUT}" 2>/dev/null; then
    log "INFO: Output còn credential placeholder — cần inject apikey cho apisix_routes/consumers/ trước khi sử dụng"
  fi

elif [ -f "${ROUTES_SRC}/apisix-${DC_PROFILE}.yaml" ]; then

  # ── Layout legacy: copy trực tiếp file monolithic ────────────────────────
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

  # ── Legacy cert inject layout─────────────────────────────────────────────────
  # Comment block này khi chuyển sang Vault (xem comment đầu file)
  if [ -f "${INJECT_SCRIPT}" ]; then
    OUTPUT="${OUTPUT}" \
    CERTS_DIR="/tmp/certs" \
    DOMAINS_FILE="/tmp/scripts/libraries/cert-list-domains.txt" \
    run_logged sh "${INJECT_SCRIPT}"
  fi
  # echo "[gitsync] Cert injection: skipped (using Vault secret provider)"

else
  log_err "ERROR: Không tìm thấy layout hợp lệ trong ${ROUTES_SRC}"
  log_err "  Cần:  upstreams/ + routes/ + ssls/  (fragments)"
  log_err "  Hoặc: apisix-${DC_PROFILE}.yaml     (legacy)"
  exit 1
fi

# ── 2. Sync plugins/ ──────────────────────────────────────────────────────────
log "Syncing plugins/..."
if [ -d "${SYNC_SRC}/plugins" ]; then
  cp -r "${SYNC_SRC}/plugins/." "/tmp/plugins/"
  log "plugins/ synced"
else
  log_err "WARN: ${SYNC_SRC}/plugins/ không tồn tại, bỏ qua"
fi

# ── 3. Sync scripts/ ──────────────────────────────────────────────────────────
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

# =============================================================================
# Log tường minh hot-reload — GHI VÀO FILE RIÊNG, không chỉ stdout
#
# LÝ DO: dòng "[gitsync] DONE" ở trên giờ đã được log() ghi vào LOG_FILE rồi,
# nhưng vẫn giữ thêm 1 dòng "[gitsync-hook]" riêng (định dạng khác, dễ grep)
# để đối chiếu trực tiếp với log "[warn] ... reloaded" của apisix-standalone
# (xem hướng dẫn đọc log ở cuối comment khối này).
#
# CÁCH DÙNG — khi nghi ngờ 1 thay đổi route/service có thực sự được áp dụng
# chưa, đối chiếu 2 log theo timeline:
#
#   1) Xem gitsync đã pull + merge xong commit nào, lúc nào, và merge-fragments.sh
#      có warning/error gì không (giờ đã nằm chung trong file này):
#        tail -50 /opt/apisix/standalone/sandbox/logs/gitsync/gitsync.log
#        grep -i "merge-fragments\|WARN\|ERROR" ./logs/gitsync/gitsync.log | tail -30
#      (hoặc docker logs gitsync --tail 30  — bản ngắn hơn, có thể bị rotate mất)
#
#   2) Đối chiếu với log "reloaded" của APISIX core (phải xuất hiện SAU thời
#      điểm gitsync ở bước 1, thường lệch vài giây, do APISIX cần thời gian
#      detect file đổi):
#        docker logs apisix-standalone --tail 30 | grep reloaded
#
#   3) Nếu bước 1 đã chạy (thấy DONE + đúng commit_hash mong đợi) nhưng bước 2
#      KHÔNG thấy dòng "reloaded" mới tương ứng → khả năng cao merge-fragments.sh
#      sinh ra file YAML lỗi (APISIX core từ chối load, không phải lỗi gitsync) →
#      kiểm tra thêm:
#        docker logs apisix-standalone --tail 30 | grep -iE "error|emerg"
#
# Lưu ý: dòng "[warn] config_yaml.lua:198: ... reloaded" là log CORE của
# APISIX (compiled sẵn trong image apache/apisix), KHÔNG sửa được trực tiếp
# qua repo này — không patch core chỉ để đổi câu chữ 1 dòng thông báo, không
# đáng so với rủi ro phải maintain thêm 1 file patch core qua mỗi lần upgrade
# APISIX version (khác bản chất với patch X-Forwarded-Port ở
# scripts/deploy/1-patch-template-lua.sh, vốn sửa hành vi signature thật).
# =============================================================================
echo "[gitsync] $(date -Iseconds) — gitsync đã pull + merge xong (commit-id=${COMMIT_HASH} | commit-msg=${COMMIT_MSG}), APISIX sẽ tự hot-reload routes trong vài giây tới (config_yaml.lua tự detect file đổi). Đối chiếu bằng: docker logs apisix-standalone --tail 30 | grep reloaded" >> "${LOG_FILE}"

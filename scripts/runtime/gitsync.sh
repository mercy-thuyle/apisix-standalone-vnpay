#!/bin/sh
# =============================================================================
# scripts/runtime/gitsync.sh test
# APISIX Standalone GitSync exechook
#
# Được git-sync container gọi tự động sau mỗi lần repo sync thành công.
# GITSYNC_EXECHOOK_COMMAND=/tmp/scripts/runtime/gitsync.sh
#
# Thứ tự thực thi:
#   1.  merge fragments      → ./apisix_routes/apisix-${DC_PROFILE}.yaml
#   1a. Detect layout của apisix_routes/ trong repo
#   1b. Layout fragments (upstreams/ routes/ ssls/ [+ services/ global_rules/
#       consumer_groups/ consumers/]) → gọi merge-fragments.sh
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
#     (chỉ 3 thư mục core upstreams/routes/ssls quyết định layout) → repo cũ
#     chưa có các section này vẫn chạy bình thường.
#   - Các plugin tương ứng (limit-req/limit-count/limit-conn/api-breaker/
#     key-auth) đã bật sẵn trong config-${DC_PROFILE}.yaml → KHÔNG cần restart
#     khi thêm rate-limit, chỉ hot-reload route/service YAML.
#
# NOTES:
#   - ./scripts → /tmp/scripts, git-sync tự sync repo về gitsync/current/
#     scripts mới có hiệu lực ngay lần trigger tiếp theo qua volume mount
#   - Không dùng find — git-sync container không có find
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
OUTPUT="/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml"
MERGE_SCRIPT="/tmp/scripts/runtime/merge-fragments.sh"
INJECT_SCRIPT="/tmp/scripts/runtime/inject-certs.sh"

# ── Kiểm tra DC_PROFILE ──────────────────────────────────────────────────────
if [ -z "${DC_PROFILE:-}" ]; then
  echo "[gitsync] ERROR: DC_PROFILE chưa được set trong .env" >&2
  exit 1
fi

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

echo "[gitsync] START — DC_PROFILE=${DC_PROFILE} | commit=${COMMIT_HASH} | ${COMMIT_MSG}"

# ── 1. Merge fragments → apisix-${DC_PROFILE}.yaml ───────────────────────────
# Detect layout CHỈ dựa trên 3 thư mục core. services/global_rules/
# consumer_groups/consumers là tùy chọn, merge-fragments.sh tự phát hiện & gộp.
if [ -d "${ROUTES_SRC}/upstreams" ] && \
   [ -d "${ROUTES_SRC}/routes" ]   && \
   [ -d "${ROUTES_SRC}/ssls" ]; then

  # ── Layout fragments: merge từ entity files ───────────────────────────────
  echo "[gitsync] Layout: fragments (core: upstreams/ routes/ ssls/; tùy chọn: services/ global_rules/ consumer_groups/ consumers/)"

  if [ ! -x "${MERGE_SCRIPT}" ]; then
    echo "[gitsync] ERROR: ${MERGE_SCRIPT} không tồn tại hoặc không executable" >&2
    exit 1
  fi

  # Chạy merge — exit 1 → giữ nguyên output cũ, APISIX không bị ảnh hưởng
  if ! "${MERGE_SCRIPT}" "${ROUTES_SRC}" "${OUTPUT}"; then
    echo "[gitsync] ERROR: merge-fragments.sh thất bại — output không thay đổi" >&2
    exit 1
  fi

  # ── 1c. Inject certs vào output sau khi merge ──────────────────────────
  # Cert không lưu trong repo — inject từ /tmp/certs/ (mount từ host ./certs/)
  # Bỏ block này khi chuyển sang Vault (xem comment đầu file)
  if [ -f "${INJECT_SCRIPT}" ]; then
    OUTPUT="${OUTPUT}" \
    CERTS_DIR="/tmp/certs" \
    DOMAINS_FILE="/tmp/scripts/libraries/cert-list-domain.txt" \
    sh "${INJECT_SCRIPT}"
  else
    echo "[gitsync] WARN: ${INJECT_SCRIPT} không tìm thấy — cert sẽ bị mất sau commit" >&2
  fi

  # Credential placeholder còn → nhắc admin inject secret cho consumers/
  # key-auth KHÔNG nên commit plaintext lên repo. Fragment mẫu dùng marker
  # '<<THAY' (hoặc CHANGE_ME). Đây chỉ là cảnh báo, KHÔNG block deploy.
  if grep -q "<<THAY" "${OUTPUT}" 2>/dev/null || grep -q "CHANGE_ME" "${OUTPUT}" 2>/dev/null; then
    echo "[gitsync] INFO: Output còn credential placeholder (<<THAY / CHANGE_ME) — cần inject apikey cho apisix_routes/consumers/ trước khi sử dụng"
  fi

elif [ -f "${ROUTES_SRC}/apisix-${DC_PROFILE}.yaml" ]; then

  # ── Layout legacy: copy trực tiếp file monolithic ────────────────────────
  echo "[gitsync] Layout: legacy (apisix-${DC_PROFILE}.yaml)"
  SRC_FILE="${ROUTES_SRC}/apisix-${DC_PROFILE}.yaml"

  if grep -q "PASTE_CONTENT" "${OUTPUT}" 2>/dev/null; then
    cp "${SRC_FILE}" "${OUTPUT}"
    echo "[gitsync] Routes updated (cert placeholder còn — cần chạy scripts/runtime/inject-certs.sh)"
  elif ! diff -q "${SRC_FILE}" "${OUTPUT}" > /dev/null 2>&1; then
    cp "${SRC_FILE}" "${OUTPUT}"
    echo "[gitsync] WARNING: Route template thay đổi — cần chạy lại scripts/runtime/inject-certs.sh"
  else
    echo "[gitsync] Routes không thay đổi, bỏ qua"
  fi

  # Inject cert cho legacy layout
  if [ -f "${INJECT_SCRIPT}" ]; then
    OUTPUT="${OUTPUT}" \
    CERTS_DIR="/tmp/certs" \
    DOMAINS_FILE="/tmp/scripts/libraries/cert-list-domain.txt" \
    sh "${INJECT_SCRIPT}"
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

echo " >[gitsync] DONE — commit=${COMMIT_HASH}"

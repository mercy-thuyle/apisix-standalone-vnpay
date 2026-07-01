#!/bin/sh
# =============================================================================
# scripts/runtime/merge-fragments.sh
# Gộp entity files trong apisix_routes/{upstreams,services,routes,global_rules,consumer_groups,consumers,ssls}/ thành 1 file
# apisix-${DC_PROFILE}.yaml đúng syntax APISIX standalone.
#
# ── SECTION HỖ TRỢ ───────────────────────────────────────────────────────────
#   BẮT BUỘC (core, thiếu = hard error):
#     upstreams/        key "upstreams:"        grouped  (subfolder theo service)
#     routes/           key "routes:"           grouped  (subfolder theo service)
#     ssls/             key "ssls:"             flat
#
#   TÙY CHỌN (rate-limit/QoS, thêm sau — thiếu thì BỎ QUA, không lỗi):
#     services/         key "services:"         flat   ← 4 tier QoS (+ offpeak)
#     global_rules/     key "global_rules:"     flat   ← guard chống abuse
#     consumer_groups/  key "consumer_groups:"  flat   ← gói quota control-plane
#     consumers/        key "consumers:"        flat   ← account + key-auth
#   → Cho phép adopt dần: ví dụ commit services/ trước, consumers/ sau.
#   → Section tùy chọn vắng mặt sẽ KHÔNG emit 'key:' rỗng (YAML null có thể làm APISIX standalone báo lỗi schema).
#
# ── QUY TẮC ENTITY FILE ──────────────────────────────────────────────────────
#   - Phải bắt đầu bằng key đúng với folder chứa nó (vd file trong services/ phải mở đầu bằng "services:").
#   - Items indent 2 spaces dưới key (format chuẩn YAML).
#   - 1 file có thể chứa 1 hoặc nhiều items.
#   - KHÔNG đặt "#END" trong fragment (chỉ xuất hiện 1 lần ở cuối output).
#
# ── FILE BỊ COMMENT TOÀN BỘ (DISABLED TEMPLATE) ─────────────────────────────
#   File có thể bị "tắt" bằng cách comment toàn bộ nội dung:
#     # global_rules:
#     #   - id: global-kafka-logger
#     #     ...
#   → merge-fragments.sh sẽ SKIP file này (WARNING, không phải hard error).
#   → Khi muốn bật: bỏ comment các dòng, để key đầu tiên không phải comment.
#   → Dùng cho template dự phòng (kafka-logger, http-logger...) — giữ trong repo
#     để tham khảo mà không làm ảnh hưởng đến output.
#
# ── VALIDATION ───────────────────────────────────────────────────────────────
#   - Key không khớp folder        → exit 1  (hard error, block merge)
#   - File không có key hợp lệ     → exit 1  (hard error, block merge)
#   - File bị comment toàn bộ      → WARNING, bỏ qua (disabled template)
#   - Duplicate id trong output    → WARNING, tiếp tục
#   - Duplicate username (consumer)→ WARNING, tiếp tục
#   - File rỗng                    → WARNING, bỏ qua
#
# ── THỨ TỰ OUTPUT ────────────────────────────────────────────────────────────
#   upstreams → services → routes → global_rules → consumer_groups → consumers → ssls → #END
#   (APISIX standalone parse toàn bộ file 1 lượt nên thứ tự không bắt buộc;
#    cố định thứ tự này để diff sạch và dễ đọc theo chiều phụ thuộc.)
#
# Usage:
#   merge-fragments.sh <routes_src_dir> <output_file>
#   - KHÔNG dùng `find`, `awk` — git-sync container (registry.k8s.io/git-sync) không có sẵn.
#   - Dùng shell glob + while read loop thay thế.
#   - Được gọi bởi: scripts/runtime/gitsync.sh
# =============================================================================

set -eu

# ── Tham số ──────────────────────────────────────────────────────────────────
ROUTES_SRC="${1:-/tmp/sync/current/apisix_routes}"
OUTPUT="${2:-/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml}"

# ── Kiểm tra DC_PROFILE ──────────────────────────────────────────────────────
if [ -z "${DC_PROFILE:-}" ]; then
  echo "[merge-fragments] ERROR: DC_PROFILE chưa được set" >&2
  exit 1
fi

# ── Thư mục BẮT BUỘC (core) — thiếu là hard error ────────────────────────────
for d in upstreams routes ssls; do
  if [ ! -d "${ROUTES_SRC}/${d}" ]; then
    echo "[merge-fragments] ERROR: Thiếu thư mục bắt core ${ROUTES_SRC}/${d}" >&2
    exit 1
# ── Thư mục TÙY CHỌN — thiếu thì chỉ log INFO, KHÔNG lỗi ─────────────────────
#   append_block()/validate_block_dir() tự skip khi thư mục vắng mặt;
#   vòng lặp này chỉ để in thông báo cho admin biết section nào chưa dùng.
  fi
done

mkdir -p "$(dirname "${OUTPUT}")"

# ── Temp files ────────────────────────────────────────────────────────────────
TMP_OUTPUT="${OUTPUT}.tmp.$$"
ERROR_FLAG="/tmp/merge-fragments-error.$$"   # tồn tại = có hard error
WARN_FILE="/tmp/merge-fragments-warn.$$"     # đếm warnings

# Cleanup khi exit (dù thành công hay lỗi)
trap 'rm -f "${ERROR_FLAG}" "${WARN_FILE}" "${TMP_OUTPUT}" 2>/dev/null || true' EXIT

touch "${WARN_FILE}"   # khởi tạo

# ── Helpers ───────────────────────────────────────────────────────────────────
log_info()  { echo "[merge-fragments] $*"; }

log_warn() {
  echo "[merge-fragments] WARN: $*" >&2
  echo "1" >> "${WARN_FILE}"
}

log_error() {
  echo "[merge-fragments] ERROR: $*" >&2
  touch "${ERROR_FLAG}"   # signal hard error — dùng file thay vì biến shell để vượt qua subshell
}

# Lấy key header đầu tiên của file (bỏ qua comment và dòng rỗng)
# Trả về chuỗi rỗng nếu toàn bộ file là comment/blank (disabled template)
get_file_key() {
  grep -v '^\s*#' "$1" | grep -v '^\s*$' | head -1 | sed 's/:.*//' | tr -d ' '
}

# Strip dòng key header (dòng đầu tiên không phải comment/blank), in phần còn lại
# Thay thế awk — không có trong git-sync container
strip_key_header() {
  SKIPPED=0
  while IFS= read -r line; do
    case "${line}" in
      "#"*|"  #"*|"   #"*|"")
        echo "${line}"
        continue
        ;;
    esac
    if [ "${SKIPPED}" = "0" ]; then
      SKIPPED=1
      continue
    fi
    echo "${line}"
  done < "$1"
}

# glob_yaml_files <dir> <depth>
# Liệt kê tất cả *.yaml trong dir, depth 1 (flat) hoặc depth 2 (có subfolder)
# depth=1: flat (ssls/)
# depth=2: có subfolder (upstreams/<group>/, routes/<group>/)
# Output: 1 path/dòng, đã sort — không dùng find, thay bằng shell glob
# Dir không tồn tại → glob không match → in ra rỗng (an toàn cho section tùy chọn)
glob_yaml_files() {
  DIR="$1"
  DEPTH="$2"   # 1 = flat (ssls/, services/, ...), 2 = subfolder (upstreams/<group>/, routes/<group>/)

  {
    # Depth 1: file trực tiếp trong DIR
    for f in "${DIR}"/*.yaml; do
      [ -f "${f}" ] && echo "${f}"
    done

    # Depth 2: file trong subfolder (chỉ khi DEPTH=2)
    if [ "${DEPTH}" = "2" ]; then
      for subdir in "${DIR}"/*/; do
        [ -d "${subdir}" ] || continue
        for f in "${subdir}"*.yaml; do
          [ -f "${f}" ] && echo "${f}"
        done
      done
    fi
  } | sort
}

# count_yaml_files <dir> <depth>
# FIX so với bản cũ: dùng grep -c để KHÔNG đếm nhầm thành 1 khi danh sách rỗng.
#   (Bản cũ dùng heredoc + $(...) rỗng → sinh 1 dòng trống → read trả về 1 sai,
#    gây emit 'key:' rỗng cho section tùy chọn vắng mặt.)
# count_yaml_files() {
#   COUNT=0
#   while IFS= read -r _line; do
#     COUNT=$((COUNT + 1))
#   done << EOF
# $(glob_yaml_files "$1" "$2")
# EOF
#   echo "${COUNT}"
# }

count_yaml_files() {
  _files=$(glob_yaml_files "$1" "$2")
  if [ -z "${_files}" ]; then
    echo 0
  else
    printf '%s\n' "${_files}" | grep -c .
  fi
}

# =============================================================================
# Pass 1 — Validate tất cả files (hard errors)
# =============================================================================
log_info "Pass 1: Validating entity files..."

# Tập key hợp lệ — phải khớp với danh sách folder ở các vòng lặp append/validate.
VALID_KEYS="upstreams services routes global_rules consumer_groups consumers ssls"

validate_block_dir() {
  EXPECTED_KEY="$1"
  DEPTH="$2"
  BLOCK_DIR="${ROUTES_SRC}/${EXPECTED_KEY}"

  # Section tùy chọn vắng mặt → không có gì để validate
  [ -d "${BLOCK_DIR}" ] || return 0

  glob_yaml_files "${BLOCK_DIR}" "${DEPTH}" | while IFS= read -r f; do
    REL="${f#${ROUTES_SRC}/}"

    if [ ! -s "${f}" ]; then
      log_warn "Bỏ qua file rỗng: ${REL}"
      continue
    fi

    FIRST_KEY=$(get_file_key "${f}")

    # ── PATCH: File bị comment toàn bộ (disabled template) ──────────────────
    # FIRST_KEY rỗng = toàn bộ nội dung là comment hoặc blank.
    # Đây là cách hợp lệ để "tắt" 1 entity (kafka-logger, http-logger...)
    # mà vẫn giữ file trong repo làm template tham khảo.
    # → WARNING (không phải hard error), bỏ qua file này.
    # Ví dụ file bị tắt:
    #   # global_rules:
    #   #   - id: global-kafka-logger
    #   #     plugins:
    #   #       kafka-logger: ...
    if [ -z "${FIRST_KEY}" ]; then
      log_warn "Bỏ qua file bị comment toàn bộ (disabled template): ${REL}"
      continue
    fi

    KEY_VALID=0
    for k in ${VALID_KEYS}; do
      [ "${FIRST_KEY}" = "${k}" ] && KEY_VALID=1 && break
    done

    # File bị comment toàn bộ (FIRST_KEY rỗng) → skip, không phải hard error
    # Dùng để "tắt" 1 global_rule/service bằng cách comment toàn bộ nội dung
    if [ -z "${FIRST_KEY}" ]; then
      log_warn "Bỏ qua file bị comment toàn bộ (disabled): ${REL}"
      continue
    fi

    if [ "${KEY_VALID}" -eq 0 ]; then
      log_error "Không tìm thấy key hợp lệ (${VALID_KEYS}): ${REL} — tìm thấy '${FIRST_KEY}'"
      continue
    fi

    if [ "${FIRST_KEY}" != "${EXPECTED_KEY}" ]; then
      log_error "Key mismatch: file khai báo '${FIRST_KEY}:' nhưng nằm trong folder '${EXPECTED_KEY}/': ${REL}"
    fi
  done
}

# Core (bắt buộc)
validate_block_dir "upstreams" "2"
validate_block_dir "routes" "2"
validate_block_dir "ssls" "1"
# Tùy chọn (tự skip nếu thư mục chưa có)
validate_block_dir "services" "1"
validate_block_dir "global_rules" "1"
validate_block_dir "consumer_groups" "1"
validate_block_dir "consumers" "1"

# Kiểm tra error flag — dùng file để vượt subshell boundary
if [ -f "${ERROR_FLAG}" ]; then
  echo "[merge-fragments] ABORT: Có lỗi cấu trúc — không ghi output. Sửa lỗi và commit lại." >&2
  exit 1
fi

log_info "Pass 1: OK"

# =============================================================================
# Pass 2 — Gộp nội dung
# =============================================================================
log_info "Pass 2: Merging..."

cat > "${TMP_OUTPUT}" << EOF
# apisix-${DC_PROFILE}.yaml — AUTO-GENERATED by merge-fragments.sh
# KHÔNG chỉnh sửa file này trực tiếp.
# Nguồn: apisix_routes/{upstreams,services,routes,global_rules,consumer_groups,consumers,ssls}/
# Generated: $(date '+%Y-%m-%dT%H:%M:%S%z')
EOF

append_block() {
  BLOCK_KEY="$1"
  DEPTH="$2"
  BLOCK_DIR="${ROUTES_SRC}/${BLOCK_KEY}"

  FILE_COUNT=$(count_yaml_files "${BLOCK_DIR}" "${DEPTH}")

  printf '\n' >> "${TMP_OUTPUT}"
  printf '# ═══ %s (%s files) ════════════════════════════════════════════════\n' \
    "${BLOCK_KEY}" "${FILE_COUNT}" >> "${TMP_OUTPUT}"
  printf '%s:\n' "${BLOCK_KEY}" >> "${TMP_OUTPUT}"

  glob_yaml_files "${BLOCK_DIR}" "${DEPTH}" | while IFS= read -r f; do
    REL="${f#${ROUTES_SRC}/}"

    [ -s "${f}" ] || continue

    # ── PATCH: Skip file bị comment toàn bộ (disabled template) ────────────
    # Khớp với logic validate_block_dir ở Pass 1 — file FIRST_KEY rỗng
    # nghĩa là toàn bộ nội dung là comment/blank → không merge vào output.
    FKEY=$(get_file_key "${f}")
    if [ -z "${FKEY}" ]; then
      continue
    fi

    printf '  # ── src: %s\n' "${REL}" >> "${TMP_OUTPUT}"

    # Strip dòng key header (dòng đầu không phải comment/blank), giữ nguyên indent còn lại — không dùng awk
    strip_key_header "${f}" >> "${TMP_OUTPUT}"

    printf '\n' >> "${TMP_OUTPUT}"
  done
}

# Thứ tự theo chiều phụ thuộc: upstream → service → route → rule → cg → consumer → ssl
append_block "upstreams" "2"
append_block "services" "1"
append_block "routes" "2"
append_block "global_rules" "1"
append_block "consumer_groups" "1"
append_block "consumers" "1"
append_block "ssls" "1"

printf '\n#END\n' >> "${TMP_OUTPUT}"

# =============================================================================
# Pass 3 — Kiểm tra duplicate id (WARNING only)
# =============================================================================
log_info "Pass 3: Checking duplicate ids..."

# (a) Duplicate id — phủ upstreams/services/routes/global_rules/consumer_groups/ssls
DUP_IDS=$(grep -E '^[[:space:]]+-[[:space:]]+id:' "${TMP_OUTPUT}" \
  | sed 's/.*id:[[:space:]]*//' \
  | tr -d '"' \
  | sort \
  | uniq -d)

if [ -n "${DUP_IDS}" ]; then
  echo "${DUP_IDS}" | while IFS= read -r dup_id; do
    log_warn "Duplicate id '${dup_id}'"
  done
fi

# (b) Duplicate username — consumer được định danh bằng 'username', KHÔNG phải 'id'
#     nên cần check riêng (dup username = 2 account đè nhau, lỗi config thật).
DUP_USERS=$(grep -E '^[[:space:]]+-[[:space:]]+username:' "${TMP_OUTPUT}" \
  | sed 's/.*username:[[:space:]]*//' \
  | tr -d '"' \
  | sort \
  | uniq -d)

if [ -n "${DUP_USERS}" ]; then
  echo "${DUP_USERS}" | while IFS= read -r dup_user; do
    log_warn "Duplicate consumer username '${dup_user}'"
  done
fi

# =============================================================================
# Atomic replace - dùng cp để giữ inode khi mount vào docker
# =============================================================================
cp "${TMP_OUTPUT}" "${OUTPUT}"
rm -f "${TMP_OUTPUT}"

# Copy output → samples/runtime/ để admin review trên host
SAMPLES_DIR="$(dirname "${ROUTES_SRC}")/samples/runtime"
if [ -d "${SAMPLES_DIR}" ]; then
  cp "${OUTPUT}" "${SAMPLES_DIR}/apisix-${DC_PROFILE}.yaml"
  log_info "Sample updated → samples/runtime/apisix-${DC_PROFILE}.yaml"
fi

# ── Summary counts ────────────────────────────────────────────────────────────
U=$(count_yaml_files   "${ROUTES_SRC}/upstreams" "2")
SVC=$(count_yaml_files "${ROUTES_SRC}/services" "1")
R=$(count_yaml_files   "${ROUTES_SRC}/routes" "2")
GR=$(count_yaml_files  "${ROUTES_SRC}/global_rules" "1")
CG=$(count_yaml_files  "${ROUTES_SRC}/consumer_groups" "1")
CON=$(count_yaml_files "${ROUTES_SRC}/consumers" "1")
S=$(count_yaml_files   "${ROUTES_SRC}/ssls" "1")
WARN_COUNT=$(wc -l < "${WARN_FILE}" 2>/dev/null || echo 0)

log_info "Done — ${U} upstream files, ${R} route files, ${S} ssl files → ${OUTPUT}"
log_info "  upstreams=${U}  services=${SVC}  routes=${R}  global_rules=${GR}  consumer_groups=${CG}  consumers=${CON}  ssls=${S}"
[ "${WARN_COUNT}" -gt 0 ] && log_info "Có ${WARN_COUNT} warning(s) — kiểm tra log ở trên"

exit 0

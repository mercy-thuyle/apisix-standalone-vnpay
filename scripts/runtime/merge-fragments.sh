#!/bin/sh
# =============================================================================
# scripts/runtime/merge-fragments.sh
# Gộp entity files trong apisix_routes/{upstreams,routes,ssls}/
# thành 1 file apisix-${DC_PROFILE}.yaml đúng syntax APISIX standalone.
#
# Quy tắc entity file:
#   - Phải bắt đầu bằng key đúng với folder chứa nó:
#       upstreams/ → key "upstreams:"
#       routes/    → key "routes:"
#       ssls/      → key "ssls:"
#   - Items indent 2 spaces dưới key (format chuẩn YAML)
#   - Có thể chứa 1 hoặc nhiều items trong cùng 1 file
#   - Không có # END (chỉ xuất hiện 1 lần ở cuối output)
#
# Validation:
#   - Key không khớp folder    → exit 1  (hard error, block merge)
#   - File không có key hợp lệ → exit 1  (hard error, block merge)
#   - Duplicate id trong output → WARNING, tiếp tục
#   - File rỗng                → WARNING, bỏ qua
#
# Thứ tự output: upstreams → routes → ssls → # END
#
# Usage:
#   merge-fragments.sh <routes_src_dir> <output_file>
#   - Không dùng `find, awk` — git-sync container (registry.k8s.io/git-sync) không có find
#   - Dùng shell glob + while read loop thay thế
#   - Được gọi bởi: scripts/runtime/gitsync.sh
# Được gọi bởi: scripts/runtime/gitsync.sh
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

# ── Kiểm tra thư mục nguồn ───────────────────────────────────────────────────
for d in upstreams routes ssls; do
  if [ ! -d "${ROUTES_SRC}/${d}" ]; then
    echo "[merge-fragments] ERROR: Thiếu thư mục ${ROUTES_SRC}/${d}" >&2
    exit 1
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
glob_yaml_files() {
  DIR="$1"
  DEPTH="$2"   # 1 = flat (ssls/), 2 = có subfolder (upstreams/<group>/, routes/<group>/)

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
count_yaml_files() {
  COUNT=0
  while IFS= read -r _line; do
    COUNT=$((COUNT + 1))
  done << EOF
$(glob_yaml_files "$1" "$2")
EOF
  echo "${COUNT}"
}

# =============================================================================
# Pass 1 — Validate tất cả files (hard errors)
# =============================================================================
log_info "Pass 1: Validating entity files..."

VALID_KEYS="upstreams routes ssls"

validate_block_dir() {
  EXPECTED_KEY="$1"
  DEPTH="$2"
  BLOCK_DIR="${ROUTES_SRC}/${EXPECTED_KEY}"

  glob_yaml_files "${BLOCK_DIR}" "${DEPTH}" | while IFS= read -r f; do
    REL="${f#${ROUTES_SRC}/}"

    if [ ! -s "${f}" ]; then
      log_warn "Bỏ qua file rỗng: ${REL}"
      continue
    fi

    FIRST_KEY=$(get_file_key "${f}")

    KEY_VALID=0
    for k in ${VALID_KEYS}; do
      [ "${FIRST_KEY}" = "${k}" ] && KEY_VALID=1 && break
    done

    if [ "${KEY_VALID}" -eq 0 ]; then
      log_error "Không tìm thấy key hợp lệ (upstreams/routes/ssls): ${REL} — tìm thấy '${FIRST_KEY}'"
      continue
    fi

    if [ "${FIRST_KEY}" != "${EXPECTED_KEY}" ]; then
      log_error "Key mismatch: file khai báo '${FIRST_KEY}:' nhưng nằm trong folder '${EXPECTED_KEY}/': ${REL}"
    fi
  done
}

validate_block_dir "upstreams" "2"
validate_block_dir "routes"    "2"
validate_block_dir "ssls"      "1"

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
# Nguồn: apisix_routes/upstreams/ + routes/ + ssls/
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

    printf '  # ── src: %s\n' "${REL}" >> "${TMP_OUTPUT}"

    # Strip dòng key header (dòng đầu không phải comment/blank), giữ nguyên indent còn lại — không dùng awk
    strip_key_header "${f}" >> "${TMP_OUTPUT}"

    printf '\n' >> "${TMP_OUTPUT}"
  done
}

append_block "upstreams" "2"
append_block "routes"    "2"
append_block "ssls"      "1"

printf '\n#END\n' >> "${TMP_OUTPUT}"

# =============================================================================
# Pass 3 — Kiểm tra duplicate id (WARNING only)
# =============================================================================
log_info "Pass 3: Checking duplicate ids..."

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

# =============================================================================
# Atomic replace
# =============================================================================
mv "${TMP_OUTPUT}" "${OUTPUT}"

U=$(count_yaml_files "${ROUTES_SRC}/upstreams" "2")
R=$(count_yaml_files "${ROUTES_SRC}/routes"    "2")
S=$(count_yaml_files "${ROUTES_SRC}/ssls"      "1")
WARN_COUNT=$(wc -l < "${WARN_FILE}" 2>/dev/null || echo 0)

log_info "Done — ${U} upstream files, ${R} route files, ${S} ssl files → ${OUTPUT}"
[ "${WARN_COUNT}" -gt 0 ] && log_info "Có ${WARN_COUNT} warning(s) — kiểm tra log ở trên"

exit 0
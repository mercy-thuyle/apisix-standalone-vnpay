#!/bin/sh

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
for d in upstreams routes services ssls; do
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
ERROR_FLAG="/tmp/merge-fragments-error.$$"
WARN_FILE="/tmp/merge-fragments-warn.$$"

# Cleanup khi exit (dù thành công hay lỗi)
trap 'rm -f "${ERROR_FLAG}" "${WARN_FILE}" "${TMP_OUTPUT}" 2>/dev/null || true' EXIT

# Khởi tạo
touch "${WARN_FILE}"

# ── Helpers ───────────────────────────────────────────────────────────────────
log_info()  { echo "[merge-fragments] $*"; }

log_warn() {
  echo "[merge-fragments] WARN: $*" >&2
  echo "1" >> "${WARN_FILE}"
}

log_error() {
  echo "[merge-fragments] ERROR: $*" >&2
  touch "${ERROR_FLAG}"
}

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
VALID_KEYS="global_rules plugin_metadata upstreams services plugin_configs routes consumer_groups consumers ssls"

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
validate_block_dir "upstreams" "1"
validate_block_dir "services" "1"
validate_block_dir "routes" "2"
validate_block_dir "ssls" "1"
# ── Thư mục TÙY CHỌN — thiếu thì chỉ log INFO, KHÔNG lỗi ─────────────────────
#   append_block()/validate_block_dir() tự skip khi thư mục vắng mặt
#   (tùy chọn, tự skip nếu thư mục chưa có)
validate_block_dir "plugin_metadata" "1"
validate_block_dir "plugin_configs" "1"
validate_block_dir "global_rules" "1"
validate_block_dir "consumer_groups" "1"
validate_block_dir "consumers" "2"

KNOWN_PLUGIN_METADATA_IDS="http-logger kafka-logger tcp-logger udp-logger clickhouse-logger elasticsearch-logger loki-logger loggly splunk-hec-logging rocketmq-logger sls-logger skywalking-logger google-cloud-logging datadog opentelemetry"
PM_DIR="${ROUTES_SRC}/plugin_metadata"
if [ -d "${PM_DIR}" ]; then
  glob_yaml_files "${PM_DIR}" "1" | while IFS= read -r f; do
    [ -s "${f}" ] || continue
    grep -E '^\s+-\s+id:' "${f}" \
      | sed 's/.*id:[[:space:]]*//' \
      | sed 's/[[:space:]]*#.*//' \
      | tr -d '"' \
      | sed 's/[[:space:]]*$//' \
      | while IFS= read -r pm_id; do
      MATCH=0
      for k in ${KNOWN_PLUGIN_METADATA_IDS}; do
        [ "${pm_id}" = "${k}" ] && MATCH=1 && break
      done
      if [ "${MATCH}" -eq 0 ]; then
        log_warn "plugin_metadata id '${pm_id}' trong $(basename "${f}") không khớp allowlist plugin logger đã biết (${KNOWN_PLUGIN_METADATA_IDS}) — kiểm tra lại đúng tên plugin thật chưa (vd 'kafka-logger'), nếu không plugin sẽ KHÔNG đọc được metadata này (silent no-op). Nếu đây là plugin hợp lệ ngoài danh sách, thêm vào KNOWN_PLUGIN_METADATA_IDS."
      fi
    done
  done
fi

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
# Nguồn: apisix_routes/{upstreams,services,plugin_configs,routes,global_rules,consumer_groups,consumers,ssls}/
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

# Thứ tự theo chiều phụ thuộc: global_rules → plugin_metadata → upstreams → services → plugin_configs → routes → consumer_groups → consumers → ssls
append_block "global_rules" "1"
append_block "plugin_metadata" "1"
append_block "upstreams" "1"
append_block "services" "1"
append_block "plugin_configs" "1"
append_block "routes" "2"
append_block "consumer_groups" "1"
append_block "consumers" "2"
append_block "ssls" "1"

printf '\n#END\n' >> "${TMP_OUTPUT}"

# =============================================================================
# Pass 3 — Kiểm tra duplicate id (WARNING only)
# =============================================================================
log_info "Pass 3: Checking duplicate ids..."

# (a) Duplicate id — phủ upstreams/services/routes/global_rules/consumer_groups/ssls
DUP_IDS=$(grep -E '^[[:space:]]+-[[:space:]]+id:' "${TMP_OUTPUT}" \
  | sed 's/.*id:[[:space:]]*//' \
  | sed 's/[[:space:]]*#.*//' \
  | tr -d '"' \
  | sed 's/[[:space:]]*$//' \
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
PM=$(count_yaml_files  "${ROUTES_SRC}/plugin_metadata" "1")
GR=$(count_yaml_files  "${ROUTES_SRC}/global_rules" "1")
U=$(count_yaml_files   "${ROUTES_SRC}/upstreams" "1")
SVC=$(count_yaml_files "${ROUTES_SRC}/services" "1")
PC=$(count_yaml_files  "${ROUTES_SRC}/plugin_configs" "1")
R=$(count_yaml_files   "${ROUTES_SRC}/routes" "2")
CG=$(count_yaml_files  "${ROUTES_SRC}/consumer_groups" "1")
CON=$(count_yaml_files "${ROUTES_SRC}/consumers" "1")
S=$(count_yaml_files   "${ROUTES_SRC}/ssls" "1")
WARN_COUNT=$(wc -l < "${WARN_FILE}" 2>/dev/null || echo 0)

log_info "Done — ${U} upstream files, ${R} route files, ${S} ssl files → ${OUTPUT}"
log_info "  plugin_metadata=${PM} global_rules=${GR}  upstreams=${U}  services=${SVC} plugin_configs=${PC} routes=${R}  consumer_groups=${CG}  consumers=${CON}  ssls=${S}"
[ "${WARN_COUNT}" -gt 0 ] && log_info "Có ${WARN_COUNT} warning(s) — kiểm tra log ở trên"

exit 0

#!/bin/sh

set -eu

# ── Tham số ──────────────────────────────────────────────────────────────────
ROUTES_SRC="${1:-/tmp/sync/current/apisix_routes}"
OUTPUT="${2:-}"
PROJECT="${PROJECT:?PROJECT is required}"
DC_SITE="${DC_SITE:?DC_SITE is required}"
APISIX_PROFILE="${PROJECT}-${DC_SITE}"

# ── Kiểm tra APISIX_PROFILE và source revision ───────────────────────────────
if [ -z "${DC_SITE:-}" ]; then
  echo "[merge-fragments] ERROR: DC_SITE chưa được set" >&2
  exit 1
fi

if [ -z "${PROJECT:-}" ]; then
  echo "[merge-fragments] ERROR: PROJECT chưa được set" >&2
  exit 1
fi

if [ -z "${OUTPUT}" ]; then
  OUTPUT="/tmp/apisix_routes/apisix-${APISIX_PROFILE}.yaml"
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

# Trả về 0 khi fragment được áp dụng cho DC_SITE hiện tại.
#
# Quy ước mới:
#   <entity>/hcm/*.yaml  → chỉ merge tại HCM
#   <entity>/han/*.yaml  → chỉ merge tại HAN
#   <entity>/*.yaml      → merge cho mọi DC
#
# Giữ nhận diện hậu tố cũ trong giai đoạn migration:
#   foo-hcm.yaml / foo-han.yaml
fragment_applies_to_profile() {
  FRAGMENT_PATH="$1"

  case "/${FRAGMENT_PATH}/" in
    */hcm/*)
      [ "${DC_SITE}" = "hcm" ]
      ;;
    */han/*)
      [ "${DC_SITE}" = "han" ]
      ;;
    *)
      case "${FRAGMENT_PATH}" in
    *-hcm.yaml)
      [ "${DC_SITE}" = "hcm" ]
      ;;
    *-han.yaml)
      [ "${DC_SITE}" = "han" ]
      ;;
    *)
      return 0
      ;;
      esac
  esac
}

get_file_key() {
  grep -v '^\s*#' "$1" | grep -v '^\s*$' | head -1 | sed 's/:.*//' | tr -d ' '
}

# Strip dòng key header (dòng đầu tiên không phải comment/blank), in phần còn lại
# Thay thế awk — không có trong git-sync container
strip_key_header() {
  SKIPPED=0
  # { cat; echo; } đảm bảo LUÔN có newline cuối trước khi đưa vào read loop —
  # nếu không, "while read" (POSIX sh) sẽ ÂM THẦM bỏ qua đúng dòng cuối cùng
  # của file khi dòng đó không kết thúc bằng \n (không báo lỗi, không log).
  # Bug thật đã xảy ra với global-network-identity.yaml: dòng "end" cuối cùng
  # (đóng function Lua) bị cắt mất, khiến plugin load lỗi "'end' expected".
  # Fix ở ĐÂY (áp dụng cho MỌI fragment file) thay vì chỉ thêm newline vào
  # từng file — không thể trông cậy mọi người luôn nhớ để trailing newline.
  # In bằng printf '%s\n', KHÔNG dùng echo: echo của dash (sh trong image APISIX
  # Debian dùng cho ADC) diễn giải backslash — "\r", "\n" trong code Lua serverless
  # bị đổi thành CR/LF thật, cắt ngang block scalar YAML → apisix init báo
  # "did not find expected key". printf '%s' in nguyên văn trên mọi shell POSIX.
  { cat "$1"; echo; } | while IFS= read -r line; do
    case "${line}" in
      "#"*|"  #"*|"   #"*|"")
        printf '%s\n' "${line}"
        continue
        ;;
    esac
    if [ "${SKIPPED}" = "0" ]; then
      SKIPPED=1
      continue
    fi
    printf '%s\n' "${line}"
  done
}

# glob_yaml_files <dir> <max_depth>
# Liệt kê file YAML từ depth 1 đến max_depth.
#
# Ví dụ routes:
#   routes/foo.yaml                              → depth 1, common
#   routes/<workload>/foo.yaml                   → depth 2, common
#   routes/<workload>/<region>/foo.yaml          → depth 3, theo DC
#
# Ví dụ upstreams/services:
#   upstreams/<workload>/<region>/foo.yaml
#   services/<workload>/<region>/foo.yaml
#
# Không dùng find vì git-sync container không bảo đảm có đầy đủ tiện ích đó.
# Output: 1 path/dòng, đã sort — không dùng find, thay bằng shell glob.
# Chỉ in file áp dụng cho DC_SITE; do đó Pass 1, merge, summary và metadata
# đều dùng cùng một tập fragment. File -han.yaml lỗi không chặn deploy HCM.
# Dir không tồn tại → glob không match → in ra rỗng (an toàn cho section tùy chọn).
glob_yaml_files() {
  DIR="$1"
  MAX_DEPTH="$2"   # 1 = flat (ssls/, services/, ...), 2 = subfolder (upstreams/<group>/, routes/<group>/)

  {
    # Depth 1: file trực tiếp trong DIR
    for f in "${DIR}"/*.yaml; do
      [ -f "${f}" ] || continue
      fragment_applies_to_profile "${f}" || continue
      echo "${f}"
    done

    # Depth 2: file trong workload/ hoặc region/ hoặc file trong subfolder (chỉ khi DEPTH=2)
    if [ "${MAX_DEPTH}" -ge 2 ]; then
      for subdir in "${DIR}"/*/; do
        [ -d "${subdir}" ] || continue
        for f in "${subdir}"*.yaml; do
          [ -f "${f}" ] || continue
          fragment_applies_to_profile "${f}" || continue
          echo "${f}"
        done
      done
    fi

    # Depth 3: file trong <workload>/<region>/
    if [ "${MAX_DEPTH}" -ge 3 ]; then
      for subdir in "${DIR}"/*/; do
        [ -d "${subdir}" ] || continue
        for nested_dir in "${subdir}"*/; do
          [ -d "${nested_dir}" ] || continue
          for f in "${nested_dir}"*.yaml; do
            [ -f "${f}" ] || continue
            fragment_applies_to_profile "${f}" || continue
            echo "${f}"
          done
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
VALID_KEYS="global_rules plugin_metadata secrets upstreams services plugin_configs routes consumer_groups consumers ssls"

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
validate_block_dir "upstreams" "2"
validate_block_dir "services" "2"
validate_block_dir "routes" "3"
validate_block_dir "ssls" "1"
# ── Thư mục TÙY CHỌN — thiếu thì chỉ log INFO, KHÔNG lỗi ─────────────────────
#   append_block()/validate_block_dir() tự skip khi thư mục vắng mặt
#   (tùy chọn, tự skip nếu thư mục chưa có)
validate_block_dir "plugin_metadata" "1"
validate_block_dir "plugin_configs" "1"
validate_block_dir "global_rules" "2"
validate_block_dir "secrets" "1"
validate_block_dir "consumer_groups" "1"
validate_block_dir "consumers" "2"

# Metadata có thể thuộc built-in logger hoặc custom plugin. Giữ allowlist để
# bắt typo silent no-op, đồng thời khai đúng các custom ID hiện được load bởi
# config-proxyhub.yaml; nếu thêm custom plugin mới thì thêm ID tương ứng ở đây.
KNOWN_PLUGIN_METADATA_IDS="http-logger kafka-logger tcp-logger udp-logger clickhouse-logger elasticsearch-logger loki-logger loggly splunk-hec-logging rocketmq-logger sls-logger skywalking-logger google-cloud-logging datadog opentelemetry custom.log-level custom.s3-traffic-classifier"
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
        log_warn "plugin_metadata id '${pm_id}' trong $(basename "${f}") không khớp allowlist plugin đã biết (${KNOWN_PLUGIN_METADATA_IDS}) — kiểm tra lại đúng tên plugin thật chưa, nếu không plugin sẽ KHÔNG đọc được metadata này (silent no-op). Nếu đây là plugin hợp lệ ngoài danh sách, thêm vào KNOWN_PLUGIN_METADATA_IDS."
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
# apisix-${APISIX_PROFILE}.yaml — AUTO-GENERATED by merge-fragments.sh
# KHÔNG chỉnh sửa file này trực tiếp.
# Nguồn: apisix_routes/{upstreams,services,plugin_configs,routes,global_rules,consumer_groups,consumers,ssls}/
# Phạm vi DC: <entity>/hcm/ chỉ cho hcm; <entity>/han/ chỉ cho han; file trực tiếp dùng chung.
# Tương thích tạm: *-hcm.yaml / *-han.yaml.
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

# Thứ tự theo chiều phụ thuộc: global_rules → plugin_metadata → secrets → upstreams → services → plugin_configs → routes → consumer_groups → consumers → ssls
# secrets đặt trước ssls vì ssls (cert/key dạng $secret://vault/...) tham chiếu tới id khai trong secrets
append_block "global_rules" "2"
append_block "plugin_metadata" "1"
append_block "secrets" "1"
append_block "upstreams" "2"
append_block "services" "2"
append_block "plugin_configs" "1"
append_block "routes" "3"
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

# Copy output → samples/runtime/ để admin review trên host. Dry-run/CI chỉ cần
# artifact đích, không được ghi vào working tree (đặc biệt khi source mount :ro).
SAMPLES_DIR="$(dirname "${ROUTES_SRC}")/samples/runtime"
if [ "${SKIP_SAMPLE_UPDATE:-0}" = "1" ]; then
  log_info "Sample update skipped (SKIP_SAMPLE_UPDATE=1)"
elif [ -d "${SAMPLES_DIR}" ]; then
  cp "${OUTPUT}" "${SAMPLES_DIR}/apisix-${APISIX_PROFILE}.yaml"
  log_info "Sample updated → samples/runtime/apisix-${APISIX_PROFILE}.yaml"
fi

# ── Summary counts ────────────────────────────────────────────────────────────
PM=$(count_yaml_files  "${ROUTES_SRC}/plugin_metadata" "1")
GR=$(count_yaml_files  "${ROUTES_SRC}/global_rules" "2")
SEC=$(count_yaml_files "${ROUTES_SRC}/secrets" "1")
U=$(count_yaml_files   "${ROUTES_SRC}/upstreams" "2")
SVC=$(count_yaml_files "${ROUTES_SRC}/services" "2")
PC=$(count_yaml_files  "${ROUTES_SRC}/plugin_configs" "1")
R=$(count_yaml_files   "${ROUTES_SRC}/routes" "3")
CG=$(count_yaml_files  "${ROUTES_SRC}/consumer_groups" "1")
CON=$(count_yaml_files "${ROUTES_SRC}/consumers" "1")
S=$(count_yaml_files   "${ROUTES_SRC}/ssls" "1")
WARN_COUNT=$(wc -l < "${WARN_FILE}" 2>/dev/null || echo 0)

log_info "Done — profile=${APISIX_PROFILE}; ${U} upstream files, ${R} route files, ${S} ssl files → ${OUTPUT}"
log_info "  plugin_metadata=${PM} global_rules=${GR} secrets=${SEC}  upstreams=${U}  services=${SVC} plugin_configs=${PC} routes=${R}  consumer_groups=${CG}  consumers=${CON}  ssls=${S}"
[ "${WARN_COUNT}" -gt 0 ] && log_info "Có ${WARN_COUNT} warning(s) — kiểm tra log ở trên"

exit 0

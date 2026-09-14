#!/bin/sh

# VNPAY ADC (bộ điều khiển dry-run APISIX)
#
# GitSync ghi SHA của commit vào /tmp/adc/request-<profile>. Container chạy nền
# này kiểm tra đúng checkout đó trong môi trường không có network, sau đó ghi
# một dòng kết quả theo cách atomic vào /tmp/adc/result-<profile>:
#   <commit>\tPASS|FAIL\t<detail>
#
# PASS đồng thời tạo approved-<profile>.yaml, chứng minh candidate đã merge và
# được APISIX chấp nhận. Chỉ GitSync mới được promote file staging đã inject
# của chính nó sang file route live đang bind mount.

set -eu

# ── Trạng thái dùng chung và checkout source ─────────────────────────────────
SYNC_SRC="/tmp/sync/current"
ADC_DIR="/tmp/adc"
PROFILE="${DC_PROFILE:?DC_PROFILE is required}"

REQUEST="${ADC_DIR}/request-${PROFILE}"
RESULT="${ADC_DIR}/result-${PROFILE}"
HEARTBEAT="${ADC_DIR}/heartbeat-${PROFILE}"
LOG_DIR="/tmp/logs/adc"
LOG_FILE="${LOG_DIR}/adc.log"

mkdir -p "${ADC_DIR}/work"
mkdir -p "${LOG_DIR}"
touch "${LOG_FILE}" 2>/dev/null || true
last_commit=""

# Ghi log vận hành ra Docker stdout và logs/adc/adc.log trên host.
# Không log nội dung YAML hoặc biến môi trường để tránh lộ secret.
log() {
  _msg="[adc] $(date -Iseconds) $*"
  printf '%s\n' "${_msg}"
  printf '%s\n' "${_msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# Ghi verdict theo cách atomic để GitSync không đọc phải dòng dang dở.
result() {
  commit="$1"
  status="$2"
  detail="$3"
  tmp="${RESULT}.tmp.$$"

  printf '%s\t%s\t%s\n' "${commit}" "${status}" "${detail}" > "${tmp}"
  mv "${tmp}" "${RESULT}"
  log "VERDICT — commit=${commit} status=${status} detail=${detail}"
}

# Dừng trọn worker validator trước khi trả verdict hoặc chạy transaction kế tiếp.
stop_validator() {
  apisix quit > /dev/null 2>&1 || true

  for _ in $(seq 1 40); do
    nginx_pid="$(cat /usr/local/apisix/logs/nginx.pid 2>/dev/null || true)"
    case "${nginx_pid}" in
      ''|*[!0-9]*) break ;;
      *)
        kill -0 "${nginx_pid}" 2>/dev/null || break
        ;;
    esac
    sleep 0.25
  done

  # Fallback nếu graceful quit chưa nhả master trong 10 giây.
  nginx_pid="$(cat /usr/local/apisix/logs/nginx.pid 2>/dev/null || true)"
  case "${nginx_pid}" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "${nginx_pid}" 2>/dev/null; then
        apisix stop > /dev/null 2>&1 || true
      fi
      ;;
  esac
}

# Validate một checkout GitSync bất biến. Mọi lỗi đều trả về cho bên yêu cầu;
# controller vẫn tiếp tục chạy để xử lý commit kế tiếp.
validate() {
  commit="$1"
  work="${ADC_DIR}/work/${PROFILE}-${commit}"
  # File chứng thực mang SHA để GitSync chỉ chấp nhận đúng transaction này.
  approved="${ADC_DIR}/approved-${PROFILE}-${commit}.yaml"
  ADC_ERROR_LOG="${work}/error.log"

  rm -rf "${work}"
  mkdir -p "${work}"
  : > "${ADC_ERROR_LOG}"
  log "START — commit=${commit} work=${work}"

  # GitSync chỉ gọi exechook sau khi checkout hoàn tất và chờ hook kết thúc trước khi sync tiếp.
  # Lock của gitsync.sh cũng chặn transaction chồng nhau;
  # vì vậy commit trong request chính là revision bất biến của lần validate này.

  # Chỉ merge từ source đã pull. samples/runtime tuyệt đối không bị ghi đè.
  if ! SKIP_SAMPLE_UPDATE=1 \
       DC_PROFILE="${PROFILE}" \
       sh "${SYNC_SRC}/scripts/runtime/merge-fragments.sh" \
       "${SYNC_SRC}/apisix_routes" \
       "${work}/apisix-${PROFILE}.yaml" > "${work}/merge.log" 2>&1; then
    result "${commit}" FAIL "merge failed"
    return
  fi
  log "OK — merge fragments"

  # Dựng private view APISIX của validator từ checkout candidate.
  cp "${SYNC_SRC}/apisix_config/config-${PROFILE}.yaml" \
     "/usr/local/apisix/conf/config-${PROFILE}.yaml"
  cp "${work}/apisix-${PROFILE}.yaml" \
     "/usr/local/apisix/conf/apisix-${PROFILE}.yaml"

  # Không đọc error.log mặc định: image APISIX nối nó vào stdout/stderr pipe,
  # khiến grep chờ EOF vô hạn. ADC phải có regular file riêng cho transaction.
  sed -i \
    "s|^  error_log:.*$|  error_log: ${ADC_ERROR_LOG}|" \
    "/usr/local/apisix/conf/config-${PROFILE}.yaml"

  # Chỉ thay file bên trong ADC container dùng một lần, không đụng file host.
  rm -rf /usr/local/apisix/apisix/plugins/custom \
         /usr/local/apisix/apisix/plugins/libraries
  ln -s "${SYNC_SRC}/plugins/custom" \
        /usr/local/apisix/apisix/plugins/custom
  ln -s "${SYNC_SRC}/plugins/libraries" \
        /usr/local/apisix/apisix/plugins/libraries

  # Giữ validator đồng nhất với các file override của image APISIX production.
  for patch in vault config_yaml kafka-logger; do
    [ -f "/tmp/adc-patches/${patch}.lua" ] || continue

    case "${patch}" in
      vault)
        target="/usr/local/apisix/apisix/secret/vault.lua"
        ;;
      config_yaml)
        target="/usr/local/apisix/apisix/core/config_yaml.lua"
        ;;
      kafka-logger)
        target="/usr/local/apisix/apisix/plugins/kafka-logger.lua"
        ;;
    esac

    cp "/tmp/adc-patches/${patch}.lua" "${target}"
  done

  # Compile mọi Lua plugin trong repo trước khi APISIX nạp schema của chúng.
  if ! find "${SYNC_SRC}/plugins" -type f -name '*.lua' -print0 \
       | sort -z \
       | xargs -0 -r -n1 /usr/local/openresty/luajit/bin/luajit -bl \
         > /dev/null; then
    result "${commit}" FAIL "Lua syntax failed"
    return
  fi
  log "OK — Lua syntax"

  if ! apisix init > "${work}/apisix-init.log" 2>&1; then
    result "${commit}" FAIL "apisix init failed"
    return
  fi
  log "OK — apisix init"

  # config_yaml.lua nạp standalone YAML theo timer sau khi worker boot.
  # Xóa log cũ để chỉ xét lỗi phát sinh từ candidate hiện tại.

  # Image APISIX chạy OpenResty foreground; chạy nền để ADC còn kiểm tra được
  # worker rồi chủ động quit, không làm GitSync exechook bị treo.
  apisix start > "${work}/apisix-start.log" 2>&1 &
  apisix_start_pid=$!

  ready=0
  for _ in $(seq 1 20); do
    # Wrapper `apisix start` có thể thoát ngay sau khi spawn nginx master.
    # Nguồn chân lý là nginx.pid, không phải PID của wrapper.
    nginx_pid="$(cat /usr/local/apisix/logs/nginx.pid 2>/dev/null || true)"
    case "${nginx_pid}" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "${nginx_pid}" 2>/dev/null; then
          ready=1
          break
        fi
        ;;
    esac

    # Chỉ fail nếu wrapper đã thoát mà nginx master chưa hề xuất hiện.
    if ! kill -0 "${apisix_start_pid}" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done

  if [ "${ready}" -ne 1 ]; then
    stop_validator
    wait "${apisix_start_pid}" 2>/dev/null || true
    log "FAIL — APISIX worker không ready; xem ${work}/apisix-start.log"
    result "${commit}" FAIL "APISIX worker not ready"
    return
  fi
  log "OK — APISIX worker ready"

  # Chờ ít nhất một chu kỳ config_yaml rồi mới kết luận candidate hợp lệ.
  # Không chỉ dựa vào PID worker: schema route/plugin sai vẫn có thể xuất hiện sau khi Nginx đã start thành công.
  # Worker chạy không đồng nghĩa declarative config hợp lệ.
  # Chờ ít nhất một chu kỳ config_yaml rồi kiểm tra lỗi schema/YAML từ candidate này.
  # config_yaml.lua của stack này có chu kỳ tối đa 30s. Chờ dài hơn một chu kỳ
  # để schema route/plugin được nạp thật trước khi ADC có thể trả PASS.
  sleep "${ADC_CONFIG_SETTLE_SECONDS:-35}"

  if grep -Eq \
      'config_yaml\.lua:.*(failed to check item data|failed to load|failed to parse)' \
      "${ADC_ERROR_LOG}"; then
    log "FAIL — APISIX từ chối declarative config; xem error.log trong ADC"
    stop_validator
    wait "${apisix_start_pid}" 2>/dev/null || true
    result "${commit}" FAIL "APISIX declarative config rejected"
    return
  fi
  log "OK — declarative config accepted"

  # Dừng worker validator; tuyệt đối không ảnh hưởng APISIX production.
  stop_validator
  wait "${apisix_start_pid}" 2>/dev/null || true

  # Artifact này chứng minh ADC thành công; GitSync giữ staging đã inject cert.
  if ! cp "${work}/apisix-${PROFILE}.yaml" "${approved}" ||
     [ ! -s "${approved}" ]; then
    result "${commit}" FAIL "ADC approval artifact write failed"
    return
  fi
  result "${commit}" PASS "validated"
}

# ── Vòng lặp điều khiển ─────────────────────────────────────────────────────
# Không validate lại cùng request mỗi giây. SHA mới tạo một transaction validate
# mới.
while :; do
  # Healthcheck dùng timestamp này để phát hiện controller bị treo.
  date +%s > "${HEARTBEAT}"

  if [ -s "${REQUEST}" ]; then
    commit="$(cat "${REQUEST}" 2>/dev/null || true)"

    if [ -n "${commit}" ] && [ "${commit}" != "${last_commit}" ]; then
      last_commit="${commit}"
      validate "${commit}"
    fi
  fi

  sleep 1
done

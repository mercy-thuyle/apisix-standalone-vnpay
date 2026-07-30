#!/usr/bin/env bash
# verify-apisix.sh
# Verify tổng hợp APISIX standalone (config_yaml.lua, KHÔNG có Admin API/etcd)
#
# Nguyên tắc mỗi bước trong script: EXPLAIN (đang test service/route/logic nào, vì sao)
# -> RUN -> RESULT (kết quả kèm next-step cụ thể nếu OK/WARN/FAIL), không chỉ echo số liệu khô.
#
# Usage (default — dùng AWS profile 'thuyldx-cloud' + bucket 'thuyldx-cloud', REGION_TAG TỰ NHẬN DIỆN
# từ hostname VM, không cần set tay khi chạy trên node HCM hoặc HAN):
#   ./verify-apisix.sh
#
# Override khi cần:
#   REGION_TAG=hcm ./verify-apisix.sh        # ép region nếu hostname không convention chuẩn
#   AWS_PROFILE=other-profile ./verify-apisix.sh
#   S3_TEST_BUCKET=other-bucket ./verify-apisix.sh
#   AWS_ACCESS_KEY_ID=xxx AWS_SECRET_ACCESS_KEY=yyy ./verify-apisix.sh   # session tạm, KHÔNG lưu vào file
#
# LƯU Ý BẢO MẬT: secret KHÔNG được hardcode trong script này. Setup profile 1 lần
# (dùng đúng user sẽ chạy script này, thường là root):
#   aws configure set aws_access_key_id <akid> --profile thuyldx-cloud
#   aws configure set aws_secret_access_key <secret> --profile thuyldx-cloud
# Script tự dò credentials qua: $AWS_SHARED_CREDENTIALS_FILE (nếu set) -> $HOME/.aws/credentials
# -> /root/.aws/credentials -> /home/*/.aws/credentials — không phụ thuộc $HOME lúc chạy qua
# sudo/su/cron. Nếu file nằm chỗ khác, chỉ định thẳng: AWS_SHARED_CREDENTIALS_FILE=/path/to/credentials
# curl --user vẫn hiện AK/SK trong `ps aux` lúc chạy (mọi user cùng máy thấy được) —
# nếu máy nhiều người dùng chung, cân nhắc chạy trong session riêng hoặc dùng cred ngắn hạn (STS).

set -uo pipefail

# ---------- AWS credentials (KHÔNG hardcode secret vào script — dùng AWS profile) ----------
# Ưu tiên theo thứ tự:
#   1. AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY nếu đã export sẵn trong shell (session tạm, không lưu)
#   2. AWS_PROFILE (mặc định: thuyldx-cloud) đọc từ ~/.aws/credentials qua `aws configure get`
#      -> setup 1 lần: aws configure set aws_access_key_id ... --profile thuyldx-cloud
#                       aws configure set aws_secret_access_key ... --profile thuyldx-cloud
#   Secret KHÔNG bao giờ được echo ra màn hình bởi script này.
AWS_PROFILE="${AWS_PROFILE:-thuyldx-cloud}"
S3_TEST_BUCKET="${S3_TEST_BUCKET:-thuyldx-cloud}"
# Nếu có biến riêng theo region (S3_TEST_BUCKET_HCM / S3_TEST_BUCKET_HAN), ưu tiên dùng
# để test full round-trip (GET/PUT/HEAD/DELETE) không bị 307 redirect do bucket khác home region.
# Mặc định vẫn dùng chung 1 bucket — 307 khi đó là tín hiệu HỢP LỆ (auth OK, sai region), không phải lỗi.

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  if command -v aws >/dev/null 2>&1; then
    # $HOME lúc script chạy có thể KHÔNG phải nơi chứa .aws/credentials thật
    # (chạy qua sudo/su/cron/khác user). Dò qua danh sách path cụ thể thay vì
    # chỉ tin vào $HOME hiện tại.
    CRED_FILE_CANDIDATES=(
      "${AWS_SHARED_CREDENTIALS_FILE:-}"
      "${HOME}/.aws/credentials"
      "/root/.aws/credentials"
    )
    # Thêm .aws/credentials của mọi user thật trong /home/*
    for d in /home/*/.aws/credentials; do
      [ -f "$d" ] && CRED_FILE_CANDIDATES+=("$d")
    done

    FOUND_CRED_FILE=""
    for f in "${CRED_FILE_CANDIDATES[@]}"; do
      [ -n "$f" ] && [ -f "$f" ] && grep -q "^\[${AWS_PROFILE}\]" "$f" 2>/dev/null && { FOUND_CRED_FILE="$f"; break; }
    done

    if [ -n "$FOUND_CRED_FILE" ]; then
      _AKID=$(AWS_SHARED_CREDENTIALS_FILE="$FOUND_CRED_FILE" aws configure get aws_access_key_id --profile "$AWS_PROFILE" 2>/dev/null)
      _SKEY=$(AWS_SHARED_CREDENTIALS_FILE="$FOUND_CRED_FILE" aws configure get aws_secret_access_key --profile "$AWS_PROFILE" 2>/dev/null)
      if [ -n "$_AKID" ] && [ -n "$_SKEY" ]; then
        export AWS_ACCESS_KEY_ID="$_AKID"
        export AWS_SECRET_ACCESS_KEY="$_SKEY"
        echo "  [INFO] Đã nạp credential từ profile '$AWS_PROFILE' trong $FOUND_CRED_FILE, akid=${_AKID:0:8}**** (secret ẩn)"
      else
        echo "  [INFO] Thấy section [$AWS_PROFILE] trong $FOUND_CRED_FILE nhưng thiếu key — SigV4 test sẽ bị SKIP"
      fi
      unset _AKID _SKEY
    else
      echo "  [INFO] Không tìm thấy profile '$AWS_PROFILE' trong: ${CRED_FILE_CANDIDATES[*]} — SigV4 test sẽ bị SKIP"
      echo "         Đặt biến AWS_SHARED_CREDENTIALS_FILE=<path> nếu file nằm chỗ khác, hoặc:"
      echo "         aws configure set aws_access_key_id <akid> --profile $AWS_PROFILE"
      echo "         aws configure set aws_secret_access_key <secret> --profile $AWS_PROFILE"
    fi
  else
    echo "  [INFO] Không có aws-cli và AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY chưa export — SigV4 test sẽ bị SKIP"
  fi
fi
# ---------- Config còn lại (override qua env) ----------
BASE_DIR="${BASE_DIR:-/opt/apisix/standalone/sandbox}"
# ── Auto-load KAFKA_SASL_PASSWORD từ .env (KHÔNG echo secret ra màn hình) ────
# .env đã dùng chung cho REDIS_PASSWORD/CERT_PASSPHRASE/VAULT_* qua
# docker-compose env_file: .env — verify script đọc cùng file, tránh phải
# export tay mỗi lần chạy (đồng bộ style với credential AWS_PROFILE ở trên).
if [ -z "${KAFKA_SASL_PASSWORD:-}" ] && [ -f "${BASE_DIR}/.env" ]; then
  _KAFKA_PW_FROM_ENV=$(grep -E '^KAFKA_SASL_PASSWORD=' "${BASE_DIR}/.env" | tail -1 | cut -d= -f2-)
  if [ -n "$_KAFKA_PW_FROM_ENV" ]; then
    export KAFKA_SASL_PASSWORD="$_KAFKA_PW_FROM_ENV"
    echo "  [INFO] Đã nạp KAFKA_SASL_PASSWORD từ ${BASE_DIR}/.env (secret ẩn)"
  else
    echo "  [INFO] Không thấy KAFKA_SASL_PASSWORD trong ${BASE_DIR}/.env — end-to-end Kafka test sẽ bị SKIP nếu không export tay"
  fi
  unset _KAFKA_PW_FROM_ENV
fi
S3_HOST="${S3_HOST:-s3-hcm.sds.infiniband.vn}"
NON_S3_HOST="${NON_S3_HOST:-cmc.sds.infiniband.vn}"
RESOLVE_IP="${RESOLVE_IP:-127.0.0.1}"

# Auto-detect region từ hostname VM thay vì hardcode — vận hành chạy trên node nào
# tự nhận đúng node đó, không phải nhớ set REGION_TAG=hcm|han mỗi lần.
# Hostname convention: sb-s3-lb-api6-<region>-<n> (vd: sb-s3-lb-api6-hcm-1)
if [ -z "${REGION_TAG:-}" ]; then
  _HOSTNAME=$(hostname)
  if echo "$_HOSTNAME" | grep -qi "hcm"; then
    REGION_TAG="hcm"
  elif echo "$_HOSTNAME" | grep -qi "hni|han"; then
    REGION_TAG="han"
  else
    REGION_TAG="hcm"
    echo "  [WARN] Không nhận diện được region từ hostname '$_HOSTNAME' — mặc định REGION_TAG=hcm. Set tay: REGION_TAG=han ./verify-apisix.sh"
  fi
  unset _HOSTNAME
fi
echo "  [INFO] REGION_TAG=$REGION_TAG (auto-detect từ hostname; override bằng REGION_TAG=xxx nếu sai)"

# Áp bucket riêng theo region nếu có set (S3_TEST_BUCKET_HCM/S3_TEST_BUCKET_HAN), override
# default chung — chỉ khi người dùng KHÔNG tự set S3_TEST_BUCKET tay.
if [ "$S3_TEST_BUCKET" = "thuyldx-cloud" ]; then
  REGION_BUCKET_VAR="S3_TEST_BUCKET_$(echo "$REGION_TAG" | tr '[:lower:]' '[:upper:]')"
  REGION_BUCKET_VALUE="${!REGION_BUCKET_VAR:-}"
  if [ -n "$REGION_BUCKET_VALUE" ]; then
    S3_TEST_BUCKET="$REGION_BUCKET_VALUE"
    echo "  [INFO] Dùng bucket riêng theo region: $REGION_BUCKET_VAR=$S3_TEST_BUCKET"
  fi
fi

# S3_HOST/NON_S3_HOST cũng nên theo region đang đứng, không mặc định cứng về HCM
if [ "$REGION_TAG" = "han" ] && [ "${S3_HOST}" = "s3-hcm.sds.infiniband.vn" ]; then
  S3_HOST="s3-hni.sds.infiniband.vn"
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
S3_SERVICE="${S3_SERVICE:-s3}"
LOKI_URL="${LOKI_URL:-https://maas-service-logs.infiniband.vn/loki/api/v1/query_range}"
# ── Kafka (Strimzi, SASL_SSL) — cùng cluster/topic dùng ở kafka-logger.lua patch [5] ──
# Không hardcode KAFKA_SASL_PASSWORD — chỉ export tạm khi cần test full round-trip:
#   KAFKA_SASL_PASSWORD=xxx ./verify-apisix.sh
# Thiếu password/kcat -> tự SKIP phần consume, vẫn chạy được các check TLS/patch/log-error.
KAFKA_BROKER="${KAFKA_BROKER:-172.26.24.80:31421}"
KAFKA_SASL_USERNAME="${KAFKA_SASL_USERNAME:-apisix}"
KAFKA_SASL_MECHANISM="${KAFKA_SASL_MECHANISM:-SCRAM-SHA-512}"
KAFKA_TOPIC="${KAFKA_TOPIC:-apisix-gateway-${REGION_TAG}}"
KAFKA_CA_CERT="${KAFKA_CA_CERT:-${BASE_DIR}/certs/ca-certificates.crt}"
MIMIR_QUERY_URL="${MIMIR_QUERY_URL:-https://maas-service-metrics.infiniband.vn/prometheus/api/v1/query}"
MIMIR_LABEL_URL="${MIMIR_LABEL_URL:-https://maas-service-metrics.infiniband.vn/prometheus/api/v1/label/__name__/values}"
ORG_ID="${ORG_ID:-vnpaycloud}"
LOKI_QUERY="${LOKI_QUERY:-{vnpaycloud_service=\"apisix\"}}"
CURL_MAX_TIME="${CURL_MAX_TIME:-15}"       # giây — chặn treo vô hạn khi backend không phản hồi
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_TO=(--connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME")

# ---------- Color palette (tự tắt nếu output không phải TTY hoặc NO_COLOR=1) ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_HEADER=$'\033[1;36m'   # bold cyan  — section header + hr separator
  C_EXPLAIN=$'\033[34m'    # blue       — dòng "Vì sao"
  C_NEXTSTEP=$'\033[33m'   # yellow     — dòng "Nếu FAIL"
  C_CMD=$'\033[1;35m'      # bold magenta — lệnh thực thi phát hiện trong explain/nextstep
  C_OK=$'\033[1;32m'       # bold green
  C_BAD=$'\033[1;31m'      # bold red
  C_WARN=$'\033[1;33m'     # bold yellow
else
  C_RESET=''; C_HEADER=''; C_EXPLAIN=''; C_NEXTSTEP=''; C_CMD=''; C_OK=''; C_BAD=''; C_WARN=''
fi

# Tự động tô màu C_CMD cho các cụm trông giống lệnh shell (docker/curl/aws/openssl/git/grep/sudo/...)
# nằm trong text của explain()/nextstep(), phần còn lại giữ nguyên màu nền truyền vào.
# Không cần sửa tay từng dòng — regex chạy tại runtime trên mọi câu.
colorize_cmds() {
  python3 -c "
import re, sys
color, cmd, reset, text = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
pattern = re.compile(r'\b(docker|curl|aws|openssl|git|grep|sudo|stat|chown|tcpdump|tshark|python3|pip|bash)\b[^,;\n]*')
def repl(m):
    return f'{cmd}{m.group(0)}{reset}{color}'
out = pattern.sub(repl, text)
sys.stdout.write(f'{color}{out}{reset}')
" "$1" "$C_CMD" "$C_RESET" "$2"
  echo
}

PASS=0; FAIL=0; WARN=0
ok()      { echo "  ${C_OK}[OK]${C_RESET}     $1"; PASS=$((PASS+1)); }
bad()     { echo "  ${C_BAD}[FAIL]${C_RESET}   $1"; FAIL=$((FAIL+1)); }
warn()    { echo "  ${C_WARN}[WARN]${C_RESET}   $1"; WARN=$((WARN+1)); }
hr()      { echo "${C_HEADER}----------------------------------------------------------------${C_RESET}"; }
explain() { echo ""; colorize_cmds "$C_HEADER" "  >> ĐANG KIỂM TRA: $1"; colorize_cmds "$C_EXPLAIN" "     Vì sao: $2"; }
nextstep(){ colorize_cmds "$C_NEXTSTEP" "     Nếu FAIL: $1"; }
section() { echo "${C_HEADER}################################################################${C_RESET}"; echo "${C_HEADER}# $1${C_RESET}"; echo "${C_HEADER}################################################################${C_RESET}"; }

cd "$BASE_DIR" || { echo "BASE_DIR không tồn tại: $BASE_DIR"; exit 1; }

section "1. RATE LIMIT + REDIS + SNI"

explain "Redis backend cho plugin limit-count (per-AKID counter)" \
        "limit-count dùng Redis để đếm request theo akid; Redis down = rate-limit không hoạt động (fail-open hoặc fail-closed tuỳ config)."
nextstep "docker logs redis --tail 50; docker restart redis nếu cần"
if docker exec redis redis-cli ping 2>/dev/null | grep -q PONG; then
  ok "redis PONG"
else
  bad "redis không PONG"
fi

explain "SNI-reject trên tầng TLS (ssl_client_hello_by_lua)" \
        "APISIX dùng SNI-based routing để chọn cert/route. Client bắn thẳng IP không kèm SNI sẽ bị reject NGAY tại TLS handshake, TRƯỚC khi vào access log/Prometheus — nên 2 hệ thống đó sẽ không bao giờ thấy event này."
nextstep "Nếu SNI_REJECT_COUNT tăng nhanh giữa các lần chạy: chạy tay 1 lần 'tcpdump -i any host <IP> and port 443 -w /tmp/x.pcap -c 20' rồi 'tshark -r /tmp/x.pcap -Y \"tls.handshake.type==1\" -T fields -e ip.src -e tls.handshake.extensions_server_name' để xác định client nguồn. KHÔNG đưa tcpdump vào script tự động."
SNI_REJECT_COUNT=$(grep -o "failed to find SNI" logs/apisix/error.log 2>/dev/null | wc -l | tr -d ' ')
SNI_REJECT_COUNT="${SNI_REJECT_COUNT:-0}"
if [ "$SNI_REJECT_COUNT" -gt 0 ]; then
  LAST_SNI_CLIENT=$(grep "failed to find SNI" logs/apisix/error.log | tail -1 | grep -oE "client: [0-9.]+" | awk '{print $2}')
  warn "$SNI_REJECT_COUNT lần reject do thiếu SNI (client gần nhất: ${LAST_SNI_CLIENT:-?}) — không lên Loki, không có metric Prometheus tương ứng."
else
  ok "Không có SNI-reject trong error.log hiện tại"
fi

explain "Cert coverage — mỗi SNI có trả về đúng cert cover host đó không, còn hạn bao lâu" \
        "Đây chính là điểm đã gây lỗi thật (cmc/s3-hcm/s3-hni.sds bị 'failed to match any SSL certificate by SNI' do thiếu cert *.sds.infiniband.vn). Verify bằng TLS handshake thật qua openssl s_client với --servername=SNI cần test, không suy đoán từ config YAML (YAML có thể đúng nhưng chưa merge/reload)."
nextstep "Không có cert trả về -> route đó sẽ 000/SSL alert khi có SNI thật gọi vào, xem ssls section trong apisix_routes/ssls/*.yaml đã cover SNI này chưa. Cert hết hạn/sắp hết hạn -> gia hạn ngay, đừng chờ tới lúc cert hết hạn giữa production."
CERT_CHECK_HOSTS="${CERT_CHECK_HOSTS:-${S3_HOST} ${NON_S3_HOST} s3-hcm.sds.infiniband.vn s3-hni.sds.infiniband.vn iam.sds.infiniband.vn s3-admin.sds.infiniband.vn}"
# Dedupe danh sách host (S3_HOST có thể trùng với 1 trong các host mặc định)
CERT_CHECK_HOSTS=$(echo "$CERT_CHECK_HOSTS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
for chost in $CERT_CHECK_HOSTS; do
  [ -z "$chost" ] && continue
  CERT_TEXT=$(timeout 10 bash -c "echo | openssl s_client -connect ${RESOLVE_IP}:443 -servername '$chost' 2>/dev/null" | openssl x509 -noout -subject -dates -ext subjectAltName 2>/dev/null)
  if [ -z "$CERT_TEXT" ]; then
    bad "SNI '$chost' — KHÔNG có cert nào trả về (SSL handshake fail hoặc không match SNI nào) — kiểm tra ssls section đã cover host này chưa"
    continue
  fi
  CERT_RESULT=$(echo "$CERT_TEXT" | python3 -c "
import sys, datetime
text = sys.stdin.read()
san_line = ''
for line in text.splitlines():
    if 'DNS:' in line:
        san_line = line
        break
sans = [s.replace('DNS:', '').strip() for s in san_line.split(',') if 'DNS:' in s]
host = '$chost'
def tls_match(pattern, hostname):
    if pattern == hostname:
        return True
    if pattern.startswith('*.'):
        suffix = pattern[1:]
        if hostname.endswith(suffix) and hostname.count('.') == pattern.count('.'):
            return True
    return False
matched = any(tls_match(p, host) for p in sans)
not_after = None
for line in text.splitlines():
    if line.startswith('notAfter='):
        date_str = line.split('=', 1)[1].strip()
        try:
            not_after = datetime.datetime.strptime(date_str, '%b %d %H:%M:%S %Y GMT').replace(tzinfo=datetime.timezone.utc)
        except Exception:
            pass
now = datetime.datetime.now(datetime.timezone.utc)
days_left = (not_after - now).days if not_after else None
if not matched:
    print(f'MISMATCH|SAN không chứa host (SANs: {sans})')
elif days_left is not None and days_left < 0:
    print(f'EXPIRED|Cert đã HẾT HẠN {abs(days_left)} ngày trước')
elif days_left is not None and days_left < 14:
    print(f'EXPIRING|Cert còn {days_left} ngày là hết hạn')
else:
    print(f'OK|Cert match đúng SNI, còn {days_left if days_left is not None else chr(63)} ngày')
" 2>/dev/null)
  CR_STATUS="${CERT_RESULT%%|*}"
  CR_MSG="${CERT_RESULT#*|}"
  case "$CR_STATUS" in
    OK) ok "SNI '$chost' — $CR_MSG" ;;
    EXPIRING) warn "SNI '$chost' — $CR_MSG" ;;
    MISMATCH|EXPIRED) bad "SNI '$chost' — $CR_MSG" ;;
    *) warn "SNI '$chost' — không parse được kết quả cert check" ;;
  esac
done

explain "Dynamic route discovery — quét toàn bộ route ACTIVE trong merged config thật" \
        "Route được quản lý qua gitsync, thêm/xoá liên tục — hardcode 1 route cố định (vd chỉ test 'cmc') sẽ bỏ sót route mới hoặc route khác đang lỗi. Đọc trực tiếp file merged apisix-\${REGION_TAG}.yaml (đây là NGUỒN THẬT APISIX container đang chạy, không phải fragment riêng lẻ trong apisix_routes/), lọc status active, bỏ route lab/debug, tách route S3 data-plane (nhận diện qua plugin custom.s3-accesskey-extractor — plugin trích AKID để ký SigV4, KHÔNG dùng service_id/plugin_config_id string vì tên các resource này có thể đổi tuỳ convention team đang dùng, chỉ có plugin gắn trên route mới phản ánh đúng hành vi thật) khỏi route control-plane (test PLAIN không ký)."
nextstep "Không tìm thấy file merged hoặc thiếu PyYAML -> set MERGED_CONFIG_FILE=<path> tay, hoặc pip install pyyaml --break-system-packages. Script tự fallback về NON_S3_HOST/S3_HOST tĩnh nếu discovery fail, không chặn phần còn lại chạy."

MERGED_CONFIG_FILE="${MERGED_CONFIG_FILE:-}"
if [ -z "$MERGED_CONFIG_FILE" ]; then
  MERGED_CONFIG_FILE=$(find "$BASE_DIR" -maxdepth 2 -name "apisix-${REGION_TAG}.yaml" 2>/dev/null | head -1)
fi

CONTROL_HOSTS=""
S3_ROUTE_HOSTS=""
if [ -z "$MERGED_CONFIG_FILE" ] || [ ! -f "$MERGED_CONFIG_FILE" ]; then
  warn "Không tìm thấy merged config apisix-${REGION_TAG}.yaml trong $BASE_DIR — fallback về route tĩnh (NON_S3_HOST=$NON_S3_HOST, S3_HOST=$S3_HOST)"
else
  ROUTE_DISCOVERY=$(python3 -c "
import yaml, sys
try:
    with open('$MERGED_CONFIG_FILE') as f:
        doc = yaml.safe_load(f)
except Exception as e:
    print(f'ERR:{e}', file=sys.stderr); sys.exit(1)
routes = doc.get('routes', []) or []
control, s3 = set(), set()
control_map, s3_map = {}, {}
skip_kw = ('debug-dump', 'lab-ceph', 'lab-')
skipped_status = []
skipped_kw = []
skipped_wildcard_only = []
total = 0
for r in routes:
    if not isinstance(r, dict):
        continue
    total += 1
    rid = r.get('id') or '(no-id)'
    name = r.get('name') or ''
    if r.get('status', 1) == 0:
        skipped_status.append(rid)
        continue
    if any(k in name or k in rid for k in skip_kw):
        skipped_kw.append(rid)
        continue
    hosts_all = r.get('hosts') or ([r['host']] if r.get('host') else [])
    hosts = [h for h in hosts_all if h and not h.startswith('*')]
    if not hosts:
        if hosts_all:
            skipped_wildcard_only.append(rid)
        continue
    svc = r.get('service_id', '')
    plugins = r.get('plugins') or {}
    is_s3_sdk = 'custom.s3-accesskey-extractor' in plugins
    for h in hosts:
        if is_s3_sdk:
            s3.add(h)
            s3_map.setdefault(h, []).append(rid)
        else:
            control.add(h)
            control_map.setdefault(h, []).append(rid)
print('CONTROL:' + ','.join(sorted(control)))
print('S3:' + ','.join(sorted(s3)))
print('TOTAL:' + str(total))
print('SKIP_STATUS:' + ','.join(skipped_status))
print('SKIP_KW:' + ','.join(skipped_kw))
print('SKIP_WILDCARD:' + ','.join(skipped_wildcard_only))
print('CONTROL_MAP:' + ';'.join(f'{h}=' + '|'.join(rids) for h, rids in sorted(control_map.items())))
print('S3_MAP:' + ';'.join(f'{h}=' + '|'.join(rids) for h, rids in sorted(s3_map.items())))
" 2>/tmp/route_discovery_err.log)
  if [ -z "$ROUTE_DISCOVERY" ]; then
    warn "Parse $MERGED_CONFIG_FILE lỗi (xem /tmp/route_discovery_err.log — có thể thiếu PyYAML: pip install pyyaml --break-system-packages) — fallback route tĩnh"
  else
    CONTROL_HOSTS=$(echo "$ROUTE_DISCOVERY" | grep '^CONTROL:' | cut -d: -f2 | tr ',' ' ')
    S3_ROUTE_HOSTS=$(echo "$ROUTE_DISCOVERY" | grep '^S3:' | cut -d: -f2 | tr ',' ' ')
    ROUTE_TOTAL=$(echo "$ROUTE_DISCOVERY" | grep '^TOTAL:' | cut -d: -f2)
    SKIP_STATUS_LIST=$(echo "$ROUTE_DISCOVERY" | grep '^SKIP_STATUS:' | cut -d: -f2)
    SKIP_KW_LIST=$(echo "$ROUTE_DISCOVERY" | grep '^SKIP_KW:' | cut -d: -f2)
    SKIP_WILDCARD_LIST=$(echo "$ROUTE_DISCOVERY" | grep '^SKIP_WILDCARD:' | cut -d: -f2)
    CONTROL_MAP=$(echo "$ROUTE_DISCOVERY" | grep '^CONTROL_MAP:' | cut -d: -f2-)
    S3_MAP=$(echo "$ROUTE_DISCOVERY" | grep '^S3_MAP:' | cut -d: -f2-)
    SKIP_STATUS_COUNT=$([ -n "$SKIP_STATUS_LIST" ] && echo "$SKIP_STATUS_LIST" | tr ',' '\n' | grep -c . || echo 0)
    SKIP_KW_COUNT=$([ -n "$SKIP_KW_LIST" ] && echo "$SKIP_KW_LIST" | tr ',' '\n' | grep -c . || echo 0)
    SKIP_WILDCARD_COUNT=$([ -n "$SKIP_WILDCARD_LIST" ] && echo "$SKIP_WILDCARD_LIST" | tr ',' '\n' | grep -c . || echo 0)
    CONTROL_COUNT=$(echo $CONTROL_HOSTS | wc -w)
    S3_COUNT=$(echo $S3_ROUTE_HOSTS | wc -w)
    echo "  [INFO] Tổng $ROUTE_TOTAL route trong $MERGED_CONFIG_FILE — test $CONTROL_COUNT control-plane + $S3_COUNT S3 data-plane."
    echo "         Bị skip: $SKIP_STATUS_COUNT route status=0 (tắt), $SKIP_KW_COUNT route lab/debug, $SKIP_WILDCARD_COUNT route chỉ có wildcard host (không curl trực tiếp được)."
    [ "$SKIP_STATUS_COUNT" -gt 0 ] && echo "           status=0: $SKIP_STATUS_LIST"
    [ "$SKIP_KW_COUNT" -gt 0 ] && echo "           lab/debug: $SKIP_KW_LIST"
    [ "$SKIP_WILDCARD_COUNT" -gt 0 ] && echo "           wildcard-only: $SKIP_WILDCARD_LIST"
    echo "         Chi tiết route đang test (host <- route_id, có thể nhiều route_id trỏ cùng host qua http/https hoặc nhiều port):"
    if [ -n "$CONTROL_MAP" ]; then
      echo "$CONTROL_MAP" | tr ';' '\n' | while IFS='=' read -r h rids; do
        [ -z "$h" ] && continue
        echo "           [control] $h <- $(echo "$rids" | tr '|' ',')"
      done
    fi
    if [ -n "$S3_MAP" ]; then
      echo "$S3_MAP" | tr ';' '\n' | while IFS='=' read -r h rids; do
        [ -z "$h" ] && continue
        echo "           [S3]      $h <- $(echo "$rids" | tr '|' ',')"
      done
    fi
  fi
fi
[ -z "$CONTROL_HOSTS" ] && CONTROL_HOSTS="$NON_S3_HOST"
[ -z "$S3_ROUTE_HOSTS" ] && S3_ROUTE_HOSTS="$S3_HOST"

explain "Route non-S3 (control-plane) — test PLAIN không ký trên TẤT CẢ host phát hiện được" \
        "Route control-plane dùng key-auth/session thường, test PLAIN không ký để baseline rate-limit + auth riêng, KHÔNG liên quan gì tới SigV4 (đó là chuyện của route S3 data-plane)."
nextstep "Nếu 403 ở route non-S3: check key-auth consumer, không phải SigV4 — xem apisix_routes/consumers/*.yaml và header 'apikey' đã đúng chưa."
for host in $CONTROL_HOSTS; do
  echo "  -- Host: $host --"
  HAD_000=0
  for i in $(seq 1 3); do
    CODE=$(curl -sk "${CURL_TO[@]}" -o /dev/null -w "%{http_code}" \
      "https://${host}/" --resolve "${host}:443:${RESOLVE_IP}")
    echo "    HTTP=$CODE"
    [ "$CODE" = "000" ] && HAD_000=1
  done
  # HTTP=000 có 2 nguyên nhân khác nhau, cần phân biệt trước khi kết luận "mạng lỗi":
  #   1. SSL cert không cover đúng SNI của host này (config sai, KHÔNG phải mạng)
  #   2. Timeout/connection refused thật (mạng/upstream)
  # Chỉ chẩn đoán sâu khi THẬT SỰ có 000 vừa xảy ra — tránh đọc log cũ tồn đọng
  # (error.log là bind-mount, không bị xoá qua container restart) gây false-positive.
  if [ "$HAD_000" -eq 1 ]; then
    SNI_MISMATCH=$(grep "failed to match any SSL certificate by SNI: ${host}" logs/apisix/error.log 2>/dev/null | tail -1)
    if [ -n "$SNI_MISMATCH" ]; then
      MATCHED_SNIS=$(echo "$SNI_MISMATCH" | grep -oE 'matched SNIs: \[[^]]*\]')
      bad "$host — HTTP=000 do SSL CERT KHÔNG COVER đúng SNI (${MATCHED_SNIS:-xem error.log}) — lỗi CONFIG cert, KHÔNG PHẢI mạng/timeout. Fix: thêm SAN đích danh trong ssls của apisix_routes/apisix-${REGION_TAG}.yaml"
    else
      bad "$host — HTTP=000 nhưng KHÔNG thấy SNI-mismatch trong error.log — nghi timeout/connection thật, không phải cert. Check network/firewall tới upstream."
    fi
  else
    ok "$host — không có HTTP=000 trong 3 lần test"
  fi
done

CURL_VER_MAJOR=$(curl --version | head -1 | awk '{print $2}' | cut -d. -f1)
CURL_VER_MINOR=$(curl --version | head -1 | awk '{print $2}' | cut -d. -f2)
if [ "$CURL_VER_MAJOR" -gt 7 ] || { [ "$CURL_VER_MAJOR" -eq 7 ] && [ "$CURL_VER_MINOR" -ge 75 ]; }; then
  SIGV4_SUPPORTED=1
else
  bad "curl quá cũ (cần >=7.75) để dùng --aws-sigv4 — dùng awscurl/boto3 thay thế"
  SIGV4_SUPPORTED=0
fi
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  warn "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY chưa set — SKIP test S3 có ký"
  SIGV4_SUPPORTED=0
fi

explain "Route S3 data-plane (service_id=svc-s3-sdk) — test SigV4 trên TẤT CẢ host phát hiện được" \
        "QUAN TRỌNG: route S3 KHÔNG dùng key-auth (comment trong apisix_routes/apisix-*.yaml ghi rõ '⚠ CHỈ cho API control-plane CÓ key-auth. KHÔNG dùng cho S3 data-plane'). S3 SDK/client chỉ được xác thực qua chữ ký SigV4/SigV2 ở tầng plugin custom.s3-accesskey-extractor, KHÔNG có concept 'apikey' header ở route này. Test với header apikey vào route S3 LUÔN sai hướng — không dùng lại pattern đó."
for s3host in $S3_ROUTE_HOSTS; do
  echo "  -- Host: $s3host --"
  if [ "$SIGV4_SUPPORTED" -eq 1 ]; then
    echo "     Bucket test: $S3_TEST_BUCKET (đổi qua biến S3_TEST_BUCKET=<bucket khác> nếu cần)"
    nextstep "SignatureDoesNotMatch/InvalidAccessKeyId -> check AK/SK/AWS_REGION/lệch giờ hệ thống. AccessDenied -> chữ ký ĐÚNG nhưng thiếu quyền, check IAM Cloudian (khác hẳn key-auth APISIX)."
    TESTKEY="verify-$(date +%s).txt"
    echo "     ⚠ LƯU Ý: PUT sẽ tạo object THẬT '$TESTKEY' trong bucket '$S3_TEST_BUCKET', DELETE ở cuối vòng lặp sẽ dọn lại. Nếu DELETE fail/timeout, object rác còn sót — check tay: aws s3 ls s3://${S3_TEST_BUCKET}/verify-*"
    for method in GET PUT HEAD DELETE; do
      extra_args=()
      [ "$method" = "PUT" ] && extra_args=(--data "verify-payload")
      BODY_FILE=$(mktemp)
      resp=$(curl -sk "${CURL_TO[@]}" -o "$BODY_FILE" -w "%{http_code}" -X "$method" \
        --aws-sigv4 "aws:amz:${AWS_REGION}:${S3_SERVICE}" \
        --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
        "${extra_args[@]}" \
        "https://${s3host}/${S3_TEST_BUCKET}/${TESTKEY}" --resolve "${s3host}:443:${RESOLVE_IP}")
      S3_ERR_CODE=$(grep -oE "<Code>[^<]+</Code>" "$BODY_FILE" 2>/dev/null | sed -E 's/<\/?Code>//g')
      echo "    [$method] HTTP=$resp  S3-Code=${S3_ERR_CODE:-none}"
      rm -f "$BODY_FILE"
      case "$S3_ERR_CODE" in
        SignatureDoesNotMatch|InvalidAccessKeyId|RequestTimeTooSkewed)
          bad "$s3host [$method] -> $resp/$S3_ERR_CODE — chữ ký SAI THẬT" ;;
        AccessDenied)
          bad "$s3host [$method] -> $resp/AccessDenied — chữ ký hợp lệ nhưng KHÔNG có quyền (IAM Cloudian)" ;;
        TemporaryRedirect|PermanentRedirect)
          REDIRECT_LOC=$(grep -oE "<Endpoint>[^<]+</Endpoint>|https://[^\"'[:space:]]+" "$BODY_FILE" 2>/dev/null | head -1)
          ok "$s3host [$method] -> $resp/$S3_ERR_CODE — auth ĐÚNG (Cloudian chỉ redirect SAU khi xác thực pass). Bucket '$S3_TEST_BUCKET' home ở region KHÁC node đang đứng (đích: ${REDIRECT_LOC:-xem response header Location}). Đây là hành vi S3-compliant chuẩn, KHÔNG phải lỗi." ;;
        NoSuchBucket)
          ok "$s3host [$method] -> $resp/NoSuchBucket — chữ ký ĐÚNG, bucket '$S3_TEST_BUCKET' chưa tồn tại (không phải lỗi)" ;;
        NoSuchKey)
          ok "$s3host [$method] -> $resp/NoSuchKey — chữ ký ĐÚNG, object chưa tồn tại (bình thường)" ;;
        "")
          case "$resp" in
            000) bad "$s3host [$method] -> timeout/connection failed sau ${CURL_MAX_TIME}s — check network/firewall tới upstream, KHÔNG phải lỗi auth." ;;
            307|308) ok "$s3host [$method] -> $resp (redirect, HEAD không có XML body để đọc Code) — auth ĐÚNG, bucket home region khác" ;;
            2*) ok "$s3host [$method] -> $resp, auth pass" ;;
            *) warn "$s3host [$method] -> $resp, không có <Code> XML, xem raw body thủ công" ;;
          esac ;;
        *)
          warn "$s3host [$method] -> $resp/$S3_ERR_CODE — mã lỗi S3 khác, tra cứu thêm" ;;
      esac
    done
  else
    echo "     SKIP ký SigV4 (thiếu AK/SK hoặc curl cũ) — chạy baseline KHÔNG ký, kỳ vọng AccessDenied/403 (ĐÚNG, không phải bug):"
    for i in $(seq 1 3); do
      curl -sk "${CURL_TO[@]}" -o /dev/null -w "    HTTP=%{http_code}\n" \
        "https://${s3host}/" --resolve "${s3host}:443:${RESOLVE_IP}"
    done
  fi
done

hr
section "2. LOG (route: TẤT CẢ, qua global-loki-logger)"

explain "access.log JSON format (route + service context)" \
        "loki-logger global rule chỉ gửi access.log (không gửi error.log) lên Loki — field route_id/service_id/akid/rt_limit/rt_remaining phải có đủ để audit theo route."
nextstep "Field thiếu -> check log_format trong config-hcm.yaml/config-han.yaml, serverless-pre-function có inject đủ header X-Route-Id/X-Service-Id không."
tail -1 logs/apisix/access.log 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  KHÔNG parse được access.log line cuối"
LAST_LOG=$(tail -1 logs/apisix/access.log 2>/dev/null)
for field in route_id service_id akid rt_limit rt_remaining rt_warning; do
  if echo "$LAST_LOG" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if '$field' in d else 1)" 2>/dev/null; then
    ok "field '$field' có trong access.log"
  else
    warn "field '$field' không thấy trong log line cuối (có thể request đó không trigger field này)"
  fi
done

explain "Quyền thư mục logs/gitsync/ (container gitsync chạy UID 65533)" \
        "git-sync image chạy non-root UID 65533; nếu thư mục host owner khác, container không ghi được log ra ngoài dù vẫn healthy bên trong."
nextstep "sudo chown -R 65533:65533 logs/gitsync/"
ls -la logs/gitsync/ 2>/dev/null
OWNER=$(stat -c '%u:%g' logs/gitsync/ 2>/dev/null)
if [ "$OWNER" = "65533:65533" ]; then
  ok "logs/gitsync/ owner đúng 65533:65533"
else
  bad "logs/gitsync/ owner=$OWNER, sai"
fi
tail -5 logs/gitsync/gitsync.log 2>/dev/null || bad "gitsync.log MISSING"

explain "Loki ingestion — endpoint maas-service-logs.infiniband.vn" \
        "Đọc RAW JSON đầy đủ (không grep) để tránh nhầm structure rỗng {\"result\":[]} với có data thật — lỗi đã gặp ở lần verify trước."
nextstep "result rỗng -> check global-loki-logger.yaml đã merge vào config chưa (xem mục 4), và global_rules có được restart-apply chưa."
LOKI_RAW=$(curl -s "${CURL_TO[@]}" -H "X-Scope-OrgID: ${ORG_ID}" "${LOKI_URL}" \
  --data-urlencode "query=${LOKI_QUERY}" --data-urlencode 'limit=3')
echo "$LOKI_RAW" | python3 -m json.tool 2>/dev/null || echo "  RAW (không phải JSON hợp lệ): $LOKI_RAW"
RESULT_COUNT=$(echo "$LOKI_RAW" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('result',[])))" 2>/dev/null)
if [ "${RESULT_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  ok "Loki có $RESULT_COUNT stream(s) — log ĐÃ lên thật"
else
  # bad "Loki result rỗng (0 stream)"
  warn "Loki result rỗng (0 stream) — KHÔNG còn là lỗi kể từ khi log pipeline chính chuyển sang Kafka (xem check Kafka end-to-end bên dưới, section này giữ lại để dò song song nếu Loki vẫn bật). Chỉ cần Kafka OK là đủ điều kiện pass tổng thể."
fi

explain "kafka-logger.lua patch [5] — ssl/ssl_verify có thật sự load vào container đang chạy chưa" \
        "Patch này SỬA HÀNH VI CHỨC NĂNG (không phải patch thẩm mỹ như config_yaml.lua) — thiếu field ssl/ssl_verify thì broker_config gửi PLAINTEXT tới listener SASL_SSL, bị Strimzi reject ở tầng protocol (không phải lỗi auth), rất dễ nhầm sang lỗi credential khi debug."
nextstep "grep rỗng -> patch chưa mount/chưa apply, xem lại volume mount kafka-logger.lua trong docker-compose.yaml và chạy lại scripts/deploy/1-patch-template-lua.sh"
if docker exec apisix-standalone grep -q 'broker_config\["ssl"\] = conf.ssl' /usr/local/apisix/apisix/plugins/kafka-logger.lua 2>/dev/null; then
  ok "kafka-logger.lua trong container có patch ssl/ssl_verify"
else
  bad "kafka-logger.lua trong container KHÔNG thấy patch ssl/ssl_verify — SASL_SSL sẽ fail ở tầng protocol"
fi

explain "global-kafka-logger.yaml — global_rule có đang BẬT (không bị comment toàn bộ) không" \
        "merge-fragments.sh cho phép 'tắt' 1 global_rule bằng cách comment toàn bộ nội dung file (dùng làm template dự phòng) — SKIP âm thầm, không lỗi. Cần phân biệt 'đã tắt có chủ đích' với 'quên bật lại sau khi sửa'."
nextstep "Nếu tắt ngoài ý muốn: bỏ comment toàn bộ nội dung global_rules/global-kafka-logger.yaml, để dòng đầu không phải comment, rồi đợi gitsync merge lại (~30s)."
KAFKA_RULE_FILE="apisix_routes/global_rules/global-kafka-logger.yaml"
if [ -f "$KAFKA_RULE_FILE" ]; then
  KAFKA_RULE_FIRST_KEY=$(grep -v '^\s*#' "$KAFKA_RULE_FILE" | grep -v '^\s*$' | head -1 | sed 's/:.*//' | tr -d ' ')
  if [ "$KAFKA_RULE_FIRST_KEY" = "global_rules" ]; then
    ok "$KAFKA_RULE_FILE đang BẬT (key đầu tiên không bị comment)"
  else
    warn "$KAFKA_RULE_FILE đang bị comment toàn bộ (disabled template) — kafka-logger KHÔNG chạy, có thể là chủ đích"
  fi
else
  warn "Không tìm thấy $KAFKA_RULE_FILE — kafka-logger chưa được cấu hình ở DC này"
fi

explain "TLS handshake tới Strimzi broker (tầng SSL của SASL_SSL, chưa gồm SASL auth)" \
        "SASL_SSL luôn bắt tay TLS TRƯỚC khi tới bước SASL negotiate — verify được layer TLS độc lập với việc có đúng SASL credential hay không, tách bạch 'lỗi mạng/cert' khỏi 'lỗi auth' giống cách section 1 tách SNI-mismatch khỏi timeout thật."
nextstep "Handshake fail -> check firewall/security group tới \$KAFKA_BROKER, hoặc CA cert tại \$KAFKA_CA_CERT chưa đúng cluster-ca của Strimzi (xem README mục cert Kafka)."
KAFKA_TLS_RESULT=$(timeout 10 bash -c "echo | openssl s_client -connect ${KAFKA_BROKER} -CAfile ${KAFKA_CA_CERT} 2>&1")
if echo "$KAFKA_TLS_RESULT" | grep -q "Verify return code: 0 (ok)"; then
  ok "TLS handshake tới $KAFKA_BROKER OK, cert verify bằng $KAFKA_CA_CERT hợp lệ"
elif echo "$KAFKA_TLS_RESULT" | grep -qE "CONNECTED|BEGIN CERTIFICATE"; then
  warn "TLS handshake tới $KAFKA_BROKER connect được nhưng cert verify KHÔNG return 0 — xem chi tiết: openssl s_client -connect ${KAFKA_BROKER} -CAfile ${KAFKA_CA_CERT}"
else
  bad "TLS handshake tới $KAFKA_BROKER THẤT BẠI — check network/firewall, không phải lỗi APISIX"
fi

explain "error.log — dấu hiệu lỗi kết nối Kafka gần đây (protocol/auth/timeout)" \
        "Phân biệt 3 loại lỗi hay gặp: PLAINTEXT-vs-SASL_SSL mismatch (patch [5] thiếu/lỗi), SASL auth sai (credential), và network timeout (hạ tầng) — mỗi loại hướng fix khác nhau, gộp chung dễ sửa nhầm chỗ."
nextstep "Có lỗi -> đọc nguyên văn dòng log, so khớp 1 trong 3 loại ở trên trước khi sửa; đừng đổi credential nếu thực ra là lỗi network."
KAFKA_ERR_COUNT=$(grep -ic "kafka" logs/apisix/error.log 2>/dev/null | tr -d ' ')
KAFKA_ERR_COUNT="${KAFKA_ERR_COUNT:-0}"
if [ "$KAFKA_ERR_COUNT" -gt 0 ]; then
  warn "$KAFKA_ERR_COUNT dòng có 'kafka' trong error.log — xem gần nhất:"
  grep -i "kafka" logs/apisix/error.log | tail -3 | sed 's/^/    /'
else
  ok "Không có dòng nào chứa 'kafka' trong error.log hiện tại"
fi

explain "End-to-end — message thật sự tới được Kafka topic '$KAFKA_TOPIC' chưa (dùng kcat)" \
        "3 check trên chỉ xác nhận layer TLS/patch/log-error riêng lẻ — đây là bước duy nhất xác nhận round-trip THẬT: APISIX ghi log qua kafka-logger -> broker nhận -> consume lại được. Cần KAFKA_SASL_PASSWORD + kcat, cả 2 đều optional (không block phần còn lại của script nếu thiếu)."
nextstep "Consume rỗng dù broker reachable -> kiểm tra topic name đúng theo DC_PROFILE chưa (apisix-gateway-\${DC_PROFILE}), hoặc global-kafka-logger.yaml vừa mới bật (cần đợi 1 request thật đi qua route trước khi có message)."
if ! command -v kcat >/dev/null 2>&1; then
  warn "Không có kcat trong PATH — SKIP end-to-end test (cài: apt install kafkacat, hoặc dùng kcat binary tĩnh)"
elif [ -z "${KAFKA_SASL_PASSWORD:-}" ]; then
  warn "KAFKA_SASL_PASSWORD chưa set — SKIP end-to-end test. Chạy: KAFKA_SASL_PASSWORD=xxx $0"
else
  KCAT_OUT=$(timeout 10 kcat -b "$KAFKA_BROKER" -X security.protocol=SASL_SSL \
    -X sasl.mechanisms="$KAFKA_SASL_MECHANISM" -X sasl.username="$KAFKA_SASL_USERNAME" \
    -X sasl.password="$KAFKA_SASL_PASSWORD" -X ssl.ca.location="$KAFKA_CA_CERT" \
    -X ssl.endpoint.identification.algorithm=none \
    -C -t "$KAFKA_TOPIC" -o -5 -e 2>&1)
  KCAT_MSG_COUNT=$(echo "$KCAT_OUT" | grep -c '^{' 2>/dev/null || true)
  KCAT_MSG_COUNT="${KCAT_MSG_COUNT:-0}"
  if [ "${KCAT_MSG_COUNT:-0}" -gt 0 ]; then
    ok "kcat consume được $KCAT_MSG_COUNT message gần nhất từ topic '$KAFKA_TOPIC' — round-trip OK"
  else
    bad "kcat KHÔNG consume được message nào từ '$KAFKA_TOPIC' — xem raw output:"
    echo "$KCAT_OUT" | tail -5 | sed 's/^/    /'
    echo "$KCAT_OUT" | grep -q "Topic authorization failed" && \
      warn "Lỗi 'Topic authorization failed' = ACL Kafka chặn READ, không phải lỗi network/TLS/SASL (3 lớp đó đã pass ở check trước) — khả năng cao SASL user hiện tại chỉ có quyền Write (đúng thiết kế least-privilege cho service ghi log), không có quyền Read để consume. Không kết luận APISIX ghi log thất bại chỉ từ lỗi này — cần user riêng có quyền Read để verify end-to-end thật."
  fi
fi

hr
section "3. METRIC"

explain "APISIX prometheus endpoint (9091) + redis_exporter (9121)" \
        "Đây là 2 nguồn scrape nội bộ (node-level), phải có data trước khi kỳ vọng gì ở Prometheus container/Mimir remote_write."
curl -s "${CURL_TO[@]}" http://127.0.0.1:9091/apisix/prometheus/metrics | grep "^apisix_http" | head -5
curl -s "${CURL_TO[@]}" http://127.0.0.1:9121/metrics | grep "^redis_up"

explain "Prometheus container scrape targets health" \
        "job_name phải tách theo region (apisix-${REGION_TAG}-metric) — do entrypoint sed substitute \${DC_PROFILE}. Nếu job_name generic (không có hậu tố region) nghĩa là substitute chưa chạy."
nextstep "docker logs prometheus | grep -i sed; check docker-compose entrypoint script substitute \${DC_PROFILE} đúng biến môi trường chưa."
docker ps | grep prometheus || bad "container prometheus không chạy"
TARGETS_RAW=$(curl -s "${CURL_TO[@]}" http://127.0.0.1:9099/api/v1/targets)
echo "$TARGETS_RAW" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d.get('data', {}).get('activeTargets', []):
    print(f\"  job={t.get('labels',{}).get('job','?')} health={t.get('health','?')} lastError={t.get('lastError','')!r}\")
" 2>/dev/null
EXPECTED_JOB="apisix-${REGION_TAG}-metric"
if echo "$TARGETS_RAW" | grep -q "\"$EXPECTED_JOB\""; then
  ok "job_name '$EXPECTED_JOB' xuất hiện — DC_PROFILE substitute OK"
else
  bad "job_name '$EXPECTED_JOB' KHÔNG thấy"
fi

explain "Mimir remote_write — scrape target 'up' cho job apisix-${REGION_TAG}-metric" \
        "Path đúng của Mimir gateway là /prometheus/api/v1/query (không phải /api/v1/query — xác nhận qua test thủ công). Dùng metric 'up{job=...}' thay vì 'apisix_http_status' (metric này không tồn tại/không phải tên chuẩn) — 'up' luôn có sẵn cho mọi scrape target, đáng tin hơn để verify remote_write."
nextstep "HTTP != 200 -> check header X-Scope-OrgID, path Mimir gateway. HTTP=200 nhưng result rỗng -> job chưa lên Mimir, check Prometheus remote_write config."
MIMIR_HTTP=$(curl -s "${CURL_TO[@]}" -o /tmp/mimir_resp.txt -w "%{http_code}" \
  -H "X-Scope-OrgID: ${ORG_ID}" "${MIMIR_QUERY_URL}" --data-urlencode "query=up{job=\"apisix-${REGION_TAG}-metric\"}")
echo "  HTTP=$MIMIR_HTTP"
if [ "$MIMIR_HTTP" = "200" ]; then
  MIMIR_UP_VALUE=$(python3 -c "
import sys, json
d = json.load(open('/tmp/mimir_resp.txt'))
results = d.get('data', {}).get('result', [])
print(results[0]['value'][1] if results else '')
" 2>/dev/null)
  if [ "$MIMIR_UP_VALUE" = "1" ]; then
    ok "job apisix-${REGION_TAG}-metric trên Mimir: up=1 — remote_write hoạt động đúng"
  elif [ "$MIMIR_UP_VALUE" = "0" ]; then
    bad "job apisix-${REGION_TAG}-metric trên Mimir: up=0 — Prometheus container mất kết nối tới target 9091/9099"
  else
    bad "job apisix-${REGION_TAG}-metric KHÔNG thấy trong Mimir (result rỗng) — check Prometheus remote_write hoặc job_name có match đúng chưa"
  fi
else
  bad "Mimir query trả HTTP=$MIMIR_HTTP"
  head -c 300 /tmp/mimir_resp.txt; echo
fi



hr
section "4. GITSYNC + MERGE-FRAGMENTS + GLOBAL_RULES APPLY LAG"

explain "merge-fragments.sh patch (skip file bị comment toàn bộ)" \
        "So bằng git diff thay vì đếm tuyệt đối grep -c — số tuyệt đối không có baseline để biết trước/sau patch."
nextstep "Diff rỗng -> patch CHƯA merge, kafka-logger/http-logger vẫn có thể block merge; xem log 'disabled template' trong gitsync.log."
if git -C "$BASE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$BASE_DIR" log --oneline -3 -- scripts/runtime/merge-fragments.sh
  git -C "$BASE_DIR" diff HEAD~5 HEAD -- scripts/runtime/merge-fragments.sh 2>/dev/null | head -50
else
  warn "$BASE_DIR không phải git work tree — không diff được"
  grep -n "disabled template" scripts/runtime/merge-fragments.sh
fi
grep -n -A2 -iE "kafka-logger|http-logger" scripts/runtime/merge-fragments.sh 2>/dev/null
tail -10 logs/gitsync/gitsync.log 2>/dev/null
docker logs apisix-standalone --tail 30 2>/dev/null | grep -iE "reloaded|skip|kafka-logger|http-logger|error"

explain "Worker restart lag: global_rules (loki-logger, prometheus...) có thực sự được apply chưa" \
        "config_yaml.lua CHỈ hot-reload routes/services/upstreams/consumers/ssls trong-process. global_rules cần WORKER RESTART thật (PID reset, dòng 'new plugins' worker id mới) mới được nạp. QUAN TRỌNG: dòng log 'NOT reloaded (restart required)' xuất hiện ở MỌI chu kỳ gitsync (mỗi 30s) VÔ ĐIỀU KIỆN, không phải chỉ khi global_rules thực sự đổi — nên KHÔNG dùng nó làm tín hiệu. Cách đúng: so mtime file global_rules/*.yaml với epoch của lần worker-restart gần nhất."
nextstep "Nếu file mtime MỚI HƠN lần restart gần nhất: docker restart apisix-standalone, rồi chạy lại script để confirm."

WORKER_AGE=$(docker exec apisix-standalone sh -c '
  UPTIME=$(cut -d" " -f1 /proc/uptime 2>/dev/null)
  CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
  OLDEST_AGE=""
  for pid_dir in /proc/[0-9]*; do
    [ -r "${pid_dir}/cmdline" ] || continue
    cmdline=$(tr "\0" " " < "${pid_dir}/cmdline" 2>/dev/null)
    case "${cmdline}" in
      *"worker process"*)
        stat_line=$(cat "${pid_dir}/stat" 2>/dev/null) || continue
        after_comm="${stat_line#*) }"
        set -- ${after_comm}
        starttime="${20}"
        [ -z "${starttime}" ] && continue
        age=$(( ${UPTIME%.*} - starttime / CLK_TCK ))
        if [ -z "${OLDEST_AGE}" ] || [ "${age}" -gt "${OLDEST_AGE}" ]; then
          OLDEST_AGE="${age}"
        fi
        ;;
    esac
  done
  echo "${OLDEST_AGE:-}"
' 2>/dev/null)

if [ -z "$WORKER_AGE" ]; then
  bad "Không lấy được worker process info qua docker exec — container không healthy hoặc /proc không đọc được, cần: docker exec apisix-standalone sh -c 'ls /proc/[0-9]*/cmdline' để debug tay"
else
  NEWPLUGIN_EPOCH=$(( $(date +%s) - WORKER_AGE ))
  echo "  Worker đã chạy: ${WORKER_AGE}s — khởi động lúc $(date -d @${NEWPLUGIN_EPOCH} '+%Y-%m-%d %H:%M:%S')"

  GLOBAL_RULES_DIR="apisix_routes/global_rules"
  if [ -d "$GLOBAL_RULES_DIR" ]; then
    STALE_FOUND=0
    for f in "$GLOBAL_RULES_DIR"/*.yaml; do
      [ -f "$f" ] || continue
      MTIME=$(stat -c '%Y' "$f" 2>/dev/null)
      [ -z "$MTIME" ] && continue
      if [ "$MTIME" -gt "$NEWPLUGIN_EPOCH" ]; then
        AGE_SINCE_EDIT=$(( $(date +%s) - MTIME ))
        echo "  [STALE] $f đổi lúc $(date -d @"$MTIME" '+%Y-%m-%d %H:%M:%S') — SAU lần restart gần nhất (cách đây ${AGE_SINCE_EDIT}s)"
        STALE_FOUND=1
      fi
    done
    if [ "$STALE_FOUND" -eq 1 ]; then
      bad "Có global_rules file đổi SAU restart gần nhất — thay đổi CHƯA được áp dụng, cần: docker restart apisix-standalone"
    else
      ok "Mọi global_rules file đều cũ hơn (hoặc bằng) lần restart gần nhất — đã được áp dụng đầy đủ"
    fi
  else
    warn "Không tìm thấy $GLOBAL_RULES_DIR — skip check mtime"
  fi
fi

hr
section "5. CONTAINERS"

explain "Toàn bộ container stack (apisix-standalone, redis, gitsync, prometheus, redis-exporter)" \
        "Baseline cuối cùng — nếu container nào unhealthy thì mọi kết quả PASS ở các mục trên đều cần nghi ngờ lại (có thể data đã stale)."
nextstep "docker logs <container> --tail 50; docker restart <container>"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
UNHEALTHY=$(docker ps --filter "health=unhealthy" -q)
if [ -n "$UNHEALTHY" ]; then
  bad "Có container unhealthy: $UNHEALTHY"
else
  ok "Không có container unhealthy"
fi

hr
echo "${C_HEADER}SUMMARY: PASS=${C_OK}$PASS${C_HEADER}  WARN=${C_WARN}$WARN${C_HEADER}  FAIL=${C_BAD}$FAIL${C_RESET}"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
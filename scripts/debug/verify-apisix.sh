#!/usr/bin/env bash
# verify-apisix.sh
# Verify tổng hợp APISIX standalone (config_yaml.lua, KHÔNG có Admin API/etcd)
#
# Nguyên tắc mỗi bước trong script: EXPLAIN (đang test service/route/logic nào, vì sao)
# -> RUN -> RESULT (kết quả kèm next-step cụ thể nếu OK/WARN/FAIL), không chỉ echo số liệu khô.
#
# Usage (default — dùng AWS profile 'thuyldx-hni' + bucket 'thuyldx-hni' đã setup sẵn trong ~/.aws/credentials):
#   REGION_TAG=hcm ./verify-apisix.sh
#   REGION_TAG=hni S3_HOST=s3-hni.sds.infiniband.vn ./verify-apisix.sh
#
# Override khi cần:
#   AWS_PROFILE=other-profile ./verify-apisix.sh
#   S3_TEST_BUCKET=other-bucket ./verify-apisix.sh
#   AWS_ACCESS_KEY_ID=xxx AWS_SECRET_ACCESS_KEY=yyy ./verify-apisix.sh   # session tạm, KHÔNG lưu vào file
#
# LƯU Ý BẢO MẬT: secret KHÔNG được hardcode trong script này. Setup profile 1 lần
# (dùng đúng user sẽ chạy script này, thường là root):
#   aws configure set aws_access_key_id <akid> --profile thuyldx-hni
#   aws configure set aws_secret_access_key <secret> --profile thuyldx-hni
# Script tự dò credentials qua: $AWS_SHARED_CREDENTIALS_FILE (nếu set) -> $HOME/.aws/credentials
# -> /root/.aws/credentials -> /home/*/.aws/credentials — không phụ thuộc $HOME lúc chạy qua
# sudo/su/cron. Nếu file nằm chỗ khác, chỉ định thẳng: AWS_SHARED_CREDENTIALS_FILE=/path/to/credentials
# curl --user vẫn hiện AK/SK trong `ps aux` lúc chạy (mọi user cùng máy thấy được) —
# nếu máy nhiều người dùng chung, cân nhắc chạy trong session riêng hoặc dùng cred ngắn hạn (STS).

set -uo pipefail

# ---------- AWS credentials (KHÔNG hardcode secret vào script — dùng AWS profile) ----------
# Ưu tiên theo thứ tự:
#   1. AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY nếu đã export sẵn trong shell (session tạm, không lưu)
#   2. AWS_PROFILE (mặc định: thuyldx-hni) đọc từ ~/.aws/credentials qua `aws configure get`
#      -> setup 1 lần: aws configure set aws_access_key_id ... --profile thuyldx-hni
#                       aws configure set aws_secret_access_key ... --profile thuyldx-hni
#   Secret KHÔNG bao giờ được echo ra màn hình bởi script này.
AWS_PROFILE="${AWS_PROFILE:-thuyldx-hni}"
S3_TEST_BUCKET="${S3_TEST_BUCKET:-thuyldx-hni}"

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
S3_HOST="${S3_HOST:-s3-hcm.sds.infiniband.vn}"
NON_S3_HOST="${NON_S3_HOST:-cmc.sds.infiniband.vn}"
RESOLVE_IP="${RESOLVE_IP:-127.0.0.1}"
REGION_TAG="${REGION_TAG:-hcm}"
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_SERVICE="${S3_SERVICE:-s3}"
LOKI_URL="${LOKI_URL:-https://maas-service-logs.infiniband.vn/loki/api/v1/query_range}"
MIMIR_QUERY_URL="${MIMIR_QUERY_URL:-https://maas-service-metrics.infiniband.vn/api/v1/query}"
MIMIR_LABEL_URL="${MIMIR_LABEL_URL:-https://maas-service-metrics.infiniband.vn/api/v1/label/__name__/values}"
ORG_ID="${ORG_ID:-vnpaycloud}"
LOKI_QUERY="${LOKI_QUERY:-{vnpaycloud_service=\"apisix\"}}"
NOTIFY_LAG_THRESHOLD="${NOTIFY_LAG_THRESHOLD:-300}"
CURL_MAX_TIME="${CURL_MAX_TIME:-15}"       # giây — chặn treo vô hạn khi backend không phản hồi
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_TO=(--connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME")

PASS=0; FAIL=0; WARN=0
ok()      { echo "  [OK]     $1"; PASS=$((PASS+1)); }
bad()     { echo "  [FAIL]   $1"; FAIL=$((FAIL+1)); }
warn()    { echo "  [WARN]   $1"; WARN=$((WARN+1)); }
hr()      { echo "----------------------------------------------------------------"; }
explain() { echo ""; echo "  >> ĐANG KIỂM TRA: $1"; echo "     Vì sao: $2"; }
nextstep(){ echo "     Nếu FAIL: $1"; }

cd "$BASE_DIR" || { echo "BASE_DIR không tồn tại: $BASE_DIR"; exit 1; }

echo "################################################################"
echo "# 1. RATE LIMIT + REDIS + SNI"
echo "################################################################"

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

explain "Route non-S3 ($NON_S3_HOST, ví dụ route-cmc.sds.infiniband.vn-https)" \
        "Route control-plane dùng key-auth/session thường, test PLAIN không ký để baseline rate-limit + auth riêng, KHÔNG liên quan gì tới SigV4 (đó là chuyện của route S3 data-plane)."
nextstep "Nếu 403 ở route non-S3: check key-auth consumer, không phải SigV4 — xem apisix_routes/consumers/*.yaml và header 'apikey' đã đúng chưa."
for i in $(seq 1 5); do
  curl -sk "${CURL_TO[@]}" -o /dev/null -w "  HTTP=%{http_code} rt_remaining=%header{x-ratelimit-remaining}\n" \
    "https://${NON_S3_HOST}/" --resolve "${NON_S3_HOST}:443:${RESOLVE_IP}"
done
echo "     Kỳ vọng: 200/404 khi chưa chạm limit, 429 khi chạm limit."

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

explain "Route S3 data-plane ($S3_HOST, service_id=svc-s3-sdk)" \
        "QUAN TRỌNG: route S3 KHÔNG dùng key-auth (comment trong apisix_routes/apisix-*.yaml ghi rõ '⚠ CHỈ cho API control-plane CÓ key-auth. KHÔNG dùng cho S3 data-plane'). S3 SDK/client chỉ được xác thực qua chữ ký SigV4/SigV2 ở tầng plugin custom.s3-accesskey-extractor, KHÔNG có concept 'apikey' header ở route này. Test với header apikey vào route S3 LUÔN sai hướng — không dùng lại pattern đó."
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
      "https://${S3_HOST}/${S3_TEST_BUCKET}/${TESTKEY}" --resolve "${S3_HOST}:443:${RESOLVE_IP}")
    S3_ERR_CODE=$(grep -oE "<Code>[^<]+</Code>" "$BODY_FILE" 2>/dev/null | sed -E 's/<\/?Code>//g')
    echo "  [$method] HTTP=$resp  S3-Code=${S3_ERR_CODE:-none}"
    rm -f "$BODY_FILE"
    case "$S3_ERR_CODE" in
      SignatureDoesNotMatch|InvalidAccessKeyId|RequestTimeTooSkewed)
        bad "$method -> $resp/$S3_ERR_CODE — chữ ký SAI THẬT" ;;
      AccessDenied)
        bad "$method -> $resp/AccessDenied — chữ ký hợp lệ nhưng KHÔNG có quyền (IAM Cloudian)" ;;
      NoSuchBucket)
        ok "$method -> $resp/NoSuchBucket — chữ ký ĐÚNG, bucket '$S3_TEST_BUCKET' chưa tồn tại (không phải lỗi)" ;;
      NoSuchKey)
        ok "$method -> $resp/NoSuchKey — chữ ký ĐÚNG, object chưa tồn tại (bình thường)" ;;
      "")
        case "$resp" in
          000) bad "$method -> timeout/connection failed sau ${CURL_MAX_TIME}s — check network/firewall tới upstream, KHÔNG phải lỗi auth" ;;
          2*) ok "$method -> $resp, auth pass" ;;
          *) warn "$method -> $resp, không có <Code> XML, xem raw body thủ công" ;;
        esac ;;
      *)
        warn "$method -> $resp/$S3_ERR_CODE — mã lỗi S3 khác, tra cứu thêm" ;;
    esac
  done
else
  echo "     SKIP ký SigV4 (thiếu AK/SK hoặc curl cũ) — chạy baseline KHÔNG ký, kỳ vọng AccessDenied/403 (ĐÚNG, không phải bug):"
  for i in $(seq 1 3); do
    curl -sk "${CURL_TO[@]}" -o /dev/null -w "  HTTP=%{http_code}\n" \
      "https://${S3_HOST}/" --resolve "${S3_HOST}:443:${RESOLVE_IP}"
  done
fi

hr
echo "################################################################"
echo "# 2. LOG (route: TẤT CẢ, qua global-loki-logger)"
echo "################################################################"

explain "access.log JSON format (route + service context)" \
        "loki-logger global rule chỉ gửi access.log (không gửi error.log) lên Loki — field route_id/service_id/akid/rt_limit/rt_remaining phải có đủ để audit theo route."
nextstep "Field thiếu -> check log_format trong config-hcm.yaml/config-hni.yaml, serverless-pre-function có inject đủ header X-Route-Id/X-Service-Id không."
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
  bad "Loki result rỗng (0 stream)"
fi

hr
echo "################################################################"
echo "# 3. METRIC"
echo "################################################################"

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

explain "Mimir remote_write — series apisix_http_status" \
        "Check HTTP code RAW trước khi parse JSON (lỗi 'Extra data' ở lần verify trước là do body không phải JSON hợp lệ, không phải do result rỗng)."
nextstep "HTTP != 200 -> check header X-Scope-OrgID, path /api/v1/query có đúng Mimir gateway config không (có thể cần prefix /prometheus/)."
MIMIR_HTTP=$(curl -s "${CURL_TO[@]}" -o /tmp/mimir_resp.txt -w "%{http_code}" \
  -H "X-Scope-OrgID: ${ORG_ID}" "${MIMIR_QUERY_URL}" --data-urlencode 'query=apisix_http_status')
echo "  HTTP=$MIMIR_HTTP"
head -c 500 /tmp/mimir_resp.txt; echo
if [ "$MIMIR_HTTP" = "200" ]; then
  python3 -m json.tool < /tmp/mimir_resp.txt 2>/dev/null | grep -E '"result"|"metric"' | head -10
  ok "Mimir query trả 200"
else
  bad "Mimir query trả HTTP=$MIMIR_HTTP"
fi

explain "Mimir — series apisix_http_status có thực sự tồn tại (độc lập với query ở trên)" \
        "remote_write từng verify bằng mã 400 (endpoint đúng) nhưng không xác nhận data đã ship — check qua /api/v1/label/__name__/values để chắc chắn."
LABEL_HTTP=$(curl -s "${CURL_TO[@]}" -o /tmp/mimir_label.txt -w "%{http_code}" -H "X-Scope-OrgID: ${ORG_ID}" "${MIMIR_LABEL_URL}")
echo "  HTTP=$LABEL_HTTP"
if [ "$LABEL_HTTP" = "200" ] && grep -q "apisix_http_status" /tmp/mimir_label.txt 2>/dev/null; then
  ok "series 'apisix_http_status' tồn tại trong Mimir"
else
  bad "series 'apisix_http_status' KHÔNG thấy trong Mimir"
fi

hr
echo "################################################################"
echo "# 4. GITSYNC + MERGE-FRAGMENTS + GLOBAL_RULES APPLY LAG"
echo "################################################################"

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
        "config_yaml.lua CHỈ hot-reload routes/services/upstreams/consumers/ssls trong-process (gitsync mỗi 30s). global_rules cần WORKER RESTART thật (PID reset, thấy dòng 'new plugins' với worker id mới) mới được nạp. Đổi global-loki-logger.yaml mà không restart = thay đổi nằm im trong file, KHÔNG chạy thật."
nextstep "Nếu treo quá ${NOTIFY_LAG_THRESHOLD}s: docker restart apisix-standalone, sau đó chạy lại script để confirm timestamp 'new plugins' đã theo sau 'NOT reloaded'."
RESTART_COUNT=$(grep -o "plugin.lua:223: load(): new plugins" logs/apisix/error.log 2>/dev/null | wc -l | tr -d ' ')
RESTART_COUNT="${RESTART_COUNT:-0}"
echo "  Số lần worker restart ghi nhận: $RESTART_COUNT"
LAST_NOTREADY_LINE=$(grep "NOT reloaded (restart required)" logs/apisix/error.log 2>/dev/null | tail -1)
LAST_NEWPLUGIN_LINE=$(grep "plugin.lua:223: load(): new plugins" logs/apisix/error.log 2>/dev/null | tail -1)
if [ -z "$LAST_NOTREADY_LINE" ]; then
  ok "Không có dòng 'NOT reloaded' nào — global_rules chưa từng đổi hoặc log đã rotate"
else
  NOTREADY_TS=$(echo "$LAST_NOTREADY_LINE" | awk '{print $1,$2}' | tr '/' '-')
  NOTREADY_EPOCH=$(date -d "$NOTREADY_TS" +%s 2>/dev/null)
  NOW_EPOCH=$(date +%s)
  AGE=$((NOW_EPOCH - NOTREADY_EPOCH))
  if [ -z "$LAST_NEWPLUGIN_LINE" ]; then
    NEWPLUGIN_EPOCH=0
  else
    NEWPLUGIN_TS=$(echo "$LAST_NEWPLUGIN_LINE" | awk '{print $1,$2}' | tr '/' '-')
    NEWPLUGIN_EPOCH=$(date -d "$NEWPLUGIN_TS" +%s 2>/dev/null)
  fi
  echo "  'NOT reloaded' gần nhất: $NOTREADY_TS (cách đây ${AGE}s)"
  echo "  'new plugins' (restart) gần nhất: ${NEWPLUGIN_TS:-chưa từng}"
  if [ "$NEWPLUGIN_EPOCH" -ge "$NOTREADY_EPOCH" ]; then
    ok "Restart đã xảy ra SAU/CÙNG lúc — global_rules đã được apply"
  elif [ "$AGE" -lt "$NOTIFY_LAG_THRESHOLD" ]; then
    warn "Chưa thấy restart theo sau, mới ${AGE}s — có thể đang chờ chu kỳ gitsync 30s, chạy lại sau ${NOTIFY_LAG_THRESHOLD}s để confirm"
  else
    bad "Treo >${NOTIFY_LAG_THRESHOLD}s không restart"
  fi
fi

hr
echo "################################################################"
echo "# 5. CONTAINERS"
echo "################################################################"

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
echo "SUMMARY: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
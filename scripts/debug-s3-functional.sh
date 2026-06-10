#!/usr/bin/env bash
# =============================================================================
# Tầng 2  →  điền BUCKET thật, chạy để test end-to-end qua APISIX
# test_s3_functional_curl.sh
# Functional test — gọi thẳng APISIX bằng curl với AWS Signature V4
#
# Mục đích:
#   Verify plugin s3-normalizer-bucket-name hoạt động đúng trên live environment cho cả 2 DC: s3-hcm.sds.infiniband.vn và s3-hni.sds.infiniband.vn
#   Bao gồm T1–T6: path-style HCM, vhost-style HCM (curl với Host: header), invalid bucket → 400, path-style HNI, cross-route isolation,
#      và 10MB streaming upload để verify proxy_request_buffering off.
#
# Expected của từng test:
#   T1.1 list-buckets:   Request thực tế GET / path-style                                                -> Expected: HTTP 200, list trả về
#   T1.3 PUT object:     Request thực tế PUT /test-thuyldx/apisix-test/...                               -> Expected: HTTP 200
#   T1.4 GET object:     Request thực tế GET /test-thuyldx/apisix-test/...                               -> Expected: HTTP 200, content khớp
#   T2.1 vhost HEAD:     Request thực tế Host: test-thuyldx.s3-hcm.sds.infiniband.vn → plugin rewrite    -> Expected: HTTP 200 hoặc 301 — đây là test quan trọng nhất
#   T3.1 invalid bucket: Request thực tế GET /nobucket/file.txt                                          -> Expected: Request thực tế
#   T6 10MB upload:      Request thực tế PUT 10MB body                                                   -> Expected: HTTP 200, không OOM

# Yêu cầu:
#   - curl (với HTTPS support)
#   - aws CLI (để sign request, hoặc dùng pre-signed URL)
#   - jq (optional, để parse JSON response)
#
# Cách chạy:
#   chmod +x test_s3_functional_curl.sh
#   ./test_s3_functional_curl.sh
#
#   Hoặc override endpoint:
#   APISIX_HCM=https://s3-hcm.sds.infiniband.vn \
#   BUCKET=your-bucket-name \
#   AWS_ACCESS_KEY_ID=xxx AWS_SECRET_ACCESS_KEY=yyy \
#   ./test_s3_functional_curl.sh
# =============================================================================

set -euo pipefail

# ─── CONFIG ───────────────────────────────────────────────────────────────────
APISIX_HCM="${APISIX_HCM:-https://s3-hcm.sds.infiniband.vn}"
APISIX_HNI="${APISIX_HNI:-https://s3-hni.sds.infiniband.vn}"

# Thay bằng bucket thực của bạn (phải tồn tại trên Cloudian)
# Bucket name PHẢI có dạng word-word (hyphen-separated) theo isBucket() rule
BUCKET="${BUCKET:-my-bucket}"          # bucket tồn tại trên HCM
BUCKET_HNI="${BUCKET_HNI:-my-bucket}"  # bucket tồn tại trên HNI (có thể cùng tên)

# Test object key — sẽ upload/download/delete trong test
TEST_KEY="apisix-plugin-test/test-$(date +%s).txt"
TEST_CONTENT="APISIX s3-normalizer-bucket-name plugin test $(date)"

# AWS credentials — lấy từ env hoặc hardcode ở đây (KHÔNG commit lên git)
: "${AWS_ACCESS_KEY_ID:?'Set AWS_ACCESS_KEY_ID'}"
: "${AWS_SECRET_ACCESS_KEY:?'Set AWS_SECRET_ACCESS_KEY'}"
AWS_REGION="${AWS_REGION:-us-east-1}"   # Cloudian thường dùng us-east-1

# curl common options
CURL_OPTS="-sk --max-time 30"   # -s silent, -k skip TLS verify (private CA)

# ─── COLORS ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS="${GREEN}✓ PASS${NC}"; FAIL="${RED}✗ FAIL${NC}"; SKIP="${YELLOW}⊘ SKIP${NC}"

PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0

log()  { echo -e "$1"; }
pass() { log "  ${PASS} — $1"; ((PASS_COUNT++)); }
fail() { log "  ${FAIL} — $1"; ((FAIL_COUNT++)); }
skip() { log "  ${SKIP} — $1"; ((SKIP_COUNT++)); }
section() { echo; log "${YELLOW}▶ $1${NC}"; }

# ─── AWS SigV4 helper (dùng aws CLI) ─────────────────────────────────────────
# aws s3api call, force path-style, endpoint override về APISIX
aws_s3() {
  local endpoint="$1"; shift
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION="$AWS_REGION" \
  aws s3api \
    --endpoint-url "$endpoint" \
    --no-verify-ssl \
    "$@" 2>&1
}

aws_s3_path() {
  local endpoint="$1"; shift
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION="$AWS_REGION" \
  aws s3api \
    --endpoint-url "$endpoint" \
    --no-verify-ssl \
    "$@" 2>&1
}

# ─── curl với Host header override (simulate vhost-style) ────────────────────
curl_vhost() {
  local host="$1"
  local url="$2"
  shift 2
  curl $CURL_OPTS \
    -H "Host: ${host}" \
    -o /dev/null -w "%{http_code}" \
    "$@" "$url"
}

# ─── Check aws CLI available ──────────────────────────────────────────────────
check_deps() {
  for cmd in curl aws; do
    if ! command -v "$cmd" &>/dev/null; then
      log "${RED}ERROR: '$cmd' not found. Please install it.${NC}"
      exit 1
    fi
  done
}

# =============================================================================
# TEST GROUPS
# =============================================================================

# ── T1: Path-style via APISIX ────────────────────────────────────────────────
test_path_style_hcm() {
  section "T1: Path-style — HCM (s3-hcm.sds.infiniband.vn)"

  # T1.1 List all buckets
  log "  T1.1 GET / — list all buckets"
  if aws_s3 "$APISIX_HCM" list-buckets &>/dev/null; then
    pass "list-buckets returned OK"
  else
    fail "list-buckets failed (check credentials/connectivity)"
  fi

  # T1.2 List objects in bucket
  log "  T1.2 GET /$BUCKET — list objects"
  if aws_s3 "$APISIX_HCM" list-objects --bucket "$BUCKET" &>/dev/null; then
    pass "list-objects bucket=$BUCKET OK"
  else
    fail "list-objects bucket=$BUCKET failed"
  fi

  # T1.3 PUT object (upload)
  log "  T1.3 PUT /$BUCKET/$TEST_KEY"
  local tmpfile; tmpfile=$(mktemp)
  echo "$TEST_CONTENT" > "$tmpfile"
  if aws_s3 "$APISIX_HCM" put-object \
      --bucket "$BUCKET" \
      --key "$TEST_KEY" \
      --body "$tmpfile" &>/dev/null; then
    pass "put-object OK → bucket=$BUCKET key=$TEST_KEY"
  else
    fail "put-object failed"
  fi
  rm -f "$tmpfile"

  # T1.4 GET object (download)
  log "  T1.4 GET /$BUCKET/$TEST_KEY"
  local tmpout; tmpout=$(mktemp)
  if aws_s3 "$APISIX_HCM" get-object \
      --bucket "$BUCKET" \
      --key "$TEST_KEY" \
      "$tmpout" &>/dev/null; then
    local content; content=$(cat "$tmpout")
    if echo "$content" | grep -q "APISIX s3-normalizer"; then
      pass "get-object OK — content verified"
    else
      fail "get-object returned wrong content: $content"
    fi
  else
    fail "get-object failed"
  fi
  rm -f "$tmpout"

  # T1.5 DELETE object
  log "  T1.5 DELETE /$BUCKET/$TEST_KEY"
  if aws_s3 "$APISIX_HCM" delete-object \
      --bucket "$BUCKET" \
      --key "$TEST_KEY" &>/dev/null; then
    pass "delete-object OK"
  else
    fail "delete-object failed"
  fi
}

# ── T2: Vhost-style via APISIX ───────────────────────────────────────────────
# vhost-style: SDK gửi Host: <bucket>.s3-hcm.sds.infiniband.vn
# Plugin rewrite → path-style trước khi forward upstream
test_vhost_style_hcm() {
  section "T2: Vhost-style — HCM (boto3/aws CLI với addressing_style=virtual)"

  # Vhost endpoint: trỏ vào APISIX nhưng bucket trong Host
  # aws CLI không native support custom vhost, dùng curl trực tiếp ký tay
  # Thay vào đó dùng boto3 script riêng (test_s3_boto3.py)

  local vhost_host="${BUCKET}.s3-hcm.sds.infiniband.vn"
  local apisix_ip; apisix_ip=$(echo "$APISIX_HCM" | sed 's|https://||;s|http://||')

  # T2.1 HEAD object — kiểm tra plugin có rewrite Host+URI đúng không
  log "  T2.1 HEAD /$TEST_KEY via vhost (Host: $vhost_host)"
  local key_check="apisix-plugin-test/ping.txt"

  # Upload object trước qua path-style
  local tmpfile; tmpfile=$(mktemp)
  echo "vhost test" > "$tmpfile"
  aws_s3 "$APISIX_HCM" put-object \
    --bucket "$BUCKET" \
    --key "$key_check" \
    --body "$tmpfile" &>/dev/null || true
  rm -f "$tmpfile"

  # GET qua vhost (curl với Host header)
  # curl kết nối tới APISIX (apisix_ip), Host header = vhost → plugin rewrite
  local http_code
  http_code=$(curl $CURL_OPTS \
    -H "Host: ${vhost_host}" \
    -o /dev/null -w "%{http_code}" \
    "https://${apisix_ip}/${key_check}" 2>/dev/null || echo "000")

  case "$http_code" in
    200) pass "GET via vhost → plugin rewrite OK (HTTP 200)" ;;
    301|302) pass "GET via vhost → redirect (HTTP $http_code) — plugin active" ;;
    404) fail "GET via vhost → 404 (object missing or bucket not found — bucket=$BUCKET key=$key_check)" ;;
    400) fail "GET via vhost → 400 BAD REQUEST — plugin returned error (bucket name invalid?)" ;;
    000) skip "Cannot reach APISIX at $apisix_ip (DNS/network)" ;;
    *)   fail "GET via vhost → unexpected HTTP $http_code" ;;
  esac

  # Cleanup
  aws_s3 "$APISIX_HCM" delete-object \
    --bucket "$BUCKET" \
    --key "$key_check" &>/dev/null || true
}

# ── T3: Invalid bucket name → 400 ────────────────────────────────────────────
test_invalid_bucket_names() {
  section "T3: Invalid bucket names → expect HTTP 400"

  local apisix_ip; apisix_ip=$(echo "$APISIX_HCM" | sed 's|https://||;s|http://||')

  # T3.1 Path-style: /nobucket/key (bucket không có hyphen)
  log "  T3.1 Path-style invalid bucket 'nobucket' (no hyphen)"
  local code
  code=$(curl $CURL_OPTS \
    -H "Host: s3-hcm.sds.infiniband.vn" \
    -o /dev/null -w "%{http_code}" \
    "https://${apisix_ip}/nobucket/file.txt" 2>/dev/null || echo "000")
  [[ "$code" == "400" ]] && pass "HTTP 400 as expected (invalid bucket 'nobucket')" \
                          || fail "Expected 400, got $code for invalid bucket 'nobucket'"

  # T3.2 Path-style: /-badname/key (bucket bắt đầu bằng -)
  log "  T3.2 Path-style invalid bucket '-badname' (leading hyphen)"
  code=$(curl $CURL_OPTS \
    -H "Host: s3-hcm.sds.infiniband.vn" \
    -o /dev/null -w "%{http_code}" \
    "https://${apisix_ip}/-badname/file.txt" 2>/dev/null || echo "000")
  [[ "$code" == "400" ]] && pass "HTTP 400 as expected (invalid bucket '-badname')" \
                          || fail "Expected 400, got $code for bucket '-badname'"

  # T3.3 Vhost-style: nobucket.s3-hcm.sds.infiniband.vn (no hyphen in bucket)
  # isBucketInDomain sẽ trả false → fall to CASE3 passthrough (không phải 400)
  # → upstream nhận request và trả lỗi 404/403 từ Cloudian
  log "  T3.3 Vhost-style 'nobucket' (no hyphen) → expect passthrough (not 400)"
  code=$(curl $CURL_OPTS \
    -H "Host: nobucket.s3-hcm.sds.infiniband.vn" \
    -o /dev/null -w "%{http_code}" \
    "https://${apisix_ip}/file.txt" 2>/dev/null || echo "000")
  [[ "$code" != "400" ]] && pass "Not 400 — passthrough as expected (got $code)" \
                          || fail "Got unexpected 400 for vhost passthrough case"
}

# ── T4: Path-style HNI ───────────────────────────────────────────────────────
test_path_style_hni() {
  section "T4: Path-style — HNI (s3-hni.sds.infiniband.vn)"

  log "  T4.1 GET / — list all buckets on HNI"
  if aws_s3 "$APISIX_HNI" list-buckets &>/dev/null; then
    pass "list-buckets HNI OK"
  else
    fail "list-buckets HNI failed"
  fi

  log "  T4.2 PUT/GET/DELETE roundtrip on HNI"
  local tmpfile; tmpfile=$(mktemp)
  echo "HNI test $TEST_CONTENT" > "$tmpfile"
  local hni_key="apisix-test/hni-$(date +%s).txt"

  local ok=true
  aws_s3 "$APISIX_HNI" put-object --bucket "$BUCKET_HNI" --key "$hni_key" --body "$tmpfile" &>/dev/null || ok=false
  rm -f "$tmpfile"

  if $ok; then
    local tmpout; tmpout=$(mktemp)
    aws_s3 "$APISIX_HNI" get-object --bucket "$BUCKET_HNI" --key "$hni_key" "$tmpout" &>/dev/null || ok=false
    rm -f "$tmpout"
    aws_s3 "$APISIX_HNI" delete-object --bucket "$BUCKET_HNI" --key "$hni_key" &>/dev/null || true
  fi

  $ok && pass "HNI roundtrip PUT→GET→DELETE OK" || fail "HNI roundtrip failed"
}

# ── T5: Cross-route isolation ─────────────────────────────────────────────────
test_cross_route_isolation() {
  section "T5: Cross-route isolation"

  local hcm_ip; hcm_ip=$(echo "$APISIX_HCM" | sed 's|https://||;s|http://||')
  local hni_ip; hni_ip=$(echo "$APISIX_HNI" | sed 's|https://||;s|http://||')

  # T5.1 HNI vhost trên HCM endpoint → phải 404 hoặc passthrough (upstream không biết HNI domain)
  log "  T5.1 HNI vhost host trên HCM APISIX instance"
  local code
  code=$(curl $CURL_OPTS \
    -H "Host: ${BUCKET}.s3-hni.sds.infiniband.vn" \
    -o /dev/null -w "%{http_code}" \
    "https://${hcm_ip}/file.txt" 2>/dev/null || echo "000")
  # Route match: *.s3-hni.sds.infiniband.vn → route id=21/22 → upstream 101 (HNI)
  # Trên DC1 có cả 2 route → request có thể reach HNI upstream từ HCM APISIX
  # Điều này là EXPECTED vì apisix-dc1.yaml define cả HCM + HNI routes
  [[ "$code" != "000" ]] && pass "Cross-domain request routed (HTTP $code) — DC1 routes both HCM+HNI" \
                           || skip "Cannot connect ($code)"
}

# ── T6: Large object handling ─────────────────────────────────────────────────
test_large_object() {
  section "T6: Large object streaming (10MB — verify proxy_request_buffering off)"

  local tmpfile; tmpfile=$(mktemp)
  # Tạo file 10MB bằng /dev/urandom
  dd if=/dev/urandom of="$tmpfile" bs=1M count=10 2>/dev/null
  local actual_size; actual_size=$(stat -c%s "$tmpfile" 2>/dev/null || stat -f%z "$tmpfile")

  local key="apisix-test/large-$(date +%s).bin"

  log "  T6.1 PUT 10MB object (streaming upload)"
  local start_ts; start_ts=$(date +%s%N)

  if aws_s3 "$APISIX_HCM" put-object \
      --bucket "$BUCKET" \
      --key "$key" \
      --body "$tmpfile" &>/dev/null; then

    local end_ts; end_ts=$(date +%s%N)
    local elapsed_ms=$(( (end_ts - start_ts) / 1000000 ))
    pass "10MB PUT OK in ${elapsed_ms}ms"

    # Download và verify size
    local tmpout; tmpout=$(mktemp)
    if aws_s3 "$APISIX_HCM" get-object \
        --bucket "$BUCKET" --key "$key" "$tmpout" &>/dev/null; then
      local dl_size; dl_size=$(stat -c%s "$tmpout" 2>/dev/null || stat -f%z "$tmpout")
      [[ "$dl_size" -eq "$actual_size" ]] \
        && pass "10MB GET OK — size match ($dl_size bytes)" \
        || fail "Size mismatch: uploaded=$actual_size downloaded=$dl_size"
    else
      fail "10MB GET failed"
    fi
    rm -f "$tmpout"

    aws_s3 "$APISIX_HCM" delete-object --bucket "$BUCKET" --key "$key" &>/dev/null || true
  else
    fail "10MB PUT failed"
  fi

  rm -f "$tmpfile"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  check_deps

  echo
  echo "═══════════════════════════════════════════════════════════════════"
  echo "  APISIX s3-normalizer-bucket-name — Functional Test Suite"
  echo "  HCM endpoint : $APISIX_HCM"
  echo "  HNI endpoint : $APISIX_HNI"
  echo "  Bucket (HCM) : $BUCKET"
  echo "  Bucket (HNI) : $BUCKET_HNI"
  echo "═══════════════════════════════════════════════════════════════════"

  test_path_style_hcm
  test_vhost_style_hcm
  test_invalid_bucket_names
  test_path_style_hni
  test_cross_route_isolation
  test_large_object

  echo
  echo "═══════════════════════════════════════════════════════════════════"
  echo -e "  Results: ${GREEN}PASS=$PASS_COUNT${NC}  ${RED}FAIL=$FAIL_COUNT${NC}  ${YELLOW}SKIP=$SKIP_COUNT${NC}"
  echo "═══════════════════════════════════════════════════════════════════"

  [[ $FAIL_COUNT -eq 0 ]]
}

main "$@"
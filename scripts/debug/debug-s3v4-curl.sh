#!/usr/bin/env bash
# Build curl command với AWS Signature V4
#
# Đây là signature debugging tool / curl command generator, không phải test script.
#   Tính AWS Signature V4 thủ công (từng bước: canonical request → string to sign → signing key → signature)
#   In ra curl command đã được ký — để bạn copy/paste chạy tay
#   Không có assertions — không biết pass/fail, không có expected vs actual
#   Không cleanup — không tạo/xóa object test
#
# Mục đích thực tế của nó là troubleshoot connectivity và TLS/SNI — đặc biệt là 2 mode:
#   curl --resolve domain:443:IP → SNI = domain name (nginx nhận đúng)
#   curl https://IP/... → SNI = IP (nginx không match được cert)
#
# Đây là tool để diagnose tại sao request bị reject — không phải để verify plugin behavior.
#
# Usage 1: bash debug-s3v4-curl.sh <access_key> <secret_key> [--resolve]
#
## Example 1: 
# time (export AWS_ACCESS_KEY_ID=68c526776d67b2d6da51 && export AWS_SECRET_ACCESS_KEY="Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10" && export AWS_DEFAULT_REGION=us-east-1 && export AWS_ENDPOINT_URL="https://s3-hcm.sds.infiniband.vn" && aws s3 ls s3://test-thuyldx/ --debug 2> debug_$(date +%Y%m%d_%H%M%S).log)
#
## Example 2: 
## Tính signature (chạy script để lấy chữ ký)
# bash debug-s3v4-curl.sh "$ACCESS_KEY" "$SECRET_KEY" --resolve 2>/dev/null | grep "^# Signature:" 
#
# Sau đó paste thủ công vào curl:
#curl -vk "https://s3-hcm.sds.infiniband.vn/bucket-demo/?delimiter=%2F&encoding-type=url&fetch-owner=true&list-type=2&prefix=" \
#  --resolve "s3-hcm.sds.infiniband.vn:443:172.26.29.231" \
#  -H "Host: s3-hcm.sds.infiniband.vn" \
#  -H "User-Agent: MinIO (linux; amd64) minio-go/v7.0.90 mc/test" \
#  -H "Accept-Encoding: identity" \
#  -H "X-Amz-Content-Sha256: ${PAYLOAD_HASH}" \
#  -H "X-Amz-Date: ${DATE_TIME}" \
#  -H "Authorization: AWS4-HMAC-SHA256 Credential=${ACCESS_KEY}/${DATE}/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=<PASTE_SIGNATURE>"

ACCESS_KEY="${1:-68c526776d67b2d6da51}"
SECRET_KEY="${2:-Qi+wH0tEGQgyAaww8YegoVK8gX4C96NKt3hM2C10}"
RESOLVE="${3:-}"   # "--resolve" để dùng --resolve thay vì connect thẳng IP

HOST="s3-hcm.sds.infiniband.vn"
REGION="us-east-1"
SERVICE="s3"
URI="${1:-/bucket-demo/}"
QUERY="delimiter=%2F&encoding-type=url&fetch-owner=true&list-type=2&prefix="
METHOD="GET"
PAYLOAD_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"  # SHA256 của empty body

# Timestamp hiện tại
DATE_TIME=$(date -u +"%Y%m%dT%H%M%SZ")
DATE=$(date -u +"%Y%m%d")

# ── Step 1: Canonical Request ────────────────────────────────────────────
CANONICAL_URI="/${URI#/}"
CANONICAL_QUERY=$(echo "$QUERY" | tr '&' '\n' | sort | tr '\n' '&' | sed 's/&$//')
CANONICAL_HEADERS="host:${HOST}\nx-amz-content-sha256:${PAYLOAD_HASH}\nx-amz-date:${DATE_TIME}\n"
SIGNED_HEADERS="host;x-amz-content-sha256;x-amz-date"

CANONICAL_REQUEST="${METHOD}\n${CANONICAL_URI}\n${CANONICAL_QUERY}\n${CANONICAL_HEADERS}\n${SIGNED_HEADERS}\n${PAYLOAD_HASH}"

# ── Step 2: String to Sign ───────────────────────────────────────────────
CREDENTIAL_SCOPE="${DATE}/${REGION}/${SERVICE}/aws4_request"
HASHED_CANONICAL=$(printf "${CANONICAL_REQUEST}" | openssl dgst -sha256 -hex | sed 's/^.* //')
STRING_TO_SIGN="AWS4-HMAC-SHA256\n${DATE_TIME}\n${CREDENTIAL_SCOPE}\n${HASHED_CANONICAL}"

# ── Step 3: Signing Key ──────────────────────────────────────────────────
hmac_sha256() {
    local key="$1"
    local data="$2"
    printf "${data}" | openssl dgst -sha256 -mac HMAC -macopt "key:${key}" -hex | sed 's/^.* //'
}
hmac_sha256_hex() {
    local key_hex="$1"
    local data="$2"
    printf "${data}" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" -hex | sed 's/^.* //'
}

DATE_KEY=$(hmac_sha256 "AWS4${SECRET_KEY}" "${DATE}")
DATE_REGION_KEY=$(hmac_sha256_hex "${DATE_KEY}" "${REGION}")
DATE_REGION_SERVICE_KEY=$(hmac_sha256_hex "${DATE_REGION_KEY}" "${SERVICE}")
SIGNING_KEY=$(hmac_sha256_hex "${DATE_REGION_SERVICE_KEY}" "aws4_request")

# ── Step 4: Signature ────────────────────────────────────────────────────
SIGNATURE=$(hmac_sha256_hex "${SIGNING_KEY}" "${STRING_TO_SIGN}")

# ── Step 5: Authorization header ─────────────────────────────────────────
AUTH="AWS4-HMAC-SHA256 Credential=${ACCESS_KEY}/${CREDENTIAL_SCOPE}, SignedHeaders=${SIGNED_HEADERS}, Signature=${SIGNATURE}"

# ── Build curl command ────────────────────────────────────────────────────
if [ "${RESOLVE}" = "--resolve" ]; then
    # Dùng --resolve: SNI = domain, connect = IP (giống nginx behavior)
    CURL_CMD="curl -vk \"https://${HOST}/${URI#/}?${QUERY}\" \\
  --resolve \"${HOST}:443:172.26.29.231\" \\
  -H \"Host: ${HOST}\" \\
  -H \"User-Agent: MinIO (linux; amd64) minio-go/v7.0.90 mc/test\" \\
  -H \"Accept-Encoding: identity\" \\
  -H \"X-Amz-Content-Sha256: ${PAYLOAD_HASH}\" \\
  -H \"X-Amz-Date: ${DATE_TIME}\" \\
  -H \"Authorization: ${AUTH}\""
else
    # Connect thẳng IP (SNI = IP)
    CURL_CMD="curl -vk \"https://172.26.29.231/${URI#/}?${QUERY}\" \\
  -H \"Host: ${HOST}\" \\
  -H \"User-Agent: MinIO (linux; amd64) minio-go/v7.0.90 mc/test\" \\
  -H \"Accept-Encoding: identity\" \\
  -H \"X-Amz-Content-Sha256: ${PAYLOAD_HASH}\" \\
  -H \"X-Amz-Date: ${DATE_TIME}\" \\
  -H \"Authorization: ${AUTH}\""
fi

echo "# Canonical Request:"
printf "${CANONICAL_REQUEST}\n\n"
echo "# String to Sign:"
printf "${STRING_TO_SIGN}\n\n"
echo "# DATE_TIME: ${DATE_TIME}"
echo "# Signature: ${SIGNATURE}"
echo ""
echo "# ── CURL COMMAND (connect via IP, SNI=IP) ──────────────────────────"
eval echo "\"${CURL_CMD}\""
echo ""
echo "# ── CURL COMMAND (--resolve, SNI=domain) ───────────────────────────"
RESOLVE="--resolve"
CURL_CMD2="curl -vk \"https://${HOST}/${URI#/}?${QUERY}\" \\
  --resolve \"${HOST}:443:172.26.29.231\" \\
  -H \"Host: ${HOST}\" \\
  -H \"User-Agent: MinIO (linux; amd64) minio-go/v7.0.90 mc/test\" \\
  -H \"Accept-Encoding: identity\" \\
  -H \"X-Amz-Content-Sha256: ${PAYLOAD_HASH}\" \\
  -H \"X-Amz-Date: ${DATE_TIME}\" \\
  -H \"Authorization: ${AUTH}\""
eval echo "\"${CURL_CMD2}\""

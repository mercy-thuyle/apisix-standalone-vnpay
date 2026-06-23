#!/usr/bin/env bash
# scripts/rdeploy/3-decrypt-certs.sh
# Decrypt .key.enc từ gitsync/current/certs/ → plaintext ra ./certs/
# Dùng CERT_DOMAINS trong scripts/libraries/decrypt-cert-helper.sh
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     ./scripts/deploy/3-decrypt-certs.sh
#
# ⚠️  Chạy thủ công trên host khi:
#   1. Deploy lần đầu
#   2. Renew cert
#   3. Clone repo sang host mới
#
# Sau khi decrypt xong → cert sẽ được inject tự động bởi:
#   scripts/runtime/inject-certs.sh (trong gitsync exechook)
# Không cần chạy inject-certs.sh thủ công nữa.

# ── VAULT INTEGRATION (uncomment khi có thông tin Vault) ─────────────────
# Khi chuyển sang Vault, script này không còn cần thiết.
# Cert fetch trực tiếp từ Vault qua APISIX secret_provider.
# Xem hướng dẫn trong scripts/libraries/decrypt-cert-helper.sh
#
# VAULT_ADDR="${VAULT_ADDR:-https://vault.internal:8200}"
# VAULT_TOKEN="${VAULT_TOKEN:-}"
# VAULT_MOUNT="${VAULT_MOUNT:-secret}"
# VAULT_PREFIX="${VAULT_PREFIX:-apisix/certs}"
#
# for domain in "${CERT_DOMAINS[@]}"; do
#   vault kv get -field=cert "${VAULT_MOUNT}/${VAULT_PREFIX}/${domain}" \
#     > "${DEPLOY_DIR}/certs/${domain}.cert"
#   vault kv get -field=key  "${VAULT_MOUNT}/${VAULT_PREFIX}/${domain}" \
#     > "${DEPLOY_DIR}/certs/${domain}.key"
#   chmod 600 "${DEPLOY_DIR}/certs/${domain}.key"
#   echo "✅ Fetched from Vault: ${domain}"
# done

set -euo pipefail

DEPLOY_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "📂 Deploy dir: ${DEPLOY_DIR}"
echo ""

# ── Source cert helper (CERT_DOMAINS + override maps) ─────────────────────
# shellcheck source=../libraries/decrypt-cert-helper.sh
source "${SCRIPT_DIR}/../libraries/decrypt-cert-helper.sh"
echo "🔧 CERT_DOMAINS (${#CERT_DOMAINS[@]}): ${CERT_DOMAINS[*]}"
echo ""

# ── Đọc CERT_PASSPHRASE từ .env ───────────────────────────────────────────
if [[ -z "${CERT_PASSPHRASE:-}" && -f "${DEPLOY_DIR}/.env" ]]; then
  CERT_PASSPHRASE="$(grep -E '^CERT_PASSPHRASE=' "${DEPLOY_DIR}/.env" | cut -d= -f2- | tr -d '[:space:]')"
fi

if [[ -z "${CERT_PASSPHRASE:-}" ]]; then
  echo "❌ CERT_PASSPHRASE chưa được set. Export hoặc khai báo trong .env"
  exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────
CERTS_ENC_DIR="${DEPLOY_DIR}/gitsync/current/certs"       # ← repo: source (xem naming convention/override trong lib)
OUTPUT_CERTS="${DEPLOY_DIR}/certs"                           # ← output: <domain>.cert + <domain>.key (normalized)

[[ ! -d "${CERTS_ENC_DIR}" ]] && { echo "❌ Not found: ${CERTS_ENC_DIR}"; exit 1; }
mkdir -p "${OUTPUT_CERTS}"

# ── Kiểm tra source files — domain nào thiếu sẽ SKIP (không hard-fail) ───
echo "🔍 Checking source files in ${CERTS_ENC_DIR}..."
READY_DOMAINS=()
for domain in "${CERT_DOMAINS[@]}"; do
  cert_src="$(src_cert_file "${domain}")"
  key_enc_src="$(src_key_enc_file "${domain}")"

  if [[ ! -f "${CERTS_ENC_DIR}/${cert_src}" || ! -f "${CERTS_ENC_DIR}/${key_enc_src}" ]]; then
    echo "   ⚠️  ${domain}  — thiếu ${cert_src} hoặc ${key_enc_src}, SKIP"
    continue
  fi
  echo "   ✅ ${domain}  (${cert_src}, ${key_enc_src})"
  READY_DOMAINS+=("${domain}")
done

if [[ ${#READY_DOMAINS[@]} -eq 0 ]]; then
  echo ""
  echo "❌ Không có domain nào sẵn sàng để decrypt"
  exit 1
fi

echo ""

# ── Decrypt keys vào /dev/shm (RAM) ──────────────────────────────────────
TMPDIR="$(mktemp -d /dev/shm/apisix-keys-XXXXXX)"
trap 'echo "🧹 Wiping RAM tmpdir..."; rm -rf "${TMPDIR}"' EXIT
chmod 700 "${TMPDIR}"

echo ""
echo "🔓 Decrypting keys → RAM (${TMPDIR})..."
for domain in "${READY_DOMAINS[@]}"; do
  key_enc_src="$(src_key_enc_file "${domain}")"
  KEY_ENC="${CERTS_ENC_DIR}/${key_enc_src}"
  KEY_OUT="${TMPDIR}/${domain}.key"

  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -a \
    -pass "pass:${CERT_PASSPHRASE}" \
    -in "${KEY_ENC}" \
    -out "${KEY_OUT}" 2>/dev/null || {
      echo "   ❌ Decrypt failed: ${domain} — sai passphrase?" >&2
      exit 1
    }
  echo "✅ Decrypted: ${domain}  (← ${key_enc_src})"
done

echo ""
# ── Validate cert ─────────────────────────────────────────────────────────
echo ""
echo "🔍 Validating certs..."
for domain in "${READY_DOMAINS[@]}"; do
  cert_src="$(src_cert_file "${domain}")"
  CERT_FILE="${CERTS_ENC_DIR}/${cert_src}"

  openssl x509 -in "${CERT_FILE}" -noout 2>/dev/null || {
    echo "❌ Invalid cert: ${CERT_FILE}"; exit 1
  }

  expiry=$(openssl x509 -in "${CERT_FILE}" -noout -enddate | cut -d= -f2)
  days_left=$(python3 -c "
from datetime import datetime, timezone
expiry = datetime.strptime('${expiry}', '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
print((expiry - datetime.now(timezone.utc)).days)")

  if [[ ${days_left} -lt 0 ]]; then
    echo "⚠️  WARNING: ${domain} EXPIRED ${days_left#-} days ago (${expiry})"
  elif [[ ${days_left} -lt 30 ]]; then
    echo "⚠️  WARNING: ${domain} expires in ${days_left} days (${expiry})"
  else
    echo "✅ Valid: ${domain} — ${days_left} days left"
  fi
done

echo ""

# ── Validate key–cert pair match ──────────────────────────────────────────
echo ""
echo "🔍 Validating key/cert pairs..."
for domain in "${READY_DOMAINS[@]}"; do
  cert_src="$(src_cert_file "${domain}")"
  CERT_FILE="${CERTS_ENC_DIR}/${cert_src}"
  KEY_FILE="${TMPDIR}/${domain}.key"

  cert_md5=$(openssl x509 -noout -modulus -in "${CERT_FILE}" | openssl md5)
  key_md5=$(openssl rsa -noout -modulus -in "${KEY_FILE}" 2>/dev/null | openssl md5)

  if [[ "${cert_md5}" != "${key_md5}" ]]; then
    echo "❌ MISMATCH: ${domain} — cert và key không khớp" >&2
    exit 1
  fi
  echo "✅ Match: ${domain}"
done

# ── Copy ra ./certs/ — LUÔN normalize về <domain>.cert / <domain>.key ────
echo ""
echo "📁 Updating ./certs/ (normalized naming)..."
chmod 755 "${OUTPUT_CERTS}"

for domain in "${READY_DOMAINS[@]}"; do
  cert_src="$(src_cert_file "${domain}")"
  cp "${CERTS_ENC_DIR}/${cert_src}" "${OUTPUT_CERTS}/${domain}.cert"
  cp "${TMPDIR}/${domain}.key"      "${OUTPUT_CERTS}/${domain}.key"
  chmod 640 "${OUTPUT_CERTS}/${domain}.cert"
  chmod 600 "${OUTPUT_CERTS}/${domain}.key"
  echo "✅ certs/${domain}.{cert,key}"
done

# trap EXIT tự wipe /dev/shm

SKIPPED=$(( ${#CERT_DOMAINS[@]} - ${#READY_DOMAINS[@]} ))
echo ""
echo "✅ Done: ${#READY_DOMAINS[@]}/${#CERT_DOMAINS[@]} domains decrypted → ./certs/"
if [[ ${SKIPPED} -gt 0 ]]; then
  echo "⚠️  ${SKIPPED} domain(s) skipped — chưa có source trong gitsync/current/certs/"
fi

echo ""
echo "▶  Cert sẽ được inject tự động vào apisix.yaml khi gitsync chạy exechook."
echo "   Để trigger ngay: git commit bất kỳ và push lên repo."
echo "   Hoặc restart gitsync: docker compose restart gitsync"

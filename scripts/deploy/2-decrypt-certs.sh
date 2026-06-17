#!/usr/bin/env bash
# scripts/rdeploy/2-decrypt-certs.sh
# Decrypt .key.enc từ gitsync/current/certs/ → plaintext ra ./certs/
# Dùng chung CERT_DOMAINS với 2-inject-certs.sh — xem scripts/libraries/cert-domains.sh
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     ./scripts/deploy/2-decrypt-certs.sh

set -euo pipefail

DEPLOY_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "📂 Deploy dir: ${DEPLOY_DIR}"

# ── Source shared CERT_DOMAINS list ──────────────────────────────────────
# shellcheck source=libraries/cert-domains.sh
source "${SCRIPT_DIR}/../libraries/cert-domains.sh"
echo "🔧 CERT_DOMAINS (${#CERT_DOMAINS[@]}): ${CERT_DOMAINS[*]}"
echo ""

# ── Đọc CERT_PASSPHRASE từ .env ───────────────────────────────────────────
if [[ -z "${CERT_PASSPHRASE:-}" && -f "${DEPLOY_DIR}/.env" ]]; then
  CERT_PASSPHRASE="$(grep -E '^CERT_PASSPHRASE=' "${DEPLOY_DIR}/.env" \
    | cut -d= -f2- | tr -d '[:space:]')"
fi

[[ -z "${CERT_PASSPHRASE:-}" ]] && {
  echo "❌ CERT_PASSPHRASE not set in .env"; exit 1
}

# ── Paths ─────────────────────────────────────────────────────────────────
CERTS_ENC_DIR="${DEPLOY_DIR}/gitsync/current/certs"       # ← repo: source (xem naming convention/override trong lib)
CERTS_DIR="${DEPLOY_DIR}/certs"                           # ← output: <domain>.cert + <domain>.key (normalized)
mkdir -p "${CERTS_DIR}"

# ── Kiểm tra source files — domain nào thiếu sẽ SKIP (không hard-fail) ───
echo "🔍 Checking source files in ${CERTS_ENC_DIR}..."
AVAILABLE=()
for domain in "${CERT_DOMAINS[@]}"; do
  cert_f="$(src_cert_file "${domain}")"
  key_f="$(src_key_enc_file "${domain}")"

  if [[ -f "${CERTS_ENC_DIR}/${cert_f}" && -f "${CERTS_ENC_DIR}/${key_f}" ]]; then
    echo "   ✅ ${domain}  (${cert_f}, ${key_f})"
    AVAILABLE+=("${domain}")
  else
    echo "   ⚠️  ${domain}  — thiếu ${cert_f} hoặc ${key_f}, SKIP"
    echo "      (kiểm tra gitsync: docker logs gitsync --tail 50)"
  fi
done

if [[ ${#AVAILABLE[@]} -eq 0 ]]; then
  echo ""
  echo "❌ Không có domain nào sẵn sàng để decrypt"
  exit 1
fi

# ── Decrypt keys vào /dev/shm (RAM) ──────────────────────────────────────
TMPDIR_KEYS="$(mktemp -d /dev/shm/apisix-keys-XXXXXX)"
trap 'echo "🧹 Wiping RAM tmpdir..."; rm -rf "${TMPDIR_KEYS}"' EXIT
chmod 700 "${TMPDIR_KEYS}"

echo ""
echo "🔓 Decrypting keys → RAM (${TMPDIR_KEYS})..."
for domain in "${AVAILABLE[@]}"; do
  key_f="$(src_key_enc_file "${domain}")"

  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -a \
    -in  "${CERTS_ENC_DIR}/${key_f}" \
    -out "${TMPDIR_KEYS}/${domain}.key" \
    -pass "pass:${CERT_PASSPHRASE}" 2>/dev/null; then
    echo "❌ Decrypt failed: ${key_f}"
    echo "   Kiểm tra CERT_PASSPHRASE trong .env"
    exit 1
  fi
  chmod 600 "${TMPDIR_KEYS}/${domain}.key"
  echo "✅ Decrypted: ${domain}  (← ${key_f})"
done

# ── Validate cert ─────────────────────────────────────────────────────────
echo ""
echo "🔍 Validating certs..."
for domain in "${AVAILABLE[@]}"; do
  cert_f="$(src_cert_file "${domain}")"
  cert_path="${CERTS_ENC_DIR}/${cert_f}"

  openssl x509 -in "${cert_path}" -noout 2>/dev/null || {
    echo "❌ Invalid cert: ${cert_path}"; exit 1
  }

  expiry=$(openssl x509 -in "${cert_path}" -noout -enddate | cut -d= -f2)
  days_left=$(python3 -c "
from datetime import datetime, timezone
expiry = datetime.strptime('${expiry}', '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc)
print((expiry - datetime.now(timezone.utc)).days)
")

  if [[ ${days_left} -lt 30 ]]; then
    echo "⚠️  WARNING: ${domain} expires in ${days_left} days (${expiry})"
  else
    echo "✅ ${domain} valid — expires in ${days_left} days"
  fi
done

# ── Validate key–cert pair match ──────────────────────────────────────────
echo ""
echo "🔍 Validating key/cert pairs..."
for domain in "${AVAILABLE[@]}"; do
  cert_f="$(src_cert_file "${domain}")"

  cert_mod=$(openssl x509 -noout -modulus \
    -in "${CERTS_ENC_DIR}/${cert_f}" | md5sum)
  key_mod=$(openssl rsa -noout -modulus \
    -in "${TMPDIR_KEYS}/${domain}.key" 2>/dev/null | md5sum)

  [[ "${cert_mod}" != "${key_mod}" ]] && {
    echo "❌ Key/Cert mismatch: ${domain}"; exit 1
  }
  echo "✅ Match: ${domain}"
done

# ── Copy ra ./certs/ — LUÔN normalize về <domain>.cert / <domain>.key ────
echo ""
echo "📁 Updating ./certs/ (normalized naming)..."
chmod 755 "${CERTS_DIR}"

for domain in "${AVAILABLE[@]}"; do
  cert_f="$(src_cert_file "${domain}")"

  cp "${CERTS_ENC_DIR}/${cert_f}"     "${CERTS_DIR}/${domain}.cert"
  chmod 644 "${CERTS_DIR}/${domain}.cert"

  cp "${TMPDIR_KEYS}/${domain}.key"   "${CERTS_DIR}/${domain}.key"
  chmod 600 "${CERTS_DIR}/${domain}.key"

  echo "✅ certs/${domain}.{cert,key}"
done

# trap EXIT tự wipe /dev/shm

SKIPPED=$(( ${#CERT_DOMAINS[@]} - ${#AVAILABLE[@]} ))
echo ""
echo "✅ Done: ${#AVAILABLE[@]}/${#CERT_DOMAINS[@]} domains decrypted → ./certs/"
if [[ ${SKIPPED} -gt 0 ]]; then
  echo "⚠️  ${SKIPPED} domain(s) skipped — chưa có source trong gitsync/current/certs/"
fi
echo "▶  Next: ./scripts/deploy/2-inject-certs.sh"
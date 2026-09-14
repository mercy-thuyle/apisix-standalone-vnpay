#!/usr/bin/env bash
# scripts/rdeploy/2-encrypt-keys.sh
# Encrypt .key → .key.enc trước khi commit lên GitLab
# Chạy trên máy ADMIN, không chạy trên DC host
#
# Usage:
#   ./scripts/deploy/2-encrypt-keys.sh <CERT_PASSPHRASE> <path/to/folder/certs>
#
# Hoặc nếu CERT_PASSPHRASE đã export:
#   ./scripts/deploy/2-encrypt-keys.sh "" /path/to/folder/certs
# VD: 
#   Passphrase truyền thẳng qua arg:
#   ./scripts/deploy/2-encrypt-keys.sh "a3f9c2e1b4d78..." /path/to/folder/certs
#
# Passphrase từ biến môi trường đã export (.bashrc / export trước đó)
#   export CERT_PASSPHRASE="a3f9c2e1b4d78..."
#   ./scripts/deploy/2-encrypt-keys.sh "" /path/to/folder/certs
#
# Passphrase từ .env (truyền inline)
#   ./scripts/deploy/2-encrypt-keys.sh "${CERT_PASSPHRASE}" /path/to/folder/certs

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────
PASSPHRASE="${1:-${CERT_PASSPHRASE:-}}"
CERTS_DIR="${2:-}"

[[ -z "${PASSPHRASE}" ]] && {
  echo "❌ CERT_PASSPHRASE not provided"
  echo "   Usage: $0 <CERT_PASSPHRASE> </path/to/folder/certs>"
  echo "   Or:    export CERT_PASSPHRASE=... && $0 \"\" </path/to/folder/certs>"
  exit 1
}

[[ -z "${CERTS_DIR}" ]] && {
  echo "❌ Certs path not provided"
  echo "   Usage: $0 <CERT_PASSPHRASE> </path/to/folder/certs>"
  exit 1
}

[[ ! -d "${CERTS_DIR}" ]] && {
  echo "❌ Directory not found: ${CERTS_DIR}"
  exit 1
}

echo "📂 Certs dir: ${CERTS_DIR}"

CERT_DOMAINS=(
  "s3-hcm.sds.infiniband.vn"
  "s3-hni.sds.infiniband.vn"
  "sds.infiniband.vn"
  "infiniband.vn"
)

resolve_cert_file() {
  local domain="$1"
  local cert_file

  for cert_file in \
    "${CERTS_DIR}/${domain}.cert" \
    "${CERTS_DIR}/${domain}.crt"; do
    if [[ -f "${cert_file}" ]]; then
      printf '%s\n' "${cert_file}"
      return 0
    fi
  done

  return 1
}

# ── Kiểm tra source key files ─────────────────────────────────────────────
echo "🔍 Checking source files..."
# for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
for domain in "${CERT_DOMAINS[@]}"; do
  cert_f="$(resolve_cert_file "${domain}")" || {
    echo "❌ Missing certificate: ${CERTS_DIR}/${domain}.cert or ${CERTS_DIR}/${domain}.crt"
    exit 1
  }
  [[ ! -f "${CERTS_DIR}/${domain}.key" ]] && {
    echo "❌ Missing key: ${CERTS_DIR}/${domain}.key"; exit 1
  }
done
echo "✅ Source files OK"

# ── Validate cert ─────────────────────────────────────────────────────────
echo ""
echo "🔍 Validating certs..."
# for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
for domain in "${CERT_DOMAINS[@]}"; do
  cert_f="$(resolve_cert_file "${domain}")"

  openssl x509 -in "${cert_f}" -noout 2>/dev/null || {
    echo "❌ Invalid cert: ${cert_f}"; exit 1
  }

  expiry=$(openssl x509 -in "${cert_f}" -noout -enddate | cut -d= -f2)
  days_left=$(python3 -c "from datetime import datetime, timezone; expiry = datetime.strptime('${expiry}', '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc); print((expiry - datetime.now(timezone.utc)).days)")

  if [[ ${days_left} -lt 30 ]]; then
    echo "⚠️  WARNING: ${domain}.cert expires in ${days_left} days (${expiry})"
  else
    echo "✅ Cert valid: ${domain} — expires in ${days_left} days"
  fi
done

# ── Validate key–cert pair match ──────────────────────────────────────────
echo ""
echo "🔍 Validating key/cert pairs..."
# for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
for domain in "${CERT_DOMAINS[@]}"; do
  cert_f="$(resolve_cert_file "${domain}")"
  cert_mod=$(openssl x509 -noout -modulus \
    -in "${cert_f}" | md5sum)
  key_mod=$(openssl rsa -noout -modulus \
    -in "${CERTS_DIR}/${domain}.key" 2>/dev/null | md5sum)
  [[ "${cert_mod}" != "${key_mod}" ]] && {
    echo "❌ Key/Cert mismatch: ${domain}"; exit 1
  }
  echo "✅ Key/Cert match: ${domain}"
done

# ── Encrypt keys vào cùng folder ─────────────────────────────────────────
echo ""
echo "🔐 Encrypting keys..."
# for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
for domain in "${CERT_DOMAINS[@]}"; do
  openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -a \
    -in  "${CERTS_DIR}/${domain}.key" \
    -out "${CERTS_DIR}/${domain}.key.enc" \
    -pass "pass:${PASSPHRASE}"
  echo "✅ Encrypted: ${domain}.key → ${domain}.key.enc"
done

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "📋 Files in ${CERTS_DIR}:"
ls -lh "${CERTS_DIR}/"
echo ""
echo "▶  Next:"
echo "   git add ${CERTS_DIR}/*.enc ${CERTS_DIR}/*.cert ${CERTS_DIR}/*.crt"
echo "   git commit -m 'rotate cert \$(date +%Y-%m-%d)'"
echo "   git push"
echo "▶  Or: just copy to git and commit"

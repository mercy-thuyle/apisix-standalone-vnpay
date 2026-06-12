#!/usr/bin/env bash
# 2-decrypt-certs.sh
# Decrypt .key.enc từ certs_enc/ → plaintext key ra certs/
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     ./scripts/2-decrypt-certs.sh

set -euo pipefail

DEPLOY_DIR="$(pwd)"
echo "📂 Deploy dir: ${DEPLOY_DIR}"

# ── Đọc CERT_PASSPHRASE từ .env ───────────────────────────────────────────
if [[ -z "${CERT_PASSPHRASE:-}" && -f "${DEPLOY_DIR}/.env" ]]; then
  CERT_PASSPHRASE="$(grep -E '^CERT_PASSPHRASE=' "${DEPLOY_DIR}/.env" \
    | cut -d= -f2- | tr -d '[:space:]')"
fi

[[ -z "${CERT_PASSPHRASE:-}" ]] && {
  echo "❌ CERT_PASSPHRASE not set in .env"; exit 1
}

# ── Paths ─────────────────────────────────────────────────────────────────
CERTS_ENC_DIR="${DEPLOY_DIR}/gitsync/current/certs"       # ← repo: .cert + .key.enc
CERTS_DIR="${DEPLOY_DIR}/certs"                           # ← output: .cert + .key plaintext

# ── Kiểm tra gitsync đã sync chưa ─────────────────────────────────────────────────
echo "🔍 Checking source files in ${CERTS_ENC_DIR}..."
for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
  for ext in "cert" "key.enc"; do
    [[ ! -f "${CERTS_ENC_DIR}/${domain}.${ext}" ]] && {
      echo "❌ Missing: ${CERTS_ENC_DIR}/${domain}.${ext}"
      echo "   Kiểm tra gitsync: docker logs gitsync --tail 50"
      exit 1
    }
  done
done
echo "✅ Source files OK"

# ── Decrypt keys vào /dev/shm (RAM) rồi cp sang certs/ ───────────────────
TMPDIR_KEYS="$(mktemp -d /dev/shm/apisix-keys-XXXXXX)"
trap 'echo "🧹 Wiping RAM tmpdir..."; rm -rf "${TMPDIR_KEYS}"' EXIT
chmod 700 "${TMPDIR_KEYS}"

echo "🔓 Decrypting keys → RAM (${TMPDIR_KEYS})..."
for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -a \
    -in  "${CERTS_ENC_DIR}/${domain}.key.enc" \
    -out "${TMPDIR_KEYS}/${domain}.key" \
    -pass "pass:${CERT_PASSPHRASE}" 2>/dev/null; then
    echo "❌ Decrypt failed: ${domain}.key.enc"
    echo "   Kiểm tra CERT_PASSPHRASE trong .env"
    exit 1
  fi
  chmod 600 "${TMPDIR_KEYS}/${domain}.key"
  echo "✅ Decrypted: ${domain}.key"
done

# ── Validate cert ─────────────────────────────────────────────────────────
echo ""
echo "🔍 Validating certs..."
for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
  cert_f="${CERTS_ENC_DIR}/${domain}.cert"

  openssl x509 -in "${cert_f}" -noout 2>/dev/null || {
    echo "❌ Invalid cert: ${cert_f}"; exit 1
  }

  expiry=$(openssl x509 -in "${cert_f}" -noout -enddate | cut -d= -f2)
  expiry_epoch=$(date -d "${expiry}" +%s)
  days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))

  if [[ ${days_left} -lt 30 ]]; then
    echo "⚠️  WARNING: ${domain}.cert expires in ${days_left} days (${expiry})"
  else
    echo "✅ Cert valid: ${domain} — expires in ${days_left} days"
  fi
done

# ── Validate key–cert pair match ──────────────────────────────────────────
echo ""
echo "🔍 Validating key/cert pairs..."
for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
  cert_mod=$(openssl x509 -noout -modulus \
    -in "${CERTS_ENC_DIR}/${domain}.cert" | md5sum)
  key_mod=$(openssl rsa -noout -modulus \
    -in "${TMPDIR_KEYS}/${domain}.key" 2>/dev/null | md5sum)
  [[ "${cert_mod}" != "${key_mod}" ]] && {
    echo "❌ Key/Cert mismatch: ${domain}"; exit 1
  }
  echo "✅ Key/Cert match: ${domain}"
done

# ── Copy ra certs/ ────────────────────────────────────────────────────────
echo ""
echo "📁 Updating ./certs/..."
chmod 755 "${CERTS_DIR}"

for domain in "s3-hcm.sds.infiniband.vn" "s3-hni.sds.infiniband.vn"; do
  cp "${CERTS_ENC_DIR}/${domain}.cert" "${CERTS_DIR}/${domain}.cert"
  chmod 644 "${CERTS_DIR}/${domain}.cert"

  cp "${TMPDIR_KEYS}/${domain}.key"    "${CERTS_DIR}/${domain}.key"
  chmod 600 "${CERTS_DIR}/${domain}.key"

  echo "✅ certs/ updated: ${domain}"
done

# trap EXIT tự wipe /dev/shm

echo ""
echo "✅ All done decrypted in folder certs/ ready"
echo "▶  Next: ./scripts/3-inject-certs.sh"
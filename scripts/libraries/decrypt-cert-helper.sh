#!/usr/bin/env bash
# scripts/libraties/decrypt-cert-helper.sh
#
# Shared cert helper là danh sách các domain — nguồn duy nhất (single source of truth) cho 2-decrypt-certs.sh
# Thêm domain mới ở ĐÂY, 2-decrypt-certs.sh tự động pick up — KHÔNG cần sửa gì thêm.
#
# Sync với: scripts/libraries/cert-list-domain.txt (cho runtime inject trong gitsync)
# Khi thêm domain mới → sửa CẢ 2 file này
#
# Convention chuẩn trong gitsync/current/certs/ (git repo):
#   <domain>.cert       (plaintext PEM, public — không cần encrypt)
#   <domain>.key.enc    (AES-256-CBC encrypted, base64)
#
# Output chuẩn trong ./certs/ (staging, sau decrypt):
#   <domain>.cert
#   <domain>.key        (plaintext, /dev/shm trước khi copy ra)
# =============================================================

# ── VAULT ──────────────
# VAULT_ADDR="${VAULT_ADDR:-https://vault.internal:8200}"
# VAULT_TOKEN="${VAULT_TOKEN:-}"           # hoặc dùng AppRole
# VAULT_MOUNT="${VAULT_MOUNT:-secret}"     # KV mount path
# VAULT_PREFIX="${VAULT_PREFIX:-apisix/certs}"
#
# Fetch cert từ Vault:
#   vault kv get -field=cert "${VAULT_MOUNT}/${VAULT_PREFIX}/${domain}" > "${domain}.cert"
#   vault kv get -field=key  "${VAULT_MOUNT}/${VAULT_PREFIX}/${domain}" > "${domain}.key"
#
# APISIX Vault secret provider (config.yaml):
#   secret_providers:
#     - id: vault-provider
#       provider: vault
#       prefix: "${VAULT_PREFIX}"
#       token: "${VAULT_TOKEN}"
#       host: "${VAULT_ADDR}"
#
# SSL entry trong apisix.yaml khi dùng Vault:
#   ssls:
#     - id: ssl-sds.infiniband.vn
#       snis: ["*.sds.infiniband.vn", "sds.infiniband.vn"]
#       cert: $secret://vault/ssl/sds.infiniband.vn/cert
#       key:  $secret://vault/ssl/sds.infiniband.vn/key


CERT_DOMAINS=(
  "infiniband.vn"
  "sds.infiniband.vn"
  "s3-hcm.sds.infiniband.vn"
  "s3-hni.sds.infiniband.vn"
)

# ── Override source filenames trong gitsync/current/certs/ ──────────────
# 2-decrypt-certs.sh mặc định tìm "<domain>.cert" + "<domain>.key.enc".
# Domain có naming KHÁC convention (ví dụ copy nguyên từ nginx dùng
# -crt.pem / -key.pem) thì khai báo override tại đây.
#
# QUAN TRỌNG: override này CHỈ ảnh hưởng input (gitsync/current/certs/).
# Output trong ./certs/ LUÔN luôn normalize về "<domain>.cert"/"<domain>.key"
declare -A SRC_CERT_FILE=(
  ["cmc.sds.infiniband.vn"]="cmc.sds.infiniband.vn-crt.pem"
  ["minio.sds.infiniband.vn"]="minio.sds.infiniband.vn-crt.pem"
)
declare -A SRC_KEY_ENC_FILE=(
  ["cmc.sds.infiniband.vn"]="cmc.sds.infiniband.vn-key.pem.enc"
  ["minio.sds.infiniband.vn"]="minio.sds.infiniband.vn-key.pem.enc"
)

# Helper — gọi từ 2-decrypt-certs.sh để resolve filename thật
# Dùng: cert_f="$(src_cert_file "$domain")"
src_cert_file()    { echo "${SRC_CERT_FILE[$1]:-$1.cert}"; }
src_key_enc_file() { echo "${SRC_KEY_ENC_FILE[$1]:-$1.key.enc}"; }

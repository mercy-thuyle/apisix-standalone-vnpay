#!/usr/bin/env bash
# scripts/libraties/cert-domains.sh
#
# Shared CERT_DOMAINS list — nguồn duy nhất (single source of truth) cho
# 2-decrypt-certs.sh và 2-inject-certs.sh. Thêm domain mới ở ĐÂY, cả 2
# script tự động pick up — KHÔNG cần sửa gì thêm trong 2-inject-certs.sh.
#
# Convention chuẩn trong gitsync/current/certs/ (git repo):
#   <domain>.cert       (plaintext PEM, public — không cần encrypt)
#   <domain>.key.enc    (AES-256-CBC encrypted, base64)
#
# Output chuẩn trong ./certs/ (staging, sau decrypt):
#   <domain>.cert
#   <domain>.key        (plaintext, /dev/shm trước khi copy ra)

CERT_DOMAINS=(
  "infiniband.vn"
  "sds.infiniband.vn"
  "s3-hcm.sds.infiniband.vn"
  "s3-hni.sds.infiniband.vn"
  "s3-rgwhcm.sds.infiniband.vn"
  "s3-rgwhni.sds.infiniband.vn"
  "cmc.sds.infiniband.vn"
  "minio.sds.infiniband.vn"
)

# ── Override source filenames trong gitsync/current/certs/ ──────────────
# 2-decrypt-certs.sh mặc định tìm "<domain>.cert" + "<domain>.key.enc".
# Domain có naming KHÁC convention (ví dụ copy nguyên từ nginx dùng
# -crt.pem / -key.pem) thì khai báo override tại đây.
#
# QUAN TRỌNG: override này CHỈ ảnh hưởng input (gitsync/current/certs/).
# Output trong ./certs/ LUÔN luôn normalize về "<domain>.cert"/"<domain>.key"
# — 2-inject-certs.sh không cần biết / không cần sửa gì cho các override này.
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
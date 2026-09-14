#!/usr/bin/env bash

CERT_DOMAINS=(
  "infiniband.vn"
  "sds.infiniband.vn"
  "s3-hcm.sds.infiniband.vn"
  "s3-hni.sds.infiniband.vn"
)

declare -A SRC_CERT_FILE=(
  ["cmc.sds.infiniband.vn"]="cmc.sds.infiniband.vn-crt.pem"
  ["minio.sds.infiniband.vn"]="minio.sds.infiniband.vn-crt.pem"
)
declare -A SRC_KEY_ENC_FILE=(
  ["cmc.sds.infiniband.vn"]="cmc.sds.infiniband.vn-key.pem.enc"
  ["minio.sds.infiniband.vn"]="minio.sds.infiniband.vn-key.pem.enc"
)

# src_cert_file()    { echo "${SRC_CERT_FILE[$1]:-$1.cert}"; }
src_cert_file() {
  local domain="$1"
  local certs_dir="$2"

  if [[ -n "${SRC_CERT_FILE[$domain]:-}" ]]; then
    echo "${SRC_CERT_FILE[$domain]}"
  elif [[ -f "${certs_dir}/${domain}.cert" ]]; then
    echo "${domain}.cert"
  elif [[ -f "${certs_dir}/${domain}.crt" ]]; then
    echo "${domain}.crt"
  else
    # Giữ .cert làm tên mặc định để 3-decrypt-certs.sh báo lỗi thiếu file rõ ràng.
    echo "${domain}.cert"
  fi
}

src_key_enc_file() { echo "${SRC_KEY_ENC_FILE[$1]:-$1.key.enc}"; }

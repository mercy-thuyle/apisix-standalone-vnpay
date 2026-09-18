#!/usr/bin/env bash

CERT_DOMAINS=(
  "vnpaycloud.vn"
  "sds.vnpaycloud.vn"
  "s3-hcm.sds.vnpaycloud.vn"
  "s3-hni.sds.vnpaycloud.vn"
)

declare -A SRC_CERT_FILE=()
declare -A SRC_KEY_ENC_FILE=()

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

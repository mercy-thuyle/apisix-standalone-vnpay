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

src_cert_file()    { echo "${SRC_CERT_FILE[$1]:-$1.cert}"; }
src_key_enc_file() { echo "${SRC_KEY_ENC_FILE[$1]:-$1.key.enc}"; }

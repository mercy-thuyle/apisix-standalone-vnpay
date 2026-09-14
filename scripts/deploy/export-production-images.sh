#!/usr/bin/env bash
# Export toàn bộ Docker image cần cho stack APISIX production.
# Chạy trên sandbox có sẵn image; output được chuyển qua Mac bằng tsh scp.

set -euo pipefail

OUTPUT_FILE="${1:-/tmp/apisix-production-images-amd64.tar.gz}"

IMAGES=(
  "apache/apisix:3.17.0-debian"
  "apisix-standalone/dashboard:3.17.0-debian"
  "registry.k8s.io/git-sync/git-sync:v4.2.1"
  "redis:7.4-alpine"
  "oliver006/redis_exporter:latest"
  "prom/prometheus:latest"
)

echo "▶ Kiểm tra image local và platform..."
for image in "${IMAGES[@]}"; do
  platform="$(docker image inspect \
    --format '{{.Os}}/{{.Architecture}}' "${image}")"

  if [[ "${platform}" != "linux/amd64" ]]; then
    echo "❌ ${image}: platform ${platform}, production yêu cầu linux/amd64" >&2
    exit 1
  fi

  echo "  ✅ ${image} (${platform})"
done

echo ""
echo "▶ Export ${#IMAGES[@]} image → ${OUTPUT_FILE}"
docker save "${IMAGES[@]}" | gzip -1 > "${OUTPUT_FILE}"

echo ""
echo "✅ Hoàn tất"
ls -lh "${OUTPUT_FILE}"
sha256sum "${OUTPUT_FILE}"
echo ""
echo "▶ Copy archive về local:"
echo "   sudo scp user@<sandbox-node>:${OUTPUT_FILE} ."
echo "▶ Copy archive về local:"
echo "   tsh scp ${OUTPUT_FILE} user@server:/home/user/

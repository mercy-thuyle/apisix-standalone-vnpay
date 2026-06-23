#!/bin/sh
# scripts/runtime/inject-certs.sh
#
# Runtime cert injector — được gọi bởi gitsync.sh sau mỗi merge thành công.
# Chạy trong gitsync container (busybox sh + perl, KHÔNG có bash/python3).
# ─────────────────────────────────────────────────────────────────────────

# ── VAULT INTEGRATION (uncomment khi có thông tin Vault) ─────────────────
# Khi chuyển sang Vault, bỏ comment block dưới và xóa toàn bộ
# phần inject bằng perl bên dưới. SSL entry trong apisix.yaml sẽ dùng:
#   cert: $secret://vault/ssl/<domain>/cert
#   key:  $secret://vault/ssl/<domain>/key
# APISIX tự fetch từ Vault — không cần inject cert vào yaml nữa.
# Xem cấu hình secret_provider trong config-{DC_PROFILE}.yaml
#
# VAULT_ADDR="${VAULT_ADDR:-https://vault.internal:8200}"
# VAULT_TOKEN="${VAULT_TOKEN:-}"
# Verify Vault reachable:
#   wget -q -O- "${VAULT_ADDR}/v1/sys/health" | grep -q '"initialized":true'

set -eu

OUTPUT="${OUTPUT:-/tmp/apisix_routes/apisix-${DC_PROFILE}.yaml}"                    # — path đến apisix-${DC_PROFILE}.yaml đã merge
CERTS_DIR="${CERTS_DIR:-/tmp/certs}"                                                # — path đến thư mục chứa cert/key (mount vào gitsync)
DOMAINS_FILE="${DOMAINS_FILE:-/tmp/scripts/libraries/cert-list-domain.txt}"         # — path đến cert-list-domain.txt

# ── Kiểm tra DC_PROFILE ──────────────────────────────────────────────────────
if [ -z "${DC_PROFILE:-}" ]; then
  echo "[gitsync] ERROR: DC_PROFILE chưa được set trong .env" >&2
  exit 1
fi

if [ ! -f "${OUTPUT}" ]; then
    echo "[inject-certs] ERROR: ${OUTPUT} không tồn tại" >&2
    exit 1
fi

if [ ! -d "${CERTS_DIR}" ]; then
    echo "[inject-certs] WARN: ${CERTS_DIR} không tồn tại — skip inject" >&2
    echo "[inject-certs] WARN: Cert placeholder sẽ còn lại trong output — APISIX SSL sẽ fail" >&2
    exit 0
fi

if [ ! -f "${DOMAINS_FILE}" ]; then
    echo "[inject-certs] ERROR: ${DOMAINS_FILE} không tồn tại" >&2
    echo "[inject-certs]   Kiểm tra scripts/libraries/cert-list-domain.txt đã commit chưa" >&2
    exit 1
fi

echo "[inject-certs] Injecting certs → ${OUTPUT}..."

INJECTED=0
MISSING=0

while IFS= read -r domain || [ -n "${domain}" ]; do
    # Bỏ qua comment và dòng rỗng
    case "${domain}" in
        "#"*|"") continue ;;
    esac

    for ext in cert key; do
        PLACEHOLDER="<PASTE_CONTENT_OF_${domain}.${ext}_HERE>"
        CERT_FILE="${CERTS_DIR}/${domain}.${ext}"

        # Kiểm tra placeholder có trong file không
        if ! grep -qF "${PLACEHOLDER}" "${OUTPUT}" 2>/dev/null; then
            continue  # placeholder không có → domain này không dùng cert riêng → OK
        fi

        if [ ! -f "${CERT_FILE}" ]; then
            echo "[inject-certs]   MISSING: ${CERT_FILE} — placeholder còn lại trong output" >&2
            MISSING=$((MISSING + 1))
            continue
        fi

        # perl -i: overwrite in-place, giữ nguyên inode cho Docker bind mount
        # Đọc PEM content, indent 6 spaces mỗi dòng, replace placeholder
        perl -i -pe "
            BEGIN {
                local \$/ = undef;
                open(my \$fh, '<', '${CERT_FILE}') or die 'Cannot open ${CERT_FILE}: ' . \$!;
                my \$raw = <\$fh>;
                close(\$fh);
                \$raw =~ s/\r\n/\n/g;
                \$raw =~ s/\s+\z//;
                \$pem = join('', map { '      ' . \$_ . \"\n\" } split(/\n/, \$raw));
            }
            s|      ${PLACEHOLDER}\n|\$pem|g;
        " "${OUTPUT}"

        INJECTED=$((INJECTED + 1))
        echo "[inject-certs]   ✓ ${domain}.${ext}"
    done
done < "${DOMAINS_FILE}"

# Đếm placeholder còn lại
REMAINING=$(grep -c "PASTE_CONTENT_OF_" "${OUTPUT}" 2>/dev/null || echo 0)

echo "[inject-certs] Done: injected=${INJECTED} missing=${MISSING} remaining=${REMAINING}"

if [ "${REMAINING}" -gt 0 ]; then
    echo "[inject-certs] WARN: ${REMAINING} placeholder(s) còn lại — APISIX SSL sẽ fail cho domain tương ứng" >&2
fi

if [ "${MISSING}" -gt 0 ]; then
    echo "[inject-certs] WARN: ${MISSING} cert file(s) thiếu — chạy ./scripts/deploy/3-decrypt-certs.sh trên host" >&2
fi

echo ""
echo "   apisix-${DC_PROFILE}.yaml"
echo "▶  APISIX standalone tự reload khi file thay đổi — KHÔNG cần restart/recreate container"
echo ""
echo "▶  Verify sau inject:"
echo "   # Host"
echo "   grep 'PASTE_CONTENT' apisix_routes/apisix-${DC_PROFILE}.yaml | wc -l  # phải là 0"
echo "   stat apisix_routes/apisix-${DC_PROFILE}.yaml | grep Inode"
echo ""
echo "   # Container"
echo "   docker exec apisix-standalone grep -c 'PASTE_CONTENT' /usr/local/apisix/conf/apisix-${DC_PROFILE}.yaml  # phải là 0"
echo "   docker exec apisix-standalone stat /usr/local/apisix/conf/apisix-${DC_PROFILE}.yaml | grep Inode"
echo ""
echo "   # Reload"
echo "   docker logs apisix-standalone --since 1m | grep -iE 'reload|sync'"

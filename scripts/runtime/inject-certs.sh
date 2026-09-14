#!/bin/sh

if [ -z "${DC_PROFILE:-}" ]; then
    DEPLOY_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
    if [ -f "${DEPLOY_DIR}/.env" ]; then
        # Dùng sed để parse .env — không cần bash/source
        eval "$(sed -n 's/^[^#][^=]*=.*/export &/p' "${DEPLOY_DIR}/.env")"
    fi
fi

set -eu

# ── Resolve paths — dùng deployment dir khi chạy local ───────────────────
# Gitsync: OUTPUT/CERTS_DIR/DOMAINS_FILE được pass từ gitsync.sh qua env
# Local:   fallback về path tương đối từ deployment dir
DEPLOY_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

OUTPUT="${OUTPUT:-${DEPLOY_DIR}/apisix_routes/apisix-${DC_PROFILE}.yaml}"
CERTS_DIR="${CERTS_DIR:-${DEPLOY_DIR}/certs}"
DOMAINS_FILE="${DOMAINS_FILE:-${DEPLOY_DIR}/scripts/libraries/cert-list-domains.txt}"

if [ ! -f "${OUTPUT}" ]; then
    echo "[inject-certs] ERROR: ${OUTPUT} không tồn tại" >&2
    exit 1
fi

if [ ! -d "${CERTS_DIR}" ]; then
    echo "[inject-certs] WARN: ${CERTS_DIR} không tồn tại — skip inject" >&2
    echo "[inject-certs] WARN: Cert placeholder còn lại → APISIX SSL sẽ fail" >&2
    exit 0
fi

if [ ! -f "${DOMAINS_FILE}" ]; then
    echo "[inject-certs] ERROR: ${DOMAINS_FILE} không tồn tại" >&2
    echo "[inject-certs]   Kiểm tra scripts/libraries/cert-list-domains.txt đã commit chưa" >&2
    exit 1
fi

echo "[inject-certs] Injecting certs → ${OUTPUT}..."

INJECTED=0
MISSING=0
PID=$$

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
            echo "[inject-certs]   MISSING: ${CERT_FILE} — placeholder còn lại" >&2
            MISSING=$((MISSING + 1))
            continue
        fi

        # Đọc PEM content, indent 6 spaces mỗi dòng, replace placeholder
        # Tạo PEM đã indent
        # sed 's/^/      /' thêm 6 spaces đầu mỗi dòng
        TEMP_PEM="/tmp/pem-${PID}-${domain}-${ext}.tmp"
        sed 's/^/      /' "${CERT_FILE}" > "${TEMP_PEM}"

        # Unique marker để sed locate chính xác dòng cần replace
        # Dùng hash của domain+ext để tránh collision
        MARKER="__INJECT_${PID}_$(echo "${domain}_${ext}" | sed 's/[^a-zA-Z0-9]/_/g')__"

        # Sed ra TEMP_OUT (KHÔNG dùng -i để tránh đổi inode)
        TEMP_OUT="/tmp/out-${PID}-${domain}-${ext}.tmp"
        sed "s|      ${PLACEHOLDER}|${MARKER}|" "${OUTPUT}" \
        | sed "/${MARKER}/r ${TEMP_PEM}" \
        | sed "/${MARKER}/d" > "${TEMP_OUT}"

        # cp vào OUTPUT — giữ nguyên inode cho Docker bind mount
        cp "${TEMP_OUT}" "${OUTPUT}"

        rm -f "${TEMP_PEM}" "${TEMP_OUT}"

        INJECTED=$((INJECTED + 1))
        echo "[inject-certs]   ✓ ${domain}.${ext}"
    done
done < "${DOMAINS_FILE}"

# Đếm placeholder còn lại
# REMAINING=$(grep -c "PASTE_CONTENT_OF_" "${OUTPUT}" 2>/dev/null || echo 0)
REMAINING=$(grep "PASTE_CONTENT_OF_" "${OUTPUT}" 2>/dev/null | wc -l | tr -d ' ')

echo "[inject-certs] Done: injected=${INJECTED} missing=${MISSING} remaining=${REMAINING}"

if [ "${REMAINING}" -gt 0 ]; then
    echo "[inject-certs] WARN: ${REMAINING} placeholder(s) còn lại — APISIX SSL sẽ fail cho domain tương ứng" >&2
    echo "[inject-certs] FATAL: ABORT — không cho phép file có placeholder chưa inject được promote vào live. Đây chính là lớp bug đã gây 'property \"key\" validation failed: string too short' (race giữa merge và inject) — xem note kỹ thuật, mục Sự cố 3." >&2
    exit 1
fi

if [ "${MISSING}" -gt 0 ]; then
    echo "[inject-certs] WARN: ${MISSING} cert file(s) thiếu — chạy ./scripts/deploy/3-decrypt-certs.sh trên host" >&2
fi

echo ""
echo " >>> [inject-certs] DONE"
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

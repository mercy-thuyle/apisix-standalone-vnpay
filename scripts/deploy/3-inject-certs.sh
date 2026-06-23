#!/usr/bin/env bash
# scripts/rdeploy/3-inject-certs.sh
# Đọc cert/key từ ./certs/ và nhúng vào apisix-${DC_PROFILE}.yaml
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     ./scripts/deploy/3-inject-certs.sh
#
# Certs cần có trong ./certs/ (sau khi chạy ./scripts/deploy/2-decrypt-certs.sh)
# — danh sách domain dùng CHUNG với 2-decrypt-certs.sh, xem scripts/libraries/cert-domains.sh
# — DC1 và DC2 dùng CHUNG set cert pairs này (wildcard theo domain,
#   không phụ thuộc backend IP của từng DC)
#
#   infiniband.vn.{cert,key}                — *.infiniband.vn (s3-hcm.infiniband.vn legacy)
#   sds.infiniband.vn.{cert,key}            — *.sds.infiniband.vn (apex mọi service .sds)
#   s3-hcm.sds.infiniband.vn.{cert,key}     — *.s3-hcm.sds.infiniband.vn (bucket vhost HCM)
#   s3-hni.sds.infiniband.vn.{cert,key}     — *.s3-hni.sds.infiniband.vn (bucket vhost HNI)
#   s3-rgwhcm.sds.infiniband.vn.{cert,key}  — *.s3-rgwhcm.sds.infiniband.vn (Ceph RGW HCM)
#   s3-rgwhni.sds.infiniband.vn.{cert,key}  — *.s3-rgwhni.sds.infiniband.vn (Ceph RGW HNI)
#
# Script chỉ inject placeholder NÀO THỰC SỰ CÓ trong apisix-${DC_PROFILE}.yaml nên cùng 1 script dùng được cho cả dc1 và dc2 dù 2 file có khác route/cert set.
# Thêm domain mới → sửa CERT_DOMAINS trong scripts/librảies/cert-domains.sh, KHÔNG cần sửa gì trong file này.

set -euo pipefail

# ── Đọc DC_PROFILE từ .env nếu chưa có trong env ─────────────────────────
DEPLOY_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "📂 Deploy dir: ${DEPLOY_DIR}"
echo "   (nên là /opt/apisix/standalone/<env>)"
echo ""

# ── Source shared CERT_DOMAINS list (dùng chung với 2-decrypt-certs.sh) ──
# shellcheck source=lib/cert-domains.sh
source "${SCRIPT_DIR}/../libraries/cert-domains.sh"
echo "🔧 CERT_DOMAINS (${#CERT_DOMAINS[@]}): ${CERT_DOMAINS[*]}"
echo ""

if [[ -z "${DC_PROFILE:-}" && -f "${DEPLOY_DIR}/.env" ]]; then
  DC_PROFILE="$(grep -E '^DC_PROFILE=' "${DEPLOY_DIR}/.env" | cut -d= -f2 | tr -d '[:space:]')"
fi

if [[ -z "${DC_PROFILE:-}" ]]; then
  echo "❌ DC_PROFILE chưa được set. Export hoặc khai báo trong .env"
  echo "   export DC_PROFILE=dc1  # dc1 | dc2"
  exit 1
fi

echo "🔧 DC_PROFILE: ${DC_PROFILE}"

YAML="${DEPLOY_DIR}/apisix_routes/apisix-${DC_PROFILE}.yaml"
CERTS_DIR="${DEPLOY_DIR}/certs"

[[ ! -f "${YAML}" ]] && { echo "❌ Not found: ${YAML}"; exit 1; }
[[ ! -d "${CERTS_DIR}" ]] && { echo "❌ Not found: ${CERTS_DIR}"; exit 1; }

# CERT_DOMAINS đã được source từ scripts/lib/cert-domains.sh ở trên

# ── Validate cert files có sẵn trong ./certs/ ────────────────────────────
echo ""
echo "🔍 Checking cert files in ${CERTS_DIR}..."
for domain in "${CERT_DOMAINS[@]}"; do
  cert_f="${CERTS_DIR}/${domain}.cert"
  key_f="${CERTS_DIR}/${domain}.key"

  if [[ ! -f "${cert_f}" || ! -f "${key_f}" ]]; then
    echo "   ⚠️  Missing: ${domain}.cert / .key (sẽ skip nếu placeholder không có trong YAML)"
    continue
  fi

  if ! openssl x509 -in "${cert_f}" -noout 2>/dev/null; then
    echo "   ❌ Invalid cert: ${cert_f}"
    exit 1
  fi

  expiry=$(openssl x509 -in "${cert_f}" -noout -enddate | cut -d= -f2)
  days_left=$(python3 -c "from datetime import datetime, timezone; expiry = datetime.strptime('${expiry}', '%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc); print((expiry - datetime.now(timezone.utc)).days)")

  if [[ ${days_left} -lt 30 ]]; then
    echo "   ⚠️  WARNING: ${domain}.cert expires in ${days_left} days (${expiry})"
  else
    echo "   ✅ Valid: ${domain}.cert — ${days_left} days left"
  fi
done

# ── Backup ────────────────────────────────────────────────────────────────
TS="$(date +%Y%m%d-%H%M%S)"
cp "${YAML}" "${YAML}.bak-${TS}"
echo ""
echo "📋 Backup: ${YAML}.bak-${TS}"

# ── Inject bằng Python (raw string replace, KHÔNG re-serialize YAML) ─────
echo ""
echo "💉 Injecting certs..."

# Build Python list literal từ bash array CERT_DOMAINS (single source of truth
# là scripts/lib/cert-domains.sh, không duplicate list ở đây)
PY_CERT_DOMAINS="$(printf '"%s", ' "${CERT_DOMAINS[@]}")"
PY_CERT_DOMAINS="[${PY_CERT_DOMAINS%, }]"

python3 - << PYEOF
import os, re

CERTS_DIR = "${CERTS_DIR}"
YAML_PATH = "${YAML}"
INDENT    = "      "   # 6 spaces — khớp indent của "cert: |" / "key: |" trong YAML

CERT_DOMAINS = ${PY_CERT_DOMAINS}

def read_pem(path):
    """Đọc file PEM, thêm indent 6-space cho mỗi dòng để khớp YAML block scalar"""
    with open(path, "r") as f:
        lines = f.read().strip().splitlines()
    return "\n".join(INDENT + line for line in lines) + "\n"

with open(YAML_PATH, "r") as f:
    content = f.read()

injected, skipped_missing, already_done = [], [], []

for domain in CERT_DOMAINS:
    for ext in ("cert", "key"):
        placeholder = f"<PASTE_CONTENT_OF_{domain}.{ext}_HERE>"
        needle = INDENT + placeholder + "\n"
        filepath = os.path.join(CERTS_DIR, f"{domain}.{ext}")

        if needle not in content:
            already_done.append(f"{domain}.{ext}")
            continue

        if not os.path.exists(filepath):
            skipped_missing.append(f"{domain}.{ext}")
            continue

        content = content.replace(needle, read_pem(filepath))
        injected.append(f"{domain}.{ext}")

# Đảm bảo #END là dòng cuối cùng — không re-serialize, chỉ chuẩn hoá trailing
content = content.rstrip()
if not content.endswith("#END"):
    content = re.sub(r'\n#END\s*$', '', content)
    content = content.rstrip()
content += "\n\n#END\n"

with open(YAML_PATH, "w") as f:
    f.write(content)

print(f"   ✅ Injected ({len(injected)}):")
for f_ in injected:
    print(f"      → {f_}")

if skipped_missing:
    print(f"   ⚠️  Skipped — cert file not found in ./certs/ ({len(skipped_missing)}):")
    for f_ in skipped_missing:
        print(f"      → {f_}  (placeholder vẫn còn trong YAML)")

if already_done:
    print(f"   ℹ️  Placeholder không tồn tại trong YAML này — bỏ qua ({len(already_done)}):")
    for f_ in already_done:
        print(f"      → {f_}")
PYEOF

# ── Verify ────────────────────────────────────────────────────────────────
echo ""
echo "🔍 Verification..."

REMAINING=$(grep -o '<PASTE_CONTENT_OF_[^>]*>' "${YAML}" || true)
if [[ -n "${REMAINING}" ]]; then
  echo "   ⚠️  Placeholders còn lại (thiếu cert file tương ứng):"
  echo "${REMAINING}" | sort -u | while read -r p; do
    echo "      ${p}"
  done
  echo "   → Domain liên quan sẽ KHÔNG có SSL cert cho đến khi inject đủ"
else
  echo "   ✅ All placeholders injected"
fi

if ! tail -5 "${YAML}" | grep -q "^#END"; then
  echo "   ❌ #END missing from end of file!"
  exit 1
fi
echo "   ✅ #END present"

echo ""
echo "✅ Done → ${YAML}"
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

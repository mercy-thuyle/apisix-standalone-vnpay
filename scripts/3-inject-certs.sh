#!/usr/bin/env bash
# 2-inject-certs.sh — đọc cert/key từ ./certs/ và nhúng vào apisix-${DC_PROFILE}.yaml
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     ./scripts/2-inject-certs.sh

set -euo pipefail

# ── Đọc DC_PROFILE từ .env nếu chưa có trong env ─────────────────────────
DEPLOY_DIR="$(pwd)"
echo "📂 Deploy dir: ${DEPLOY_DIR}"
echo "   (nên là /opt/apisix/standalone/<env>)"
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

# ── Kiểm tra file tồn tại ────────────────────────────────────────────────
required_files=(
  "s3-hcm.sds.infiniband.vn.cert"
  "s3-hcm.sds.infiniband.vn.key"
  "s3-hni.sds.infiniband.vn.cert"
  "s3-hni.sds.infiniband.vn.key"
)

for f in "${required_files[@]}"; do
  if [[ ! -f "${CERTS_DIR}/${f}" ]]; then
    echo "❌ Missing: ${CERTS_DIR}/${f}"
    exit 1
  fi
done

# ── Validate cert files ─────────────────────────────────────────────────────────
for f in "s3-hcm.sds.infiniband.vn.cert" "s3-hni.sds.infiniband.vn.cert"; do
  if ! openssl x509 -in "${CERTS_DIR}/${f}" -noout 2>/dev/null; then
    echo "❌ Invalid cert: ${CERTS_DIR}/${f}"
    exit 1
  fi
  echo "✅ Cert OK: ${f}"
done

cp "${YAML}" "${YAML}.bak"
echo "📋 Backup: ${YAML}.bak"

python3 - << PYEOF
import sys, re

INDENT = "      "  # 6 spaces

def read_pem(path):
    with open(path, "r") as f:
        lines = f.read().strip().splitlines()
    return "\n".join(INDENT + line for line in lines) + "\n"

replacements = {
    "<PASTE_CONTENT_OF_s3-hcm.sds.infiniband.vn.cert_HERE>": read_pem("${CERTS_DIR}/s3-hcm.sds.infiniband.vn.cert"),
    "<PASTE_CONTENT_OF_s3-hcm.sds.infiniband.vn.key_HERE>":  read_pem("${CERTS_DIR}/s3-hcm.sds.infiniband.vn.key"),
    "<PASTE_CONTENT_OF_s3-hni.sds.infiniband.vn.cert_HERE>": read_pem("${CERTS_DIR}/s3-hni.sds.infiniband.vn.cert"),
    "<PASTE_CONTENT_OF_s3-hni.sds.infiniband.vn.key_HERE>":  read_pem("${CERTS_DIR}/s3-hni.sds.infiniband.vn.key"),
}

with open("${YAML}", "r") as f:
    content = f.read()

missing = [k for k in replacements if k not in content]
if missing:
    print("⚠️  Placeholders not found (already injected?):")
    for m in missing:
        print(f"   {m}")
    sys.exit(0)

for placeholder, pem_content in replacements.items():
    content = content.replace(INDENT + placeholder + "\n", pem_content)

# Đảm bảo #END luôn là dòng cuối cùng, không có whitespace thừa sau nó
content = content.rstrip()
if not content.endswith("#END"):
    # Xóa #END cũ nếu bị lẫn vào giữa rồi append lại
    content = re.sub(r'\n#END\s*$', '', content)
    content = content.rstrip()
content = content + "\n\n#END\n"

with open("${YAML}", "w") as f:
    f.write(content)

print("✅ Certs injected → ${YAML}")
PYEOF

# ── Verify ────────────────────────────────────────────────────────────────
if grep -q "PASTE_CONTENT" "${YAML}"; then
  echo "❌ Inject failed — placeholder still present"
  exit 1
fi

if ! tail -3 "${YAML}" | grep -q "^#END"; then
  echo "❌ #END missing from end of file!"
  exit 1
fi

echo "✅ Verification passed"
echo "   Last 3 lines:"
tail -3 "${YAML}"
echo ""
echo "▶  Next: docker compose restart"
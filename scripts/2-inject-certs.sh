#!/usr/bin/env bash
# inject-certs.sh — đọc cert/key từ ./certs/ và nhúng vào apisix-standalone.yaml
set -euo pipefail

YAML="./conf_routes/apisix_routes/apisix-dc1.yaml"
CERTS_DIR="./certs"

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

# Validate cert files
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

# Verify
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
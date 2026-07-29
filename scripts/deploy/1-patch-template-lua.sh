#!/usr/bin/env bash
# scripts/deploy/1-patch-template-lua.sh
#
# Patch 5 file APISIX core để fix hành vi không mong muốn:
#   1. ngx_tpl.lua      — xóa proxy_set_header X-Forwarded-Port
#   2. init.lua         — xóa var_x_forwarded_port khỏi upstream_proxy_headers
#   3. vault.lua        — KV v2 support (thêm /data/ vào path)
#   4. config_yaml.lua   — đổi warn message "reloaded" thành rõ ràng hơn
#   5. kafka-logger.lua — a/thêm ssl/ssl_verify cho SASL_SSL Kafka (Strimzi TLS)
#                       — b/thêm api_version để có timestamp thật (fix epoch-0)
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     bash ./scripts/deploy/1-patch-template-lua.sh

set -euo pipefail

IMAGE="apache/apisix:3.17.0-debian"
TPL="/usr/local/apisix/apisix/cli/ngx_tpl.lua"
INIT="/usr/local/apisix/apisix/init.lua"
VAULT="/usr/local/apisix/apisix/secret/vault.lua"
CONFIG_YAML="/usr/local/apisix/apisix/core/config_yaml.lua"
KAFKA_LOGGER="/usr/local/apisix/apisix/plugins/kafka-logger.lua"

# ── Output vào $PWD (nơi caller đang đứng) ───────────────────────────────
# Dùng BASH_SOURCE để resolve đúng dù gọi từ bất kỳ $PWD nào
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "📂 Deploy dir: ${DEPLOY_DIR}"
echo "   (nên là /opt/apisix/standalone/<env>)"
echo ""

# ── 1. Patch ngx_tpl.lua ──────────────────────────────────────────────────
echo "▶ [1/5] Patch ngx_tpl.lua — xóa proxy_set_header X-Forwarded-Port..."
docker run --rm "${IMAGE}" cat "${TPL}" > "${DEPLOY_DIR}/ngx_tpl.lua.orig"
grep -v 'proxy_set_header.*X-Forwarded-Port' "${DEPLOY_DIR}/ngx_tpl.lua.orig" > "${DEPLOY_DIR}/ngx_tpl.lua"
echo "  diff:"
diff "${DEPLOY_DIR}/ngx_tpl.lua.orig" "${DEPLOY_DIR}/ngx_tpl.lua" || true

# ── 2. Patch init.lua ─────────────────────────────────────────────────────
echo ""
echo "▶ [2/5] Patch init.lua — xóa var_x_forwarded_port khỏi upstream_proxy_headers..."
docker run --rm "${IMAGE}" cat "${INIT}" > "${DEPLOY_DIR}/init.lua.orig"
# Xóa dòng set_header X-Forwarded-Port (APISIX 3.16: core.request.set_header)
# Khớp cả 2 pattern: bảng upstream_proxy_headers VÀ set_header trực tiếp
grep -v 'set_header(api_ctx, "X-Forwarded-Port"' "${DEPLOY_DIR}/init.lua.orig" \
  | grep -v "var_x_forwarded_port.*=.*'X-Forwarded-Port'" > "${DEPLOY_DIR}/init.lua"
echo "  diff:"
diff "${DEPLOY_DIR}/init.lua.orig" "${DEPLOY_DIR}/init.lua" || true

# ── 3. Patch vault.lua — KV v2 support ───────────────────────────────────
echo ""
echo "▶ [3/5] Patch vault.lua — Vault KV v2 support... (thêm /data/ vào path)..."
docker run --rm "${IMAGE}" cat "${VAULT}" > "${DEPLOY_DIR}/vault.lua.orig"
cp "${DEPLOY_DIR}/vault.lua.orig" "${DEPLOY_DIR}/vault.lua"

# Patch 1: thêm /data/ vào path — match pattern chính xác từ file gốc
sed -i 's|.. conf.prefix .. "/" .. key)|.. conf.prefix .. "/data/" .. key)|' \
    "${DEPLOY_DIR}/vault.lua"

# Patch 2a: check condition thêm ret.data.data
sed -i 's|if not ret or not ret.data then|if not ret or not ret.data or not ret.data.data then|' \
    "${DEPLOY_DIR}/vault.lua"

# Patch 2b: extract từ ret.data.data thay vì ret.data
sed -i 's|return ret.data\[sub_key\]|return ret.data.data[sub_key]|' \
    "${DEPLOY_DIR}/vault.lua"

# Verify
echo "  diff:"
diff "${DEPLOY_DIR}/vault.lua.orig" "${DEPLOY_DIR}/vault.lua" || true

PATCH_OK=0
grep -q '"/data/"' "${DEPLOY_DIR}/vault.lua"          && echo "  ✅ path /data/: OK"          || { echo "  ❌ path /data/: FAILED";          PATCH_OK=1; }
grep -q 'ret.data.data then' "${DEPLOY_DIR}/vault.lua" && echo "  ✅ check ret.data.data: OK"  || { echo "  ❌ check ret.data.data: FAILED";  PATCH_OK=1; }
grep -q 'ret.data.data\[' "${DEPLOY_DIR}/vault.lua"   && echo "  ✅ return ret.data.data: OK" || { echo "  ❌ return ret.data.data: FAILED"; PATCH_OK=1; }

[ "${PATCH_OK}" -eq 0 ] || exit 1

# ── 4. Patch config_yaml.lua — warn message rõ ràng hơn ──────────────────
echo ""
echo "▶ [4/5] Patch config_yaml.lua — thêm context vào warn message 'reloaded'..."
echo "  ⚠ Đây là patch thẩm mỹ (không ảnh hưởng chức năng)."
echo "  ⚠ Nhạy cảm với thay đổi source code qua mỗi version — verify diff kỹ."
docker run --rm "${IMAGE}" cat "${CONFIG_YAML}" > "${DEPLOY_DIR}/config_yaml.lua.orig"
cp "${DEPLOY_DIR}/config_yaml.lua.orig" "${DEPLOY_DIR}/config_yaml.lua"

OLD_MSG='log.warn("config file ", config_file.path, " reloaded.")'
NEW_MSG='log.warn("config file ", config_file.path, " hot-reloaded by gitsync every 30s (routes/plugin_configs/services/upstreams/consumers/ssls only) AND config file ", apisix_conf_path, " NOT reloaded (restart required) -> Verify: docker logs gitsync --tail 20")'
sed -i "s|${OLD_MSG}|${NEW_MSG}|" "${DEPLOY_DIR}/config_yaml.lua"

echo "  diff:"
diff "${DEPLOY_DIR}/config_yaml.lua.orig" "${DEPLOY_DIR}/config_yaml.lua" || true

# Verify patch [4] áp dụng đúng
if grep -q 'hot-reloaded by gitsync every' "${DEPLOY_DIR}/config_yaml.lua"; then
  echo "  ✅ config_yaml.lua warn message: OK"
else
  echo "  ❌ config_yaml.lua warn message: FAILED"
  echo "     Pattern gốc có thể đã thay đổi trong version này."
  echo "     Kiểm tra lại:"
  echo "       docker run --rm ${IMAGE} grep -n 'reloaded' ${CONFIG_YAML}"
  echo "     Rồi cập nhật sed pattern trong script này."
  exit 1
fi

# ── 5.a. Patch kafka-logger.lua — thêm ssl/ssl_verify support ─────────────
echo ""
echo "▶ [5.a/5] Patch kafka-logger.lua — thêm ssl/ssl_verify vào schema + broker_config..."
echo "  ⚠ Đây là patch HÀNH VI CHỨC NĂNG (khác patch [4] thẩm mỹ)."
echo "  ⚠ Nhạy cảm với thay đổi source code qua mỗi version — verify diff kỹ,"
echo "    và bắt buộc re-test end-to-end với Kafka thật sau mỗi lần upgrade."
docker run --rm "${IMAGE}" cat "${KAFKA_LOGGER}" > "${DEPLOY_DIR}/kafka-logger.lua.orig"
cp "${DEPLOY_DIR}/kafka-logger.lua.orig" "${DEPLOY_DIR}/kafka-logger.lua"

python3 - "${DEPLOY_DIR}/kafka-logger.lua" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old_schema = '''        log_format = {type = "object"},
        -- deprecated, use "brokers" instead'''
new_schema = '''        log_format = {type = "object"},
        ssl = {type = "boolean", default = false},
        ssl_verify = {type = "boolean", default = true},
        -- deprecated, use "brokers" instead'''

old_broker = '''    broker_config["refresh_interval"] = conf.meta_refresh_interval * 1000'''
new_broker = '''    broker_config["refresh_interval"] = conf.meta_refresh_interval * 1000
    broker_config["ssl"] = conf.ssl
    broker_config["ssl_verify"] = conf.ssl_verify'''

for old, new, label in [(old_schema, new_schema, "schema"), (old_broker, new_broker, "broker_config")]:
    c = content.count(old)
    if c != 1:
        print(f"ERROR: anchor '{label}' matched {c} times (expected 1)", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)
PYEOF

if [ $? -ne 0 ]; then
    echo "  ❌ kafka-logger.lua patch FAILED — pattern gốc đã thay đổi trong version này."
    echo "     Kiểm tra lại:"
    echo "       docker run --rm ${IMAGE} sed -n '35,45p' ${KAFKA_LOGGER}"
    echo "       docker run --rm ${IMAGE} grep -n 'refresh_interval' ${KAFKA_LOGGER}"
    echo "     Rồi cập nhật anchor pattern trong script này."
    exit 1
fi

echo "  diff:"
diff "${DEPLOY_DIR}/kafka-logger.lua.orig" "${DEPLOY_DIR}/kafka-logger.lua" || true

PATCH_OK=0
grep -q 'ssl = {type = "boolean", default = false}'          "${DEPLOY_DIR}/kafka-logger.lua" && echo "  ✅ schema: ssl: OK"                 || { echo "  ❌ schema: ssl: FAILED";                 PATCH_OK=1; }
grep -q 'ssl_verify = {type = "boolean", default = true}'    "${DEPLOY_DIR}/kafka-logger.lua" && echo "  ✅ schema: ssl_verify: OK"          || { echo "  ❌ schema: ssl_verify: FAILED";          PATCH_OK=1; }
grep -q 'broker_config\["ssl"\] = conf.ssl'                  "${DEPLOY_DIR}/kafka-logger.lua" && echo "  ✅ broker_config: ssl: OK"          || { echo "  ❌ broker_config: ssl: FAILED";          PATCH_OK=1; }
grep -q 'broker_config\["ssl_verify"\] = conf.ssl_verify'    "${DEPLOY_DIR}/kafka-logger.lua" && echo "  ✅ broker_config: ssl_verify: OK"   || { echo "  ❌ broker_config: ssl_verify: FAILED";   PATCH_OK=1; }

# Lua syntax check bằng luajit trong image — tránh cài lua riêng trên host
docker run --rm -v "${DEPLOY_DIR}/kafka-logger.lua:/tmp/kafka-logger.lua:ro" "${IMAGE}" \
    /usr/local/openresty/luajit/bin/luajit -bl /tmp/kafka-logger.lua > /dev/null \
    && echo "  ✅ lua syntax hợp lệ: OK" \
    || { echo "  ❌ lua syntax lỗi: FAILED"; PATCH_OK=1; }

[ "${PATCH_OK}" -eq 0 ] || exit 1

# ── 5.b. Patch kafka-logger.lua — thêm api_version (fix timestamp epoch-0) ─
echo ""
echo "▶ [5.b/5] Patch kafka-logger.lua — thêm api_version vào schema + broker_config..."
echo "  ⚠ Đây là patch HÀNH VI CHỨC NĂNG (cùng file với patch [5], áp dụng"
echo "    tiếp lên bản đã patch SSL — KHÔNG cat lại từ image gốc)."
echo "  ⚠ Set api_version=2 trong apisix_routes/global_rules/*.yaml SAU khi"
echo "    patch này để thực sự kích hoạt Message Format v1 (timestamp thật)."

python3 - "${DEPLOY_DIR}/kafka-logger.lua" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

old_schema = '''        ssl_verify = {type = "boolean", default = true},
        -- deprecated, use "brokers" instead'''
new_schema = '''        ssl_verify = {type = "boolean", default = true},
        api_version = {
            type = "integer",
            minimum = 0,
            maximum = 2,
            default = 1,
            description = "Kafka Produce API version. Set to 2 to enable Message " ..
                           "Format v1 (RecordBatch with real CreateTime), fixing " ..
                           "epoch-0 timestamp on broker. See patch [6] trong " ..
                           "1-patch-template-lua.sh.",
        },
        -- deprecated, use "brokers" instead'''

old_broker = '''    broker_config["ssl"] = conf.ssl
    broker_config["ssl_verify"] = conf.ssl_verify'''
new_broker = '''    broker_config["ssl"] = conf.ssl
    broker_config["ssl_verify"] = conf.ssl_verify
    broker_config["api_version"] = conf.api_version'''

for old, new, label in [(old_schema, new_schema, "schema"), (old_broker, new_broker, "broker_config")]:
    c = content.count(old)
    if c != 1:
        print(f"ERROR: anchor '{label}' matched {c} times (expected 1)", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)
PYEOF

if [ $? -ne 0 ]; then
    echo "  ❌ kafka-logger.lua patch [5.b] FAILED — pattern gốc đã thay đổi (có thể"
    echo "     do patch [5.a] đổi cấu trúc, hoặc version APISIX mới đổi source)."
    echo "     Kiểm tra lại:"
    echo "       grep -n 'ssl_verify\\|broker_config\\[\"ssl_verify\"\\]' ${DEPLOY_DIR}/kafka-logger.lua"
    echo "     Rồi cập nhật anchor pattern trong script này."
    exit 1
fi

echo "  diff (so với bản GỐC image, đã gồm cả patch [5.a]+[5.b]):"
diff "${DEPLOY_DIR}/kafka-logger.lua.orig" "${DEPLOY_DIR}/kafka-logger.lua" || true

PATCH_OK=0
grep -q 'api_version = {'                                     "${DEPLOY_DIR}/kafka-logger.lua" && echo "  ✅ schema: api_version: OK"                 || { echo "  ❌ schema: api_version: FAILED";                 PATCH_OK=1; }
grep -q 'broker_config\["api_version"\] = conf.api_version'   "${DEPLOY_DIR}/kafka-logger.lua" && echo "  ✅ broker_config: api_version: OK"          || { echo "  ❌ broker_config: api_version: FAILED";          PATCH_OK=1; }

# Lua syntax check lần cuối (sau cả 2 patch [5.a]+[5.b] trên cùng file)
docker run --rm -v "${DEPLOY_DIR}/kafka-logger.lua:/tmp/kafka-logger.lua:ro" "${IMAGE}" \
    /usr/local/openresty/luajit/bin/luajit -bl /tmp/kafka-logger.lua > /dev/null \
    && echo "  ✅ lua syntax hợp lệ (sau patch [5]+[6]): OK" \
    || { echo "  ❌ lua syntax lỗi: FAILED"; PATCH_OK=1; }

[ "${PATCH_OK}" -eq 0 ] || exit 1

# ── Tổng kết ──────────────────────────────────────────────────────────────
echo ""
echo "✅ Đã tạo 5 patch (5 file) tại: ${DEPLOY_DIR}"
echo "   ngx_tpl.lua       ngx_tpl.lua.orig"
echo "   init.lua          init.lua.orig"
echo "   vault.lua         vault.lua.orig"
echo "   config_yaml.lua   config_yaml.lua.orig"
echo "   kafka-logger.lua  kafka-logger.lua.orig   (patch [5.a] ssl + [5.b] api_version, cùng 1 file)"
echo ""
echo "▶ docker-compose volumes cần thêm (so với bản gốc — [4][5.a][5.b] là mới thêm gần đây):"
echo '      - ./ngx_tpl.lua:/usr/local/apisix/apisix/cli/ngx_tpl.lua:ro'
echo '      - ./init.lua:/usr/local/apisix/apisix/init.lua:ro'
echo '      - ./vault.lua:/usr/local/apisix/apisix/secret/vault.lua:ro'
echo '      - ./config_yaml.lua:/usr/local/apisix/apisix/core/config_yaml.lua:ro'
echo '      - ./kafka-logger.lua:/usr/local/apisix/apisix/plugins/kafka-logger.lua:ro'
echo ""
echo "▶ Sau khi thêm volume mount, áp dụng:"
echo "      docker compose up -d --force-recreate apisix-standalone"
echo ""
echo "▶ Verify warn message mới (sau khi gitsync pull lần đầu):"
echo "      docker logs apisix-standalone --tail 20 | grep 'hot-reloaded'"
echo ""
echo "▶ Verify kafka-logger patch [5.a]+[5.b] đã load vào container đang chạy:"
echo "      docker exec apisix-standalone grep -n 'ssl\\|api_version' /usr/local/apisix/apisix/plugins/kafka-logger.lua"
echo "      (kỳ vọng thấy CẢ 4 dòng: schema ssl, schema ssl_verify, schema"
echo "       api_version, VÀ 3 dòng broker_config[...] tương ứng)"
echo ""
echo "▶ Cấu hình global_rules/kafka-logger.yaml cần set (patch không tự bật,"
echo "  chỉ MỞ KHẢ NĂNG dùng field — vẫn phải khai trong YAML):"
echo "      ssl: true"
echo "      ssl_verify: false          # patch [5.a]"
echo "      api_version: 2             # patch [5.b] — BẮT BUỘC =2, không phải 1 (mặc định)"
echo "                                  # để thực sự có timestamp thật, xem giải thích [5.b] ở header"
echo ""
echo "▶ LƯU Ý plugin_metadata (KHÔNG thuộc patch [5.a]/[5.b] này — field log_format"
echo "  đã có sẵn trong schema kafka-logger.lua GỐC, không cần patch):"
echo "  Cấu trúc JSON message gửi lên Kafka (field nào, tên gì) KHÔNG khai ở"
echo "  global_rules/kafka-logger.yaml (nơi đó chỉ có ssl/api_version/brokers ở trên),"
echo "  mà khai riêng ở apisix_routes/plugin_metadata/kafka-logger.yaml:"
echo "      plugin_metadata:"
echo "        - id: kafka-logger        # ⚠ PHẢI đúng tên plugin thật, không phải tên gợi nhớ"
echo "          log_format: { ... }     # flat JSON — không dựng được cấu trúc lồng nhau"
echo "  File này hot-reload qua gitsync như mọi fragment khác (routes/global_rules/...),"
echo "  KHÔNG cần chạy lại patch này, KHÔNG cần restart container."
echo "  Verify sau khi gitsync pull: xem log 'plugin_metadata đang active cho plugin:'"
echo "      grep 'plugin_metadata' ./logs/gitsync/gitsync.log | tail -5"
echo "  rồi consume thử topic để xác nhận field mới đã lên message thật:"
echo "      kcat -b 172.26.24.80:31421 -X security.protocol=SASL_SSL \\"
echo "           -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=apisix \\"
echo "           -X sasl.password=\"\$KAFKA_SASL_PASSWORD\" \\"
echo "           -X ssl.ca.location=/opt/apisix/standalone/sandbox/certs/ca-certificates.crt \\"
echo "           -C -t apisix-gateway-\${DC_PROFILE} -o -1 -e | head -1"
echo ""
echo "▶ Verify end-to-end với Kafka thật (SAU khi set ssl/api_version ở trên"
echo "  trong apisix_routes/global_rules/*.yaml và gitsync đã hot-reload):"
echo "      docker exec apisix-standalone tail -f /usr/local/apisix/logs/error.log | grep -i kafka"
echo "      kcat -b 172.26.24.80:31421 -X security.protocol=SASL_SSL \\"
echo "           -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=apisix \\"
echo "           -X sasl.password=\"\$KAFKA_SASL_PASSWORD\" \\"
echo "           -X ssl.ca.location=/opt/apisix/standalone/sandbox/certs/ca-certificates.crt \\"
echo "           -C -t apisix-gateway-\${DC_PROFILE} -o -5 -e"
echo ""
echo "▶ Verify end-to-end với Kafka thật (SAU khi set ssl/api_version ở trên"
echo "  trong apisix_routes/global_rules/*.yaml và gitsync đã hot-reload):"
echo "      docker exec apisix-standalone tail -f /usr/local/apisix/logs/error.log | grep -i kafka"
echo "      kcat -b 172.26.24.80:31421 -X security.protocol=SASL_SSL \\"
echo "           -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=apisix \\"
echo "           -X sasl.password=\"\$KAFKA_SASL_PASSWORD\" \\"
echo "           -X ssl.ca.location=/opt/apisix/standalone/sandbox/certs/ca-certificates.crt \\"
echo "           -C -t apisix-gateway-\${DC_PROFILE} -o -5 -e"
echo ""
echo "▶ Verify riêng patch [5.b] — timestamp KHÔNG còn epoch-0 (quan trọng nhất,"
echo "  vì patch [5.a] có thể pass mà [5.b] vẫn sai nếu quên set api_version:2"
echo "  trong YAML, hoặc anchor patch match nhầm chỗ):"
echo "      1. Bắn 1 request test qua route bất kỳ"
echo "      2. Mở Redpanda Console -> topic apisix-gateway-\${DC_PROFILE}"
echo "      3. Cột TIMESTAMP của message MỚI phải ra đúng giờ hiện tại,"
echo "         KHÔNG PHẢI '1/1/1970, 7:59:59 AM'"
echo "      ⚠ Message CŨ (ghi trước khi patch) vẫn giữ epoch-0 vĩnh viễn —"
echo "        không hồi tố được, chỉ message mới từ giờ trở đi mới đúng."
echo ""
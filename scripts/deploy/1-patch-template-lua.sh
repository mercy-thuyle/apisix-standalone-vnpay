#!/usr/bin/env bash
# scripts/deploy/1-patch-template-lua.sh
#
# Patch 7 file APISIX core để fix hành vi không mong muốn:
#   1. ngx_tpl.lua      — xóa proxy_set_header X-Forwarded-Port
#   2. init.lua         — xóa var_x_forwarded_port khỏi upstream_proxy_headers
#   3. vault.lua        — KV v2 support (thêm /data/ vào path)
#   4. config_yaml.lua   — đổi warn message "reloaded" thành rõ ràng hơn
#   5. kafka-logger.lua — a/thêm ssl/ssl_verify cho SASL_SSL Kafka (Strimzi TLS)
#                       — b/thêm api_version để có timestamp thật (fix epoch-0)
#   6. kafka-logger.lua + lua-resty-kafka (producer.lua/request.lua)
#                       — a/schema api_version: mở max 2 -> 3
#                       — b/producer.lua: Produce v3 request header (transactional_id)
#                                          + decode response v3 (giống v2)
#                       — c/request.lua: RecordBatch encoder (magic byte 2) cho
#                          Produce v3+, bắt buộc để publish lên Kafka >= 4.0
#                          (Kafka 4.x đã remove Produce API v0-2 / MessageSet
#                          v0-1 theo KIP-896 + KIP-724 — root cause RC-8, xem
#                          learnings.md)
#
# ⚠️  Khuyến nghị: đứng tại deployment dir trước khi chạy
#     cd /opt/apisix/standalone/sandbox    (hoặc production, lab, ...)
#     bash ./scripts/deploy/1-patch-template-lua.sh

set -euo pipefail

IMAGE="registry-hcm.vnpaycloud.vn/apisix/apache-apisix:3.17.0-debian"
TPL="/usr/local/apisix/apisix/cli/ngx_tpl.lua"
INIT="/usr/local/apisix/apisix/init.lua"
VAULT="/usr/local/apisix/apisix/secret/vault.lua"
CONFIG_YAML="/usr/local/apisix/apisix/core/config_yaml.lua"
KAFKA_LOGGER="/usr/local/apisix/apisix/plugins/kafka-logger.lua"
KAFKA_PRODUCER="/usr/local/apisix/deps/share/lua/5.1/resty/kafka/producer.lua"
KAFKA_REQUEST="/usr/local/apisix/deps/share/lua/5.1/resty/kafka/request.lua"

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

# ── 4. Patch config_yaml.lua — log live reload rõ ràng hơn ────────────────
echo ""
echo "▶ [4/5] Patch config_yaml.lua — chuẩn hoá log live reload..."
echo "  ⚠ Đây là patch thẩm mỹ (không ảnh hưởng chức năng)."
echo "  ⚠ Nhạy cảm với thay đổi source code qua mỗi version — verify diff kỹ."
docker run --rm "${IMAGE}" cat "${CONFIG_YAML}" > "${DEPLOY_DIR}/config_yaml.lua.orig"
cp "${DEPLOY_DIR}/config_yaml.lua.orig" "${DEPLOY_DIR}/config_yaml.lua"

OLD_MSG='log.warn("config file ", config_file.path, " reloaded.")'
NEW_MSG='if ngx.worker.id() == 0 then
    log.warn(
        "[APISIX LIVE-RELOAD OK] yaml=", config_file.path,
        " | source=gitsync",
        " | entities=routes/plugin_configs/services/upstreams/consumers/ssls",
        " | config.yaml requires container restart",
        " | validation/promote: check logs/adc/adc.log + logs/gitsync/gitsync.log"
    )
end'

# Không dùng sed: NEW_MSG chứa ký tự |, dễ làm sed hiểu nhầm delimiter.
export OLD_MSG NEW_MSG
python3 - "${DEPLOY_DIR}/config_yaml.lua" <<'PYEOF'
import os
import sys

path = sys.argv[1]
old = os.environ["OLD_MSG"]
new = os.environ["NEW_MSG"]

with open(path) as f:
    content = f.read()

matches = content.count(old)
if matches != 1:
    print(
        f"ERROR: config_yaml.lua anchor matched {matches} times (expected 1)",
        file=sys.stderr,
    )
    sys.exit(1)

with open(path, "w") as f:
    f.write(content.replace(old, new))
PYEOF

echo "  diff:"
diff "${DEPLOY_DIR}/config_yaml.lua.orig" "${DEPLOY_DIR}/config_yaml.lua" || true

# Verify patch [4] áp dụng đúng
if grep -q '\[APISIX LIVE-RELOAD OK\]' "${DEPLOY_DIR}/config_yaml.lua"; then
  echo "  ✅ config_yaml.lua: LIVE-RELOAD OK chỉ ghi từ worker 0: OK"
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

# ── 6.a. Patch kafka-logger.lua — mở schema api_version 2 -> 3 ───────────
echo ""
echo "▶ [6.a/7] Patch kafka-logger.lua — mở api_version max 2 -> 3 (RecordBatch)..."
echo "  ⚠ Áp dụng tiếp lên bản đã patch [5.a]+[5.b] — KHÔNG cat lại từ image gốc."
echo "  ⚠ api_version=3 chỉ THỰC SỰ publish đúng nếu patch [6.b]+[6.c] (producer.lua"
echo "    + request.lua) bên dưới cũng được áp dụng — thiếu 1 trong 2 sẽ lỗi runtime."

python3 - "${DEPLOY_DIR}/kafka-logger.lua" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
   content = f.read()

old = '''        api_version = {
            type = "integer",
            minimum = 0,
            maximum = 2,
            default = 1,
            description = "Kafka Produce API version. Set to 2 to enable Message " ..
                           "Format v1 (RecordBatch with real CreateTime), fixing " ..
                           "epoch-0 timestamp on broker. See patch [6] trong " ..
                           "1-patch-template-lua.sh.",
        },'''
new = '''        api_version = {
            type = "integer",
            minimum = 0,
            maximum = 3,
            default = 1,
            description = "Kafka Produce API version. Set to 2 to enable Message " ..
                           "Format v1 (RecordBatch with real CreateTime), fixing " ..
                           "epoch-0 timestamp on broker. Set to 3 to enable Message " ..
                           "Format v2 / RecordBatch (magic byte 2) required by Kafka " ..
                           "broker >= 4.0 (KIP-896 removed Produce API v0-2, KIP-724 " ..
                           "removed MessageSet v0/v1) — requires patch [6.b]+[6.c] " ..
                           "(producer.lua/request.lua) trong 1-patch-template-lua.sh.",
        },'''

c = content.count(old)
if c != 1:
    print(f"ERROR: anchor 'api_version schema' matched {c} times (expected 1)", file=sys.stderr)
    sys.exit(1)

with open(path, "w") as f:
    f.write(content.replace(old, new))
PYEOF

if [ $? -ne 0 ]; then
    echo "  ❌ kafka-logger.lua patch [6.a] FAILED — anchor không khớp."
    echo "     Kiểm tra lại: grep -n 'maximum = 2' ${DEPLOY_DIR}/kafka-logger.lua"
    exit 1
fi

echo "  diff (so với bản GỐC image, đã gồm patch [5.a]+[5.b]+[6.a]):"
diff "${DEPLOY_DIR}/kafka-logger.lua.orig" "${DEPLOY_DIR}/kafka-logger.lua" || true

grep -q 'maximum = 3,' "${DEPLOY_DIR}/kafka-logger.lua" \
    && echo "  ✅ schema: api_version maximum=3: OK" \
    || { echo "  ❌ schema: api_version maximum=3: FAILED"; exit 1; }

docker run --rm -v "${DEPLOY_DIR}/kafka-logger.lua:/tmp/kafka-logger.lua:ro" "${IMAGE}" \
    /usr/local/openresty/luajit/bin/luajit -bl /tmp/kafka-logger.lua > /dev/null \
    && echo "  ✅ lua syntax hợp lệ: OK" \
    || { echo "  ❌ lua syntax lỗi: FAILED"; exit 1; }

# ── 6.b. Patch producer.lua — Produce v3 request/response ────────────────
echo ""
echo "▶ [6.b/7] Patch producer.lua — Produce v3 header (transactional_id) + decode..."
echo "  ⚠ Bắt buộc re-test end-to-end với Kafka thật sau mỗi lần đổi version lib."
docker run --rm "${IMAGE}" cat "${KAFKA_PRODUCER}" > "${DEPLOY_DIR}/producer.lua.orig"
cp "${DEPLOY_DIR}/producer.lua.orig" "${DEPLOY_DIR}/producer.lua"

python3 - "${DEPLOY_DIR}/producer.lua" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

patches = [
    (
        '''local API_VERSION_V0 = 0
local API_VERSION_V1 = 1
local API_VERSION_V2 = 2

local ok, new_tab = pcall(require, "table.new")''',
        '''local API_VERSION_V0 = 0
local API_VERSION_V1 = 1
local API_VERSION_V2 = 2
local API_VERSION_V3 = 3

local ok, new_tab = pcall(require, "table.new")''',
        "API_VERSION_V3 const",
    ),
    (
        '''local function produce_encode(self, topic_partitions)
    local req = request:new(request.ProduceRequest,
                            correlation_id(self), self.client.client_id, self.api_version)

    req:int16(self.required_acks)''',
        '''local function produce_encode(self, topic_partitions)
    local req = request:new(request.ProduceRequest,
                            correlation_id(self), self.client.client_id, self.api_version)

    if self.api_version >= API_VERSION_V3 then
        -- Produce v3+ request header adds transactional_id; nil = not
        -- using Kafka transactions (kafka-logger only async-produces)
        req:string(nil)
    end

    req:int16(self.required_acks)''',
        "transactional_id in produce_encode",
    ),
    (
        '''            elseif api_version == API_VERSION_V2 then
                ret[topic][partition] = {
                    errcode = resp:int16(),
                    offset = resp:int64(),
                    timestamp = resp:int64(), -- If CreateTime is used, this field is always -1
                }''',
        '''            elseif api_version >= API_VERSION_V2 then
                -- Produce response body is unchanged from v2 through v3
                -- (v3 only adds a request-side field), safe to reuse decode
                ret[topic][partition] = {
                    errcode = resp:int16(),
                    offset = resp:int64(),
                    timestamp = resp:int64(), -- If CreateTime is used, this field is always -1
                }''',
        "produce_decode v3",
    ),
]

for old, new, label in patches:
    c = content.count(old)
    if c != 1:
        print(f"ERROR: anchor '{label}' matched {c} times (expected 1)", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)
PYEOF

if [ $? -ne 0 ]; then
    echo "  ❌ producer.lua patch [6.b] FAILED — pattern gốc đã thay đổi."
    echo "     Kiểm tra lại: docker run --rm ${IMAGE} cat ${KAFKA_PRODUCER}"
    exit 1
fi

echo "  diff:"
diff "${DEPLOY_DIR}/producer.lua.orig" "${DEPLOY_DIR}/producer.lua" || true

PATCH_OK=0
grep -q 'local API_VERSION_V3 = 3'                  "${DEPLOY_DIR}/producer.lua" && echo "  ✅ API_VERSION_V3 const: OK"     || { echo "  ❌ API_VERSION_V3 const: FAILED";     PATCH_OK=1; }
grep -q 'self.api_version >= API_VERSION_V3'        "${DEPLOY_DIR}/producer.lua" && echo "  ✅ transactional_id branch: OK" || { echo "  ❌ transactional_id branch: FAILED"; PATCH_OK=1; }
grep -q 'elseif api_version >= API_VERSION_V2 then' "${DEPLOY_DIR}/producer.lua" && echo "  ✅ produce_decode >= v2: OK"    || { echo "  ❌ produce_decode >= v2: FAILED";    PATCH_OK=1; }

docker run --rm -v "${DEPLOY_DIR}/producer.lua:/tmp/producer.lua:ro" "${IMAGE}" \
    /usr/local/openresty/luajit/bin/luajit -bl /tmp/producer.lua > /dev/null \
    && echo "  ✅ lua syntax hợp lệ: OK" \
    || { echo "  ❌ lua syntax lỗi: FAILED"; PATCH_OK=1; }

[ "${PATCH_OK}" -eq 0 ] || exit 1

# ── 6.c. Patch request.lua — RecordBatch encoder (magic byte 2) ──────────
echo ""
echo "▶ [6.c/7] Patch request.lua — RecordBatch encoder cho Produce v3+..."
echo "  ⚠ Đây là code hand-roll wire-protocol nhị phân — BẮT BUỘC test round-trip"
echo "    (produce rồi consume lại, so key/value/timestamp) trước khi lên production."
docker run --rm "${IMAGE}" cat "${KAFKA_REQUEST}" > "${DEPLOY_DIR}/request.lua.orig"
cp "${DEPLOY_DIR}/request.lua.orig" "${DEPLOY_DIR}/request.lua"

python3 - "${DEPLOY_DIR}/request.lua" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

patches = [
    (
        '''local bit = require "bit"

local setmetatable = setmetatable
local concat = table.concat
local rshift = bit.rshift
local band = bit.band
local char = string.char''',
        '''local bit = require "bit"
local protocol_common = require "resty.kafka.protocol.common"


local setmetatable = setmetatable
local concat = table.concat
local rshift = bit.rshift
local band = bit.band
local lshift = bit.lshift
local bxor = bit.bxor
local bor = bit.bor
local arshift = bit.arshift
local char = string.char''',
        "imports",
    ),
    (
        '''    local str = concat(req)
    return crc32(str), str, key_len + len + head_len
end

function _M.message_set(self, messages, index)
    local req = self._req
    local off = self.offset
    local msg_set_size = 0
    local index = index or #messages

    local message_version = MESSAGE_VERSION_0''',
        '''    local str = concat(req)
    return crc32(str), str, key_len + len + head_len
end

-- ZigZag-encode a signed 32-bit integer, required by RecordBatch/Record
-- varint fields (timestampDelta, offsetDelta, keyLength, valueLength,
-- headersCount, record length).
local function zigzag32(n)
    return bxor(lshift(n, 1), arshift(n, 31))
end

local function encode_varint(signed_n)
    local n = zigzag32(signed_n)
    local bytes = {}
    local i = 0
    repeat
        i = i + 1
        local b = band(n, 0x7f)
        n = rshift(n, 7)
        if n ~= 0 then
            bytes[i] = char(bor(b, 0x80))
        else
            bytes[i] = char(b)
        end
    until n == 0
    return concat(bytes)
end

-- Encode one Record inside a RecordBatch (message format v2, magic byte
-- 2). Kafka broker >= 4.0 (KIP-724 / KIP-896) no longer accepts the
-- legacy MessageSet v0/v1 format this file produced below for api_version < 3.
local function record_encode(offset_delta, timestamp_delta, key, msg)
    local key = key or ""
    local key_len = #key

    local body = concat({
        str_int8(0),                                    -- record attributes
        encode_varint(timestamp_delta),                 -- timestampDelta
        encode_varint(offset_delta),                    -- offsetDelta
        encode_varint(key_len == 0 and -1 or key_len),   -- keyLength
        key,
        encode_varint(#msg),                             -- valueLength
        msg,
        encode_varint(0),                                -- headers count
    })

    return encode_varint(#body) .. body
end

function _M.record_batch_set(self, messages, index)
    local req = self._req
    local record_num = index / 2
    local now_ms = ffi.new("int64_t", (ngx_now() * 1000))

    local records = {}
    for i = 1, record_num do
        records[i] = record_encode(i - 1, 0, messages[(i - 1) * 2 + 1], messages[(i - 1) * 2 + 2])
    end
    local records_str = concat(records)

    local batch_body = concat({
        str_int16(0),                       -- attributes: no compression / non-transactional
        str_int32(record_num - 1),          -- lastOffsetDelta
        str_int64(now_ms),                  -- firstTimestamp
        str_int64(now_ms),                  -- maxTimestamp
        str_int64(ffi.new("int64_t", -1)),  -- producerId: no idempotent producer
        str_int16(-1),                      -- producerEpoch
        str_int32(-1),                      -- baseSequence
        str_int32(record_num),              -- recordsCount
        records_str,
    })

    -- crc32c covers everything from `attributes` through end of `records`
    local crc = protocol_common.crc32c(batch_body)

    local batch = concat({
        str_int32(-1),  -- partitionLeaderEpoch
        str_int8(2),    -- magic byte 2: RecordBatch
        str_int32(crc),
    }) .. batch_body

    -- batchLength = everything after the batchLength field itself
    local full_batch = str_int64(0) .. str_int32(#batch) .. batch
    local total_len = #full_batch

    req[self.offset] = str_int32(total_len)  -- "records" bytes-field length
    req[self.offset + 1] = full_batch

    self.offset = self.offset + 2
    self.len = self.len + 4 + total_len
end

function _M.message_set(self, messages, index)
    local index = index or #messages

    if self.api_key == _M.ProduceRequest and self.api_version >= API_VERSION_V3 then
        return self:record_batch_set(messages, index)
    end

    local req = self._req
    local off = self.offset
    local msg_set_size = 0

    local message_version = MESSAGE_VERSION_0''',
        "record_batch_set + message_set branch",
    ),
]

for old, new, label in patches:
    c = content.count(old)
    if c != 1:
        print(f"ERROR: anchor '{label}' matched {c} times (expected 1)", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new)

with open(path, "w") as f:
    f.write(content)
PYEOF

if [ $? -ne 0 ]; then
    echo "  ❌ request.lua patch [6.c] FAILED — pattern gốc đã thay đổi."
    echo "     Kiểm tra lại: docker run --rm ${IMAGE} cat ${KAFKA_REQUEST}"
    exit 1
fi

echo "  diff:"
diff "${DEPLOY_DIR}/request.lua.orig" "${DEPLOY_DIR}/request.lua" || true

PATCH_OK=0
grep -q 'function _M.record_batch_set'         "${DEPLOY_DIR}/request.lua" && echo "  ✅ record_batch_set: OK"      || { echo "  ❌ record_batch_set: FAILED";      PATCH_OK=1; }
grep -q 'self.api_version >= API_VERSION_V3'   "${DEPLOY_DIR}/request.lua" && echo "  ✅ message_set branch v3: OK" || { echo "  ❌ message_set branch v3: FAILED"; PATCH_OK=1; }
grep -q 'protocol_common.crc32c(batch_body)'   "${DEPLOY_DIR}/request.lua" && echo "  ✅ crc32c on batch_body: OK"  || { echo "  ❌ crc32c on batch_body: FAILED";  PATCH_OK=1; }

docker run --rm -v "${DEPLOY_DIR}/request.lua:/tmp/request.lua:ro" "${IMAGE}" \
    /usr/local/openresty/luajit/bin/luajit -bl /tmp/request.lua > /dev/null \
    && echo "  ✅ lua syntax hợp lệ: OK" \
    || { echo "  ❌ lua syntax lỗi: FAILED"; PATCH_OK=1; }

[ "${PATCH_OK}" -eq 0 ] || exit 1

# ── Tổng kết ──────────────────────────────────────────────────────────────
echo ""
echo "✅ Đã tạo 7 patch (7 file) tại: ${DEPLOY_DIR}"
echo "   ngx_tpl.lua       ngx_tpl.lua.orig"
echo "   init.lua          init.lua.orig"
echo "   vault.lua         vault.lua.orig"
echo "   config_yaml.lua   config_yaml.lua.orig"
echo "   kafka-logger.lua  kafka-logger.lua.orig   (patch [5.a] ssl + [5.b] api_version, cùng 1 file)"
echo "   producer.lua      producer.lua.orig       (patch [6.b] Produce v3 header/decode)"
echo "   request.lua       request.lua.orig        (patch [6.c] RecordBatch encoder)"
echo ""
echo "▶ docker-compose volumes cần thêm (so với bản gốc — [4][5.a][5.b] là mới thêm gần đây):"
echo '      - ./ngx_tpl.lua:/usr/local/apisix/apisix/cli/ngx_tpl.lua:ro'
echo '      - ./init.lua:/usr/local/apisix/apisix/init.lua:ro'
echo '      - ./vault.lua:/usr/local/apisix/apisix/secret/vault.lua:ro'
echo '      - ./config_yaml.lua:/usr/local/apisix/apisix/core/config_yaml.lua:ro'
echo '      - ./kafka-logger.lua:/usr/local/apisix/apisix/plugins/kafka-logger.lua:ro'
echo '      - ./producer.lua:/usr/local/apisix/deps/share/lua/5.1/resty/kafka/producer.lua:ro'
echo '      - ./request.lua:/usr/local/apisix/deps/share/lua/5.1/resty/kafka/request.lua:ro'
echo ""
echo "▶ Sau khi thêm volume mount, áp dụng:"
echo "      docker compose up -d --force-recreate apisix-standalone"
echo ""
echo "▶ Verify live reload message mới (sau khi GitSync promote):"
echo "      docker logs apisix-standalone --since 2m | grep -F '[APISIX LIVE-RELOAD OK]'"
echo ""
echo "▶ Theo dõi đủ chuỗi ADC → GitSync → APISIX live reload:"
echo "      tail -F logs/adc/adc.log logs/gitsync/gitsync.log logs/apisix/error.log"
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
echo "           -C -t apisix-gateway-\${DC_SITE} -o -1 -e | head -1"
echo ""
echo "▶ Verify end-to-end với Kafka thật (SAU khi set ssl/api_version ở trên"
echo "  trong apisix_routes/global_rules/*.yaml và gitsync đã hot-reload):"
echo "      docker exec apisix-standalone tail -f /usr/local/apisix/logs/error.log | grep -i kafka"
echo "      kcat -b 172.26.24.80:31421 -X security.protocol=SASL_SSL \\"
echo "           -X sasl.mechanisms=SCRAM-SHA-512 -X sasl.username=apisix \\"
echo "           -X sasl.password=\"\$KAFKA_SASL_PASSWORD\" \\"
echo "           -X ssl.ca.location=/opt/apisix/standalone/sandbox/certs/ca-certificates.crt \\"
echo "           -C -t apisix-gateway-\${DC_SITE} -o -5 -e"
echo ""
echo "▶ Verify riêng patch [5.b] — timestamp KHÔNG còn epoch-0 (quan trọng nhất,"
echo "  vì patch [5.a] có thể pass mà [5.b] vẫn sai nếu quên set api_version:2"
echo "  trong YAML, hoặc anchor patch match nhầm chỗ):"
echo "      1. Bắn 1 request test qua route bất kỳ"
echo "      2. Mở Redpanda Console -> topic apisix-gateway-\${DC_SITE}"
echo "      3. Cột TIMESTAMP của message MỚI phải ra đúng giờ hiện tại,"
echo "         KHÔNG PHẢI '1/1/1970, 7:59:59 AM'"
echo "      ⚠ Message CŨ (ghi trước khi patch) vẫn giữ epoch-0 vĩnh viễn —"
echo "        không hồi tố được, chỉ message mới từ giờ trở đi mới đúng."
echo ""
echo "▶ Verify riêng patch [6] — api_version:3 publish thành công lên Kafka >= 4.0"
echo "  (BẮT BUỘC chạy round-trip trên SANDBOX trước, chưa xác nhận thì KHÔNG đẩy"
echo "  3 file kafka-logger.lua/producer.lua/request.lua này lên production):"
echo "      1. Set api_version: 3 trong apisix_routes/global_rules/*.yaml (env test)"
echo "      2. Bắn 1 request test qua route có kafka-logger"
echo "      3. tail logs/apisix/error.log — KHÔNG còn 'err: closed, retryable: true'"
echo "      4. Consume lại đúng topic, xác nhận message mới lên đủ key/value/timestamp:"
echo "         kcat -b <brokers> -t <topic> -C -o -1 -e \\"
echo "              -X security.protocol=SASL_SSL -X sasl.mechanism=SCRAM-SHA-512 \\"
echo "              -X sasl.username=\$KAFKA_SASL_USER -X sasl.password=\"\$KAFKA_SASL_PASSWORD\" \\"
echo "              -X ssl.ca.location=certs/ca-certificates.crt"
echo "      ⚠ Chỉ sau khi bước 4 ra đúng message thật (không lỗi, không rỗng) mới"
echo "        coi patch [6] là PASS — đây là code hand-roll wire-protocol, không"
echo "        phải patch upstream đã qua review cộng đồng."
echo ""
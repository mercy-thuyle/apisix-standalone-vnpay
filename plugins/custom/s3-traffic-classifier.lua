-- =============================================================================
-- s3-traffic-classifier.lua  — APISIX Plugin (Layer 0 — Dynamic Policy prep)
-- Path: /usr/local/apisix/apisix/plugins/custom/s3-traffic-classifier.lua
--
-- Mục đích:
--   Phân loại request S3 theo thứ tự ưu tiên K > S > Anon (đã chốt qua bàn luận
--   thực tế: AKID giả mạo chỉ tự hại chính request đó — không đụng ai; bucket
--   giả mạo/đoán tên trong URL lại có thể ăn vào quota của khách hàng thật vì
--   tên bucket là công khai, đoán được, không cần bằng chứng danh tính nào —
--   nên KHÔNG dùng bucket làm điều kiện tối thượng, chỉ dùng để CHỌN KEY bên
--   trong nhánh đã xác nhận có AKID):
--     1. Authenticated — có AKID (Authorization SigV4/SigV2 hoặc presigned
--        query, dùng lại s3-akid-utils.lua — KHÔNG verify chữ ký, Cloudian tự
--        làm việc đó). 2 case con:
--          1a. AKID + có bucket → key = bucket (X-S3-Bucket-Name, do
--              s3-normalizer-bucket-name export sẵn, plugin này KHÔNG set thêm).
--          1b. AKID + KHÔNG có bucket (vd ListBuckets/account-op qua aws cli/
--              console) → key = AKID, plugin này set X-S3-Akid-Only.
--     2. SNAT — KHÔNG có AKID, remote_addr khớp CIDR trong danh sách SNAT.
--     3. Anonymous — KHÔNG có AKID, remote_addr KHÔNG khớp danh sách SNAT.
--     Plugin set header cho case 1b/2/3 — tính loại trừ lẫn nhau giữa các rule
--   ở Layer 2 dựa vào cơ chế "key resolve rỗng → rule tự bị skip" của limit-count
--   3.16+ (xem apisix/plugins/limit-count/init.lua get_rules(): n_resolved == 0 → goto CONTINUE), KHÔNG dựa vào if/else ở Layer 2.
--
-- Phụ thuộc:
--   - BẮT BUỘC chạy SAU custom.s3-normalizer-bucket-name trong cùng route (đọc ctx.s3_bucket_name do plugin đó export
--     xem CONTRACT trong file s3-normalizer-bucket-name.lua). Nếu route không có s3-normalizer, hoặc bind sai thứ tự,
--     ctx.s3_bucket_name luôn nil → mọi request bị coi là "không có bucket" và rơi vào nhánh SNAT/Anonymous — SAI,
--     cần tự kiểm tra route binding nếu thấy request có bucket vẫn bị phân vào 2 nhóm kia.
--   - apisix.core.ip (wrapper chính thức của lua-resty-ipmatcher, đã là dependency lõi APISIX
--     dùng chung với plugin ip-restriction built-in, không cần cài thêm gì).
--     Nguồn xác nhận: apisix/core/ip.lua expose create_ip_matcher(ip_list),
--     apisix/init.lua tự require "resty.ipmatcher" cho core routing — không phải thư viện ngoài, an toàn dùng trong custom plugin.
--   - plugins/libraries/log-level.lua (KHÔNG phải plugin, thư viện dùng chung) —
--     điều khiển log [DEBUG] qua plugin_metadata "custom.log-level" (core_log_level/
--     core_log_scope), hot-reload qua gitsync. Xem plugins/custom/log-level.lua.
--
-- Đăng ký plugin trong config.yaml:
--   plugins:
--     - custom.s3-traffic-classifier
--     - custom.log-level          -- BẮT BUỘC nếu muốn bật/tắt log [DEBUG] động
--
-- Danh sách CIDR SNAT — khai ở plugin_metadata (KHÔNG hardcode trong file này):
--   plugin_metadata:
--     - id: custom.s3-traffic-classifier
--       snat_cidrs:
--         - "172.27.2.204/32"
--         - "172.27.2.205/32"
--         - "172.25.216.121/32"
--         - "172.25.216.168/32"
--
--   → Đã verify thực tế trên hệ thống: plugin_metadata load được và hot-reload được trong file-driven standalone mode
--     (Control API xác nhận qua GET /v1/plugin_metadatas trả đúng nội dung, không cần restart khi chỉ sửa danh sách CIDR
--     chỉ sửa/commit fragment plugin_metadata, gitsync tự pull). File .lua này chỉ cần restart khi đổi LOGIC, không phải khi đổi danh sách IP.
--
--   ⚠ 4 CIDR trên là /32 (khớp đúng 4 IP Mercy đưa để test) — PLACEHOLDER, cần xác nhận lại dải thật (có thể là /29, /30...
--     nếu SNAT là cả 1 dải NAT pool chứ không phải 4 IP lẻ) trước khi dùng cho production.
--
-- Output — header set cho Layer 2 đọc (chỉ set 1 TRONG 2 nhóm dưới, không bao giờ set cả 2 cùng lúc, và KHÔNG set gì nếu đã có bucket):
--   X-SNAT       — giá trị CỐ ĐỊNH (conf.snat_group_value, default "snat-shared") khi remote_addr khớp CIDR SNAT
--                  dùng làm key đếm CHUNG cho toàn dải (rule "SNAT nhóm" ở Layer 2).
--   X-SNAT-Ip    — remote_addr, chỉ set kèm X-SNAT — dùng làm key đếm RIÊNG từng IP trong dải (rule "SNAT từng IP" ở Layer 2,
--                  chạy song song với rule nhóm, cả 2 counter cùng active).
--   X-Real-Ip    — remote_addr, CHỈ set khi remote_addr KHÔNG khớp CIDR SNAT nào — dùng làm key nhóm Anonymous ở Layer 2.
--
-- An toàn header: 3 header trên đều do gateway tự set qua core.request.set_header (ghi đè, không phải append)
--                 client tự gửi sẵn header cùng tên (spoofing), sẽ bị ghi đè bởi giá trị gateway tính ra, không tin giá trị client gửi.
-- =============================================================================

local core        = require("apisix.core")
local core_ip     = require("apisix.core.ip")
local apisix_plugin = require("apisix.plugin")
local akid_utils   = require("s3-akid-utils")
local log_level_utils = require("log-level-utils")

local plugin_name = "s3-traffic-classifier"

-- id thật dùng để lookup plugin_metadata PHẢI khớp đúng full path require
-- ("apisix.plugins." .. METADATA_ID), khác plugin_name (chỉ dùng cho log).
-- Cùng lý do CONSUMER_PLUGIN_KEY = "custom." .. plugin_name trong
-- s3-qos-consumer.lua — mọi custom plugin lookup theo tên đều cần
-- namespace "custom." đầy đủ. Cùng string này dùng luôn làm self_id khi
-- gọi log_level_utils.emit("core", SELF_ID, ...) — khớp đúng tên plugin custom.
local METADATA_ID = "custom." .. plugin_name
local SELF_ID = METADATA_ID

-- =============================================================================
-- Schema — route-level (đặt tên header/giá trị nhóm SNAT, KHÔNG bắt buộc)
-- =============================================================================
local schema = {
    type = "object",
    properties = {
        anon_header       = { type = "string", minLength = 1, default = "X-Real-Ip" },
        snat_group_header = { type = "string", minLength = 1, default = "X-SNAT" },
        snat_ip_header    = { type = "string", minLength = 1, default = "X-SNAT-Ip" },
        -- Header set khi có AKID nhưng KHÔNG có bucket (case 1b) — Layer 2
        -- dùng làm key riêng cho tier Authenticated không-gắn-bucket-cụ-thể.
        akid_only_header  = { type = "string", minLength = 1, default = "X-S3-Akid-Only" },
        -- Giá trị CỐ ĐỊNH set vào snat_group_header — mọi IP trong danh sách
        -- SNAT dùng CHUNG giá trị này, tạo 1 counter đếm gộp cho cả dải.
        snat_group_value  = { type = "string", minLength = 1, default = "snat-shared" },
    },
}

-- =============================================================================
-- Metadata schema — danh sách CIDR SNAT, quản lý qua plugin_metadata (hot-reload)
-- =============================================================================
local metadata_schema = {
    type = "object",
    properties = {
        snat_cidrs = {
            type        = "array",
            items       = { type = "string", minLength = 1 },
            default     = {},
            description = "Danh sách CIDR (IPv4/IPv6) coi là SNAT — dạng "
                       .. "lua-resty-ipmatcher, vd [\"172.27.2.204/32\", \"10.0.0.0/24\"]",
        },
    },
}

local _M = {
    version         = 0.1,
    priority        = 9000,   -- < 10005 (s3-normalizer) để đọc được ctx.s3_bucket_name;
                               -- không phụ thuộc thứ tự với s3-qos-consumer (9500)
                               -- hay s3-accesskey-extractor (2510) — 2 file đó độc lập trục.
    name            = plugin_name,
    schema          = schema,
    metadata_schema = metadata_schema,
}

-- Cache ipmatcher instance theo TTL — tránh build lại từ đầu mỗi request.
-- TTL 60s: đồng bộ tinh thần "eventual consistency" đang dùng cho gitsync
-- (poll 30s) — không cần chính xác tuyệt đối tức thời cho danh sách SNAT.
local matcher_cache = core.lrucache.new({ ttl = 60, count = 1 })

local function get_snat_matcher()
    local metadata = apisix_plugin.plugin_metadata(METADATA_ID)
    local cidrs = metadata and metadata.value and metadata.value.snat_cidrs

    if not cidrs or #cidrs == 0 then
        -- Chưa cấu hình plugin_metadata, hoặc danh sách rỗng — KHÔNG lỗi,
        -- coi như chưa có SNAT nào, mọi request không-bucket rơi về Anonymous.
        return nil
    end

    local matcher, err = matcher_cache("snat_matcher", cidrs,
        function()
            local m, e = core_ip.create_ip_matcher(cidrs)
            if not m then
                core.log.error(plugin_name, ": không tạo được ip matcher từ snat_cidrs, err=", e)
            end
            return m
        end)

    if err then
        core.log.error(plugin_name, ": lrucache lỗi khi build matcher, err=", err)
        return nil
    end
    return matcher
end

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    return core.schema.check(schema, conf)
end

-- =============================================================================
-- rewrite phase — chạy SAU s3-normalizer-bucket-name (priority thấp hơn)
-- =============================================================================
function _M.rewrite(conf, ctx)
    local route_id = (ctx.matched_route and ctx.matched_route.value
        and ctx.matched_route.value.id) or "unknown"

    -- K trước tiên (ưu tiên tối thượng) — KHÔNG verify chữ ký, chỉ cần biết
    -- client CÓ CỐ ký hay không (Cloudian tự trả 403 nếu chữ ký sai/AKID giả).
    local auth = core.request.header(ctx, "Authorization")
    local akid = akid_utils.extract(auth, core.request.get_uri_args(ctx))

    if akid then
        if ctx.s3_bucket_name then
            -- Case 1a: AKID + có bucket → key = bucket, Layer 2 dùng thẳng
            -- X-S3-Bucket-Name (do s3-normalizer set) — plugin này KHÔNG set
            -- gì thêm.
            log_level_utils.emit("core", { SELF_ID, route_id }, log_level_utils.LEVEL_RANK.info,
                plugin_name, ": [DEBUG] AKID='", akid, "' + ctx.s3_bucket_name='",
                ctx.s3_bucket_name, "' — nhóm Authenticated (key=bucket)")
        else
            -- Case 1b: AKID nhưng KHÔNG có bucket (vd ListBuckets/account-op)
            -- → key = AKID, set header riêng cho Layer 2 dùng.
            core.request.set_header(ctx, conf.akid_only_header, akid)
            log_level_utils.emit("core", { SELF_ID, route_id }, log_level_utils.LEVEL_RANK.info,
                plugin_name, ": [DEBUG] AKID='", akid, "' KHÔNG có bucket — nhóm ",
                "Authenticated (key=AKID), set ", conf.akid_only_header, "=", akid)
        end
        return
    end

    -- Có bucket nhưng KHÔNG có AKID (K=0): s3-normalizer-bucket-name đã set
    -- X-S3-Bucket-Name VÔ ĐIỀU KIỆN (không biết gì về K, ra đời trước khi có
    -- khái niệm này) — PHẢI xoá header đó ở đây, nếu không rule "Authen" ở
    -- Layer 2 (key=${http_x_s3_bucket_name}) vẫn fire song song với rule
    -- SNAT/Anon, double-count và không đóng được lỗ hổng gốc (traffic không
    -- ký ăn vào quota của chính bucket đó). Set về "" để khớp cơ chế nginx
    -- var rỗng → limit-count tự skip rule (giống cách X-SNAT/X-Real-Ip loại
    -- trừ nhau đã dùng từ đầu).
    if ctx.s3_bucket_name then
        -- Đọc THẲNG conf.set_header thật của s3-normalizer-bucket-name từ
        -- route object đang chạy (ctx.matched_route.value.plugins) — 1 nguồn
        -- sự thật duy nhất, không tự khai default riêng ở plugin này (tránh
        -- 2 default phải tự nhớ khớp nhau, xem thảo luận đã chốt). Nếu route
        -- không khai gì, APISIX đã tự điền default "X-S3-Bucket-Name" vào
        -- route object lúc load (schema default), nên luôn đọc được giá trị
        -- thật đang áp dụng, không phải giá trị Mercy đoán.
        local normalizer_conf = ctx.matched_route and ctx.matched_route.value
            and ctx.matched_route.value.plugins
            and ctx.matched_route.value.plugins["custom.s3-normalizer-bucket-name"]
        local bucket_header = normalizer_conf and normalizer_conf.set_header
        if bucket_header and bucket_header ~= "" then
            core.request.set_header(ctx, bucket_header, "")
        end
    end

    -- Không có AKID → xét tiếp S (SNAT) rồi mới Anonymous, KHÔNG quan tâm có
    -- bucket hay không (bucket không kèm AKID không được tin làm định danh —
    -- xem lý do ở block comment đầu file).

    local remote_addr = ctx.var.remote_addr
    if not remote_addr then
        -- Tình huống bất thường thật sự (remote_addr rỗng) — LUÔN log,
        -- KHÔNG qua log_level_utils.emit(), vì đây là cảnh báo thật, không phải
        -- log [DEBUG] thường quy.
        core.log.warn(plugin_name, ": remote_addr rỗng, bỏ qua phân loại")
        return
    end

    local matcher = get_snat_matcher()
    local is_snat = matcher and matcher:match(remote_addr)

    if is_snat then
        core.request.set_header(ctx, conf.snat_group_header, conf.snat_group_value)
        core.request.set_header(ctx, conf.snat_ip_header, remote_addr)
        log_level_utils.emit("core", { SELF_ID, route_id }, log_level_utils.LEVEL_RANK.info,
            plugin_name, ": [DEBUG] remote_addr=", remote_addr,
            " khớp SNAT CIDR — set ", conf.snat_group_header, "=", conf.snat_group_value,
            ", ", conf.snat_ip_header, "=", remote_addr)
    else
        core.request.set_header(ctx, conf.anon_header, remote_addr)
        log_level_utils.emit("core", { SELF_ID, route_id }, log_level_utils.LEVEL_RANK.info,
            plugin_name, ": [DEBUG] remote_addr=", remote_addr,
            " KHÔNG khớp SNAT CIDR nào — nhóm Anonymous, set ",
            conf.anon_header, "=", remote_addr)
    end
end

return _M

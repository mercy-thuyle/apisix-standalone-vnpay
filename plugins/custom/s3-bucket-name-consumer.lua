-- =============================================================================
-- s3-bucket-name-consumer.lua  — APISIX Plugin (custom auth-type)
-- Path: /usr/local/apisix/apisix/plugins/custom/s3-bucket-name-consumer.lua
--
-- Mục đích:
--   Resolve MỘT SỐ bucket đã đăng ký thủ công (không phải mọi bucket) thành
--   1 Consumer object của APISIX, để tận dụng thứ tự merge plugin cao nhất
--   (Consumer > Consumer Group > Route > Plugin Config > Service) cho những
--   bucket cần policy riêng (IP/geo restriction, quota khác mặc định, v.v.)
--
-- Phụ thuộc:
--   - BẮT BUỘC chạy SAU custom.s3-normalizer-bucket-name trong cùng route,
--     vì đọc ctx.s3_bucket_name do plugin đó export (xem CONTRACT trong file
--     s3-normalizer-bucket-name.lua). Nếu route không có s3-normalizer, hoặc
--     s3-normalizer bind SAI thứ tự (priority thấp hơn), ctx.s3_bucket_name
--     luôn nil → plugin này luôn no-op (an toàn nhưng vô dụng).
--
-- Đăng ký plugin trong config.yaml:
--   plugins:
--     - custom.s3-bucket-name-consumer
--
-- Vận hành / thêm bucket mới vào policy riêng:
--   1. Thêm 1 entry vào consumers.yaml: username = "bucket-<bucket-name>",
--      group_id = consumer_group phù hợp (vd consumer-group-s3bucket-restricted),
--      plugins = { custom.s3-bucket-name-consumer: {} } (marker rỗng — CHÚ Ý
--      key PHẢI có prefix "custom.", thiếu prefix sẽ bị check_single_plugin_schema
--      báo "unknown plugin" và Consumer coi như không có field này — đã gặp bug
--      này thực tế, xem lịch sử debug 2026-07-13).
--   2. Commit, gitsync tự pull trong ≤30s (GITSYNC_PERIOD), APISIX reload.
--   3. KHÔNG cần restart container — khác với sửa .lua (route/consumer object
--      là hot-reload qua gitsync, chỉ code Lua mới cần restart).
--   4. Verify: gọi request tới bucket đó, xem error.log có dòng
--      "[s3-bucket-name-consumer]: bucket=... resolved consumer=bucket-<bucket-name>"
--      (username LUÔN có prefix "bucket-").
-- =============================================================================

local core         = require("apisix.core")
local consumer_mod = require("apisix.consumer")

-- _M.name — PHẢI để trần, đã xác nhận qua test thực tế Route dispatch chạy
-- đúng rewrite() với tên này. KHÔNG đổi theo giả thuyết nào khác.
local plugin_name = "s3-bucket-name-consumer"

-- Tên ĐẦY ĐỦ dùng RIÊNG cho mọi lookup xuyên qua consumer_mod (consumer_mod.plugin()).
-- PHẢI khớp y hệt key khai trong consumers.yaml: plugins: { custom.s3-bucket-name-consumer: {} }
local CONSUMER_PLUGIN_KEY = "custom." .. plugin_name

-- Prefix bắt buộc để tách namespace username khỏi consumer control-plane hiện có.
-- CHỈ dùng nội bộ khi lookup Consumer — KHÔNG áp lên bucket name thật
-- (client vẫn tạo bucket bình thường qua S3 API, không cần biết quy ước này).
local USERNAME_PREFIX = "bucket-"

-- =============================================================================
-- Plugin metadata
-- =============================================================================
local _M = {
    version  = 0.3,
    priority = 9500,
    type     = "auth",   -- bắt buộc để attach_consumer() hợp lệ, xem giải thích đầu file
    name     = plugin_name,

    -- Route-level schema: plugin này KHÔNG cần config gì ở route — mọi input
    -- lấy từ ctx.s3_bucket_name (do s3-normalizer export) và từ danh sách
    -- Consumer đã đăng ký (do Admin/GitOps quản lý). Để trống có chủ đích.
    schema = { type = "object", properties = {} },

    -- Consumer-level schema: plugin marker rỗng, KHÔNG cần field riêng vì
    -- danh tính đã nằm sẵn trong Consumer.username (schema_def.lua dòng 731-734,
    -- pattern ^[a-zA-Z0-9_\-]+$ — khớp charset bucket name, không cần field
    -- "bucket" riêng biệt trong consumer_schema).
    consumer_schema = { type = "object", properties = {} },
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_CONSUMER then
        return core.schema.check(_M.consumer_schema, conf)
    end
    return core.schema.check(_M.schema, conf)
end

-- =============================================================================
-- rewrite phase — chạy SAU s3-normalizer-bucket-name (priority thấp hơn)
-- =============================================================================
function _M.rewrite(conf, ctx)
    local bucket = ctx.s3_bucket_name
    if not bucket then
        -- Không phải request nhắm 1 bucket cụ thể (list-buckets, passthrough, host không match route S3...)
        -- → không có gì để resolve, bỏ qua.
        core.log.info(plugin_name, ": [DEBUG] ctx.s3_bucket_name = nil, không phải S3 object request")
        return
    end

    local lookup_username = USERNAME_PREFIX .. bucket
    core.log.info(plugin_name, ": [DEBUG] bucket=", bucket, " lookup_username=", lookup_username)

    -- Lấy danh sách Consumer đang bind plugin này (cấu trúc xác nhận từ consumer.lua's plugin_consumer()).
    -- plugin_conf = { nodes = {consumer1, consumer2, ...}, len = N, conf_version = ... }
    local plugin_conf = consumer_mod.plugin(CONSUMER_PLUGIN_KEY)
    if not plugin_conf or not plugin_conf.nodes then
        -- Chưa có Consumer nào bind plugin này (chưa ai đăng ký bucket riêng)
        -- → mọi bucket đều rơi về policy mặc định ở Route/Plugin Config.
        --  HÀNH VI BÌNH THƯỜNG khi mới khởi tạo hệ thống hoặc chưa đăng ký bucket nào.
        core.log.info(plugin_name, ": [DEBUG] consumer_mod.plugin('", CONSUMER_PLUGIN_KEY, "') trả về NIL — chưa có Consumer nào bind plugin này (bình thường nếu chưa đăng ký bucket nào)")
        return
    end

    core.log.info(plugin_name, ": [DEBUG] consumer_mod.plugin('", CONSUMER_PLUGIN_KEY, "') OK, type=", type(plugin_conf), " so_consumer_dang_ky=", plugin_conf.len or "?")

    -- Tự loop tìm theo .username — KHÔNG dùng consumer_mod.find_consumer()
    local matched = nil
    for _, c in ipairs(plugin_conf.nodes) do
        if c.username == lookup_username then
            matched = c
            break
        end
    end

    if not matched then
        -- Bucket chưa đăng ký policy riêng → anonymous, fallback về Route/
        -- Plugin Config mặc định. ĐÂY LÀ HÀNH VI BÌNH THƯỜNG cho đa số bucket
        -- (chỉ bucket cần policy đặc biệt mới cần đăng ký làm Consumer).
        core.log.info(plugin_name, ": [DEBUG] loop qua ", plugin_conf.len or 0, " consumer, KHÔNG có .username nào khớp '", lookup_username, "' — bucket này chưa đăng ký policy riêng")
        return
    end

    -- attach_consumer() tự set ctx.consumer, ctx.consumer_name,
    -- ctx.consumer_group_id (dùng để merge Consumer Group), và tự thêm header
    -- X-Consumer-Username lên upstream request (xem consumer.lua attach_consumer()).
    --
    consumer_mod.attach_consumer(ctx, matched, plugin_conf)
    core.log.info(plugin_name, ": bucket=", bucket, " resolved consumer=", matched.username)
    core.log.info(plugin_name, ": [DEBUG] ✅ resolved bucket=", bucket, " → consumer=", matched.username)
end

return _M

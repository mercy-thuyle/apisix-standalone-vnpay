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
--   ⚠ ĐÂY KHÔNG PHẢI AUTHENTICATION THẬT — không verify chữ ký, không verify
--   secret nào cả. Bucket name là public info (xuất hiện thẳng trong URL),
--   ai cũng "tự xưng" được. Plugin này chỉ làm 1 việc: match bucket name với
--   1 danh sách bucket đã biết trước (đăng ký qua Git), để áp policy khác
--   nhau theo bucket — bản chất là "named allowlist", không phải identity
--   verification. Nếu cần thật sự xác thực caller thì đó là việc của AKID +
--   backend SigV4 (Cloudian/Ceph), KHÔNG phải plugin này.
--
-- Vì sao dùng field `type = "auth"` dù không auth thật:
--   APISIX yêu cầu field `type = 'auth'` trên plugin để nó được phép gọi
--   consumer_mod.attach_consumer() và tham gia vào merge-order Consumer.
--   Đây là cách APISIX phân loại "plugin có quyền set ctx.consumer", không
--   bắt buộc plugin đó phải verify credential.
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
-- =============================================================================
-- ĐÃ ĐỐI CHIẾU VỚI SOURCE THẬT (2026-07-13) — không còn là giả thuyết:
--   /usr/local/apisix/apisix/consumer.lua
--   /usr/local/apisix/apisix/plugins/key-auth.lua
--   /usr/local/apisix/apisix/plugins/consumer-restriction.lua
--
-- 1) consumer_mod.find_consumer(plugin_name, key, key_value) — chữ ký THẬT
--    khác hoàn toàn bản trước dùng nhầm consumer_mod.find_consumer(consumers, lookup_username).
--    Hàm thật dùng để tìm consumer theo GIÁ TRỊ 1 FIELD bên trong auth_conf
--    (vd key-auth: find_consumer("key-auth", "key", <api-key-value>) — so khớp
--    giá trị API key thật, không phải username). KHÔNG có khái niệm "tìm theo
--    username" trong hàm này — gọi sai chữ ký (bảng thay vì string) khiến nó
--    LUÔN trả nil, bất kể bucket có đăng ký hay không (đã tái hiện đúng qua
--    log test: cả bucket đã đăng ký lẫn chưa đăng ký đều nil giống hệt nhau).
--    → KHÔNG dùng find_consumer ở đây. Tự loop consumer_mod.plugin().nodes,
--      so khớp field .username (xem construct_consumer_data() trong
--      consumer.lua — mỗi node có sẵn .username y hệt giá trị khai trong YAML).
--
-- 2) consumer_mod.plugin(name) — "name" ở đây PHẢI khớp y hệt string dùng làm
--    key trong Consumer.plugins YAML (xem consumer.lua hàm plugin_consumer():
--    `for name, config in pairs(val.value.plugins) do plugin.get(name) ...
--    plugins[name] = {...}` — "name" chính là key literal, không phải _M.name
--    của plugin). Vì Consumer.plugins bắt buộc dùng key "custom.s3-bucket-name-
--    consumer" (đầy đủ — đã xác nhận qua bug check_single_plugin_schema trước
--    đó), lookup cũng phải dùng đúng chuỗi này, KHÔNG phải plugin_name trần.
--    (_M.name vẫn để trần — đã CHỨNG MINH đúng cho Route dispatch, không đụng).
--
-- ⚠️ NAMESPACE COLLISION — quy ước bắt buộc (phòng ngừa, không phải rủi ro
--   đã xảy ra trong thực tế — nhưng rẻ để phòng nên vẫn làm):
--   Consumer.username là UNIQUE TOÀN INSTANCE, không tách theo plugin/route.
--   consumers.yaml hiện tại đã dùng username KHÔNG PREFIX cho control-plane
--   (vd: customer_acme, automation_reporting, internal_logcleaner).
--   Nếu 1 bucket tình cờ trùng tên, PUT consumer mới cùng username sẽ GHI ĐÈ
--   TOÀN BỘ object cũ trong standalone mode (full-replace theo username,
--   không merge field) → mất key-auth credential của consumer control-plane
--   mà không có cảnh báo rõ ràng.
--
--   → Prefix "bucket-" khi lookup, KHÔNG bao giờ dùng bucket name trần làm
--     username. Mọi consumer sinh từ bucket phải khai trong consumers.yaml
--     dạng: username: "bucket-<bucket-name>" (xem ví dụ cuối file).
--
--   ⚠ QUAN TRỌNG: prefix này CHỈ tồn tại trong lookup_username nội bộ plugin
--   (biến USERNAME_PREFIX bên dưới) — KHÔNG phải constraint áp lên bucket
--   name thật. Client vẫn tạo bucket qua S3 API bình thường theo đúng S3
--   naming convention (Cloudian/Ceph tự validate), gateway tự nối prefix khi
--   tra Consumer — hoàn toàn vô hình với client, không cần client biết hay
--   tuân theo quy ước này.
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
    version  = 0.2,  -- fix bug thật: type(consumers) → type(plugin_conf) (biến consumers không tồn tại, gây log sai "type=nil")
    -- Chỉ cần NHỎ HƠN priority của s3-normalizer-bucket-name (10005) để chạy
    -- sau và đọc được ctx.s3_bucket_name đã set. Giá trị cụ thể không quan
    -- trọng miễn còn khoảng cách an toàn với các plugin custom khác trong
    -- cùng route (hiện có: s3-accesskey-extractor=2510, cmc-validator=10004,
    -- s3-normalizer=10005). Chọn 9500 để có khoảng đệm rõ ràng, dễ chèn thêm
    -- plugin khác ở giữa sau này nếu cần.
    -- ⚠ 9500 thứ tự thực thi plugin trong phase rewrite của APISIX. PHẢI < priority s3-normalizer-bucket-name (10005)
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
        core.log.warn(plugin_name, ": [DEBUG] ctx.s3_bucket_name = nil, không phải S3 object request")
        return
    end

    local lookup_username = USERNAME_PREFIX .. bucket
    core.log.warn(plugin_name, ": [DEBUG] bucket=", bucket, " lookup_username=", lookup_username)

    -- Lấy danh sách Consumer đang bind plugin này (cấu trúc xác nhận từ consumer.lua's plugin_consumer()).
    -- plugin_conf = { nodes = {consumer1, consumer2, ...}, len = N, conf_version = ... }
    local plugin_conf = consumer_mod.plugin(CONSUMER_PLUGIN_KEY)
    if not plugin_conf or not plugin_conf.nodes then
        -- Chưa có Consumer nào bind plugin này (chưa ai đăng ký bucket riêng)
        -- → mọi bucket đều rơi về policy mặc định ở Route/Plugin Config.
        --  HÀNH VI BÌNH THƯỜNG khi mới khởi tạo hệ thống hoặc chưa đăng ký bucket nào.
        core.log.warn(plugin_name, ": [DEBUG] consumer_mod.plugin('", CONSUMER_PLUGIN_KEY, "') trả về NIL — chưa có Consumer nào bind plugin này (bình thường nếu chưa đăng ký bucket nào)")
        return
    end

    core.log.warn(plugin_name, ": [DEBUG] consumer_mod.plugin('", CONSUMER_PLUGIN_KEY, "') OK, type=", type(plugin_conf), " so_consumer_dang_ky=", plugin_conf.len or "?")

    -- ⚠️ VERIFY: Tự loop tìm theo .username — KHÔNG dùng consumer_mod.find_consumer()
    -- (sai mục đích, xem giải thích đầu file).
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
        core.log.warn(plugin_name, ": [DEBUG] loop qua ", plugin_conf.len or 0, " consumer, KHÔNG có .username nào khớp '", lookup_username, "' — bucket này chưa đăng ký policy riêng")
        return
    end

    -- attach_consumer() tự set ctx.consumer, ctx.consumer_name,
    -- ctx.consumer_group_id (dùng để merge Consumer Group), và tự thêm header
    -- X-Consumer-Username lên upstream request (xem consumer.lua attach_consumer()).
    consumer_mod.attach_consumer(ctx, matched, matched.auth_conf)
    core.log.info(plugin_name, ": bucket=", bucket, " resolved consumer=", matched.username)
    core.log.warn(plugin_name, ": [DEBUG] ✅ resolved bucket=", bucket, " → consumer=", matched.username)
end

return _M

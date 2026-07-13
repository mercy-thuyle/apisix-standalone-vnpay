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
-- ⚠️ TODO — CẦN VERIFY TRƯỚC KHI DÙNG PRODUCTION (chưa test trên container thật):
--   API `consumer_mod.plugin()` / cách lookup Consumer theo username (không
--   phải theo giá trị credential như key-auth) chưa được đối chiếu với source
--   thật của bản 3.15.0. Trước khi merge:
--     docker exec apisix-standalone cat /usr/local/apisix/apisix/consumer.lua
--     docker exec apisix-standalone cat /usr/local/apisix/apisix/plugins/consumer-restriction.lua
--   consumer-restriction.lua đáng đọc trước vì nó vốn đã so khớp ctx.consumer.username
--   với 1 danh sách — logic gần với nhu cầu ở đây hơn key-auth (key-auth so khớp
--   theo GIÁ TRỊ SECRET, không phải theo username trực tiếp).
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
--      plugins = { s3-bucket-name-consumer: {} } (marker rỗng, không cần config).
--   2. Commit, gitsync tự pull trong ≤30s (GITSYNC_PERIOD), APISIX reload.
--   3. KHÔNG cần restart container — khác với sửa .lua (route/consumer object
--      là hot-reload qua gitsync, chỉ code Lua mới cần restart).
--   4. Verify: gọi request tới bucket đó, xem error.log có dòng
--      "[s3-bucket-name-consumer]: bucket=... resolved consumer=bkt-..."
-- =============================================================================

local core         = require("apisix.core")
local consumer_mod = require("apisix.consumer")

local plugin_name = "s3-bucket-name-consumer"

-- Prefix bắt buộc để tách namespace username khỏi consumer control-plane hiện có.
-- Xem mục "NAMESPACE COLLISION" ở trên — KHÔNG được xóa/đổi prefix này mà
-- không audit lại toàn bộ consumers.yaml control-plane trước.
-- Prefix CHỈ dùng nội bộ khi lookup Consumer — KHÔNG áp lên bucket name thật.
local USERNAME_PREFIX = "bucket-"

-- =============================================================================
-- Plugin metadata
-- =============================================================================
local _M = {
    version  = 0.1,
    -- Chỉ cần NHỎ HƠN priority của s3-normalizer-bucket-name (10005) để chạy
    -- sau và đọc được ctx.s3_bucket_name đã set. Giá trị cụ thể không quan
    -- trọng miễn còn khoảng cách an toàn với các plugin custom khác trong
    -- cùng route (hiện có: s3-accesskey-extractor=2510, cmc-validator=10004,
    -- s3-normalizer=10005). Chọn 9500 để có khoảng đệm rõ ràng, dễ chèn thêm
    -- plugin khác ở giữa sau này nếu cần.
    -- ⚠ 9500 KHÔNG liên quan gì đến port dịch vụ nào (đừng nhầm với port
    --   upstream node, vd 127.0.0.1:9999 của route debug-dump) và cũng KHÔNG
    --   liên quan route-level "priority" field — đây thuần túy là thứ tự
    --   thực thi plugin trong phase rewrite của APISIX.
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
        -- Không phải request nhắm 1 bucket cụ thể (list-buckets, passthrough,
        -- host không match route S3...) → không có gì để resolve, bỏ qua.
        return
    end

    local lookup_username = USERNAME_PREFIX .. bucket

    -- Lấy danh sách Consumer đang bind plugin này (đã đăng ký qua consumers.yaml).
    local consumers = consumer_mod.plugin(plugin_name)
    if not consumers then
        -- Chưa có Consumer nào bind plugin này (chưa ai đăng ký bucket riêng)
        -- → mọi bucket đều rơi về policy mặc định ở Route/Plugin Config.
        return
    end

    -- ⚠️ CHƯA VERIFY: cách lookup consumer theo username trực tiếp (không phải
    -- theo giá trị credential như key-auth vẫn làm). Xem mục TODO đầu file —
    -- PHẢI đối chiếu với consumer.lua / consumer-restriction.lua thật trong
    -- container trước khi tin đoạn dưới đây.
    local matched = consumer_mod.find_consumer
        and consumer_mod.find_consumer(consumers, lookup_username)

    if not matched then
        -- Bucket chưa đăng ký policy riêng → anonymous, fallback về Route/
        -- Plugin Config mặc định. ĐÂY LÀ HÀNH VI BÌNH THƯỜNG cho đa số bucket
        -- (chỉ bucket cần policy đặc biệt mới cần đăng ký làm Consumer).
        return
    end

    consumer_mod.attach_consumer(ctx, matched, matched.auth_conf)
    core.log.info(plugin_name, ": bucket=", bucket,
        " resolved consumer=", matched.username)
end

return _M

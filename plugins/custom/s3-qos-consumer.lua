-- =============================================================================
-- s3-qos-consumer.lua  — APISIX Plugin (custom auth-type)
-- Path: /usr/local/apisix/apisix/plugins/custom/s3-qos-consumer.lua
--
-- Mục đích:
--   Resolve MỘT SỐ đối tượng đã đăng ký thủ công (không phải mọi request)
--   thành 1 Consumer object của APISIX, để tận dụng thứ tự merge plugin cao
--   nhất (Consumer > Consumer Group > Route > Plugin Config > Service) cho
--   những đối tượng cần policy riêng (IP/geo restriction, quota khác mặc
--   định, v.v.). Hỗ trợ 3 loại đối tượng, tự quyết định ưu tiên khi nhiều
--   loại cùng khớp 1 request — xem "Thứ tự ưu tiên" bên dưới:
--     1. Bucket + SNAT-IP  (username "bucketsnat-<bucket>-<ip>") — hẹp nhất
--     2. Bucket riêng      (username "bucket-<bucket>")
--     3. SNAT-IP riêng     (username "snatip-<ip>")           — rộng nhất
--
-- Thứ tự ưu tiên — vì sao combo > bucket > snat-ip (không phải ngược lại):
--   Nguyên tắc gốc giống hệt luật K > S > Anon đã chốt ở s3-traffic-
--   classifier.lua: tín hiệu phạm vi CÀNG HẸP thì ưu tiên CÀNG CAO, vì sai
--   ở tín hiệu rộng gây thiệt hại lan sang bên thứ ba không liên quan.
--     - 1 bucket = đại diện ĐÚNG 1 khách hàng.
--     - 1 SNAT-IP = đại diện NHIỀU khách hàng cùng đứng sau 1 NAT (đã ghi
--       nhận ở s3-traffic-classifier.lua, không phải 1 định danh).
--   Nếu SNAT-IP thắng khi cả 2 cùng khớp: policy riêng của 1 bucket cụ thể
--   sẽ ÂM THẦM bị bỏ qua mỗi khi khách hàng đó đứng sau 1 NAT đã đăng ký —
--   hành vi không nhất quán, phụ thuộc mạng client đang dùng, rất khó debug.
--   Nếu Bucket thắng: chỉ đúng 1 bucket đó thoát khỏi policy NAT chung, mọi
--   traffic khác (khách hàng khác) qua cùng NAT vẫn chịu policy NAT bình
--   thường — thiệt hại (nếu đăng ký sai) tự khoanh vùng, không lan rộng.
--   Combo (cả 2 cùng khớp) là tín hiệu hẹp nhất trong 3 loại — 1 bucket cụ
--   thể được truy cập từ 1 IP cụ thể — nên luôn xét trước cả 2 loại đơn.
--
-- QUAN TRỌNG — chỉ 1 lần gọi attach_consumer() duy nhất mỗi request:
--   Cả 3 loại đối tượng dùng CHUNG 1 hàm dispatcher tuần tự bên dưới, KHÔNG
--   tách thành 3 plugin/priority riêng — tránh tuyệt đối rủi ro 2 plugin
--   độc lập cùng gọi attach_consumer(), ai chạy SAU ghi đè ai chạy TRƯỚC một
--   cách ngẫu nhiên theo priority load, không kiểm soát được bằng mắt khi
--   đọc route YAML.
--
-- Phụ thuộc:
--   - BẮT BUỘC chạy SAU custom.s3-normalizer-bucket-name trong cùng route,
--     vì đọc ctx.s3_bucket_name do plugin đó export (xem CONTRACT trong file
--     s3-normalizer-bucket-name.lua). Nếu route không có s3-normalizer, hoặc
--     s3-normalizer bind SAI thứ tự (priority thấp hơn), ctx.s3_bucket_name
--     luôn nil → nhánh bucket/combo luôn no-op (an toàn, tự fallback SNAT-IP
--     nếu có đăng ký, không crash).
--   - remote_addr lấy trực tiếp từ ctx.var.remote_addr — KHÔNG dùng chung
--     danh sách CIDR snat_cidrs của s3-traffic-classifier.lua (đó là danh
--     sách PHÂN LOẠI rộng "IP nào coi là SNAT nói chung"; ở đây là danh sách
--     IP CỤ THỂ đã đăng ký cần policy riêng — 2 mục đích khác nhau, không
--     dùng lẫn). Do đó không cần lua-resty-ipmatcher, chỉ so khớp chuỗi trực
--     tiếp với username đã đăng ký, giống hệt cách bucket đang làm.
--
-- Đăng ký plugin trong config.yaml:
--   plugins:
--     - custom.s3-qos-consumer
--
-- Vận hành / thêm đối tượng mới vào policy riêng — thêm 1 entry consumers.yaml:
--   1a. Riêng theo bucket:
--       username: "bucket-<tên-bucket>"
--   1b. Riêng theo SNAT-IP cụ thể (KHÔNG phải cả dải CIDR, chỉ 1 IP) — LƯU Ý
--       dấu "." của IPv4 KHÔNG hợp lệ trong username (schema_def.lua consumer
--       pattern ^[a-zA-Z0-9_\-]+$), BẮT BUỘC đổi "." thành "-" khi đăng ký:
--       username: "snatip-<ip-đã-đổi-chấm-thành-gạch>"    (IP 172.27.2.204 → snatip-172-27-2-204)
--   1c. Kết hợp cả 2 (ưu tiên cao nhất, chỉ khớp khi ĐÚNG bucket này TỪ ĐÚNG
--       IP này — các case khác của bucket/IP đó vẫn rơi về 1a/1b nếu có,
--       hoặc về Route/Plugin Config mặc định nếu không đăng ký gì thêm),
--       cùng lưu ý đổi "." thành "-" trong phần IP:
--       username: "bucketsnat-<tên-bucket>-<ip-đã-đổi-chấm-thành-gạch>"
--                 (vd bucketsnat-thuyldx-qos-partner-172-27-2-204)
--   2. Mọi entry đều cần group_id phù hợp + marker rỗng:
--       group_id: consumer-group-s3bucket-... (tuỳ tier)
--       plugins: { custom.s3-qos-consumer: {} }           (CHÚ Ý key PHẢI có
--       prefix "custom.", thiếu prefix sẽ bị check_single_plugin_schema báo
--       "unknown plugin" — đã gặp bug này thực tế, xem lịch sử debug 2026-07-13).
--   3. Commit, gitsync tự pull trong ≤30s (GITSYNC_PERIOD), APISIX reload.
--      KHÔNG cần restart container — khác với sửa .lua (route/consumer object
--      là hot-reload qua gitsync, chỉ code Lua mới cần restart).
--   4. Verify: gọi request tới đúng đối tượng đó, xem error.log có dòng
--      "[s3-qos-consumer]: matched_type=... resolved consumer=..."
-- =============================================================================

local core         = require("apisix.core")
local consumer_mod = require("apisix.consumer")

-- _M.name — PHẢI để trần, đã xác nhận qua test thực tế Route dispatch chạy
-- đúng rewrite() với tên này. KHÔNG đổi theo giả thuyết nào khác.
local plugin_name = "s3-qos-consumer"

-- Tên ĐẦY ĐỦ dùng RIÊNG cho mọi lookup xuyên qua consumer_mod (consumer_mod.plugin()).
-- PHẢI khớp y hệt key khai trong consumers.yaml: plugins: { custom.s3-qos-consumer: {} }
local CONSUMER_PLUGIN_KEY = "custom." .. plugin_name

-- Prefix bắt buộc để tách namespace username khỏi consumer control-plane hiện
-- có VÀ tách 3 loại đối tượng khỏi nhau (tránh 1 bucket tên trùng 1 IP dạng
-- chuỗi trùng nhau, dù xác suất gần như 0 nhưng vẫn giữ prefix riêng cho rõ
-- ràng khi đọc log/debug). CHỈ dùng nội bộ khi lookup Consumer — KHÔNG áp
-- lên bucket name/IP thật (client vẫn dùng S3 API/kết nối bình thường,
-- không cần biết quy ước này).
local USERNAME_PREFIX_BUCKET = "bucket-"
local USERNAME_PREFIX_SNAT_IP = "snatip-"
local USERNAME_PREFIX_BUCKET_SNAT = "bucketsnat-"

-- =============================================================================
-- Plugin metadata
-- =============================================================================
local _M = {
    version  = 0.4,
    priority = 9500,
    type     = "auth",   -- bắt buộc để attach_consumer() hợp lệ, xem giải thích đầu file
    name     = plugin_name,

    -- Route-level schema: plugin này KHÔNG cần config gì ở route — mọi input
    -- lấy từ ctx.s3_bucket_name (do s3-normalizer export), ctx.var.remote_addr,
    -- và từ danh sách Consumer đã đăng ký (do Admin/GitOps quản lý). Để trống có chủ đích.
    schema = { type = "object", properties = {} },

    -- Consumer-level schema: plugin marker rỗng, KHÔNG cần field riêng vì
    -- danh tính đã nằm sẵn trong Consumer.username. Xác nhận qua source thật
    -- apisix/schema_def.lua (_M.consumer.properties.username):
    --   pattern = [[^[a-zA-Z0-9_\-]+$]]
    -- Dấu "." trong IPv4 KHÔNG khớp charset này (chỉ cho a-z A-Z 0-9 _ -)
    -- → BẮT BUỘC đổi "." thành "-" khi build username cho SNAT-IP/combo, xem
    -- normalize_ip_for_username() bên dưới.
    consumer_schema = { type = "object", properties = {} },
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_CONSUMER then
        return core.schema.check(_M.consumer_schema, conf)
    end
    return core.schema.check(_M.schema, conf)
end

-- =============================================================================
-- Helper — build 1 lần map username -> consumer node từ danh sách đăng ký,
-- dùng chung cho cả 3 loại lookup (combo/bucket/snat-ip), tránh loop 3 lần
-- riêng biệt qua cùng 1 danh sách.
-- =============================================================================
local function build_username_index(nodes)
    local index = core.table.new(0, #nodes)
    for _, c in ipairs(nodes) do
        index[c.username] = c
    end
    return index
end

-- IPv4 có dấu "." không khớp pattern username ^[a-zA-Z0-9_\-]+$ của
-- schema_def.lua (Consumer) — bắt buộc đổi "." thành "-" khi build username,
-- và đổi lại y hệt khi đăng ký entry trong consumers.yaml (vd IP 172.27.2.204
-- → đăng ký username "snatip-172-27-2-204", KHÔNG phải "snatip-172.27.2.204").
local function normalize_ip_for_username(ip)
    return (ip:gsub("%.", "-"))
end

-- =============================================================================
-- rewrite phase — chạy SAU s3-normalizer-bucket-name (priority thấp hơn)
-- =============================================================================
function _M.rewrite(conf, ctx)
    local bucket = ctx.s3_bucket_name
    local remote_addr = ctx.var.remote_addr

    if not remote_addr then
        -- Tình huống bất thường thật sự (remote_addr rỗng) — LUÔN log, không
        -- phụ thuộc cấu hình debug, giống cách s3-traffic-classifier.lua xử lý.
        core.log.info(plugin_name, ": [DEBUG] ctx.var.remote_addr = nil, bỏ qua toàn bộ resolve")
        return
    end

    local ip_key = remote_addr and normalize_ip_for_username(remote_addr)

    core.log.info(plugin_name, ": [DEBUG] bucket=", bucket or "-", " remote_addr=", remote_addr)

    -- Lấy danh sách Consumer đang bind plugin này — DÙNG CHUNG cho cả 3 loại
    -- lookup, chỉ 1 lần gọi consumer_mod.plugin() mỗi request.
    local plugin_conf = consumer_mod.plugin(CONSUMER_PLUGIN_KEY)
    if not plugin_conf or not plugin_conf.nodes then
        -- Chưa có Consumer nào bind plugin này (chưa ai đăng ký đối tượng riêng)
        -- → mọi request đều rơi về policy mặc định ở Route/Plugin Config.
        -- HÀNH VI BÌNH THƯỜNG khi mới khởi tạo hệ thống hoặc chưa đăng ký gì.
        core.log.info(plugin_name, ": [DEBUG] consumer_mod.plugin('", CONSUMER_PLUGIN_KEY, "') trả về NIL — chưa có Consumer nào bind plugin này")
        return
    end

    local index = build_username_index(plugin_conf.nodes)

    -- Thứ tự ưu tiên combo > bucket > snat-ip — xem giải thích đầy đủ ở
    -- header file. Dừng ngay khi khớp case đầu tiên, KHÔNG xét tiếp.

    local matched, matched_type

    if bucket then
        local combo_username = USERNAME_PREFIX_BUCKET_SNAT .. bucket .. "-" .. ip_key
        matched = index[combo_username]
        if matched then
            matched_type = "bucket+snat-ip"
        end
    end

    if not matched and bucket then
        local bucket_username = USERNAME_PREFIX_BUCKET .. bucket
        matched = index[bucket_username]
        if matched then
            matched_type = "bucket"
        end
    end

    if not matched then
        local snat_username = USERNAME_PREFIX_SNAT_IP .. ip_key
        matched = index[snat_username]
        if matched then
            matched_type = "snat-ip"
        end
    end

    if not matched then
        -- Không đối tượng nào đăng ký khớp → fallback về Route/Plugin Config
        -- mặc định. ĐÂY LÀ HÀNH VI BÌNH THƯỜNG cho đa số request
        -- (chỉ đối tượng cần policy đặc biệt mới cần đăng ký làm Consumer).
        core.log.info(plugin_name, ": [DEBUG] không có Consumer nào khớp bucket='", bucket or "-", "' hoặc remote_addr='", remote_addr, "' — dùng policy mặc định")
        return
    end

    -- attach_consumer() tự set ctx.consumer, ctx.consumer_name,
    -- ctx.consumer_group_id (dùng để merge Consumer Group), và tự thêm header
    -- X-Consumer-Username lên upstream request (xem consumer.lua attach_consumer()).

    consumer_mod.attach_consumer(ctx, matched, plugin_conf)
    core.log.info(plugin_name, ": matched_type=", matched_type, " resolved consumer=", matched.username)
    core.log.info(plugin_name, ": [DEBUG] ✅ bucket=", bucket or "-", " remote_addr=", remote_addr, " matched_type=", matched_type, " → consumer=", matched.username)
end

return _M

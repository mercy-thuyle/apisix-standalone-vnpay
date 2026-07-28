-- =============================================================================
-- s3-normalizer-bucket-name.lua  — APISIX Plugin test-gitsync
-- Path: /usr/local/apisix/apisix/plugins/custom/s3-normalizer-bucket-name.lua
--
-- Mục đích:
--   Normalize S3 request từ vhost-style → path-style trước khi forward upstream.
--   Plugin KHÔNG hardcode domain — domain list được truyền từ route config.
--   → Cùng 1 file Lua dùng cho lab / sandbox / production chỉ bằng cách
--     thay đổi plugin config trong apisix-dc1.yaml (hot-reload, không restart).
--
-- Phụ thuộc:
--   - s3-validator-bucket-name-utils.lua (library)
--     require được nhờ extra_lua_path trong config.yaml:
--     extra_lua_path: "/usr/local/apisix/apisix/plugins/libraries/?.lua"
--
-- Đăng ký plugin trong config.yaml:
--   plugins:
--     - custom.s3-normalizer-bucket-name
--
-- Domain:
--   Lab:        s3.hcm.lab.thuyldx
--   Sandbox:    s3-hcm.sds.infiniband.vn | s3-hni.sds.infiniband.vn
--   Production: s3-hcm.sds.vnpaycloud.vn | s3-hni.sds.vnpaycloud.vn
--
-- Schema (truyền vào từ route config trong apisix-dc1.yaml):
--   path_hosts    [string]  — hostname exact match cho path-style request
--                             vd: ["s3.hcm.lab.thuyldx"]
--                             vd: ["s3-hcm.sds.infiniband.vn"]
--   vhost_domains [string]  — Lua pattern suffix cho vhost-style request
--                             PHẢI escape dấu chấm (.) → %. và gạch (-) → %-
--                             vd: ["s3%.hcm%.lab%.thuyldx"]
--                             vd: ["s3%-hcm%.sds%.infiniband%.vn"]
--
-- Logic xử lý:
--   CASE 1 — vhost-style:  <bucket>.<domain-suffix>/key
--            → không rewrite vì Cloudian tự hỗ trợ vhost-style native
--            → set Host header về path-style host
--            → forward upstream nhận đúng path-style request
--
--   CASE 2 — path-style:   <domain>/<bucket>/key
--            → validate bucket name syntax
--            → pass through, không rewrite
--
--   CASE 3 — không match:  pass through (request không liên quan S3)
--
-- Method filtering:
--   Mặc định: validate MỌI HTTP method (GET, PUT, DELETE, HEAD, POST, ...)
--   Giữ nguyên behavior này để chặt chẽ hơn NGINX cũ (chỉ PUT).
--   Nếu muốn giới hạn lại chỉ PUT (giống NGINX cũ — hyperstore-s3.lua):
--     Bỏ comment block "PUT-only mode" bên dưới
--     và comment lại block "All methods mode"
-- =============================================================================
-- CONTRACT: ctx.s3_bucket_name  (⚠ đọc kỹ trước khi sửa file này hoặc file
--           nào require ctx.s3_bucket_name)
-- =============================================================================
--   - Được SET bởi plugin này, ở CẢ 2 case (vhost + path), NGAY SAU khi bucket
--     name đã pass validate isBucket() — tức là giá trị luôn hợp lệ theo cú
--     pháp S3 bucket name khi tồn tại (không cần plugin downstream validate lại).
--   - KHÔNG được set (nil) khi: list-all-buckets (GET /), host không match
--     route này, hoặc URI không có bucket segment. Mọi plugin đọc biến này
--     PHẢI tự xử lý case nil (coi như "không phải S3 object request").
--   - Plugin nào dùng: custom.s3-bucket-name-consumer (resolve bucket → Consumer,
--     ưu tiên chạy SAU plugin này cùng phase rewrite, xem file đó để biết priority).
--   - Đây là ctx var nội bộ (KHÔNG phải core.ctx.register_var — không leak ra
--     nginx var/log tự động, muốn log ra access_log phải tự thêm serverless
--     hoặc field khác).
--   - [2026-07-19] Đã thêm export qua request header (conf.set_header, default
--     "X-S3-Bucket-Name") — KHÔNG dùng core.ctx.register_var + kafka-logger
--     plugin_metadata.log_format, vì log_format của kafka-logger KHÔNG merge
--     với log mặc định — khai log_format là THAY THẾ TOÀN BỘ cấu trúc log gốc
--     (mất request.headers/querystring đầy đủ, phải tự liệt kê lại từng field
--     bằng $nginx_var — mà dict như headers/querystring không có $var tương
--     đương để liệt kê lại). Đây là giới hạn cố định của kafka-logger, không
--     phải bug riêng version nào (đã kiểm tra: 3.15 hiện tại lẫn bản mới hơn
--     đều không có field nào kiểu "log_format_extra" để merge).
--     → Set header là cách AN TOÀN hơn: log mặc định (get_full_log() trong
--     log-util.lua) tự log toàn bộ ngx.req.get_headers(), nên header mới tự
--     động lộ diện trong request.headers, KHÔNG cần sửa gì ở kafka-logger.
--     An toàn SigV4 — header không nằm trong SignedHeaders, giống lý do
--     X-S3-Access-Key an toàn trong s3-accesskey-extractor.lua.
-- =============================================================================
-- [BUCKET_NAME_HEADER_EXPORT] — TÓM TẮT VẬN HÀNH, đọc trước khi debug/sửa
-- =============================================================================
--   Grep nhanh mọi chỗ liên quan thay đổi này:  grep -rn "BUCKET_NAME_HEADER_EXPORT\|X-S3-Bucket-Name\|set_header" .
--
--   File NÀY (s3-normalizer-bucket-name.lua):
--     - Thêm field schema conf.set_header (default "X-S3-Bucket-Name", "" = tắt)
--     - Thêm core.request.set_header(ctx, conf.set_header, bucket) ở CẢ 2 case
--       (vhost + path) — tìm bằng comment "-- [BUCKET_NAME_HEADER_EXPORT]" bên dưới
--
--   File KHÁC cần biết (không cần sửa code, chỉ cần biết để vận hành/debug):
--     - route YAML nào bind plugin custom.s3-normalizer-bucket-name: field
--       set_header mới sẽ tự nhận default "X-S3-Bucket-Name" nếu route KHÔNG
--       khai gì thêm — chỉ cần sửa route YAML nếu muốn đổi tên header hoặc
--       tắt (set_header: ""). Không sửa gì thì dùng default, không cần đụng.
--     - kafka-logger / Loki / dashboard Grafana: KHÔNG cần sửa gì ở tầng
--       kafka-logger (meta_format/log_format giữ nguyên "default"). Header
--       mới tự xuất hiện trong log ở field request.headers["x-s3-bucket-name"]
--       (nginx lowercase hết header name). Query Loki dùng field này qua
--       `| json` (Loki tự flatten "-" → "_" trong tên field khi auto-extract):
--         sum by (request_headers_x_s3_bucket_name) (rate({...} | json [1m]))
--     - README.md (mục "Kiểm tra log/metric"): nên bổ sung 1 dòng verify
--       header này bằng kcat/curl sau khi deploy (xem hướng dẫn verify cuối
--       file này).
--
--   Restart bắt buộc: file .lua KHÔNG hot-reload qua gitsync (khác route
--   YAML) — phải restart container apisix-standalone sau khi deploy file này.
--
--   Verify sau deploy:
--     curl -sk -D - -o /dev/null https://s3-hcm.sds.infiniband.vn/<bucket>/<key> \
--       -H 'Authorization: AWS4-HMAC-SHA256 Credential=<AKID>/...'
--     → xem response header hoặc dùng echo-upstream (README mục debug Cách 2)
--       để confirm upstream nhận đúng X-S3-Bucket-Name=<bucket>
-- =============================================================================

local core        = require("apisix.core")
-- local regex       = require("s3-validator-bucket-name-utils")   -- /usr/local/apisix/apisix/plugins/libraries/s3-validator-bucket-name-utils.lua
local validator = require("s3-validator-bucket-name-utils")

local plugin_name = "s3-normalizer-bucket-name"

-- =============================================================================
-- Schema — APISIX validate conf khi load/reload route
-- =============================================================================
local schema = {
    type = "object",
    properties = {
        path_hosts = {
            type        = "array",
            minItems    = 1,
            items       = { type = "string", minLength = 1 },
            description = "Danh sách hostname exact match cho path-style S3 request. "
                       .. "vd: [\"s3.hcm.lab.thuyldx\"] hoặc [\"s3-hcm.sds.infiniband.vn\"]"
        },
        vhost_domains = {
            type        = "array",
            minItems    = 1,
            items       = { type = "string", minLength = 1 },
            description = "Danh sách Lua pattern suffix cho vhost-style S3 request. "
                       .. "Dấu chấm và gạch ngang phải được escape: . → %., - → %-. "
                       .. "vd: [\"s3%.hcm%.lab%.thuyldx\"] hoặc [\"s3%-hcm%.sds%.infiniband%.vn\"]"
        },
        -- [BUCKET_NAME_HEADER_EXPORT] Header phơi bucket_name ra để lộ diện trong
        -- request.headers của log mặc định (get_full_log() đã tự log toàn bộ
        -- ngx.req.get_headers(), không cần đụng kafka-logger log_format/plugin_metadata).
        -- Đặt "" để TẮT. An toàn với SigV4: header này KHÔNG nằm trong SignedHeaders,
        -- giống lý do X-S3-Access-Key an toàn trong s3-accesskey-extractor.lua.
        set_header = { type = "string", default = "X-S3-Bucket-Name" },
    },
    required = { "path_hosts", "vhost_domains" }
}

-- =============================================================================
-- Plugin metadata
-- =============================================================================
local _M = {
    version  = 2.2,   -- v2.1: thêm ctx.s3_bucket_name export (không đổi behavior forward)
                       -- v2.2 [BUCKET_NAME_HEADER_EXPORT]: thêm conf.set_header, export
                       -- bucket_name qua request header (không đổi behavior forward/rewrite)
    -- Priority 10005: chạy trước proxy-rewrite (10000) và redirect (900)
    -- để URI đã được normalize/parse trước khi các plugin khác xử lý.
    -- ⚠ Đây là plugin EXECUTION priority trong 1 phase (rewrite) — KHÔNG liên
    --   quan gì đến route-level "priority" field (dùng cho thứ tự match route,
    --   vd route-debug-dump priority:100) hay port của upstream node
    --   (vd 127.0.0.1:9999 trong route debug-dump). 3 khái niệm trùng từ khóa
    --   "priority"/số nhưng là 3 namespace độc lập — đừng suy luận chéo.
    priority = 10005,
    name     = plugin_name,
    schema   = schema,
}

-- =============================================================================
-- check_schema — APISIX gọi khi load/reload route để validate conf
-- =============================================================================
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- =============================================================================
-- rewrite phase
--   Chạy trước khi request được forward lên upstream.
--   Tương đương rewrite_by_lua_block trong NGINX.
-- =============================================================================
function _M.rewrite(conf, ctx)

    local method = core.request.get_method()

    -- -- =========================================================================
    -- -- METHOD FILTER
    -- -- =========================================================================

    -- -- [All methods mode] — validate mọi HTTP method (default, chặt hơn NGINX cũ)
    -- -- Giữ nguyên block này, không làm gì — tiếp tục xuống logic bên dưới
    -- -- ---------

    -- -- [PUT-only mode] — giống behavior NGINX cũ (hyperstore-s3.lua, hyperstore-s3-subdomains.lua)
    -- -- Chỉ validate khi PUT (tạo bucket). GET/DELETE/HEAD/POST → pass through không validate.
    -- -->> Bỏ comment 3 dòng dưới để bật PUT-only mode:
    -- if method ~= "PUT" then
    --     return
    -- end

    -- =========================================================================
    -- Lấy Host header
    -- =========================================================================
    local host = core.request.header(ctx, "host")
    if not host then
        core.log.warn(plugin_name, ": missing Host header")
        return 400, { error_msg = "Missing Host header" }
    end

    -- Strip port nếu có: "s3.hcm.lab.thuyldx:9080" → "s3.hcm.lab.thuyldx"
    local host_no_port = string.match(host, "^([^:]+)")
    local uri          = ctx.var.uri

    -- =========================================================================
    -- CASE 1: vhost-style → <bucket>.<domain-suffix>/key
    --   vd: my-bucket.s3.hcm.lab.thuyldx/photos/img.jpg
    --   vd: data-lake.s3-hcm.sds.infiniband.vn/2024/log.gz
    -- =========================================================================
    if validator.isBucketInDomain(host_no_port, conf.vhost_domains) then

        -- Trích xuất bucket name từ subdomain
        local bucket = validator.extractBucketFromDomain(host_no_port, conf.vhost_domains)

        if not bucket then
            core.log.warn(plugin_name, " [vhost]: cannot extract bucket from host=", host)
            return 400, { error_msg = "Invalid vhost format: " .. host }
        end

        -- Validate bucket name syntax
        if not validator.isBucket(bucket) then
            core.log.warn(plugin_name, " [vhost]: invalid bucket name=", bucket, " host=", host)
            return 400, { error_msg = "Invalid S3 bucket name '" .. bucket .. "'" }
        end

        -- -- path_hosts[1]: path-style host tương ứng với vhost domain này
        -- -- Lý do dùng [1]: vhost domain và path domain là cặp 1-1 trong cùng 1 route config
        -- -- vd: route hcm → path_hosts[1] = "s3-hcm.sds.infiniband.vn"
        -- local path_host = conf.path_hosts[1]

        -- -- Rewrite URI: /<bucket><original-uri>
        -- -- vd: host=my-bucket.s3.hcm.lab.thuyldx uri=/key → new_uri=/my-bucket/key
        -- local new_uri = "/" .. bucket .. uri
        -- ngx.req.set_uri(new_uri)

        -- -- Set Host header về path-style host để upstream nhận đúng domain
        -- core.request.set_header(ctx, "Host", path_host)

        -- core.log.info(plugin_name, " [vhost] rewrite: ",
        --     host, uri, " → host=", path_host, " uri=", new_uri,
        --     " method=", method)
        -- return

        -- Export bucket name cho plugin downstream (vd: s3-bucket-name-consumer).
        -- KHÔNG rewrite URI/Host — Cloudian tự hỗ trợ vhost-style native, giữ
        -- nguyên hành vi pass-through hiện tại (xem RC-8 trong runbook: rewrite
        -- Host/URI ở đây từng phá SigV4 signature validation của client).
        ctx.s3_bucket_name = bucket

        -- [BUCKET_NAME_HEADER_EXPORT] case vhost — xem tóm tắt vận hành ở đầu file
        if conf.set_header and conf.set_header ~= "" then
            core.request.set_header(ctx, conf.set_header, bucket)
        end

        core.log.info(plugin_name, " [vhost]: valid bucket=", bucket, " host=", host,
            " method=", method, " (pass-through, không rewrite)")
        -- Không return tường minh — rơi hết function, forward nguyên trạng.

    -- =========================================================================
    -- CASE 2: path-style → <domain>/<bucket>/key
    --   vd: s3.hcm.lab.thuyldx/my-bucket/photos/img.jpg
    --   vd: s3-hcm.sds.infiniband.vn/data-lake/2024/log.gz
    --   Không rewrite, chỉ validate bucket name.
    -- =========================================================================
    else
        -- Kiểm tra host có trong danh sách path_hosts của route không
        local is_path_host = false
        for _, ph in ipairs(conf.path_hosts) do
            if host_no_port == ph then
                is_path_host = true
                break
            end
        end

        if not is_path_host then
            -- Host không thuộc route này → pass through, không xử lý
            core.log.info(plugin_name, " [passthrough]: host=", host,
                " not matched in path_hosts or vhost_domains")
            return
        end

        -- List all buckets: GET / → pass through không validate
        if uri == "/" or uri == "" then
            core.log.info(plugin_name, " [path]: list-all-buckets, pass through host=", host)
            return
        end

        -- Trích xuất bucket name từ URI path
        local bucket = validator.extractBucketFromPath(uri)

        if not bucket then
            core.log.info(plugin_name, " [path]: no bucket segment in uri=", uri, " pass through")
            return
        end

        -- Validate bucket name syntax
        if not validator.isBucket(bucket) then
            core.log.warn(plugin_name, " [path]: invalid bucket name=", bucket, " uri=", uri)
            return 400, { error_msg = "Invalid S3 bucket name '" .. bucket .. "'" }
        end

        -- ⚠ QUAN TRỌNG: set ctx.s3_bucket_name TRƯỚC return, không phải sau —
        ctx.s3_bucket_name = bucket

        -- [BUCKET_NAME_HEADER_EXPORT] case path — xem tóm tắt vận hành ở đầu file
        if conf.set_header and conf.set_header ~= "" then
            core.request.set_header(ctx, conf.set_header, bucket)
        end

        core.log.info(plugin_name, " [path]: valid bucket=", bucket,
            " method=", method, " uri=", uri)
        return
    end

end

return _M
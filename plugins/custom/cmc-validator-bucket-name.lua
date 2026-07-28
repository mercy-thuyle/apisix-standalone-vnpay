-- =============================================================================
-- Path: /usr/local/apisix/apisix/plugins/custom/cmc-validator-bucket-name.lua
--
-- Mục đích:
--   Validate bucket name khi user tạo bucket qua Cloudian Management Console (CMC).
--   Migrate từ cmc-conf.lua (NGINX) sang APISIX plugin.
--
-- Phụ thuộc:
--   - s3-validator-bucket-name-utils.lua (library)
--     require được nhờ extra_lua_path trong config.yaml:
--     extra_lua_path: "/usr/local/apisix/apisix/plugins/libraries/?.lua"
--
-- Đăng ký plugin trong config.yaml:
--   plugins:
--     - custom.cmc-validator-bucket-name
--
-- Schema (truyền vào từ route config):
--   Không có tham số bắt buộc — domain list được đọc từ Host header và redirect URL được map từ host trong hosts_redirect_map 
--   (hardcode theo đúng behavior của cmc-conf.lua NGINX cũ).
--
-- Trigger:
--   POST /s3/bucket/create.htm
--   POST body field: bucketName
--
-- Logic xử lý:
--   1. Chỉ xử lý POST /s3/bucket/create.htm — các request khác pass through
--   2. Đọc bucketName từ POST body
--   3. Validate bằng s3-validator-bucket-name-utils.isBucket()
--   4. Nếu hợp lệ → pass through, Cloudian xử lý tiếp
--   5. Nếu không hợp lệ:
--      [Redirect mode — default, giwux nguyên behavior NGINX cũ]
--        → redirect về portal error page theo từng host
--          sds.vnpaycloud.vn     → /s3/storage?bucket-error=true
--          console.vnpaycloud.vn → /entity/s3-storage?bucket-error=true
--      [JSON mode — comment block, bật khi muốn nhất quán với s3-normalizer]
--        → trả 400 JSON { error_msg = "..." }
--
-- So sánh với s3-normalizer-bucket-name.lua:
--   s3-normalizer  — S3 API (SDK/CLI), validate trên mọi request, trả 400 JSON
--   cmc-validator  — Web portal (browser), validate chỉ POST tạo bucket, redirect
-- =============================================================================

local core      = require("apisix.core")
local validator = require("s3-validator-bucket-name-utils")

local plugin_name = "cmc-validator-bucket-name"

-- =============================================================================
-- Redirect URL map theo host — giữ nguyên behavior cmc-conf.lua NGINX cũ
-- host                    → redirect path khi bucket name invalid
-- =============================================================================
local REDIRECT_MAP = {
    ["sds.vnpaycloud.vn"]     = "/s3/storage?bucket-error=true",
    ["console.vnpaycloud.vn"] = "/entity/s3-storage?bucket-error=true",
    ["sds.infiniband.vn"]     = "/s3/storage?bucket-error=true",
    ["console.infiniband.vn"] = "/entity/s3-storage?bucket-error=true",
    ["cmc.sds.infiniband.vn"]  = "/s3/storage?bucket-error=true",
}

-- =============================================================================
-- Schema
-- =============================================================================
local schema = {
    type       = "object",
    properties = {},
}

-- =============================================================================
-- Plugin metadata
-- =============================================================================
local _M = {
    version  = 1.0,
    -- Priority 10004: chạy sau s3-normalizer-bucket-name (10005)
    -- CMC portal và S3 API không overlap route nên priority ít quan trọng nhưng đặt thấp hơn s3-normalizer để rõ ràng thứ tự
    priority = 10004,
    name     = plugin_name,
    schema   = schema,
}

-- =============================================================================
-- check_schema
-- =============================================================================
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- =============================================================================
-- access phase
--   Dùng access phase (khác s3-normalizer dùng rewrite) vì:
--   - Cần đọc POST body (ngx.req.read_body)
--   - Không cần rewrite URI/Host
--   - Redirect phải chạy trước khi proxy forward
-- =============================================================================
function _M.access(conf, ctx)

    local method = core.request.get_method()
    local uri    = ctx.var.uri

    -- =========================================================================
    -- Chỉ xử lý POST /s3/bucket/create.htm
    -- Mọi request khác → pass through
    -- =========================================================================
    if method ~= "POST" or uri ~= "/s3/bucket/create.htm" then
        core.log.info(plugin_name, ": skip, method=", method, " uri=", uri)
        return
    end

    -- =========================================================================
    -- Đọc POST body để lấy bucketName
    -- =========================================================================
    ngx.req.read_body()
    local args, err = ngx.req.get_post_args()

    if err == "truncated" then
        core.log.warn(plugin_name, ": post args truncated, pass through")
        return
    end

    if not args then
        core.log.info(plugin_name, ": no post args, pass through")
        return
    end

    -- Lấy bucketName từ POST form field
    local bucket_name = args["bucketName"]

    if not bucket_name then
        core.log.info(plugin_name, ": bucketName not in POST args, pass through")
        return
    end

    core.log.warn(plugin_name, ": create bucket request, bucketName=", bucket_name)

    -- =========================================================================
    -- Validate bucket name
    -- =========================================================================
    if validator.isBucket(bucket_name) then
        -- Hợp lệ → pass through, Cloudian xử lý tiếp
        core.log.info(plugin_name, ": valid bucket name=", bucket_name, " pass through")
        return
    end

    -- =========================================================================
    -- Bucket name KHÔNG hợp lệ → xử lý lỗi
    -- =========================================================================
    core.log.warn(plugin_name, ": invalid bucket name=", bucket_name)

    local host = core.request.header(ctx, "host")
    local host_no_port = string.match(host or "", "^([^:]+)")

    -- -------------------------------------------------------------------------
    -- [Redirect mode] — default, giữ nguyên behavior NGINX cũ (cmc-conf.lua)
    -- Browser được redirect về portal error page theo từng host.
    -- -------------------------------------------------------------------------
    local redirect_path = REDIRECT_MAP[host_no_port]

    if redirect_path then
        local redirect_url = "https://" .. host_no_port .. redirect_path
        core.log.warn(plugin_name, ": redirect to ", redirect_url)
        return ngx.redirect(redirect_url, 302)
    else
        -- Host không có trong REDIRECT_MAP (host mới chưa được map)
        -- Fallback: trả 400 để không silent fail
        core.log.warn(plugin_name, ": host=", host, " not in REDIRECT_MAP, fallback 400")
        return 400, { error_msg = "Invalid S3 bucket name '" .. bucket_name .. "'" }
    end

    -- -- -------------------------------------------------------------------------
    -- -- [JSON mode] — nhất quán với s3-normalizer-bucket-name.lua (trả 400 JSON)
    -- -- Để đổi sang JSON mode:
    -- --   1. Comment toàn bộ block [Redirect mode] ở trên
    -- --   2. Bỏ comment block này
    -- -- -------------------------------------------------------------------------
    -- core.log.warn(plugin_name, ": invalid bucket name=", bucket_name,
    --     " returning 400 JSON")
    -- return 400, { error_msg = "Invalid S3 bucket name '" .. bucket_name .. "'" }

end

return _M

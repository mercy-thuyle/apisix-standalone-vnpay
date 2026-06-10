-- =============================================================================
-- s3-normalizer-bucket-name.lua  — APISIX Plugin
-- Path: /usr/local/apisix/apisix/plugins/custom/s3-normalizer-bucket-name.lua
--
-- Mục đích:
--   Normalize S3 request từ vhost-style → path-style trước khi forward upstream.
--   Plugin KHÔNG hardcode domain — domain list được truyền từ route config.
--   → Cùng 1 file Lua dùng cho lab / sandbox / production chỉ bằng cách
--     thay đổi plugin config trong apisix-dc1.yaml (hot-reload, không restart).
--
-- Đăng ký plugin trong config.yaml:
--   plugins:
--     - custom.s3-normalizer-bucket-name
--
-- Phụ thuộc:
--   - s3-validator-bucket-name-utils.lua (library) require được nhờ extra_lua_path trong config.yaml:
--     extra_lua_path: "/usr/local/apisix/apisix/plugins/libraries/?.lua"
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
--            → rewrite URI thành /<bucket>/key
--            → set Host header về path-style host
--            → forward upstream nhận đúng path-style request
--
--   CASE 2 — path-style:   <domain>/<bucket>/key
--            → validate bucket name syntax
--            → pass through, không rewrite
--
--   CASE 3 — không match:  pass through (request không liên quan S3)
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
    },
    required = { "path_hosts", "vhost_domains" }
}

-- =============================================================================
-- Plugin metadata
-- =============================================================================
local _M = {
    version  = 2.0,
    -- Priority 10005: chạy trước proxy-rewrite (10000) và redirect (900)
    -- để URI đã được normalize trước khi các plugin khác xử lý
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
    -- ── Lấy Host header ──────────────────────────────────────────────────────
    local host = core.request.header(ctx, "host")
    if not host then
        core.log.warn(plugin_name, ": missing Host header")
        return 400, { error_msg = "Missing Host header" }
    end

    -- Strip port nếu có: "s3.hcm.lab.thuyldx:9080" → "s3.hcm.lab.thuyldx"
    local host_no_port = string.match(host, "^([^:]+)")
    local uri          = ctx.var.uri
    local method       = core.request.get_method()

    -- =========================================================================
    -- CASE 1: vhost-style → <bucket>.<domain-suffix>/key
    --   vd: my-bucket.s3.hcm.lab.thuyldx/photos/img.jpg
    --   vd: data-lake.s3-hcm.sds.infiniband.vn/2024/log.gz
    --   Rewrite: URI = /<bucket>/key, Host = path-style host 
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

        -- path_hosts[1]: path-style host tương ứng với vhost domain này
        -- Lý do dùng [1]: vhost domain và path domain là cặp 1-1 trong cùng 1 route config
        -- vd: route hcm → path_hosts[1] = "s3-hcm.sds.infiniband.vn"
        local path_host = conf.path_hosts[1]

        -- Rewrite URI: /<bucket><original-uri>
        -- vd: host=my-bucket.s3.hcm.lab.thuyldx uri=/key → new_uri=/my-bucket/key
        local new_uri = "/" .. bucket .. uri
        ngx.req.set_uri(new_uri)

        -- Set Host header về path-style host để upstream nhận đúng domain
        core.request.set_header(ctx, "Host", path_host)

        core.log.info(plugin_name, " [vhost] rewrite: ",
            host, uri, " → host=", path_host, " uri=", new_uri,
            " method=", method)
        return

    -- =========================================================================
    -- CASE 2: path-style  →  <domain>/<bucket>/key
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

        core.log.info(plugin_name, " [path]: valid bucket=", bucket,
            " method=", method, " uri=", uri)
        return
    end

end

return _M
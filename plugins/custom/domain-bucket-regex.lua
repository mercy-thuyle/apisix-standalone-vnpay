local core = require("apisix.core")
local regex = require("cloudian-regex")         -- → /usr/local/apisix/apisix/plugins/libraries/cloudian-regex.lua
local plugin_name = "domain-bucket-regex"

-- =============================================
-- Ported từ cloudian-regex.lua
-- Domain lab: s3.hcm.lab.thuyldx
-- Domain sandbox: s3-hcm.sds.infiniband.vn | *.s3-hcm.sds.infiniband.vn | s3-hni.sds.infiniband.vn | *.s3-hni.sds.infiniband.vn
-- =============================================

local function isMatch(my_string, pattern)
    local extracted = string.match(my_string, pattern)
    if extracted then
        return true
    else
        return false
    end
end

local function isBucketInPath(uri)
    if string.match(uri, "^/%w+-[%w-]*%w+/?$") then
        return true
    elseif string.match(uri, "^/%w+-[%w-]*%w+/.+$") then
        return true
    else
        return false
    end
end

local function isBucket(bucketname)
    if string.match(bucketname, "^%w+-[%w-]*%w+$") then
        return true
    else
        return false
    end
end

local function isBucketInDomain(hostname)
    -- Lab domain: <bucket>.s3.hcm.lab.thuyldx
    if string.match(hostname, "^%w+-[%w-]*%w+%.s3%.hcm%.lab%.thuyldx$") then
        return true
    else
        return false
    end
end

-- =============================================
-- APISIX plugin definition
-- =============================================

local schema = {
    type = "object",
    properties = {}     -- Nếu script của bạn không cần tham số truyền vào, để trống
}

local _M = {
    version = 0.1,
    priority = 10005,   -- Priority cực cao để chạy trước các plugin khác (như rewrite phase)
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Chạy ở phase 'rewrite' (tương đương rewrite_by_lua_block trong NGINX)
function _M.rewrite(conf, ctx)
    -- =========================================================
    -- [PASTE LOGIC TỪ FILE cloudian-regex.lua CỦA BẠN VÀO ĐÂY]
    -- Ví dụ logic bóc tách Bucket từ Host header:
    -- =========================================================

    local host = core.request.header(ctx, "host")
    if not host then
        return 400, {error_msg = "Missing Host header"}
    end

    -- Strip port từ host nếu có (vd: s3.hcm.lab.thuyldx:1080 → s3.hcm.lab.thuyldx)
    local host_no_port = string.match(host, "^([^:]+)")
    local uri = ctx.var.uri
    local method = ngx.req.get_method()

    -- =============================================
    -- CASE 1: Virtual-host style
    -- bucket.s3.hcm.lab.thuyldx    → rewrite URI
    -- =============================================
    if isBucketInDomain(host_no_port) then
        -- Extract bucket name từ subdomain
        local bucket = string.match(host_no_port, "^([^.]+)%.s3%.hcm%.lab%.thuyldx$")

        if not bucket then
            core.log.warn("ceph-rados-regex [vhost]: cannot extract bucket from: ", host)
            return 400, {error_msg = "Invalid vhost format"}
        end

        -- Validate bucket name syntax
        if not isBucket(bucket) then
            core.log.warn("ceph-rados-regex [vhost]: invalid bucket name: ", bucket)
            return 400, {error_msg = "Invalid bucket name '" .. bucket .. "': must match pattern 'word-word'"}
        end

        -- Rewrite URI và đổi Host về path-style
        local new_uri = "/" .. bucket .. uri
        ngx.req.set_uri(new_uri)
        core.request.set_header(ctx, "Host", "s3.hcm.lab.thuyldx")
        core.log.info("ceph-rados-regex [vhost]: ", host, uri, " → ", new_uri)
        return

    -- =============================================
    -- CASE 2: Path style
    -- s3.hcm.lab.thuyldx/bucket/path
    -- =============================================
    elseif host_no_port == "s3.hcm.lab.thuyldx" then

        -- List all buckets (GET /) → pass through. Chỉ validate khi URI có bucket (không phải request gốc /)
        if uri == "/" or uri == "" then
            -- URI không match pattern bucket → có thể là list all buckets, bỏ qua
            core.log.info("ceph-rados-regex [path]: list all buckets, pass through")
            return
        end

        -- Extract bucket từ URI
        local bucket = string.match(uri, "^/([^/?]+)")

        if not bucket then
            core.log.info("ceph-rados-regex [path]: cannot extract bucket, pass through: ", uri)
            return
        end

        -- Validate bucket name
        if not isBucket(bucket) then
            core.log.warn("ceph-rados-regex [path]: invalid bucket name: ", bucket, " uri: ", uri)
            return 400, {error_msg = "Invalid bucket name '" .. bucket .. "': must match pattern 'word-word'"}
        end

        core.log.info("ceph-rados-regex [path]: valid bucket=", bucket, " method=", method, " uri=", uri)
        return
    end

    -- Host không match cả 2 case → pass through
    core.log.info("ceph-rados-regex: host not matched, pass through: ", host)
end

return _M
-- =============================================================================
-- Upgrade từ cloudian-regex.lua test
-- s3-validator-bucket-name-utils.lua  — Pure Lua utility library
-- Path: /usr/local/apisix/apisix/plugins/libraries/s3-validator-bucket-name-utils.lua
--
-- Mục đích: shared validation logic cho S3 bucket name và domain matching.
-- KHÔNG phải APISIX plugin — không có _M, schema, lifecycle hooks.
-- Dùng: require("s3-validator-bucket-name-utils") từ bất kỳ APISIX plugin nào.
--
-- Require được nhờ config.yaml:
--   extra_lua_path: "/usr/local/apisix/apisix/plugins/libraries/?.lua"
--
-- Môi trường sử dụng:
--   Lab:        s3.hcm.lab.thuyldx
--   Sandbox:    s3-hcm.sds.infiniband.vn | s3-hni.sds.infiniband.vn
--   Production: s3-hcm.sds.vnpaycloud.vn | s3-hni.sds.vnpaycloud.vn
-- =============================================================================

local _M = { _version = "2.0" }

-- -----------------------------------------------------------------------------
-- isMatch(str, pattern) → bool
--   Generic Lua pattern match helper.
-- -----------------------------------------------------------------------------
function _M.isMatch(str, pattern)
    return string.match(str, pattern) ~= nil
end

-- -----------------------------------------------------------------------------
-- isBucket(name) → bool
--   Validate S3 bucket name theo pattern: word-word[-word...]
--
--   Hợp lệ:       "my-bucket", "data-lake-01", "logs-hcm"
--   Không hợp lệ: "bucket" (thiếu gạch ngang), "-bad" (bắt đầu bằng -),
--                 "bad-" (kết thúc bằng -), "bad--name" (-- liên tiếp)
-- -----------------------------------------------------------------------------
function _M.isBucket(name)
    -- Phải bắt đầu bằng \w+, có ít nhất 1 dấu gạch ngang, kết thúc bằng \w+
    -- Không cho phép dấu gạch ngang ở đầu/cuối, không cho -- liên tiếp
    if not name then return false end
    -- Dạng dài: word-w[w-]*w  (vd: data-lake-01, my-bucket-name)
    if string.match(name, "^%w+%-%w[%w%-]*%w$") then return true end
    -- Dạng ngắn: word-w       (vd: tx-1, s3-a)
    if string.match(name, "^%w+%-%w$") then return true end
    return false
end

-- -----------------------------------------------------------------------------
-- isBucketInPath(uri) → bool
--   Kiểm tra URI có dạng path-style S3: /<bucket> hoặc /<bucket>/<key>
--
--   Hợp lệ:       "/my-bucket/", "/my-bucket/key/path"
--   Không hợp lệ: "/", "/nobucket" (không có dấu gạch ngang)
-- -----------------------------------------------------------------------------
function _M.isBucketInPath(uri)
    if not uri then return false end
    -- /<bucket>/        (trailing slash, không có key)
    if string.match(uri, "^/%w+%-%w[%w%-]*%w+/?$") then return true end
    -- /<bucket>/<key...>
    if string.match(uri, "^/%w+%-%w[%w%-]*%w+/.+$") then return true end
    return false
end

-- -----------------------------------------------------------------------------
-- isBucketInDomain(hostname, domains) → bool
--   Kiểm tra hostname có dạng vhost-style S3: <bucket>.<domain-suffix>
--
--   Tham số:
--     hostname  string  — hostname thực tế (đã strip port)
--                         vd: "my-bucket.s3-hcm.sds.infiniband.vn"
--     domains   table   — list Lua pattern của domain suffix (dấu chấm/gạch đã escape)
--                         vd: { "s3%-hcm%.sds%.infiniband%.vn", "s3%-hni%.sds%.infiniband%.vn" }
--
--   Lý do dùng Lua pattern thay vì plain string:
--     - Lua string.match dùng pattern, dấu chấm (.) match bất kỳ ký tự nếu không escape
--     - Phải escape: "." → "%.", "-" → "%-" trong domain suffix
--
--   Lua pattern escape (bắt buộc trong domains table):
--     dấu chấm  .  →  %.
--     dấu gạch  -  →  %-
--
--   Ví dụ domains table theo môi trường:
--     Lab:        { "s3%.hcm%.lab%.thuyldx" }
--     Sandbox:    { "s3%-hcm%.sds%.infiniband%.vn", "s3%-hni%.sds%.infiniband%.vn" }
--     Production: { "s3%-hcm%.sds%.vnpaycloud%.vn", "s3%-hni%.sds%.vnpaycloud%.vn" }
-- -----------------------------------------------------------------------------
function _M.isBucketInDomain(hostname, domains)
    if not hostname or not domains then return false end
    for _, suffix in ipairs(domains) do
        -- Pattern dạng dài: ^<bucket-pattern>.<suffix>$
        -- bucket pattern: \w+-[\w-]*\w+ (có ít nhất 1 dấu gạch ngang)
        if string.match(hostname, "^%w+%-%w[%w%-]*%w+%." .. suffix .. "$") then
            return true
        end
        -- Dạng ngắn: bk-1.<suffix>
        if string.match(hostname, "^%w+%-%w%." .. suffix .. "$") then
            return true
        end
    end
    return false
end

-- -----------------------------------------------------------------------------
-- extractBucketFromDomain(hostname, domains) → bucket | nil
--   Trích xuất bucket name từ vhost-style hostname.
--
--   vd: "my-bucket.s3-hcm.sds.infiniband.vn" → "my-bucket"
--   Trả về nil nếu không match bất kỳ suffix nào trong domains.
-- -----------------------------------------------------------------------------
function _M.extractBucketFromDomain(hostname, domains)
    if not hostname or not domains then return nil end
    for _, suffix in ipairs(domains) do
        local bucket = string.match(hostname, "^([%w%-]+)%." .. suffix .. "$")
        if bucket then
            return bucket
        end
    end
    return nil
end

-- -----------------------------------------------------------------------------
-- extractBucketFromPath(uri) → bucket | nil
--   Trích xuất bucket name từ path-style URI: /<bucket>/...
--   Trả về nil nếu URI là "/" hoặc không có bucket.

--   vd: "/my-bucket/key/file.txt" → "my-bucket"
--       "/my-bucket/"             → "my-bucket"
--       "/"                       → nil
--       ""                        → nil
-- -----------------------------------------------------------------------------
function _M.extractBucketFromPath(uri)
    if not uri or uri == "/" or uri == "" then return nil end
    return string.match(uri, "^/([^/?]+)")
end

return _M
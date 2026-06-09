-- Pure Lua utility — KHÔNG phải APISIX plugin
-- Lua library thuần (utility module): do đó không dùng trực tiếp cho APISIX được. Dùng: require("cloudian-regex") từ plugin bất kỳ

-- Nếu muốn tái sử dụng cloudian-regex.lua như một shared utility trong APISIX (tránh duplicate code), đặt nó ở một path riêng và require từ plugin.
-- Đặt file tại: /usr/local/apisix/apisix/plugins/custom/lib/regex.lua
-- Mount docker-compsoe.yaml: ./plugins/lib:/usr/local/apisix/apisix/plugins/custom/lib:ro
-- local regex = require("apisix.plugins.custom.lib.regex")
-- Sau đó gọi: regex.isBucket(bucket)

local regex = { _version = "1.0" }

function regex.isMatch (my_string, pattern)
    local extracted = string.match(my_string, pattern)
    
    if (extracted) then
        return true
    else
        return false
    end
end

function regex.isBucketInPath (uri)
    if (string.match(uri, "^/%w+-[%w-]*%w+/?$")) then
        return true
    elseif (string.match(uri, "^/%w+-[%w-]*%w+/.+$")) then
        return true
    else
       return false
    end
end

function regex.isBucket (bucketname)
    if (string.match(bucketname, "^%w+-[%w-]*%w+$")) then
        return true
    else
       return false
    end
end

-- C1: Không khai báo tham số domains là table chứa Lua pattern suffix, list toàn bộ domain ra
function regex.isBucketInDomain (bucketname)
    if (string.match(bucketname, "^%w+-[%w-]*%w+%.s3%-hcm%.sds%.vnpaycloud%.vn$")) then
        return true
    elseif (string.match(bucketname, "^%w+-[%w-]*%w+%.s3%-hni%.sds%.vnpaycloud%.vn$")) then
        return true
    elseif (string.match(bucketname, "^%w+-[%w-]*%w+%.s3%-hcm%.sds%.infiniband%.vn$")) then
        return true
    elseif (string.match(bucketname, "^%w+-[%w-]*%w+%.s3%-hni%.sds%.infiniband%.vn$")) then
        return true
    else
       return false
    end
end
-- C1 --

-- C2: Tham số domains là table chứa Lua pattern suffix, ví dụ:
--   Cloudian: { "s3%-hcm%.sds%.infiniband%.vn", "s3%-hni%.sds%.infiniband%.vn" }
--   Ceph lab:  { "s3%.hcm%.lab%.thuyldx" }
function regex.isBucketInDomain(hostname, domains)
    for _, suffix in ipairs(domains) do
        if string.match(hostname, "^%w+-[%w-]*%w+%." .. suffix .. "$") then
            return true
        end
    end
    return false
end
-- C2 --

return regex

-- Pure Lua utility — KHÔNG phải APISIX plugin
-- Lua library thuần (utility module): do đó không dùng trực tiếp cho APISIX được. Dùng: require("cloudian-regex") từ plugin bất kỳ

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

return regex

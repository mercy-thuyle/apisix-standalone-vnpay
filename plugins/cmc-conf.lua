local regex = dofile("/etc/nginx/libraries/customize/cloudian-regex/cloudian-regex.lua")

if ngx.var.request_uri == "/s3/bucket/create.htm" then
    if ngx.req.get_method() == "POST" then
        ngx.req.read_body()
        local args, err = ngx.req.get_post_args()

        if err == "truncated" then
            -- one can choose to ignore or reject the current request here
        else
            if not args then
                --do nothing
            else
                for key, val in pairs(args) do
                    if (key == "bucketName") then
                        ngx.log(ngx.WARN, 'GOT Create bucket from CMC: ', key, ": ", val)
                        local checkMatch = regex.isBucket(val) -- Check match with pattern
                        if (checkMatch) then
                            --do nothing
                        else
                            -- ngx.redirect("https://portal.vnpaycloud.vn/entity/s3/storage?bucket-error=true")
                            if ngx.var.http_host == "sds.vnpaycloud.vn" then
                              ngx.redirect("https://"..ngx.var.http_host.."/s3/storage?bucket-error=true")
                           elseif ngx.var.http_host == "console.vnpaycloud.vn" then
                              ngx.redirect("https://"..ngx.var.http_host.."/entity/s3-storage?bucket-error=true")
                           end
                        end
                    end
                end
            end
        end
    end
end
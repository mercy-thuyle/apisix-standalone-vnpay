local exHttpRequest = dofile("/etc/nginx/libraries/customize/ExHttpRequest/ExHttpRequest.lua")
local regex = dofile("/etc/nginx/libraries/customize/cloudian-regex/cloudian-regex.lua")

if ngx.req.get_method() == "PUT" then
    if (regex.isBucketInPath(ngx.var.request_uri)) then
      --ngx.log(ngx.STDERR, "Exactly createbucket request : ", exHttpRequest.getRequestBody())
    else
      ngx.status = 400
      ngx.say("Bucket is invalid")
      ngx.exit(ngx.OK)
    end
end
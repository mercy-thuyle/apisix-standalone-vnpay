local json = dofile("/etc/nginx/libraries/third-party/json/json.lua")
local exHttpRequest = { _version = "1.0" }

function exHttpRequest.getRequestBody ()
   ngx.req.read_body()
   local requestBodyData = ngx.req.get_body_data()
   ngx.log(ngx.STDERR, requestBodyData) --Current Request Body Data 
   --requestBodyData = json.decode (requestBodyData) -- Convert Json to Table structure
   return requestBodyData
end

function exHttpRequest.returnWhenRequestBodyHasValue (keyIndex, value, ngx_return_code)
--      local  match = ngx.re.match(requestBodyData, content)
--      if match then
--         ngx.exit(ngx_return_code)
--      end
--      local json_as_string = json.encode(requestBodyData)
--      ngx.log(ngx.STDERR, "===============" .. json_as_string)
      
        -- local convertedTable = json.decode (requestBodyData)

        local tempValue = keyIndex
   if (tempValue == value) then
      --ngx.exit(ngx_return_code) -- return to 403
   end
--      ngx.log(ngx.STDERR, "===============", accessToTable (convertedTable,  
end

function exHttpRequest.RequestBodySetKey (requestBodyData, keyIndex, valueOfKey)
   -- requestBodyData.keyIndex = valueOfKey
end

function exHttpRequest.RequestBodyRemoveKey (requestBodyData, keyIndex)
   -- requestBodyData.keyIndex = nil
end

function exHttpRequest.replaceRequestBodyContent (requestBodyData, content, newContent)

   if requestBodyData then
      requestBodyData = ngx.re.gsub(requestBodyData, content, newContent)
   end
      ngx.req.set_body_data(requestBodyData)
     -- ngx.log(ngx.STDERR, requestBodyData) --New Request Body Data
end

return exHttpRequest
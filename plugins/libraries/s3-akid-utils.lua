-- =============================================================================
-- plugins/libraries/s3-akid-utils.lua
-- Pure-Lua utility — TRÍCH AWS Access Key ID (AKID) từ request S3.
-- KHÔNG phụ thuộc ngx/apisix → unit-test được bằng lua thuần.
--
-- Mục đích: ĐỊNH DANH caller (không phải XÁC THỰC). Backend (Cloudian/Ceph) đã
-- validate chữ ký SigV4 rồi; gateway chỉ cần đọc AKID để làm khóa rate-limit.
-- AKID là định danh công khai (như username), KHÔNG phải secret.
--
-- Hỗ trợ 4 dạng:
--   1. SigV4 header   : Authorization: AWS4-HMAC-SHA256 Credential=<AKID>/<date>/...
--   2. SigV4 streaming: Authorization: AWS4-HMAC-SHA256 Credential=<AKID>/...  (giống #1)
--   3. SigV2 header   : Authorization: AWS <AKID>:<signature>
--   4. Presigned URL  : ?X-Amz-Credential=<AKID>/<date>/...  (SigV4)
--                       ?AWSAccessKeyId=<AKID>               (SigV2)
-- =============================================================================

-- HEADERS cần check
-- Client  ──request──>  APISIX  ──request──> Upstream (Cloudian/Ceph)
--         <─response──          <─response──

-- Tầng 1: Header CLIENT gửi lên APISIX          (request headers - inbound)
-- Tầng 2: Header APISIX gửi lên UPSTREAM        (request headers - proxied)
-- Tầng 3: Header UPSTREAM trả về APISIX         (response headers - from backend)
-- Tầng 4: Header APISIX trả về CLIENT           (response headers - outbound)

-- -----------------------------------------------------------------------
-- Cách 1: curl -v (Debug nhanh không cần setup) hoặc curl -D - (Xem response header với rate-limit, APISIX metadata)— xem tầng 1 và tầng 4
-- # Xem TẤT CẢ header request và response (verbose)
-- curl -vsk https://s3-hcm.sds.infiniband.vn/test-bucket/file.txt -H 'Authorization: AWS4-HMAC-SHA256 Credential=AKIATEST/20260623/ap-southeast-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=fakesig' -H 'x-amz-date: 20260623T000000Z' 2>&1
-- # > = header CLIENT gửi lên APISIX
-- # < = header APISIX trả về CLIENT

-- # Chỉ lấy response header (gọn hơn)
-- curl -sk -D - -o /dev/null https://s3-hcm.sds.infiniband.vn/test-bucket/file.txt -H 'Authorization: AWS4-HMAC-SHA256 Credential=AKIATEST/...'
-- # -D -   : dump response header ra stdout
-- # -o /dev/null : bỏ body đi
-- local _M = { _VERSION = "0.1" }

-- # Chỉ lấy 1 header cụ thể (curl 7.84+)
-- curl -sk -o /dev/null -w '%header{x-ratelimit-remaining}\n' https://s3-hcm.sds.infiniband.vn/test-bucket/file.txt -H 'Authorization: AWS4-HMAC-SHA256 Credential=AKIATEST/...'
-- -----------------------------------------------------------------------
-- Cách 2: Echo server — xem tầng 2 (header APISIX gửi lên upstream) Xem header APISIX đã thêm/sửa trước khi gửi upstream
-- Đây là cách quan trọng nhất để debug plugin vì bạn thấy được những gì APISIX thực sự forward lên backend: X-S3-Access-Key, X-Real-IP, X-Forwarded-*, v.v.
-- # B1: Dựng echo server tạm (httpbin hoặc netcat)

-- # Cách A: httpbin bằng docker (đẹp nhất)
-- docker run -d --name echo-upstream --network host kennethreitz/httpbin

-- # Cách B: netcat đơn giản (không cần docker, chỉ cần nc)
-- while true; do
--   echo -e "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK" | nc -l -p 8888 -q 1
-- done

-- # B2: Tạo upstream tạm trỏ về echo server
-- # Thêm vào fragment upstream tạm (hoặc sửa tạm 1 upstream hiện có):

-- # apisix_routes/upstreams/debug/upstream-echo.yaml
-- upstreams:
--   - id: upstream-echo-debug
--     type: roundrobin
--     scheme: http
--     nodes:
--       "127.0.0.1:8000": 1   # httpbin mặc định port 8000

-- # B3: Tạo route tạm trỏ về echo
-- # apisix_routes/routes/debug/route-echo-debug.yaml
-- routes:
--   - id: route-echo-debug
--     uri: /debug/headers
--     host: s3-hcm.sds.infiniband.vn   # dùng chung host để test đúng plugin
--     methods: [GET, PUT, HEAD]
--     upstream_id: upstream-echo-debug
--     service_id: tier-0-s3-dataplane   # giữ tier để test đúng plugin
--     plugins:
--       custom.s3-accesskey-extractor: {}

-- # B4: Bắn request và xem TOÀN BỘ header APISIX gửi lên upstream
-- curl -sk https://s3-hcm.sds.infiniband.vn/debug/headers -H 'Authorization: AWS4-HMAC-SHA256 Credential=AKIATEST123/20260623/ap-southeast-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=fakesig' -H 'x-amz-date: 20260623T000000Z' | python3 -m json.tool
-- # httpbin /headers trả về JSON chứa đúng header upstream nhận được:
-- # {
-- #   "headers": {
-- #     "Authorization": "AWS4-HMAC-SHA256 Credential=AKIATEST123/...",
-- #     "Host": "s3-hcm.sds.infiniband.vn",
-- #     "X-Forwarded-For": "...",
-- #     "X-Real-Ip": "...",
-- #     "X-S3-Access-Key": "AKIATEST123",   ← plugin đã set đúng
-- #     "X-Amz-Date": "20260623T000000Z"
-- #   }
-- # }
-- -----------------------------------------------------------------------
-- Cách 3: APISIX access log format — ghi cả header vào log Xem header thường xuyên, nhiều request
-- Thêm vào config-hcm.yaml (cần restart):
-- nginx_config:
--   http:
--     # Log cả request header để debug (CHỈ bật tạm, TẮT sau khi debug xong)
--     # WARNING: log Authorization header = log credential → không để trên prod
--     access_log_format: >
--       $remote_addr - "$request" $status
--       AKID="$http_x_s3_access_key"
--       RateLimit-Remaining="$sent_http_x_ratelimit_remaining"
--       RateLimit-Limit="$sent_http_x_ratelimit_limit"
--       Host="$http_host"
--       UA="$http_user_agent"
--     access_log_format_escape: default

-- # Xem realtime
-- tail -f /opt/apisix/standalone/sandbox/logs/apisix-hcm/access.log
-- -----------------------------------------------------------------------
-- Cách 4: serverless-pre-function dump header ra log — không cần restart Debug plugin cụ thể, không restart
--     Thêm tạm vào route cần debug (hot-reload, không restart):

-- # Thêm vào route fragment tạm thời
-- routes:
--     - id: route-s3-hcm.sds.infiniband.vn-https-proxy
--     # ... giữ nguyên ...
--     plugins:
--         # ... giữ nguyên plugin khác ...

--         # DEBUG ONLY — xóa sau khi debug xong
--         serverless-pre-function:
--         phase: rewrite
--         functions:
--             - |
--             return function(conf, ctx)
--                 local headers = ngx.req.get_headers()
--                 local out = {}
--                 for k, v in pairs(headers) do
--                 -- Che Authorization để không log credential thật
--                 if k:lower() == "authorization" then
--                     local akid = (v or ""):match("Credential=([^/,]+)") or "?"
--                     table.insert(out, k .. ": AWS4...[AKID=" .. akid .. "]")
--                 else
--                     table.insert(out, k .. ": " .. tostring(v))
--                 end
--                 end
--                 table.sort(out)
--                 ngx.log(ngx.WARN, "[DEBUG-HEADERS] " .. table.concat(out, " | "))
--             end

-- # Xem header dump trong error.log (level WARN)
-- tail -f /opt/apisix/standalone/sandbox/logs/apisix-hcm/error.log | grep 'DEBUG-HEADERS'
-- # → [DEBUG-HEADERS] authorization: AWS4...[AKID=AKIATEST123] | host: s3-hcm... | x-amz-date: ... | x-s3-access-key: AKIATEST123
-- =============================================================================


-- Trích AKID từ giá trị header Authorization (SigV4 trước, SigV2 sau).
-- @param auth string|nil  giá trị header Authorization
-- @return string|nil      AKID hoặc nil nếu không khớp
function _M.from_auth_header(auth)
    if not auth or auth == "" then
        return nil
    end
    -- SigV4: ...Credential=<AKID>/<date>/<region>/<service>/aws4_request, ...
    -- Cắt tới ký tự '/', ',', hoặc khoảng trắng đầu tiên.
    local akid = auth:match("Credential=([^/,%s]+)")
    if akid and akid ~= "" then
        return akid
    end
    -- SigV2: AWS <AKID>:<signature>
    akid = auth:match("^AWS%s+([^:%s]+):")
    if akid and akid ~= "" then
        return akid
    end
    return nil
end

-- Trích AKID từ bảng query args (presigned URL). args phải ĐÃ url-decode
-- (apisix core.request.get_uri_args trả về bản đã decode).
-- @param args table|nil
-- @return string|nil
function _M.from_query_args(args)
    if not args then
        return nil
    end
    -- SigV4 presigned: X-Amz-Credential=<AKID>/<date>/<region>/<service>/aws4_request
    local cred = args["X-Amz-Credential"]
    if type(cred) == "table" then cred = cred[1] end   -- query lặp → lấy phần tử đầu
    if cred and cred ~= "" then
        local akid = cred:match("^([^/]+)")
        if akid and akid ~= "" then
            return akid
        end
    end
    -- SigV2 presigned: AWSAccessKeyId=<AKID>
    local k = args["AWSAccessKeyId"]
    if type(k) == "table" then k = k[1] end
    if k and k ~= "" then
        return k
    end
    return nil
end

-- Tổng hợp: header trước (đa số request), query sau (chỉ presigned).
function _M.extract(auth, args)
    return _M.from_auth_header(auth) or _M.from_query_args(args)
end

return _M
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
--
-- Client  ──request──>  APISIX  ──request──> Upstream (Cloudian/Ceph)
--         <─response──          <─response──

-- Tầng 1: Header CLIENT gửi lên APISIX          (request headers - inbound)
-- Tầng 2: Header APISIX gửi lên UPSTREAM        (request headers - proxied)
-- Tầng 3: Header UPSTREAM trả về APISIX         (response headers - from backend)
-- Tầng 4: Header APISIX trả về CLIENT           (response headers - outbound)

local _M = { _VERSION = "0.1" }

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

-- =============================================================================
-- plugins/custom/s3-accesskey-extractor.lua
-- APISIX plugin — trích AKID (AWS Access Key ID) để dùng làm khóa rate-limit.
-- Tham chiếu trong config.yaml: 'custom.s3-accesskey-extractor'
--
-- LUỒNG:
--   rewrite phase → đọc AKID (header/presigned) → set ctx var 's3_access_key'
--   (+ tùy chọn header 'X-S3-Access-Key') → limit-count dùng làm key.
--   Chạy ở rewrite nên LUÔN trước limit-count (access phase).
--
-- KHÓA cho limit-count (chọn 1):
--   key_type: var, key: s3_access_key          ← biến nội bộ (KHÔNG leak upstream)
--   key_type: var, key: http_x_s3_access_key   ← qua header (cần set_header bật)
--
-- ⚠ AKID có thể bị client GIẢ MẠO (gateway không verify chữ ký). Đây là công cụ
--   ĐO ĐẾM cho traffic hợp lệ, KHÔNG phải chống abuse → GIỮ guard theo IP
--   (global_rules limit-conn + limit-conn tier-0) làm lớp phòng thủ.
--
-- ⚠ Đổi config.yaml (plugins list) và file .lua này đều cần RESTART container
--   (plugin nạp lúc khởi động, không hot-reload như route YAML).
-- =============================================================================

local core        = require("apisix.core")
local akid_utils  = require("s3-akid-utils")   -- từ extra_lua_path (plugins/libraries)

local plugin_name = "s3-accesskey-extractor"

local schema = {
    type = "object",
    properties = {
        -- Không tìm thấy AKID (request vô danh / public bucket):
        --   true  → dùng "ip:<remote_addr>" làm khóa → anonymous tự thành PER-IP
        --           (tránh mọi anonymous dồn vào 1 bucket đếm chung).
        --   false → dùng anonymous_value cố định.
        anonymous_use_ip = { type = "boolean", default = true },
        anonymous_value  = { type = "string",  default = "anonymous" },

        -- Header phơi AKID ra (để dùng key http_x_s3_access_key / debug).
        -- Đặt "" để TẮT (không gửi header nào lên upstream).
        -- An toàn với SigV4: header này KHÔNG nằm trong SignedHeaders nên KHÔNG phá chữ ký (khác X-Forwarded-Port mà Cloudian dùng để ký).
        set_header = { type = "string", default = "X-S3-Access-Key" },

        -- (Tùy chọn) map AKID → tier cho số ít account đặc biệt. Map LỚN/động nên externalize, đừng nhồi hết vào đây.
        -- tier_map     = { type = "object", additionalProperties = { type = "string" } },
        -- default_tier = { type = "string", default = "standard" },
        -- tier_header  = { type = "string", default = "X-S3-Tier" },   -- "" để tắt
    },
}

local _M = {
    version  = 0.1,
    priority = 2510,          -- cao, chạy sớm trong rewrite (trước/độc lập normalizer)
    name     = plugin_name,
    schema   = schema,
}

-- Đăng ký biến nội bộ 1 LẦN khi load. Bọc pcall: nếu build không có
-- register_var thì plugin vẫn nạp được, dùng đường header (http_x_s3_access_key).
pcall(function()
    core.ctx.register_var("s3_access_key", function(ctx)
        return ctx.s3_access_key
    end)
    -- core.ctx.register_var("s3_tier", function(ctx)
    --     return ctx.s3_tier
    -- end)
end)

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- 1) Header trước (đa số request đã ký bằng Authorization, SigV4/SigV2 thông thường))
    local auth = core.request.header(ctx, "Authorization")
    local akid = akid_utils.from_auth_header(auth)

    -- 2) Chỉ parse query khi header không có AKID (tiết kiệm: presigned URL mới cần)
    if not akid then
        akid = akid_utils.from_query_args(core.request.get_uri_args(ctx))
    end

    -- 3) Vô danh → fallback per-IP (mặc định) hoặc giá trị cố định
    if not akid then
        if conf.anonymous_use_ip then
            akid = "ip:" .. (ctx.var.remote_addr or "unknown")
        else
            akid = conf.anonymous_value
        end
    end

    ctx.s3_access_key = akid
    if conf.set_header and conf.set_header ~= "" then
        core.request.set_header(ctx, conf.set_header, akid)
    end

    -- 4) (Tùy chọn) gán tier
    -- if conf.tier_map then
    --     local tier = conf.tier_map[akid] or conf.default_tier
    --     ctx.s3_tier = tier
    --     if conf.tier_header and conf.tier_header ~= "" then
    --         core.request.set_header(ctx, conf.tier_header, tier)
    --     end
    -- end
end

return _M
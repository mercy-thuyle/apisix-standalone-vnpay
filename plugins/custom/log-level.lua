local core = require("apisix.core")

local plugin_name = "log-level"

local schema = {
    type = "object",
}

local metadata_schema = {
    type = "object",
    properties = {
        core_log_level = {
            type = "string",
            description = "Mức log cho plugins/custom (core.log.*) — áp dụng theo core_log_scope. "
                        .. "Hot-reload qua gitsync, không cần restart."
                        .. "CHỈ áp dụng cho các id liệt kê trong core_log_scope. "
                        .. "Log luôn bắn ra qua core.log.warn (error_log_level "
                        .. "mặc định đang warn) — field này chỉ quyết định CÓ bắn "
                        .. "hay không, không đổi level vật lý của dòng log gốc. "
                        .. "8 mức khớp đúng nginx error_log directive (xem "
                        .. "https://nginx.org/en/docs/ngx_core_module.html#error_log).",
            default = "warn"
        },
        core_log_scope = {
            type = "array",
            items = { type = "string" },
            description = "Danh sách tên plugin (VD custom.s3-traffic-classifier) "
                        .. "được áp core_log_level. '*' hoặc 'all' = áp toàn bộ."
                        .. "Khai id cụ thể để chỉ bật/tắt riêng 1-vài plugin, "
                        .. "không ảnh hưởng plugin khác.",
            default = {}
        },
        ngx_log_level = {
            type = "string",
            description = "Mức log cho serverless-pre/post-function (ngx.log) "
                        .. "— áp dụng theo ngx_log_scope. Hot-reload qua gitsync."
                        .. "(embedded trong route/plugin_config YAML) "
                        .. "— CHỈ áp dụng cho id liệt kê ",
            default = "warn"
        },
        ngx_log_scope = {
            type = "array",
            items = { type = "string" },
            description = "Danh sách tên plugin_config/route được áp ngx_log_level. "
                        .. "'*' hoặc 'all' = áp toàn bộ."
                        .. " Lấy theo field 'id:' khai trong chính file đó được áp "
                        .. "ngx_log_level. '*' hoặc 'all' = áp dụng toàn bộ.",
            default = {}
        },
    },
}

local _M = {
    version         = 0.1,
    priority        = 0,
    name            = plugin_name,
    schema          = schema,
    metadata_schema = metadata_schema,
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    return core.schema.check(schema, conf)
end

-- Plugin này KHÔNG gắn vào route nào, không có phase function.
-- Chỉ tồn tại để "custom.log-level" là 1 plugin hợp lệ, cho phép
-- plugin_metadata cùng id được validate_plugin() chấp nhận.

return _M

local apisix_plugin = require("apisix.plugin")
local core = require("apisix.core")

local LEVEL_RANK = {
    emerg = 1, alert = 2, crit = 3, error = 4,
    warn  = 5, notice = 6, info = 7, debug = 8,
}

local function in_scope(scope_list, self_id)
    if not scope_list then
        return false
    end
    for _, id in ipairs(scope_list) do
        if id == "*" or id == "all" or id == self_id then
            return true
        end
    end
    return false
end

local _M = {
    LEVEL_RANK = LEVEL_RANK,
}

-- field_prefix: "core" (dùng trong plugins/custom) hoặc "ngx" (dùng trong
-- serverless-pre-function/serverless-post-function).
-- self_id: core → tên plugin custom (VD "custom.s3-traffic-classifier");
--          ngx  → tên plugin_config/route (VD "plugin-config-traffic-classifier").
-- -- KHÔNG trộn 2 loại id vào chung 1 scope — core_log_scope chỉ chứa tên plugin, ngx_log_scope chỉ chứa tên
--   plugin_config/route.
-- self_ids: 1 string HOẶC 1 table nhiều string (vd {plugin_config_id,
--   route_id}) — khớp bất kỳ 1 phần tử nào trong scope là đủ để bật.
-- msg_rank: dùng log_level.LEVEL_RANK.info / .debug / .warn / ... để gọi,
--   KHÔNG hardcode số.

function _M.emit(field_prefix, self_ids, msg_rank, ...)
    local metadata = apisix_plugin.plugin_metadata("custom.log-level")
    if not metadata or not metadata.value then
        return
    end

    local level = metadata.value[field_prefix .. "_log_level"]
    local scope = metadata.value[field_prefix .. "_log_scope"]
    -- if not level or not in_scope(scope, self_id) then
    if not level then
        return
    end

    local ids = type(self_ids) == "table" and self_ids or {self_ids}
    local matched = false
    for _, id in ipairs(ids) do
        if in_scope(scope, id) then matched = true break end
    end
    if not matched then return end

    if msg_rank <= (LEVEL_RANK[level] or LEVEL_RANK.warn) then
        core.log.warn(...)   -- luôn là warn — vượt qua nginx floor cố định
    end
end

return _M

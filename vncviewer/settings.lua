--[[--
Versioned settings store for the vncviewer plugin.

Thin wrapper over @{luasettings|LuaSettings}, holding connection profiles and global
application settings in `~/.config/koreader/settings/vncviewer.lua`.

The on-disk table is versioned with `settings_version`; @{Settings:migrate} fills in
missing keys and coerces wrong types, so an older or hand-edited file keeps working.

@module vncviewer.settings
]]

local LuaSettings = require("luasettings")
local logger = require("logger")

local Settings = {}
Settings.__index = Settings

--- Current on-disk schema version. Bump when the shape of `data` changes.
Settings.SETTINGS_VERSION = 1

--- Profile field names, in the order they are written to disk.
Settings.PROFILE_FIELDS = { "name", "host", "port", "username", "password" }

--- Global settings defaults (the `settings` sub-table).
Settings.DEFAULTS = {
    orientation = 0,                 -- Screen.DEVICE_ROTATED_UPRIGHT, used as the app default
    keyboard_always_visible = false,
    zoom_mode = "fit",               -- "fit" or a numeric scale factor
    enable_tight = false,            -- opt-in Tight encoding (not in RFC 6143; see README)
}

--- Opens (and returns) the settings store at `path`.
--- @param path string
--- @treturn table settings object with fields `ls` (LuaSettings) and `data` (raw table)
function Settings.open(path)
    local ls = LuaSettings:open(path)
    local self = setmetatable({}, Settings)
    self.ls = ls
    self.data = ls.data
    --- Normalise whatever was on disk before anybody reads it.
    Settings.migrate(self.data)
    return self
end

--- Coerces a raw value to the type of the corresponding default.
local function coerce_like(value, default)
    local want = type(default)
    if want == "number" then
        local n = tonumber(value)
        return n or default
    elseif want == "boolean" then
        if type(value) == "boolean" then return value end
        return default
    elseif want == "string" then
        if type(value) == "string" then return value end
        return default
    end
    return value
end

--- Cleans one profile table, dropping unknown fields and coercing types.
--- @treturn table|nil cleaned profile, or nil when it has no usable name
local function clean_profile(p)
    if type(p) ~= "table" then return nil end
    local name = p.name
    if type(name) ~= "string" then return nil end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    local port = tonumber(p.port) or 5900
    port = math.floor(port)
    if port < 1 or port > 65535 then port = 5900 end
    return {
        name = name,
        host = type(p.host) == "string" and p.host or "",
        port = port,
        username = type(p.username) == "string" and p.username or "",
        password = type(p.password) == "string" and p.password or "",
    }
end

--- Idempotent migration of a raw settings table, in place.
---
--- Fills missing keys from @{Settings.DEFAULTS}, coerces types, drops unknown profile
--- fields and renumbers the profile array without holes. Never raises.
--- @param data table
--- @treturn boolean whether anything was changed
function Settings.migrate(data)
    if type(data) ~= "table" then return false end
    local changed = false

    local v = tonumber(data.settings_version) or 0
    if v ~= Settings.SETTINGS_VERSION then changed = true end

    if v < 1 then
        -- Initial schema: nothing to convert, the version stamp is enough.
    end

    -- Global settings sub-table.
    if type(data.settings) ~= "table" then
        data.settings = {}
        changed = true
    end
    for key, default in pairs(Settings.DEFAULTS) do
        if data.settings[key] == nil then
            data.settings[key] = default
            changed = true
        else
            local coerced = coerce_like(data.settings[key], default)
            if coerced ~= data.settings[key] then
                data.settings[key] = coerced
                changed = true
            end
        end
    end
    for key in pairs(data.settings) do
        if Settings.DEFAULTS[key] == nil then
            logger.dbg("vncviewer: dropping unknown setting", key)
            data.settings[key] = nil
            changed = true
        end
    end

    -- Connection profiles: clean, drop unusable entries, close array holes.
    if type(data.profiles) ~= "table" then
        data.profiles = {}
        changed = true
    else
        local cleaned = {}
        for _, p in ipairs(data.profiles) do
            local c = clean_profile(p)
            if c then
                cleaned[#cleaned + 1] = c
            else
                changed = true
            end
        end
        -- Detect value changes (field drops/coercions) that ipairs count alone misses.
        local known = {}
        for _, f in ipairs(Settings.PROFILE_FIELDS) do known[f] = true end
        local same = #cleaned == #data.profiles
        for i = 1, #cleaned do
            if not same then break end
            local o = data.profiles[i]
            for _, f in ipairs(Settings.PROFILE_FIELDS) do
                if o[f] ~= cleaned[i][f] then same = false break end
            end
            if same then
                for k in pairs(o) do
                    if not known[k] then same = false break end
                end
            end
        end
        data.profiles = cleaned
        if not same then changed = true end
    end

    if tonumber(data.settings_version) ~= Settings.SETTINGS_VERSION then
        data.settings_version = Settings.SETTINGS_VERSION
        changed = true
    end

    return changed
end

--- @treturn table array of connection profiles
function Settings:profiles()
    return self.data.profiles
end

--- Finds a profile by name (exact match).
--- @treturn table|nil
function Settings:get_profile(name)
    for _, p in ipairs(self:profiles()) do
        if p.name == name then return p end
    end
    return nil
end

--- Adds or updates a profile, keyed by name.
---
--- @param p table profile (`name`, `host`, `port`, `username`, `password`)
--- @param existing_name string|nil name to replace; when nil, `p.name` must be unused
--- @treturn boolean, string|nil true on success, else false and an error message
function Settings:save_profile(p, existing_name)
    local name = type(p.name) == "string" and p.name:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if name == "" then
        return false, "empty name"
    end
    if type(p.host) ~= "string" or p.host:gsub("%s", "") == "" then
        return false, "empty host"
    end
    local port = tonumber(p.port) or 5900
    port = math.floor(port)
    if port < 1 or port > 65535 then
        return false, "invalid port"
    end

    local profiles = self:profiles()
    local idx, found
    for i, existing in ipairs(profiles) do
        if existing.name == name then
            idx, found = i, existing
            break
        end
    end
    if found and name ~= existing_name then
        return false, "duplicate name"
    end
    if not found and existing_name then
        -- Rename: the old name must exist and the new one must be free.
        for i, existing in ipairs(profiles) do
            if existing.name == existing_name then
                idx, found = i, existing
                break
            end
        end
        if not found then
            return false, "no such profile"
        end
    end

    local cleaned = clean_profile({
        name = name, host = p.host, port = port,
        username = p.username, password = p.password,
    })
    if idx then
        profiles[idx] = cleaned
    else
        profiles[#profiles + 1] = cleaned
    end
    return true
end

--- Deletes a profile by name.
--- @treturn boolean whether a profile was removed
function Settings:delete_profile(name)
    local profiles = self:profiles()
    for i, p in ipairs(profiles) do
        if p.name == name then
            table.remove(profiles, i)
            return true
        end
    end
    return false
end

--- @treturn any the global setting `key`, or nil
function Settings:get_setting(key)
    return self.data.settings[key]
end

--- Sets a global setting.
function Settings:set_setting(key, value)
    self.data.settings[key] = value
end

--- Writes the settings file.
function Settings:flush()
    self.ls.data = self.data
    self.ls:flush()
end

return Settings

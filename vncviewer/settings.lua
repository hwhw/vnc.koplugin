--[[--
Settings store for the vncviewer plugin.

Thin wrapper over @{luasettings|LuaSettings}, holding connection profiles and global
application settings in `~/.config/koreader/settings/vncviewer.lua`.

There is no schema version and no migration: there is no released file format to stay compatible
with. The file is just kept in shape instead - missing keys get their defaults, unknown keys are
dropped, and profiles that cannot be used are dropped - so a hand-edited file still loads.

@module vncviewer.settings
]]

local LuaSettings = require("luasettings")
local logger = require("logger")

local Settings = {}
Settings.__index = Settings

--- Profile field names.
Settings.PROFILE_FIELDS = { "name", "host", "port", "password" }

--- The only top-level keys of the file.
Settings.DATA_KEYS = { "profiles", "settings", "server" }

local known_data_key = {}
for _, key in ipairs(Settings.DATA_KEYS) do known_data_key[key] = true end

--- Global settings defaults (the `settings` sub-table).
Settings.DEFAULTS = {
    orientation = 0,                 -- Screen.DEVICE_ROTATED_UPRIGHT, used as the app default
    keyboard_always_visible = false,
    zoom_mode = "fit",               -- "fit", "fit_with_keyboard", or a numeric scale factor
    enable_tight = false,            -- opt-in Tight encoding (not in RFC 6143; see NOTES.txt)
}

--- VNC server defaults (the `server` sub-table). See @{vncviewer.server}.
Settings.SERVER_DEFAULTS = {
    ip = "0.0.0.0",                  -- bind address; 0.0.0.0 serves every interface
    port = 5900,
    password = "",                   -- empty = no authentication (RFB "None" security)
}

--- Opens (and returns) the settings store at `path`.
--- @param path string
--- @treturn table settings object with fields `ls` (LuaSettings) and `data` (raw table)
function Settings.open(path)
    local ls = LuaSettings:open(path)
    local self = setmetatable({ ls = ls, data = ls.data }, Settings)
    self:normalise()
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
        password = type(p.password) == "string" and p.password or "",
    }
end

--[[--
Keeps a raw settings table in shape, in place.

Fills in missing global settings, drops settings and profiles that are not usable, and closes
holes in the profile array. Never raises, so a broken file cannot keep the plugin from loading.
]]
function Settings:normalise()
    if type(self.data) ~= "table" then
        self.data = {}
    end
    local data = self.data

    for key in pairs(data) do
        if not known_data_key[key] then
            logger.dbg("vncviewer: dropping unknown settings key", key)
            data[key] = nil
        end
    end

    local function normalise_section(key, defaults)
        if type(data[key]) ~= "table" then data[key] = {} end
        local section = data[key]
        for name, default in pairs(defaults) do
            section[name] = coerce_like(section[name], default)
        end
        for name in pairs(section) do
            if defaults[name] == nil then
                logger.dbg("vncviewer: dropping unknown", key, "key", name)
                section[name] = nil
            end
        end
        return section
    end

    normalise_section("settings", Settings.DEFAULTS)
    local server = normalise_section("server", Settings.SERVER_DEFAULTS)
    server.port = math.max(1, math.min(65535, math.floor(server.port)))
    if server.ip == "" then server.ip = Settings.SERVER_DEFAULTS.ip end

    if type(data.profiles) ~= "table" then data.profiles = {} end
    local cleaned = {}
    for _, p in ipairs(data.profiles) do
        local c = clean_profile(p)
        if c then
            cleaned[#cleaned + 1] = c
        else
            logger.dbg("vncviewer: dropping an unusable connection profile")
        end
    end
    data.profiles = cleaned
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
--- @param p table profile (`name`, `host`, `port`, `password`)
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
        name = name, host = p.host, port = port, password = p.password,
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

--- The VNC server configuration sub-table (bind address, port, password).
--- @treturn table
function Settings:server()
    return self.data.server
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

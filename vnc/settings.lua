--[[--
Settings store for the vnc plugin.

Thin wrapper over @{luasettings|LuaSettings}, holding connection profiles and global
application settings in `~/.config/koreader/settings/vnc.lua`.

There is no schema version and no migration: there is no released file format to stay compatible
with. The file is just kept in shape instead - missing keys get their defaults, unknown keys are
dropped, and profiles that cannot be used are dropped - so a hand-edited file still loads.

@module vnc.settings
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

--- VNC server defaults (the `server` sub-table). See @{vnc.server}.
Settings.SERVER_DEFAULTS = {
    ip = "0.0.0.0",                  -- bind address; 0.0.0.0 serves every interface
    port = 5900,
    password = "",                   -- empty = no authentication (RFB "None" security)
    autostart = false,               -- start the server with KOReader (main.lua defers it)
}

--- Environment variables that override the server settings for one run.
---
--- They are read once (at load) and never written back to the settings file: a run binds what the
--- environment says while the menu keeps showing and editing the stored values.
Settings.ENV = {
    enable   = "VNC_KOPLUGIN_ENABLE_SERVER",   -- decides the boot start, in place of `autostart`
    host     = "VNC_KOPLUGIN_SERVER_HOST",     -- overrides `ip`
    port     = "VNC_KOPLUGIN_SERVER_PORT",     -- overrides `port`
    password = "VNC_KOPLUGIN_SERVER_PASSWORD",  -- overrides `password`
}

--[[--
Reads the server environment once, behind a lookup seam so it is testable without touching the
real environment.

Rules (a value that is `nil` in the result means "no opinion": use the stored setting):

* `enable`: unset or set-but-empty -> no opinion. Trimmed, case-insensitive `0`, `no` and `false`
  -> do not start; anything else non-empty -> start. An accidentally exported empty variable must
  therefore not open a listening server.
* `host`: empty -> no opinion, otherwise the (trimmed) bind address.
* `port`: an integer 1..65535 -> the port. Anything else is ignored with a warning.
* `password`: empty-but-set is a meaningful override ("no password"), so any set value is kept
  verbatim (not trimmed).

--- @tparam[opt] function getenv `name -> value|nil`; defaults to `os.getenv`
--- @treturn table `{ enable, host, port, password }`; absent means no opinion
]]
function Settings.read_env(getenv)
    getenv = getenv or os.getenv
    local env = {}

    local enable = getenv(Settings.ENV.enable)
    if enable ~= nil then
        enable = enable:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if enable ~= "" then
            env.enable = not (enable == "0" or enable == "no" or enable == "false")
        end
    end

    local host = getenv(Settings.ENV.host)
    if host ~= nil then
        host = host:gsub("^%s+", ""):gsub("%s+$", "")
        if host ~= "" then env.host = host end
    end

    local port = getenv(Settings.ENV.port)
    if port ~= nil then
        local n = tonumber(port)
        if n and n == math.floor(n) and n >= 1 and n <= 65535 then
            env.port = math.floor(n)
        else
            logger.warn("vnc: ignoring an invalid", Settings.ENV.port .. ":", port)
        end
    end

    local password = getenv(Settings.ENV.password)
    if password ~= nil then env.password = password end

    return env
end

--- Opens (and returns) the settings store at `path`.
--- @param path string
--- @param[opt] function getenv lookup seam for @{Settings.read_env}; defaults to `os.getenv`
--- @treturn table settings object with fields `ls` (LuaSettings) and `data` (raw table)
function Settings.open(path, getenv)
    local ls = LuaSettings:open(path)
    -- The environment is read once, here, and kept away from `data` so it can never be flushed.
    local self = setmetatable({ ls = ls, data = ls.data, env = Settings.read_env(getenv) }, Settings)
    self:normalise()
    local names = {}
    for _, key in ipairs({ "enable", "host", "port", "password" }) do
        if self.env[key] ~= nil then names[#names + 1] = key end
    end
    if #names > 0 then
        logger.info("vnc: environment overrides in effect for this run: " .. table.concat(names, ", "))
    end
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
            logger.dbg("vnc: dropping unknown settings key", key)
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
                logger.dbg("vnc: dropping unknown", key, "key", name)
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
            logger.dbg("vnc: dropping an unusable connection profile")
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

--- Whether the server should start with KOReader. The environment's enable variable, when it has
--- an opinion, wins over the stored `autostart` setting; otherwise the stored setting decides.
--- @treturn boolean
function Settings:should_autostart()
    if self.env.enable ~= nil then return self.env.enable end
    return self.data.server.autostart == true
end

--- The server settings this *run* uses: the stored table with the environment overrides merged in.
---
--- The overrides live outside `data.server`, so `flush()` cannot persist them. Without an override
--- the stored table itself is returned, so the menu and a running server share it exactly as
--- before; with one, the run gets a snapshot and the menu keeps showing/editing the stored values.
--- @treturn table
function Settings:server_for_run()
    local stored = self.data.server
    local env = self.env
    if env.host == nil and env.port == nil and env.password == nil then
        return stored
    end
    return {
        ip = env.host ~= nil and env.host or stored.ip,
        port = env.port ~= nil and env.port or stored.port,
        password = env.password ~= nil and env.password or stored.password,
        autostart = stored.autostart,
    }
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

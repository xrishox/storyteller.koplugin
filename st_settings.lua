-- SPDX-License-Identifier: AGPL-3.0-or-later

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local Settings = {}

function Settings:new()
    local instance = setmetatable({}, { __index = self })
    instance.data = LuaSettings:open(
        DataStorage:getDataDir() .. "/storyteller.lua"
    )
    return instance
end

function Settings:getServerUrl()
    return self.data:readSetting("server_url")
end

function Settings:setServerUrl(url)
    self.data:saveSetting("server_url", url)
    self.data:flush()
end

function Settings:getToken()
    return self.data:readSetting("access_token")
end

function Settings:setToken(token)
    self.data:saveSetting("access_token", token)
    self.data:flush()
end

function Settings:getUsername()
    return self.data:readSetting("username")
end

function Settings:setUsername(username)
    self.data:saveSetting("username", username)
    self.data:flush()
end

function Settings:clearAuth()
    self.data:delSetting("access_token")
    self.data:delSetting("username")
    self.data:flush()
end

function Settings:isLoggedIn()
    return self.data:has("access_token")
end

function Settings:getSyncEnabled()
    return self.data:readSetting("sync_enabled", true)
end

function Settings:setSyncEnabled(enabled)
    self.data:saveSetting("sync_enabled", enabled)
    self.data:flush()
end

function Settings:getDownloadDir()
    return self.data:readSetting("download_dir")
end

function Settings:setDownloadDir(dir)
    self.data:saveSetting("download_dir", dir)
    self.data:flush()
end

function Settings:getPreferredFormat()
    return self.data:readSetting("preferred_format", "readaloud")
end

function Settings:setPreferredFormat(format_name)
    self.data:saveSetting("preferred_format", format_name)
    self.data:flush()
end

return Settings

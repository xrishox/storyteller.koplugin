-- SPDX-License-Identifier: AGPL-3.0-or-later

local DataStorage = require("datastorage")
local json = require("rapidjson")

local Log = {}

function Log:getPath()
    return DataStorage:getSettingsDir() .. "/storyteller.log"
end

function Log:_write(level, message, data)
    local handle = io.open(self:getPath(), "a")
    if not handle then
        return
    end

    local line = os.date("%Y-%m-%d %H:%M:%S") .. " [" .. tostring(level) .. "] " .. tostring(message)
    if data ~= nil then
        local ok, encoded = pcall(json.encode, data)
        if ok and encoded then
            line = line .. " " .. encoded
        else
            line = line .. " " .. tostring(data)
        end
    end

    handle:write(line .. "\n")
    handle:close()
end

function Log:info(message, data)
    self:_write("info", message, data)
end

function Log:warn(message, data)
    self:_write("warn", message, data)
end

function Log:error(message, data)
    self:_write("error", message, data)
end

return Log

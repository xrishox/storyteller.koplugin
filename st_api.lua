-- SPDX-License-Identifier: AGPL-3.0-or-later

local json = require("rapidjson")
local logger = require("logger")
local socketutil = require("socketutil")
local Log = require("st_log")

local Api = {}

function Api:new(settings)
    local instance = setmetatable({}, { __index = self })
    instance.settings = settings
    return instance
end

function Api:getBaseUrl()
    local base_url = self.settings:getServerUrl() or ""
    return base_url:gsub("/+$", "")
end

function Api:normalizeUrl(url)
    if not url or url == "" then
        return ""
    end
    if url:match("^https?://") then
        return url:gsub("/+$", "")
    end
    return ("http://%s"):format(url):gsub("/+$", "")
end

function Api:request(method, path, body, opts)
    local ltn12 = require("ltn12")

    opts = opts or {}
    local base_url = self:getBaseUrl()
    if base_url == "" then
        return false, "server_url_missing"
    end

    local url = base_url .. path
    local is_https = url:match("^https://") ~= nil
    local transport = is_https and require("ssl.https") or require("socket.http")
    local sink = {}
    Log:info("api_request", {
        method = method,
        path = path,
        url = url,
        authenticated = opts.authenticated ~= false,
        request_body = body,
    })

    local headers = {
        ["Accept"] = "application/json",
    }

    if opts.authenticated ~= false then
        local token = self.settings:getToken()
        if not token then
            return false, "not_authenticated"
        end
        headers["Authorization"] = "Bearer " .. token
    end

    local request_body
    if body then
        request_body = json.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = #request_body
    end

    socketutil:set_timeout(
        opts.timeout_block or socketutil.LARGE_BLOCK_TIMEOUT,
        opts.timeout_total or socketutil.LARGE_TOTAL_TIMEOUT
    )

    local request = {
        url = url,
        method = method,
        headers = headers,
        sink = socketutil.table_sink(sink),
    }
    if request_body then
        request.source = ltn12.source.string(request_body)
    end

    local _, code, response_headers, status = transport.request(request)
    socketutil:reset_timeout()

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("Storyteller: request timeout for", path)
        Log:warn("api_timeout", { method = method, path = path })
        return false, { error = "timeout" }
    end

    local response_body = table.concat(sink)
    local data = nil
    local decode_ok = false
    if response_body and #response_body > 0 then
        local ok_decode, decoded = pcall(json.decode, response_body)
        if ok_decode then
            data = decoded
            decode_ok = true
        end
    end

    local expected_codes = opts.expected_codes or {}
    if code == 200 or code == 201 or code == 204 or expected_codes[code] then
        Log:info("api_response", {
            method = method,
            path = path,
            url = url,
            status = code,
            status_line = status,
            headers = response_headers,
            decode_ok = decode_ok,
            body = data,
            raw_body = decode_ok and nil or response_body,
        })
        return true, data, response_headers, status, response_body
    end

    logger.warn("Storyteller: HTTP", code, "for", path)
    Log:warn("api_http_error", {
        method = method,
        path = path,
        url = url,
        status = code,
        status_line = status,
        headers = response_headers,
        decode_ok = decode_ok,
        body = data or response_body,
    })
    if data and type(data) == "table" then
        return false, data, response_headers, status, response_body
    end
    return false, {
        error = "http_error",
        status = code,
        body = response_body,
    }, response_headers, status, response_body
end

function Api:requestDeviceCode()
    return self:request("POST", "/api/v2/device/start", {}, { authenticated = false })
end

function Api:pollForToken(device_code)
    return self:request("POST", "/api/v2/device/token", {
        device_code = device_code,
    }, { authenticated = false, expected_codes = { [400] = true } })
end

function Api:getCurrentUser()
    return self:request("GET", "/api/v2/user")
end

function Api:listBooks()
    return self:request("GET", "/api/v2/books")
end

function Api:listCollections()
    return self:request("GET", "/api/v2/collections")
end

function Api:listSeries()
    return self:request("GET", "/api/v2/series")
end

function Api:getPosition(book_id)
    return self:request("GET", "/api/v2/books/" .. book_id .. "/positions", nil, {
        expected_codes = { [404] = true },
    })
end

function Api:updatePosition(book_id, payload)
    return self:request("POST", "/api/v2/books/" .. book_id .. "/positions", payload, {
        expected_codes = { [409] = true },
    })
end

function Api:getDownloadUrl(book_id, format_name)
    local base_url = self:getBaseUrl()
    if base_url == "" then
        return nil
    end
    return ("%s/api/v2/books/%s/files?format=%s"):format(base_url, book_id, format_name)
end

function Api:downloadFile(book_id, format_name, filepath)
    local ltn12 = require("ltn12")
    local url = self:getDownloadUrl(book_id, format_name)
    if not url then
        return false, "server_url_missing"
    end

    local token = self.settings:getToken()
    if not token then
        return false, "not_authenticated"
    end

    local is_https = url:match("^https://") ~= nil
    local transport = is_https and require("ssl.https") or require("socket.http")
    local file = io.open(filepath, "wb")
    if not file then
        Log:error("download_open_failed", { filepath = filepath })
        return false, "cannot_open_output"
    end
    Log:info("download_start", {
        book_id = book_id,
        format = format_name,
        filepath = filepath,
    })

    socketutil:set_timeout(
        socketutil.FILE_BLOCK_TIMEOUT,
        socketutil.FILE_TOTAL_TIMEOUT
    )

    local _, code, response_headers = transport.request{
        url = url,
        method = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Accept"] = "application/epub+zip,application/octet-stream",
        },
        sink = ltn12.sink.file(file),
    }
    socketutil:reset_timeout()

    if code == 200 or code == 206 then
        Log:info("download_complete", {
            book_id = book_id,
            format = format_name,
            filepath = filepath,
            status = code,
            headers = response_headers,
        })
        return true, response_headers
    end

    os.remove(filepath)
    Log:warn("download_failed", {
        book_id = book_id,
        format = format_name,
        filepath = filepath,
        status = code,
    })
    return false, { status = code }
end

return Api

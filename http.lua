--[[
    HTTP Request Handling for Control4 DriverWorks

    Provides HTTP GET/POST functionality using the legacy C4:urlGet/urlPost API
    which is more reliable for OS 2.10.6 compatibility.
]]--

local JSON = require("json")

local Http = {}

-- Pending HTTP request handlers (for legacy urlPost/urlGet API)
local g_PendingRequests = {}

-- Debug function reference (set via Http.setDebugFunction)
local dbgFunc = function(msg, ...) end
local logErrorFunc = function(msg, ...) end

-- Set debug functions from main driver
function Http.setDebugFunction(dbg, logError)
    dbgFunc = dbg or function(msg, ...) end
    logErrorFunc = logError or function(msg, ...) end
end

-- Build standard headers for Fire TV API
-- Note: Content-Length is added by HttpPost, not here
function Http.BuildHeaders(apiKey, clientToken, authenticated)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "*/*",
        ["x-api-key"] = apiKey
    }

    if authenticated and clientToken then
        headers["x-client-token"] = clientToken
    end

    return headers
end

-- Make HTTP GET request using legacy C4:urlGet API
-- This is more reliable for OS 2.10.6 compatibility
function Http.Get(url, headers, callback)
    dbgFunc("HTTP GET: %s", url)

    local requestHeaders = headers or {}

    -- Use legacy C4:urlGet API - signature: C4:urlGet(url, headers, allowSelfSignedCert)
    local ticket = C4:urlGet(url, requestHeaders, true)

    if ticket and ticket ~= 0 then
        -- Store callback for when response arrives via ReceivedAsync
        table.insert(g_PendingRequests, {
            ticket = ticket,
            callback = callback,
            url = url,
            method = "GET"
        })
        dbgFunc("HTTP GET queued with ticket: %s", tostring(ticket))
    else
        logErrorFunc("HTTP GET failed to send: no ticket returned")
        if callback then
            callback(false, nil, nil, "Failed to send request")
        end
    end
end

-- Make HTTP POST request using legacy C4:urlPost API
-- This is more reliable for OS 2.10.6 compatibility
function Http.Post(url, data, headers, callback)
    local body = data or ""

    if type(data) == "table" then
        body = JSON.encode(data)
    end

    dbgFunc("HTTP POST: %s", url)
    dbgFunc("HTTP POST Body (%d bytes): %s", #body, body)

    local requestHeaders = headers or {}

    -- Debug: log all headers being sent
    for k, v in pairs(requestHeaders) do
        dbgFunc("HTTP Header: %s: %s", k, v)
    end

    -- Use legacy C4:urlPost API - signature: C4:urlPost(url, data, headers, allowSelfSignedCert)
    -- The 4th parameter enables self-signed cert support for HTTPS
    local ticket = C4:urlPost(url, body, requestHeaders, true)

    if ticket and ticket ~= 0 then
        -- Store callback for when response arrives via ReceivedAsync
        table.insert(g_PendingRequests, {
            ticket = ticket,
            callback = callback,
            url = url,
            method = "POST"
        })
        dbgFunc("HTTP POST queued with ticket: %s", tostring(ticket))
    else
        logErrorFunc("HTTP POST failed to send: no ticket returned")
        if callback then
            callback(false, nil, nil, "Failed to send request")
        end
    end
end

-- ReceivedAsync callback for legacy C4:urlPost/C4:urlGet API
-- This is called by Control4 when an HTTP request completes
-- Note: This must be exposed as a global function in the main driver
function Http.HandleReceivedAsync(ticketId, strData, responseCode, tHeaders, strError)
    dbgFunc("ReceivedAsync: ticket=%s, code=%s, error=%s",
        tostring(ticketId), tostring(responseCode), tostring(strError))

    -- Find the matching request
    for i, request in ipairs(g_PendingRequests) do
        if request.ticket == ticketId then
            -- Remove from pending list
            table.remove(g_PendingRequests, i)

            -- Determine success
            local success = (strError == nil or strError == "") and
                           responseCode and responseCode >= 200 and responseCode < 300

            dbgFunc("HTTP Response: code=%s, body=%s", tostring(responseCode), tostring(strData))

            -- Call the callback
            if request.callback then
                request.callback(success, strData, responseCode, strError)
            end
            return
        end
    end

    dbgFunc("ReceivedAsync: No matching request for ticket %s", tostring(ticketId))
end

return Http

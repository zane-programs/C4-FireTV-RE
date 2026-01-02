--[[
    Fire TV Remote Control Driver for Control4

    This driver implements the Fire TV Remote Control protocol,
    allowing Control4 systems to control Amazon Fire TV devices.

    Protocol based on reverse-engineering of the official Fire TV Remote app.

    Compatible with Control4 OS 2.10.6+
]]--

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

DRIVER_NAME = "Fire TV Remote"
DRIVER_VERSION = "1.0.0"

-- Fire TV API Configuration
API_KEY = "0987654321"  -- Hardcoded in official app
DIAL_PORT = 8009        -- Wake/DIAL protocol port
API_PORT = 8080         -- HTTPS API port

-- Key action types for D-pad buttons
KEY_ACTION_DOWN = "keyDown"
KEY_ACTION_UP = "keyUp"

-- Default timing values (milliseconds)
DEFAULT_KEY_DELAY = 50    -- Delay between keyDown and keyUp
DEFAULT_CHAR_DELAY = 50   -- Delay between characters when typing
DEFAULT_WAKE_WAIT = 2000  -- Wait after wake before retry

-- Network binding ID
NET_BINDING_ID = 6001

--------------------------------------------------------------------------------
-- Global State
--------------------------------------------------------------------------------

g_FireTV = {
    host = nil,
    clientToken = nil,
    connected = false,
    paired = false,
    lastWakeTime = 0,
    autoWake = true,
    timeout = 10,
    debugMode = false,
    friendlyName = "Control4"
}

g_Timers = {}

--------------------------------------------------------------------------------
-- Debug Logging
--------------------------------------------------------------------------------

function dbg(msg, ...)
    if g_FireTV.debugMode then
        local formattedMsg = string.format(msg or "", ...)
        print("[" .. DRIVER_NAME .. "] " .. formattedMsg)
        C4:DebugLog("[" .. DRIVER_NAME .. "] " .. formattedMsg)
    end
end

function log(msg, ...)
    local formattedMsg = string.format(msg or "", ...)
    print("[" .. DRIVER_NAME .. "] " .. formattedMsg)
end

function logError(msg, ...)
    local formattedMsg = string.format(msg or "", ...)
    print("[" .. DRIVER_NAME .. "] ERROR: " .. formattedMsg)
    C4:DebugLog("[" .. DRIVER_NAME .. "] ERROR: " .. formattedMsg)
end

--------------------------------------------------------------------------------
-- Simple JSON Library (OS 2.10.6 Compatible)
--------------------------------------------------------------------------------

JSON = {}

function JSON.encode(val)
    local t = type(val)

    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        -- Escape special characters
        local escaped = val:gsub('\\', '\\\\')
                           :gsub('"', '\\"')
                           :gsub('\n', '\\n')
                           :gsub('\r', '\\r')
                           :gsub('\t', '\\t')
        return '"' .. escaped .. '"'
    elseif t == "table" then
        -- Check if array or object
        local isArray = true
        local maxIndex = 0
        for k, v in pairs(val) do
            if type(k) ~= "number" then
                isArray = false
                break
            end
            maxIndex = math.max(maxIndex, k)
        end

        if isArray and maxIndex > 0 then
            -- Array
            local items = {}
            for i = 1, maxIndex do
                table.insert(items, JSON.encode(val[i]))
            end
            return "[" .. table.concat(items, ",") .. "]"
        else
            -- Object
            local pairs_list = {}
            for k, v in pairs(val) do
                local key = type(k) == "string" and k or tostring(k)
                table.insert(pairs_list, '"' .. key .. '":' .. JSON.encode(v))
            end
            return "{" .. table.concat(pairs_list, ",") .. "}"
        end
    else
        return "null"
    end
end

function JSON.decode(str)
    if str == nil or str == "" then
        return nil
    end

    local pos = 1
    local len = #str

    local function skipWhitespace()
        while pos <= len and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local function parseValue()
        skipWhitespace()

        if pos > len then
            return nil
        end

        local char = str:sub(pos, pos)

        if char == '"' then
            return parseString()
        elseif char == '{' then
            return parseObject()
        elseif char == '[' then
            return parseArray()
        elseif char == 't' then
            if str:sub(pos, pos + 3) == "true" then
                pos = pos + 4
                return true
            end
        elseif char == 'f' then
            if str:sub(pos, pos + 4) == "false" then
                pos = pos + 5
                return false
            end
        elseif char == 'n' then
            if str:sub(pos, pos + 3) == "null" then
                pos = pos + 4
                return nil
            end
        elseif char == '-' or char:match("%d") then
            return parseNumber()
        end

        return nil
    end

    function parseString()
        pos = pos + 1  -- Skip opening quote
        local result = ""

        while pos <= len do
            local char = str:sub(pos, pos)

            if char == '"' then
                pos = pos + 1
                return result
            elseif char == '\\' then
                pos = pos + 1
                local escaped = str:sub(pos, pos)
                if escaped == 'n' then
                    result = result .. '\n'
                elseif escaped == 'r' then
                    result = result .. '\r'
                elseif escaped == 't' then
                    result = result .. '\t'
                elseif escaped == '\\' then
                    result = result .. '\\'
                elseif escaped == '"' then
                    result = result .. '"'
                elseif escaped == 'u' then
                    -- Unicode escape (simplified)
                    local hex = str:sub(pos + 1, pos + 4)
                    local codepoint = tonumber(hex, 16)
                    if codepoint then
                        if codepoint < 128 then
                            result = result .. string.char(codepoint)
                        else
                            result = result .. "?"  -- Simplified unicode handling
                        end
                    end
                    pos = pos + 4
                else
                    result = result .. escaped
                end
            else
                result = result .. char
            end
            pos = pos + 1
        end

        return result
    end

    function parseNumber()
        local startPos = pos

        if str:sub(pos, pos) == '-' then
            pos = pos + 1
        end

        while pos <= len and str:sub(pos, pos):match("%d") do
            pos = pos + 1
        end

        if pos <= len and str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= len and str:sub(pos, pos):match("%d") do
                pos = pos + 1
            end
        end

        if pos <= len and str:sub(pos, pos):lower() == 'e' then
            pos = pos + 1
            if str:sub(pos, pos):match("[+-]") then
                pos = pos + 1
            end
            while pos <= len and str:sub(pos, pos):match("%d") do
                pos = pos + 1
            end
        end

        return tonumber(str:sub(startPos, pos - 1))
    end

    function parseArray()
        pos = pos + 1  -- Skip [
        local result = {}

        skipWhitespace()
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return result
        end

        while true do
            local value = parseValue()
            table.insert(result, value)

            skipWhitespace()
            local char = str:sub(pos, pos)

            if char == ']' then
                pos = pos + 1
                return result
            elseif char == ',' then
                pos = pos + 1
            else
                break
            end
        end

        return result
    end

    function parseObject()
        pos = pos + 1  -- Skip {
        local result = {}

        skipWhitespace()
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return result
        end

        while true do
            skipWhitespace()

            -- Parse key
            if str:sub(pos, pos) ~= '"' then
                break
            end
            local key = parseString()

            skipWhitespace()
            if str:sub(pos, pos) ~= ':' then
                break
            end
            pos = pos + 1  -- Skip :

            -- Parse value
            local value = parseValue()
            result[key] = value

            skipWhitespace()
            local char = str:sub(pos, pos)

            if char == '}' then
                pos = pos + 1
                return result
            elseif char == ',' then
                pos = pos + 1
            else
                break
            end
        end

        return result
    end

    return parseValue()
end

--------------------------------------------------------------------------------
-- Timer Utilities
--------------------------------------------------------------------------------

function SetTimer(name, interval, callback, recurring)
    KillTimer(name)

    local timer = C4:SetTimer(interval, function(timerInfo)
        if not recurring then
            g_Timers[name] = nil
        end
        if callback then
            callback()
        end
    end, recurring or false)

    g_Timers[name] = timer
    return timer
end

function KillTimer(name)
    if g_Timers[name] then
        g_Timers[name]:Cancel()
        g_Timers[name] = nil
    end
end

function KillAllTimers()
    for name, timer in pairs(g_Timers) do
        if timer then
            timer:Cancel()
        end
    end
    g_Timers = {}
end

--------------------------------------------------------------------------------
-- HTTP Request Handling (C4:url() interface - OS 2.10.5+)
--------------------------------------------------------------------------------

-- Build standard headers for Fire TV API
-- Note: Content-Length is added by HttpPost, not here
function BuildHeaders(authenticated)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "*/*",
        ["x-api-key"] = API_KEY
    }

    if authenticated and g_FireTV.clientToken then
        headers["x-client-token"] = g_FireTV.clientToken
    end

    return headers
end

-- Make HTTP GET request using C4:url() interface
function HttpGet(url, headers, callback)
    dbg("HTTP GET: %s", url)

    local requestHeaders = headers or {}

    C4:url()
        :SetOption("timeout", g_FireTV.timeout)
        :SetOption("fail_on_error", false)
        :SetOption("ssl_verify_peer", false)  -- Fire TV uses self-signed certs
        :SetOption("ssl_verify_host", false)
        :OnDone(function(transfer, responses, errCode, errMsg)
            local success = false
            local responseCode = nil
            local responseBody = nil
            local errorStr = errMsg

            if errCode == 0 and responses and #responses > 0 then
                local lastResponse = responses[#responses]
                responseCode = lastResponse.code
                responseBody = lastResponse.body
                success = responseCode and responseCode >= 200 and responseCode < 300
            end

            dbg("HTTP GET Response: code=%s, errCode=%s, errMsg=%s",
                tostring(responseCode), tostring(errCode), tostring(errMsg))

            if callback then
                callback(success, responseBody, responseCode, errorStr)
            end
        end)
        :Get(url, requestHeaders)
end

-- Make HTTP POST request using C4:url() interface
-- Note: For OS 2.10.6 compatibility, we explicitly set Content-Length header
function HttpPost(url, data, headers, callback)
    local body = data or ""

    if type(data) == "table" then
        body = JSON.encode(data)
    end

    dbg("HTTP POST: %s", url)
    dbg("HTTP POST Body (%d bytes): %s", #body, body)

    -- Debug: show first few bytes as hex to detect encoding issues
    if #body > 0 then
        local hexBytes = {}
        for i = 1, math.min(20, #body) do
            table.insert(hexBytes, string.format("%02X", string.byte(body, i)))
        end
        dbg("HTTP POST Body hex: %s", table.concat(hexBytes, " "))
    end

    -- Merge provided headers with Content-Length
    local requestHeaders = headers or {}
    if body ~= "" then
        requestHeaders["Content-Length"] = tostring(#body)
    end

    -- Debug: log all headers being sent
    for k, v in pairs(requestHeaders) do
        dbg("HTTP Header: %s: %s", k, v)
    end

    local ok, err = pcall(function()
        C4:url()
            :SetOption("timeout", g_FireTV.timeout)
            :SetOption("fail_on_error", false)
            :SetOption("ssl_verify_peer", false)  -- Fire TV uses self-signed certs
            :SetOption("ssl_verify_host", false)
            :OnDone(function(transfer, responses, errCode, errMsg)
                local success = false
                local responseCode = nil
                local responseBody = nil
                local errorStr = errMsg

                if errCode == 0 and responses and #responses > 0 then
                    local lastResponse = responses[#responses]
                    responseCode = lastResponse.code
                    responseBody = lastResponse.body
                    success = responseCode and responseCode >= 200 and responseCode < 300
                end

                dbg("HTTP POST Response: code=%s, errCode=%s, errMsg=%s, body=%s",
                    tostring(responseCode), tostring(errCode), tostring(errMsg), tostring(responseBody))

                if callback then
                    callback(success, responseBody, responseCode, errorStr)
                end
            end)
            :Post(url, body, requestHeaders)
    end)

    if not ok then
        logError("HTTP POST failed to send: %s", tostring(err))
        if callback then
            callback(false, nil, nil, tostring(err))
        end
    end
end

--------------------------------------------------------------------------------
-- Fire TV Protocol Implementation
--------------------------------------------------------------------------------

-- Build Fire TV API URL
function BuildApiUrl(path)
    return string.format("https://%s:%d%s", g_FireTV.host, API_PORT, path)
end

-- Build DIAL URL (for wake)
function BuildDialUrl(path)
    return string.format("http://%s:%d%s", g_FireTV.host, DIAL_PORT, path)
end

-- Wake the Fire TV remote receiver app via DIAL protocol
function WakeFireTV(callback)
    if not g_FireTV.host then
        logError("Cannot wake: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    local url = BuildDialUrl("/apps/FireTVRemote")
    local headers = {["Content-Type"] = "text/plain"}

    dbg("Waking Fire TV at %s", g_FireTV.host)

    HttpPost(url, "", headers, function(success, data, code, error)
        if success or code == 201 then
            dbg("Fire TV wake successful")
            g_FireTV.lastWakeTime = os.time()
            UpdateConnectionStatus(true)
            if callback then callback(true) end
        else
            dbg("Fire TV wake failed: %s", tostring(error))
            if callback then callback(false) end
        end
    end)
end

-- Ensure device is awake before making API calls
function EnsureAwake(callback)
    if not g_FireTV.autoWake then
        if callback then callback(true) end
        return
    end

    -- Wake if we haven't recently
    local now = os.time()
    if now - g_FireTV.lastWakeTime > 30 then
        WakeFireTV(function(success)
            if success then
                -- Wait a bit after wake before continuing
                SetTimer("wake_wait", DEFAULT_WAKE_WAIT, function()
                    if callback then callback(true) end
                end)
            else
                if callback then callback(false) end
            end
        end)
    else
        if callback then callback(true) end
    end
end

-- Request PIN display on Fire TV for pairing
function RequestPin(callback)
    if not g_FireTV.host then
        logError("Cannot request PIN: No Fire TV IP address configured")
        C4:UpdateProperty("Pairing Status", "Error: No IP Address")
        if callback then callback(false) end
        return
    end

    log("Requesting PIN display on Fire TV")
    C4:UpdateProperty("Pairing Status", "Requesting PIN...")

    EnsureAwake(function(awake)
        if not awake then
            C4:UpdateProperty("Pairing Status", "Error: Cannot wake device")
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/FireTV/pin/display")
        local headers = BuildHeaders(false)
        local body = {friendlyName = g_FireTV.friendlyName}

        HttpPost(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    log("PIN requested successfully - check Fire TV screen")
                    C4:UpdateProperty("Pairing Status", "Enter PIN from TV screen")
                    if callback then callback(true) end
                else
                    logError("PIN request failed: unexpected response")
                    C4:UpdateProperty("Pairing Status", "Error: PIN request failed")
                    if callback then callback(false) end
                end
            else
                logError("PIN request failed: %s", tostring(error))
                C4:UpdateProperty("Pairing Status", "Error: " .. tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Verify PIN and complete pairing
function VerifyPin(pin, callback)
    if not g_FireTV.host then
        logError("Cannot verify PIN: No Fire TV IP address configured")
        C4:UpdateProperty("Pairing Status", "Error: No IP Address")
        if callback then callback(false) end
        return
    end

    if not pin or pin == "" then
        logError("Cannot verify PIN: No PIN provided")
        C4:UpdateProperty("Pairing Status", "Error: No PIN entered")
        if callback then callback(false) end
        return
    end

    -- Clean up PIN (remove spaces, etc.)
    pin = pin:gsub("%s+", "")

    log("Verifying PIN: %s", pin)
    C4:UpdateProperty("Pairing Status", "Verifying PIN...")

    EnsureAwake(function(awake)
        if not awake then
            C4:UpdateProperty("Pairing Status", "Error: Cannot wake device")
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/FireTV/pin/verify")
        local headers = BuildHeaders(false)
        local body = {pin = pin}

        HttpPost(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description and response.description ~= "" then
                    -- Success! description contains the client token
                    local token = response.description
                    log("Pairing successful! Token received.")

                    g_FireTV.clientToken = token
                    g_FireTV.paired = true

                    -- Persist the token
                    PersistData.clientToken = token
                    PersistData.host = g_FireTV.host

                    C4:UpdateProperty("Pairing Status", "Paired")
                    C4:UpdateProperty("PIN Code", "")  -- Clear PIN field

                    -- Fire paired event
                    C4:FireEvent("Paired")

                    -- Get device info
                    RefreshDeviceInfo()

                    if callback then callback(true) end
                else
                    logError("PIN verification failed: Invalid PIN")
                    C4:UpdateProperty("Pairing Status", "Error: Invalid PIN")
                    C4:FireEvent("Pairing Failed")
                    if callback then callback(false) end
                end
            else
                logError("PIN verification failed: %s", tostring(error))
                C4:UpdateProperty("Pairing Status", "Error: " .. tostring(error))
                C4:FireEvent("Pairing Failed")
                if callback then callback(false) end
            end
        end)
    end)
end

-- Get device status
function GetStatus(callback)
    if not g_FireTV.host then
        if callback then callback(false, nil) end
        return
    end

    local url = BuildApiUrl("/v1/FireTV/status")
    local headers = BuildHeaders(true)

    HttpGet(url, headers, function(success, data, code, error)
        if success then
            local status = JSON.decode(data)
            dbg("Device status: %s", data)
            if callback then callback(true, status) end
        else
            dbg("Failed to get status: %s", tostring(error))
            if callback then callback(false, nil) end
        end
    end)
end

-- Get device properties
function GetProperties(callback)
    if not g_FireTV.host then
        if callback then callback(false, nil) end
        return
    end

    local url = BuildApiUrl("/v1/FireTV/properties")
    local headers = BuildHeaders(true)

    HttpGet(url, headers, function(success, data, code, error)
        if success then
            local props = JSON.decode(data)
            dbg("Device properties: %s", data)
            if callback then callback(true, props) end
        else
            dbg("Failed to get properties: %s", tostring(error))
            if callback then callback(false, nil) end
        end
    end)
end

-- Refresh device information
function RefreshDeviceInfo()
    EnsureAwake(function(awake)
        if not awake then return end

        GetProperties(function(success, props)
            if success and props then
                local name = props.pfm or "Fire TV"
                C4:UpdateProperty("Fire TV Name", name)
            end
        end)
    end)
end

-- Send a key command
function SendKey(action, keyAction, callback)
    if not g_FireTV.host then
        logError("Cannot send key: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    if not g_FireTV.paired then
        logError("Cannot send key: Not paired with Fire TV")
        if callback then callback(false) end
        return
    end

    EnsureAwake(function(awake)
        if not awake then
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/FireTV?action=" .. action)
        local headers = BuildHeaders(true)
        local body = {}

        if keyAction then
            body.keyActionType = keyAction
        end

        HttpPost(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    dbg("Key %s (%s) sent successfully", action, keyAction or "press")
                    if callback then callback(true) end
                else
                    dbg("Key %s failed: unexpected response", action)
                    if callback then callback(false) end
                end
            else
                dbg("Key %s failed: %s", action, tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Send D-pad key (requires keyDown + keyUp)
function SendDpadKey(action, callback)
    SendKey(action, KEY_ACTION_DOWN, function(success)
        if not success then
            if callback then callback(false) end
            return
        end

        -- Small delay between keyDown and keyUp
        SetTimer("dpad_" .. action, DEFAULT_KEY_DELAY, function()
            SendKey(action, KEY_ACTION_UP, callback)
        end)
    end)
end

-- Send system key (no keyDown/keyUp needed)
function SendSystemKey(action, callback)
    SendKey(action, nil, callback)
end

-- Send media command
function SendMediaCommand(action, params, callback)
    if not g_FireTV.host then
        logError("Cannot send media command: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    if not g_FireTV.paired then
        logError("Cannot send media command: Not paired with Fire TV")
        if callback then callback(false) end
        return
    end

    EnsureAwake(function(awake)
        if not awake then
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/media?action=" .. action)
        local headers = BuildHeaders(true)
        local body = params or {}

        HttpPost(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    dbg("Media %s sent successfully", action)
                    if callback then callback(true) end
                else
                    dbg("Media %s failed: unexpected response", action)
                    if callback then callback(false) end
                end
            else
                dbg("Media %s failed: %s", action, tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Send a single character
function SendCharacter(char, callback)
    if not g_FireTV.host then
        logError("Cannot send character: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    if not g_FireTV.paired then
        logError("Cannot send character: Not paired with Fire TV")
        if callback then callback(false) end
        return
    end

    EnsureAwake(function(awake)
        if not awake then
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/FireTV/text")
        local headers = BuildHeaders(true)
        local body = {text = char}

        HttpPost(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    dbg("Character '%s' sent successfully", char)
                    if callback then callback(true) end
                else
                    dbg("Character send failed: unexpected response")
                    if callback then callback(false) end
                end
            else
                dbg("Character send failed: %s", tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Send text string (one character at a time)
function SendText(text, callback, charIndex)
    charIndex = charIndex or 1

    if charIndex > #text then
        if callback then callback(true) end
        return
    end

    local char = text:sub(charIndex, charIndex)

    SendCharacter(char, function(success)
        if not success then
            if callback then callback(false) end
            return
        end

        -- Small delay between characters
        SetTimer("text_char_" .. charIndex, DEFAULT_CHAR_DELAY, function()
            SendText(text, callback, charIndex + 1)
        end)
    end)
end

--------------------------------------------------------------------------------
-- Connection Status
--------------------------------------------------------------------------------

function UpdateConnectionStatus(connected)
    local prevConnected = g_FireTV.connected
    g_FireTV.connected = connected

    if connected then
        C4:UpdateProperty("Connection Status", "Connected")
        if not prevConnected then
            C4:FireEvent("Connection Restored")
        end
    else
        C4:UpdateProperty("Connection Status", "Not Connected")
        if prevConnected then
            C4:FireEvent("Connection Lost")
        end
    end
end

function TestConnection(callback)
    if not g_FireTV.host then
        C4:UpdateProperty("Connection Status", "Not Connected")
        if callback then callback(false) end
        return
    end

    WakeFireTV(function(success)
        if success then
            GetStatus(function(statusSuccess, status)
                if statusSuccess then
                    C4:UpdateProperty("Connection Status", "Connected")
                    log("Connection test successful")
                    if callback then callback(true) end
                else
                    C4:UpdateProperty("Connection Status", "Error: Cannot get status")
                    if callback then callback(false) end
                end
            end)
        else
            C4:UpdateProperty("Connection Status", "Error: Cannot wake device")
            if callback then callback(false) end
        end
    end)
end

--------------------------------------------------------------------------------
-- Driver Lifecycle
--------------------------------------------------------------------------------

function OnDriverInit()
    log("Driver initializing...")
    C4:UpdateProperty("Driver Version", DRIVER_VERSION)
end

function OnDriverLateInit()
    log("Driver late init...")

    -- Initialize PersistData
    if PersistData == nil then
        PersistData = {}
    end

    -- Restore saved state
    if PersistData.clientToken then
        g_FireTV.clientToken = PersistData.clientToken
        g_FireTV.paired = true
        C4:UpdateProperty("Pairing Status", "Paired")
        log("Restored pairing token from persistent storage")
    end

    if PersistData.host then
        g_FireTV.host = PersistData.host
        C4:UpdateProperty("Fire TV IP Address", g_FireTV.host)
    end

    -- Initialize properties
    for property, _ in pairs(Properties) do
        OnPropertyChanged(property)
    end

    log("Driver initialized successfully")
end

function OnDriverDestroyed()
    log("Driver being destroyed...")
    KillAllTimers()
end

--------------------------------------------------------------------------------
-- Property Handling
--------------------------------------------------------------------------------

function OnPropertyChanged(strProperty)
    local value = Properties[strProperty]

    dbg("Property changed: %s = %s", strProperty, tostring(value))

    if strProperty == "Fire TV IP Address" then
        if value and value ~= "" then
            g_FireTV.host = value
            PersistData.host = value

            -- If we have a saved token for this host, use it
            if PersistData.clientToken then
                g_FireTV.clientToken = PersistData.clientToken
                g_FireTV.paired = true
                C4:UpdateProperty("Pairing Status", "Paired")
            else
                g_FireTV.paired = false
                C4:UpdateProperty("Pairing Status", "Not Paired")
            end

            C4:UpdateProperty("Connection Status", "Not Connected")
        else
            g_FireTV.host = nil
            C4:UpdateProperty("Connection Status", "Not Connected")
        end

    elseif strProperty == "Controller Name" then
        g_FireTV.friendlyName = value or "Control4"

    elseif strProperty == "Command Timeout" then
        local timeout = tonumber(value) or 10
        g_FireTV.timeout = timeout
        -- Timeout is now set per-request in HttpGet/HttpPost using C4:url():SetOption()

    elseif strProperty == "Auto Wake" then
        g_FireTV.autoWake = (value == "Yes")

    elseif strProperty == "Debug Mode" then
        g_FireTV.debugMode = (value == "On")
        if g_FireTV.debugMode then
            log("Debug mode enabled")
        end
    end
end

--------------------------------------------------------------------------------
-- Command Handling
--------------------------------------------------------------------------------

function ExecuteCommand(strCommand, tParams)
    tParams = tParams or {}

    dbg("ExecuteCommand: %s", strCommand)

    -- Handle LUA_ACTION (for actions from Composer)
    if strCommand == "LUA_ACTION" then
        if tParams.ACTION then
            strCommand = tParams.ACTION
            tParams.ACTION = nil
        end
    end

    -- Pairing commands
    if strCommand == "StartPairing" then
        RequestPin()

    elseif strCommand == "VerifyPIN" then
        local pin = Properties["PIN Code"]
        VerifyPin(pin)

    elseif strCommand == "TestConnection" then
        TestConnection()

    elseif strCommand == "RefreshDeviceInfo" then
        RefreshDeviceInfo()

    elseif strCommand == "ClearPairing" then
        g_FireTV.clientToken = nil
        g_FireTV.paired = false
        PersistData.clientToken = nil
        C4:UpdateProperty("Pairing Status", "Not Paired")
        log("Pairing credentials cleared")

    -- Navigation commands
    elseif strCommand == "Up" then
        SendDpadKey("dpad_up")

    elseif strCommand == "Down" then
        SendDpadKey("dpad_down")

    elseif strCommand == "Left" then
        SendDpadKey("dpad_left")

    elseif strCommand == "Right" then
        SendDpadKey("dpad_right")

    elseif strCommand == "Select" then
        SendDpadKey("select")

    -- System commands
    elseif strCommand == "Home" then
        SendSystemKey("home")

    elseif strCommand == "Back" then
        SendSystemKey("back")

    elseif strCommand == "Menu" then
        SendSystemKey("menu")

    -- Media commands
    elseif strCommand == "PlayPause" or strCommand == "Play" or strCommand == "Pause" then
        SendMediaCommand("play")

    elseif strCommand == "Stop" then
        SendMediaCommand("stop")

    elseif strCommand == "FastForward" then
        local seconds = tonumber(tParams.Seconds) or 10
        SendMediaCommand("scan", {
            direction = "forward",
            durationInSeconds = tostring(seconds),
            speed = "1"
        })

    elseif strCommand == "Rewind" then
        local seconds = tonumber(tParams.Seconds) or 10
        SendMediaCommand("scan", {
            direction = "back",
            durationInSeconds = tostring(seconds),
            speed = "1"
        })

    -- Text input commands
    elseif strCommand == "SendText" then
        local text = tParams.Text
        if text and text ~= "" then
            SendText(text)
        end

    elseif strCommand == "SendCharacter" then
        local char = tParams.Character
        if char and char ~= "" then
            SendCharacter(char:sub(1, 1))
        end

    -- Utility commands
    elseif strCommand == "Wake" then
        WakeFireTV()

    else
        dbg("Unknown command: %s", strCommand)
    end
end

--------------------------------------------------------------------------------
-- Proxy Communication
--------------------------------------------------------------------------------

-- Binding IDs
PROXY_BINDING_ID = 5001
VIDEO_OUTPUT_BINDING_ID = 2000
AUDIO_OUTPUT_BINDING_ID = 4000

function ReceivedFromProxy(idBinding, strCommand, tParams)
    dbg("ReceivedFromProxy: binding=%d, command=%s", idBinding, strCommand)

    if tParams then
        for k, v in pairs(tParams) do
            dbg("  Param: %s = %s", tostring(k), tostring(v))
        end
    end

    if idBinding == PROXY_BINDING_ID then
        -- Handle room ON/OFF commands from cable proxy
        if strCommand == "ON" then
            log("Room activated - waking Fire TV")
            WakeFireTV(function(success)
                if success then
                    -- Optionally go to home screen when room turns on
                    SendSystemKey("home")
                end
            end)

        elseif strCommand == "OFF" then
            log("Room deactivated")
            -- Fire TV doesn't have a true power off via this protocol
            -- Could pause media or go home if desired
            -- SendMediaCommand("pause")

        -- Handle input selection commands
        elseif strCommand == "INPUT_SELECTION" then
            -- Fire TV is a single-input device, just wake it
            WakeFireTV()

        -- Standard remote control commands
        else
            ExecuteCommand(strCommand, tParams)
        end
    end
end

--------------------------------------------------------------------------------
-- Binding Change Handler (for AV connections)
--------------------------------------------------------------------------------

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)
    dbg("OnBindingChanged: binding=%d, class=%s, bound=%s, otherDevice=%s, otherBinding=%s",
        idBinding, strClass, tostring(bIsBound), tostring(otherDeviceID), tostring(otherBindingID))

    if idBinding == VIDEO_OUTPUT_BINDING_ID then
        if bIsBound then
            log("HDMI video output connected to device %d", otherDeviceID)
        else
            log("HDMI video output disconnected")
        end
    elseif idBinding == AUDIO_OUTPUT_BINDING_ID then
        if bIsBound then
            log("Audio output connected to device %d", otherDeviceID)
        else
            log("Audio output disconnected")
        end
    end
end

--------------------------------------------------------------------------------
-- Network Communication (for advanced usage)
--------------------------------------------------------------------------------

function ReceivedFromNetwork(idBinding, nPort, strData)
    dbg("ReceivedFromNetwork: binding=%d, port=%d, data=%s", idBinding, nPort, strData)
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    dbg("OnConnectionStatusChanged: binding=%d, port=%d, status=%s", idBinding, nPort, strStatus)
end

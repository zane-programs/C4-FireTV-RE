--[[
    Fire TV Protocol Implementation

    This module implements the Fire TV Remote Control protocol,
    based on reverse-engineering of the official Fire TV Remote app.
]]--

local JSON = require("json")
local Http = require("http")
local Timers = require("timers")

local FireTV = {}

-- Constants
local API_KEY = "0987654321"  -- Hardcoded in official app
local DIAL_PORT = 8009        -- Wake/DIAL protocol port
local API_PORT = 8080         -- HTTPS API port

-- Key action types for D-pad buttons
local KEY_ACTION_DOWN = "keyDown"
local KEY_ACTION_UP = "keyUp"

-- Default timing values (milliseconds)
local DEFAULT_KEY_DELAY = 50    -- Delay between keyDown and keyUp
local DEFAULT_CHAR_DELAY = 50   -- Delay between characters when typing
local DEFAULT_WAKE_WAIT = 2000  -- Wait after wake before retry

-- Note that the below is in seconds!!!
local DEFAULT_WAKE_THRESHOLD_SEC = 30  -- Time before auto-wake (SECONDS)

-- Debug function references (set via FireTV.setDebugFunctions)
local dbgFunc = function(msg, ...) end
local logFunc = function(msg, ...) end
local logErrorFunc = function(msg, ...) end

-- State reference (set via FireTV.setState)
local g_FireTV = nil

-- Set debug functions from main driver
function FireTV.setDebugFunctions(dbg, log, logError)
    dbgFunc = dbg or function(msg, ...) end
    logFunc = log or function(msg, ...) end
    logErrorFunc = logError or function(msg, ...) end
    -- Also pass to Http module
    Http.setDebugFunction(dbg, logError)
end

-- Set state reference from main driver
function FireTV.setState(state)
    g_FireTV = state
end

-- Build Fire TV API URL
local function BuildApiUrl(path)
    return string.format("https://%s:%d%s", g_FireTV.host, API_PORT, path)
end

-- Build DIAL URL (for wake)
local function BuildDialUrl(path)
    return string.format("http://%s:%d%s", g_FireTV.host, DIAL_PORT, path)
end

-- Build headers for authenticated requests
local function BuildHeaders(authenticated)
    return Http.BuildHeaders(API_KEY, g_FireTV.clientToken, authenticated)
end

-- Wake the Fire TV remote receiver app via DIAL protocol
function FireTV.Wake(callback)
    if not g_FireTV.host then
        logErrorFunc("Cannot wake: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    local url = BuildDialUrl("/apps/FireTVRemote")
    local headers = {["Content-Type"] = "text/plain"}

    dbgFunc("Waking Fire TV at %s", g_FireTV.host)

    Http.Post(url, "", headers, function(success, data, code, error)
        if success or code == 201 then
            dbgFunc("Fire TV wake successful")
            g_FireTV.lastWakeTime = os.time()
            FireTV.UpdateConnectionStatus(true)
            if callback then callback(true) end
        else
            dbgFunc("Fire TV wake failed: %s", tostring(error))
            if callback then callback(false) end
        end
    end)
end

-- Ensure device is awake before making API calls
function FireTV.EnsureAwake(callback)
    if not g_FireTV.autoWake then
        if callback then callback(true) end
        return
    end

    -- Wake if we haven't recently
    local now = os.time()
    if now - g_FireTV.lastWakeTime > DEFAULT_WAKE_THRESHOLD_SEC then
        FireTV.Wake(function(success)
            if success then
                -- Wait a bit after wake before continuing
                Timers.SetTimer("wake_wait", DEFAULT_WAKE_WAIT, function()
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
function FireTV.RequestPin(callback)
    if not g_FireTV.host then
        logErrorFunc("Cannot request PIN: No Fire TV IP address configured")
        C4:UpdateProperty("Pairing Status", "Error: No IP Address")
        if callback then callback(false) end
        return
    end

    logFunc("Requesting PIN display on Fire TV")
    C4:UpdateProperty("Pairing Status", "Requesting PIN...")

    FireTV.EnsureAwake(function(awake)
        if not awake then
            C4:UpdateProperty("Pairing Status", "Error: Cannot wake device")
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/FireTV/pin/display")
        local headers = BuildHeaders(false)
        local body = {friendlyName = g_FireTV.friendlyName}

        Http.Post(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    logFunc("PIN requested successfully - check Fire TV screen")
                    C4:UpdateProperty("Pairing Status", "Enter PIN from TV screen")
                    if callback then callback(true) end
                else
                    logErrorFunc("PIN request failed: unexpected response")
                    C4:UpdateProperty("Pairing Status", "Error: PIN request failed")
                    if callback then callback(false) end
                end
            else
                logErrorFunc("PIN request failed: %s", tostring(error))
                C4:UpdateProperty("Pairing Status", "Error: " .. tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Verify PIN and complete pairing
function FireTV.VerifyPin(pin, callback)
    if not g_FireTV.host then
        logErrorFunc("Cannot verify PIN: No Fire TV IP address configured")
        C4:UpdateProperty("Pairing Status", "Error: No IP Address")
        if callback then callback(false) end
        return
    end

    if not pin or pin == "" then
        logErrorFunc("Cannot verify PIN: No PIN provided")
        C4:UpdateProperty("Pairing Status", "Error: No PIN entered")
        if callback then callback(false) end
        return
    end

    -- Clean up PIN (remove spaces, etc.)
    pin = pin:gsub("%s+", "")

    logFunc("Verifying PIN: %s", pin)
    C4:UpdateProperty("Pairing Status", "Verifying PIN...")

    FireTV.EnsureAwake(function(awake)
        if not awake then
            C4:UpdateProperty("Pairing Status", "Error: Cannot wake device")
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/FireTV/pin/verify")
        local headers = BuildHeaders(false)
        local body = {pin = pin}

        Http.Post(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description and response.description ~= "" then
                    -- Success! description contains the client token
                    local token = response.description
                    logFunc("Pairing successful! Token received.")

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
                    FireTV.RefreshDeviceInfo()

                    if callback then callback(true) end
                else
                    logErrorFunc("PIN verification failed: Invalid PIN")
                    C4:UpdateProperty("Pairing Status", "Error: Invalid PIN")
                    C4:FireEvent("Pairing Failed")
                    if callback then callback(false) end
                end
            else
                logErrorFunc("PIN verification failed: %s", tostring(error))
                C4:UpdateProperty("Pairing Status", "Error: " .. tostring(error))
                C4:FireEvent("Pairing Failed")
                if callback then callback(false) end
            end
        end)
    end)
end

-- Get device status
function FireTV.GetStatus(callback)
    if not g_FireTV.host then
        if callback then callback(false, nil) end
        return
    end

    local url = BuildApiUrl("/v1/FireTV/status")
    local headers = BuildHeaders(true)

    Http.Get(url, headers, function(success, data, code, error)
        if success then
            local status = JSON.decode(data)
            dbgFunc("Device status: %s", data)
            if callback then callback(true, status) end
        else
            dbgFunc("Failed to get status: %s", tostring(error))
            if callback then callback(false, nil) end
        end
    end)
end

-- Get device properties
function FireTV.GetProperties(callback)
    if not g_FireTV.host then
        if callback then callback(false, nil) end
        return
    end

    local url = BuildApiUrl("/v1/FireTV/properties")
    local headers = BuildHeaders(true)

    Http.Get(url, headers, function(success, data, code, error)
        if success then
            local props = JSON.decode(data)
            dbgFunc("Device properties: %s", data)
            if callback then callback(true, props) end
        else
            dbgFunc("Failed to get properties: %s", tostring(error))
            if callback then callback(false, nil) end
        end
    end)
end

-- Refresh device information
function FireTV.RefreshDeviceInfo()
    FireTV.EnsureAwake(function(awake)
        if not awake then return end

        FireTV.GetProperties(function(success, props)
            if success and props then
                local name = props.pfm or "Fire TV"
                C4:UpdateProperty("Fire TV Name", name)
            end
        end)
    end)
end

-- Send a key command
function FireTV.SendKey(action, keyAction, callback)
    if not g_FireTV.host then
        logErrorFunc("Cannot send key: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    if not g_FireTV.paired then
        logErrorFunc("Cannot send key: Not paired with Fire TV")
        if callback then callback(false) end
        return
    end

    FireTV.EnsureAwake(function(awake)
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

        Http.Post(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    dbgFunc("Key %s (%s) sent successfully", action, keyAction or "press")
                    if callback then callback(true) end
                else
                    dbgFunc("Key %s failed: unexpected response", action)
                    if callback then callback(false) end
                end
            else
                dbgFunc("Key %s failed: %s", action, tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Send D-pad key (requires keyDown + keyUp)
function FireTV.SendDpadKey(action, callback)
    FireTV.SendKey(action, KEY_ACTION_DOWN, function(success)
        if not success then
            if callback then callback(false) end
            return
        end

        -- Small delay between keyDown and keyUp
        Timers.SetTimer("dpad_" .. action, DEFAULT_KEY_DELAY, function()
            FireTV.SendKey(action, KEY_ACTION_UP, callback)
        end)
    end)
end

-- Send system key (no keyDown/keyUp needed)
function FireTV.SendSystemKey(action, callback)
    FireTV.SendKey(action, nil, callback)
end

-- Send media command
function FireTV.SendMediaCommand(action, params, callback)
    if not g_FireTV.host then
        logErrorFunc("Cannot send media command: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    if not g_FireTV.paired then
        logErrorFunc("Cannot send media command: Not paired with Fire TV")
        if callback then callback(false) end
        return
    end

    FireTV.EnsureAwake(function(awake)
        if not awake then
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/media?action=" .. action)
        local headers = BuildHeaders(true)
        local body = params or {}

        Http.Post(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    dbgFunc("Media %s sent successfully", action)
                    if callback then callback(true) end
                else
                    dbgFunc("Media %s failed: unexpected response", action)
                    if callback then callback(false) end
                end
            else
                dbgFunc("Media %s failed: %s", action, tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Send a single character
function FireTV.SendCharacter(char, callback)
    if not g_FireTV.host then
        logErrorFunc("Cannot send character: No Fire TV IP address configured")
        if callback then callback(false) end
        return
    end

    if not g_FireTV.paired then
        logErrorFunc("Cannot send character: Not paired with Fire TV")
        if callback then callback(false) end
        return
    end

    FireTV.EnsureAwake(function(awake)
        if not awake then
            if callback then callback(false) end
            return
        end

        local url = BuildApiUrl("/v1/FireTV/text")
        local headers = BuildHeaders(true)
        local body = {text = char}

        Http.Post(url, body, headers, function(success, data, code, error)
            if success then
                local response = JSON.decode(data)
                if response and response.description == "OK" then
                    dbgFunc("Character '%s' sent successfully", char)
                    if callback then callback(true) end
                else
                    dbgFunc("Character send failed: unexpected response")
                    if callback then callback(false) end
                end
            else
                dbgFunc("Character send failed: %s", tostring(error))
                if callback then callback(false) end
            end
        end)
    end)
end

-- Send text string (one character at a time)
function FireTV.SendText(text, callback, charIndex)
    charIndex = charIndex or 1

    if charIndex > #text then
        if callback then callback(true) end
        return
    end

    local char = text:sub(charIndex, charIndex)

    FireTV.SendCharacter(char, function(success)
        if not success then
            if callback then callback(false) end
            return
        end

        -- Small delay between characters
        Timers.SetTimer("text_char_" .. charIndex, DEFAULT_CHAR_DELAY, function()
            FireTV.SendText(text, callback, charIndex + 1)
        end)
    end)
end

-- Update connection status
function FireTV.UpdateConnectionStatus(connected)
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

-- Test connection to Fire TV
function FireTV.TestConnection(callback)
    if not g_FireTV.host then
        C4:UpdateProperty("Connection Status", "Not Connected")
        if callback then callback(false) end
        return
    end

    FireTV.Wake(function(success)
        if success then
            FireTV.GetStatus(function(statusSuccess, status)
                if statusSuccess then
                    C4:UpdateProperty("Connection Status", "Connected")
                    logFunc("Connection test successful")
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

-- Expose HandleReceivedAsync for the main driver to use
FireTV.HandleReceivedAsync = Http.HandleReceivedAsync

return FireTV

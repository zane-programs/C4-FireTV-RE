--[[
    Fire TV Remote Control Driver for Control4

    This driver implements the Fire TV Remote Control protocol,
    allowing Control4 systems to control Amazon Fire TV devices.

    Protocol based on reverse-engineering of the official Fire TV Remote app.

    Compatible with Control4 OS 2.10.6+
]]--

--------------------------------------------------------------------------------
-- Load Modules
--------------------------------------------------------------------------------

local Timers = require("timers")
local FireTV = require("firetv")

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

DRIVER_NAME = "Fire TV Remote"
DRIVER_VERSION = "1.0.0"

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
-- Initialize Modules
--------------------------------------------------------------------------------

-- Pass state and debug functions to FireTV module
FireTV.setState(g_FireTV)
FireTV.setDebugFunctions(dbg, log, logError)

--------------------------------------------------------------------------------
-- ReceivedAsync Callback (required for HTTP requests)
--------------------------------------------------------------------------------

-- This global function is called by Control4 when HTTP requests complete
function ReceivedAsync(ticketId, strData, responseCode, tHeaders, strError)
    FireTV.HandleReceivedAsync(ticketId, strData, responseCode, tHeaders, strError)
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
    Timers.KillAllTimers()
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
        FireTV.RequestPin()

    elseif strCommand == "VerifyPIN" then
        local pin = Properties["PIN Code"]
        FireTV.VerifyPin(pin)

    elseif strCommand == "TestConnection" then
        FireTV.TestConnection()

    elseif strCommand == "RefreshDeviceInfo" then
        FireTV.RefreshDeviceInfo()

    elseif strCommand == "ClearPairing" then
        g_FireTV.clientToken = nil
        g_FireTV.paired = false
        PersistData.clientToken = nil
        C4:UpdateProperty("Pairing Status", "Not Paired")
        log("Pairing credentials cleared")

    -- Navigation commands
    elseif strCommand == "UP" then
        FireTV.SendDpadKey("dpad_up")

    elseif strCommand == "DOWN" then
        FireTV.SendDpadKey("dpad_down")

    elseif strCommand == "LEFT" then
        FireTV.SendDpadKey("dpad_left")

    elseif strCommand == "RIGHT" then
        FireTV.SendDpadKey("dpad_right")

    elseif strCommand == "ENTER" then
        FireTV.SendDpadKey("select")

    -- System commands
    elseif strCommand == "GUIDE" then
        FireTV.SendSystemKey("home")

    elseif strCommand == "RECALL" or strCommand == "CANCEL" then
        FireTV.SendSystemKey("back")

    elseif strCommand == "CUSTOM_3" or strCommand == "MENU" then
        FireTV.SendSystemKey("menu")

    -- Media commands
    elseif strCommand == "PLAY" or strCommand == "PAUSE" then
        FireTV.SendMediaCommand("play")

    elseif strCommand == "Stop" then
        FireTV.SendMediaCommand("stop")

    elseif strCommand == "SCAN_FWD" then
        local seconds = tonumber(tParams.Seconds) or 10
        FireTV.SendMediaCommand("scan", {
            direction = "forward",
            durationInSeconds = tostring(seconds),
            speed = "1"
        })

    elseif strCommand == "SCAN_REV" then
        local seconds = tonumber(tParams.Seconds) or 10
        FireTV.SendMediaCommand("scan", {
            direction = "back",
            durationInSeconds = tostring(seconds),
            speed = "1"
        })

    -- Text input commands
    elseif strCommand == "SendText" then
        local text = tParams.Text
        if text and text ~= "" then
            FireTV.SendText(text)
        end

    elseif strCommand == "SendCharacter" then
        local char = tParams.Character
        if char and char ~= "" then
            FireTV.SendCharacter(char:sub(1, 1))
        end

    -- Utility commands
    elseif strCommand == "Wake" then
        FireTV.Wake()

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
            FireTV.Wake(function(success)
                if success then
                    -- Optionally go to home screen when room turns on
                    FireTV.SendSystemKey("home")
                end
            end)

        elseif strCommand == "OFF" then
            log("Room deactivated")
            -- Fire TV doesn't have a true power off via this protocol
            -- Could pause media or go home if desired
            -- FireTV.SendMediaCommand("pause")

        -- Handle input selection commands
        elseif strCommand == "INPUT_SELECTION" then
            -- Fire TV is a single-input device, just wake it
            FireTV.Wake()

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

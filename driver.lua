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

-- mDNS Configuration
MDNS_MULTICAST_ADDR = "224.0.0.251"
MDNS_PORT = 5353
MDNS_SERVICE_TYPE = "_amzn-wplay._tcp.local."
MDNS_BINDING_ID = 6999
MDNS_DISCOVERY_TIMEOUT = 10000  -- 10 seconds

--------------------------------------------------------------------------------
-- Global State
--------------------------------------------------------------------------------

g_DiscoveredDevices = {}  -- Table of discovered Fire TV devices

g_Discovery = {
    active = false,
    startTime = 0
}

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
-- mDNS Discovery Implementation
--------------------------------------------------------------------------------

-- DNS record types
DNS_TYPE_A = 1
DNS_TYPE_PTR = 12
DNS_TYPE_TXT = 16
DNS_TYPE_SRV = 33

-- Encode a DNS name (e.g., "_amzn-wplay._tcp.local.")
function EncodeDnsName(name)
    local result = ""
    for label in string.gmatch(name, "([^%.]+)") do
        result = result .. string.char(#label) .. label
    end
    result = result .. string.char(0)  -- Null terminator
    return result
end

-- Decode a DNS name from a packet at a given position
function DecodeDnsName(packet, pos)
    local labels = {}
    local jumped = false
    local originalPos = pos

    while pos <= #packet do
        local len = string.byte(packet, pos)

        if len == 0 then
            pos = pos + 1
            break
        elseif len >= 192 then
            -- Pointer (compression)
            if not jumped then
                originalPos = pos + 2
            end
            local offset = ((len - 192) * 256) + string.byte(packet, pos + 1)
            pos = offset + 1
            jumped = true
        else
            pos = pos + 1
            local label = string.sub(packet, pos, pos + len - 1)
            table.insert(labels, label)
            pos = pos + len
        end
    end

    if jumped then
        pos = originalPos
    end

    return table.concat(labels, "."), pos
end

-- Build an mDNS query packet for Fire TV discovery
function BuildMdnsQuery()
    -- Transaction ID (0x0000 for mDNS)
    local transactionId = string.char(0x00, 0x00)

    -- Flags (0x0000 for standard query)
    local flags = string.char(0x00, 0x00)

    -- Question count (1)
    local qdCount = string.char(0x00, 0x01)

    -- Answer, Authority, Additional counts (0)
    local anCount = string.char(0x00, 0x00)
    local nsCount = string.char(0x00, 0x00)
    local arCount = string.char(0x00, 0x00)

    -- Header
    local header = transactionId .. flags .. qdCount .. anCount .. nsCount .. arCount

    -- Question: _amzn-wplay._tcp.local. PTR IN
    local qname = EncodeDnsName(MDNS_SERVICE_TYPE)
    local qtype = string.char(0x00, DNS_TYPE_PTR)  -- PTR
    local qclass = string.char(0x00, 0x01)         -- IN

    local question = qname .. qtype .. qclass

    return header .. question
end

-- Parse a 16-bit big-endian integer
function ParseUint16(packet, pos)
    local high = string.byte(packet, pos) or 0
    local low = string.byte(packet, pos + 1) or 0
    return (high * 256) + low
end

-- Parse a 32-bit big-endian integer
function ParseUint32(packet, pos)
    local b1 = string.byte(packet, pos) or 0
    local b2 = string.byte(packet, pos + 1) or 0
    local b3 = string.byte(packet, pos + 2) or 0
    local b4 = string.byte(packet, pos + 3) or 0
    return (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
end

-- Parse TXT record data into a table
function ParseTxtRecord(data)
    local result = {}
    local pos = 1
    local len = #data

    while pos <= len do
        local strLen = string.byte(data, pos)
        if not strLen or strLen == 0 then break end

        pos = pos + 1
        if pos + strLen - 1 > len then break end

        local str = string.sub(data, pos, pos + strLen - 1)
        pos = pos + strLen

        -- Parse key=value
        local eq = string.find(str, "=")
        if eq then
            local key = string.sub(str, 1, eq - 1)
            local value = string.sub(str, eq + 1)
            result[key] = value
        end
    end

    return result
end

-- Parse an mDNS response packet
function ParseMdnsResponse(packet, sourceIp)
    if #packet < 12 then
        dbg("mDNS packet too short: %d bytes", #packet)
        return nil
    end

    local pos = 1

    -- Parse header
    local transactionId = ParseUint16(packet, pos)
    pos = pos + 2
    local flags = ParseUint16(packet, pos)
    pos = pos + 2
    local qdCount = ParseUint16(packet, pos)
    pos = pos + 2
    local anCount = ParseUint16(packet, pos)
    pos = pos + 2
    local nsCount = ParseUint16(packet, pos)
    pos = pos + 2
    local arCount = ParseUint16(packet, pos)
    pos = pos + 12

    dbg("mDNS response: flags=%04x, questions=%d, answers=%d, authority=%d, additional=%d",
        flags, qdCount, anCount, nsCount, arCount)

    -- Skip questions
    for i = 1, qdCount do
        local name
        name, pos = DecodeDnsName(packet, pos)
        pos = pos + 4  -- Skip QTYPE and QCLASS
    end

    local device = {
        host = sourceIp,
        port = API_PORT,
        name = nil,
        model = nil,
        manufacturer = nil,
        properties = {}
    }

    local foundFireTV = false

    -- Parse all resource records
    local totalRecords = anCount + nsCount + arCount

    for i = 1, totalRecords do
        if pos > #packet then break end

        local name
        name, pos = DecodeDnsName(packet, pos)

        if pos + 10 > #packet then break end

        local rtype = ParseUint16(packet, pos)
        pos = pos + 2
        local rclass = ParseUint16(packet, pos) % 32768  -- Remove cache flush bit
        pos = pos + 2
        local ttl = ParseUint32(packet, pos)
        pos = pos + 4
        local rdlength = ParseUint16(packet, pos)
        pos = pos + 2

        if pos + rdlength > #packet + 1 then break end

        local rdata = string.sub(packet, pos, pos + rdlength - 1)
        pos = pos + rdlength

        dbg("mDNS record: name=%s, type=%d, class=%d, ttl=%d, len=%d",
            name, rtype, rclass, ttl, rdlength)

        -- Check if this is a Fire TV service
        if string.find(name, "_amzn-wplay") or string.find(name, "amzn") then
            foundFireTV = true
        end

        if rtype == DNS_TYPE_PTR then
            -- PTR record - contains service instance name
            local ptrName
            ptrName, _ = DecodeDnsName(packet, pos - rdlength)
            dbg("PTR: %s -> %s", name, ptrName)

            if string.find(ptrName, "_amzn-wplay") or string.find(name, "_amzn-wplay") then
                foundFireTV = true
            end

        elseif rtype == DNS_TYPE_TXT then
            -- TXT record - contains device properties
            local txtData = ParseTxtRecord(rdata)
            dbg("TXT record parsed")

            for k, v in pairs(txtData) do
                dbg("  TXT: %s = %s", k, v)
                device.properties[k] = v
            end

            -- Extract device name from TXT record
            device.name = txtData["fn"] or txtData["n"] or txtData["friendlyName"] or device.name
            device.model = txtData["md"] or txtData["model"] or device.model
            device.manufacturer = txtData["manufacturer"] or device.manufacturer

        elseif rtype == DNS_TYPE_SRV then
            -- SRV record - contains port and target
            if rdlength >= 6 then
                local priority = ParseUint16(rdata, 1)
                local weight = ParseUint16(rdata, 3)
                local port = ParseUint16(rdata, 5)
                local target
                target, _ = DecodeDnsName(packet, pos - rdlength + 6)

                dbg("SRV: priority=%d, weight=%d, port=%d, target=%s",
                    priority, weight, port, target)

                device.port = port
            end

        elseif rtype == DNS_TYPE_A then
            -- A record - IPv4 address
            if rdlength == 4 then
                local ip = string.format("%d.%d.%d.%d",
                    string.byte(rdata, 1),
                    string.byte(rdata, 2),
                    string.byte(rdata, 3),
                    string.byte(rdata, 4))
                dbg("A record: %s -> %s", name, ip)

                -- Use this IP if we found it in the response
                device.host = ip
            end
        end
    end

    if foundFireTV then
        -- Set default name if not found
        if not device.name or device.name == "" then
            device.name = "Fire TV (" .. device.host .. ")"
        end

        return device
    end

    return nil
end

-- Start mDNS discovery
function StartDiscovery()
    if g_Discovery.active then
        log("Discovery already in progress")
        return
    end

    log("Starting mDNS discovery for Fire TV devices...")
    g_Discovery.active = true
    g_Discovery.startTime = os.time()
    g_DiscoveredDevices = {}

    C4:UpdateProperty("Discovery Status", "Discovering...")

    -- Create multicast binding for mDNS
    C4:CreateNetworkConnection(MDNS_BINDING_ID, MDNS_MULTICAST_ADDR)

    -- Join multicast group and send query
    C4:NetConnect(MDNS_BINDING_ID, MDNS_PORT, "MULTICAST")

    -- Send the mDNS query
    local query = BuildMdnsQuery()
    C4:SendToNetwork(MDNS_BINDING_ID, MDNS_PORT, query)
    dbg("Sent mDNS query (%d bytes)", #query)

    -- Send query again after a short delay (some devices may miss first query)
    SetTimer("mdns_retry", 1000, function()
        if g_Discovery.active then
            C4:SendToNetwork(MDNS_BINDING_ID, MDNS_PORT, query)
            dbg("Sent mDNS query retry")
        end
    end)

    -- Stop discovery after timeout
    SetTimer("mdns_timeout", MDNS_DISCOVERY_TIMEOUT, function()
        StopDiscovery()
    end)
end

-- Stop mDNS discovery
function StopDiscovery()
    if not g_Discovery.active then
        return
    end

    g_Discovery.active = false
    KillTimer("mdns_timeout")
    KillTimer("mdns_retry")

    -- Disconnect multicast
    C4:NetDisconnect(MDNS_BINDING_ID, MDNS_PORT)

    local count = 0
    for _ in pairs(g_DiscoveredDevices) do
        count = count + 1
    end

    log("Discovery complete. Found %d Fire TV device(s)", count)

    if count > 0 then
        C4:UpdateProperty("Discovery Status", "Found " .. count .. " device(s)")
    else
        C4:UpdateProperty("Discovery Status", "No devices found")
    end

    UpdateDiscoveredDevicesList()
end

-- Update the discovered devices property list
function UpdateDiscoveredDevicesList()
    local items = {"-- Select Device --"}

    for host, device in pairs(g_DiscoveredDevices) do
        local displayName = device.name or ("Fire TV (" .. host .. ")")
        if device.model then
            displayName = displayName .. " [" .. device.model .. "]"
        end
        table.insert(items, displayName .. "|" .. host)
    end

    -- Sort by name
    table.sort(items, function(a, b)
        if a == "-- Select Device --" then return true end
        if b == "-- Select Device --" then return false end
        return a < b
    end)

    -- Create comma-separated list for property
    local itemList = table.concat(items, ",")
    C4:UpdatePropertyList("Discovered Devices", itemList)
end

-- Handle mDNS response from network
function HandleMdnsResponse(data, sourceIp)
    if not g_Discovery.active then
        return
    end

    dbg("Received mDNS response from %s (%d bytes)", sourceIp, #data)

    local device = ParseMdnsResponse(data, sourceIp)

    if device then
        -- Use the actual source IP if the parsed one doesn't make sense
        local deviceHost = device.host or sourceIp

        -- Check if we already have this device
        if not g_DiscoveredDevices[deviceHost] then
            log("Discovered Fire TV: %s at %s", device.name or "Unknown", deviceHost)

            g_DiscoveredDevices[deviceHost] = device

            -- Persist discovered devices
            PersistData.discoveredDevices = g_DiscoveredDevices

            -- Update the device list
            UpdateDiscoveredDevicesList()
        end
    end
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
-- HTTP Request Handling
--------------------------------------------------------------------------------

-- Build standard headers for Fire TV API
function BuildHeaders(authenticated)
    local headers = {
        ["Content-Type"] = "application/json; charset=utf-8",
        ["Accept"] = "*/*",
        ["x-api-key"] = API_KEY
    }

    if authenticated and g_FireTV.clientToken then
        headers["x-client-token"] = g_FireTV.clientToken
    end

    return headers
end

-- Convert headers table to the format expected by C4:url* functions
function HeadersToString(headers)
    local parts = {}
    for key, value in pairs(headers) do
        table.insert(parts, key .. ": " .. value)
    end
    return table.concat(parts, "\r\n")
end

-- Make HTTP GET request
function HttpGet(url, headers, callback)
    local headerStr = HeadersToString(headers or {})

    dbg("HTTP GET: %s", url)

    C4:urlGet(url, headerStr, false, function(ticketId, strData, responseCode, tHeaders, strError)
        dbg("HTTP GET Response: code=%s, error=%s", tostring(responseCode), tostring(strError))

        if callback then
            local success = responseCode and responseCode >= 200 and responseCode < 300
            callback(success, strData, responseCode, strError)
        end
    end)
end

-- Make HTTP POST request
function HttpPost(url, data, headers, callback)
    local headerStr = HeadersToString(headers or {})
    local body = data or ""

    if type(data) == "table" then
        body = JSON.encode(data)
    end

    dbg("HTTP POST: %s", url)
    dbg("HTTP POST Body: %s", body)

    C4:urlPost(url, body, headerStr, false, function(ticketId, strData, responseCode, tHeaders, strError)
        dbg("HTTP POST Response: code=%s, error=%s, data=%s",
            tostring(responseCode), tostring(strError), tostring(strData))

        if callback then
            local success = responseCode and responseCode >= 200 and responseCode < 300
            callback(success, strData, responseCode, strError)
        end
    end)
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

    -- Restore discovered devices
    if PersistData.discoveredDevices then
        g_DiscoveredDevices = PersistData.discoveredDevices
        UpdateDiscoveredDevicesList()
        log("Restored %d discovered device(s) from storage",
            (function() local c=0; for _ in pairs(g_DiscoveredDevices) do c=c+1 end; return c end)())
    end

    -- Initialize properties
    for property, _ in pairs(Properties) do
        OnPropertyChanged(property)
    end

    -- Set URL timeout
    C4:urlSetTimeout(g_FireTV.timeout)

    log("Driver initialized successfully")
end

function OnDriverDestroyed()
    log("Driver being destroyed...")

    -- Stop discovery if active
    if g_Discovery.active then
        StopDiscovery()
    end

    KillAllTimers()
end

--------------------------------------------------------------------------------
-- Property Handling
--------------------------------------------------------------------------------

function OnPropertyChanged(strProperty)
    local value = Properties[strProperty]

    dbg("Property changed: %s = %s", strProperty, tostring(value))

    if strProperty == "Discovered Devices" then
        -- Handle device selection from discovery list
        if value and value ~= "" and value ~= "-- Select Device --" then
            -- Extract IP from "Device Name|IP" format
            local pipePos = string.find(value, "|")
            if pipePos then
                local selectedIp = string.sub(value, pipePos + 1)
                local selectedName = string.sub(value, 1, pipePos - 1)

                log("Selected device: %s (%s)", selectedName, selectedIp)

                -- Update the IP address property
                g_FireTV.host = selectedIp
                PersistData.host = selectedIp
                C4:UpdateProperty("Fire TV IP Address", selectedIp)

                -- Get the device info if available
                if g_DiscoveredDevices[selectedIp] then
                    local device = g_DiscoveredDevices[selectedIp]
                    C4:UpdateProperty("Fire TV Name", device.name or "Fire TV")
                end

                -- Check pairing status
                if PersistData.clientToken then
                    g_FireTV.clientToken = PersistData.clientToken
                    g_FireTV.paired = true
                    C4:UpdateProperty("Pairing Status", "Paired")
                else
                    g_FireTV.paired = false
                    C4:UpdateProperty("Pairing Status", "Not Paired")
                end

                C4:UpdateProperty("Connection Status", "Not Connected")
            end
        end

    elseif strProperty == "Fire TV IP Address" then
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
        C4:urlSetTimeout(timeout)

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

    -- Discovery commands
    if strCommand == "DiscoverDevices" then
        StartDiscovery()

    elseif strCommand == "StopDiscovery" then
        StopDiscovery()

    -- Pairing commands
    elseif strCommand == "StartPairing" then
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
    dbg("ReceivedFromNetwork: binding=%d, port=%d, len=%d", idBinding, nPort, #strData)

    -- Handle mDNS responses
    if idBinding == MDNS_BINDING_ID and nPort == MDNS_PORT then
        -- Extract source IP from the connection context if available
        -- For multicast responses, we need to parse the data
        -- The source IP should be available via GetSenderAddress in some Control4 versions
        local sourceIp = "unknown"

        -- Try to get sender address (may not be available in all OS versions)
        if C4.GetSenderAddress then
            sourceIp = C4:GetSenderAddress(idBinding) or "unknown"
        end

        -- Parse and handle the mDNS response
        HandleMdnsResponse(strData, sourceIp)
    end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    dbg("OnConnectionStatusChanged: binding=%d, port=%d, status=%s", idBinding, nPort, strStatus)
end

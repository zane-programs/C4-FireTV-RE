--[[
    Simple JSON Library for Control4 (OS 2.10.6 Compatible)

    Provides JSON encode/decode functionality without external dependencies.
]]--

local JSON = {}

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

return JSON

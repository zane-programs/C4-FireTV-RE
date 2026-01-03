--[[
    Timer Utilities for Control4 DriverWorks

    Provides named timer management using C4:SetTimer().
]]--

local Timers = {}

-- Global timer storage
local g_Timers = {}

function Timers.SetTimer(name, interval, callback, recurring)
    Timers.KillTimer(name)

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

function Timers.KillTimer(name)
    if g_Timers[name] then
        g_Timers[name]:Cancel()
        g_Timers[name] = nil
    end
end

function Timers.KillAllTimers()
    for name, timer in pairs(g_Timers) do
        if timer then
            timer:Cancel()
        end
    end
    g_Timers = {}
end

return Timers

--
-- FS25 - GlobalMarket - InitGlobalMarketSettingsEvent
-- Description: Client ping to request current admin settings upon joining.
--

InitGlobalMarketSettingsEvent = {}
local InitGlobalMarketSettingsEvent_mt = Class(InitGlobalMarketSettingsEvent, Event)

InitEventClass(InitGlobalMarketSettingsEvent, "InitGlobalMarketSettingsEvent")

function InitGlobalMarketSettingsEvent.emptyNew()
    return Event.new(InitGlobalMarketSettingsEvent_mt)
end

function InitGlobalMarketSettingsEvent.new()
    return InitGlobalMarketSettingsEvent.emptyNew()
end

function InitGlobalMarketSettingsEvent:writeStream(streamId, connection)
    -- empty ping
end

function InitGlobalMarketSettingsEvent:readStream(streamId, connection)
    self:run(connection)
end

function InitGlobalMarketSettingsEvent:run(connection)

    if not connection:getIsServer() then
        if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil then
            local s = GlobalMarketSettings.current
            connection:sendEvent(SyncGlobalMarketSettingsEvent.new(
                s.deliveryBaseIndex, 
                s.deliveryLiterIndex, 
                s.isDetailedFinance, 
                s.isDebugActive, 
                s.debugLevelIndex, 
                s.debugDurationIndex
            ))
        end
    end
end
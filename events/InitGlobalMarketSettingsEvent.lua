-- =========================================================================================
-- FS25_GlobalMarket - InitGlobalMarketSettingsEvent.lua
-- Client-to-server handshake event requesting active global market settings upon joining.
-- Author: D-S-Agrarservice
-- =========================================================================================

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
    -- When the server receives this ping from a joining client,
    -- it bounces back the actual Sync event containing all current parameters.
    if not connection:getIsServer() then
        if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil then
            local s = GlobalMarketSettings.current

            connection:sendEvent(SyncGlobalMarketSettingsEvent.new(
                s.deliveryBaseIndex,
                s.deliveryLiterIndex,
                s.isDetailedFinance,
                s.isDebugActive,
                s.debugLevelIndex,
                s.debugDurationIndex,
                s.compatModeIndex,
                s.isIconPulseActive,
                s.showStatusIcon,
                s.dealerMarkupIndex,
                s.capacityIndex,
                s.storageDecayIndex,
                s.greatDemandModeIndex
            ))
        end
    end
end

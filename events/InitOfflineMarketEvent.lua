-- =========================================================================================
-- FS25_GlobalMarket - InitOfflineMarketEvent.lua
-- Client-to-server handshake event requesting market state or relaying Great Demand tests.
-- Author: D-S-Agrarservice
-- =========================================================================================

InitOfflineMarketEvent = {}
local InitOfflineMarketEvent_mt = Class(InitOfflineMarketEvent, Event)

InitEventClass(InitOfflineMarketEvent, "InitOfflineMarketEvent")

-- Creates an empty instance for reading from the network stream
function InitOfflineMarketEvent.emptyNew()
    return Event.new(InitOfflineMarketEvent_mt)
end

-- Creates a new instance for writing to the network stream
function InitOfflineMarketEvent.new(triggerGreatDemandFillType)
    local self = InitOfflineMarketEvent.emptyNew()
    self.triggerGreatDemandFillType = triggerGreatDemandFillType
    return self
end

-- Writes data to the network stream
function InitOfflineMarketEvent:writeStream(streamId, connection)
    local hasTrigger = (self.triggerGreatDemandFillType ~= nil and self.triggerGreatDemandFillType ~= "")
    streamWriteBool(streamId, hasTrigger)
    if hasTrigger then
        streamWriteString(streamId, self.triggerGreatDemandFillType)
    end
end

-- Reads data from the network stream
function InitOfflineMarketEvent:readStream(streamId, connection)
    local hasTrigger = streamReadBool(streamId)
    if hasTrigger then
        self.triggerGreatDemandFillType = streamReadString(streamId)
    else
        self.triggerGreatDemandFillType = nil
    end
    self:run(connection)
end

-- Executes the event logic
function InitOfflineMarketEvent:run(connection)
    -- If the server receives this ping, send the current market state back to the specific client
    if not connection:getIsServer() then
        if g_currentMission.globalMarket ~= nil then
            if self.triggerGreatDemandFillType ~= nil then
                local isMaster = (g_currentMission.userManager ~= nil and g_currentMission.userManager.getIsConnectionMasterUser ~= nil)
                    and g_currentMission.userManager:getIsConnectionMasterUser(connection)
                    or true
                if isMaster and g_currentMission.globalMarket.consoleCommandTriggerGreatDemand ~= nil then
                    local arg = (self.triggerGreatDemandFillType ~= "*") and self.triggerGreatDemandFillType or nil
                    g_currentMission.globalMarket:consoleCommandTriggerGreatDemand(arg)
                end
                return
            end

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:info("Network: Server received InitOfflineMarketEvent. Sending Sync payload to requesting client.")
            end
            connection:sendEvent(SynchOfflineMarketEvent.new())
        end
    end
end

--
-- FS25 - GlobalMarket - InitOfflineMarketEvent
--

InitOfflineMarketEvent = {}
local InitOfflineMarketEvent_mt = Class(InitOfflineMarketEvent, Event)

InitEventClass(InitOfflineMarketEvent, "InitOfflineMarketEvent")

function InitOfflineMarketEvent.emptyNew()
    return Event.new(InitOfflineMarketEvent_mt)
end

function InitOfflineMarketEvent.new()
    return InitOfflineMarketEvent.emptyNew()
end

function InitOfflineMarketEvent:writeStream(streamId, connection)
    -- No data payload needed for this request event
end

function InitOfflineMarketEvent:readStream(streamId, connection)
    self:run(connection)
end

function InitOfflineMarketEvent:run(connection)
    -- If the server receives this request, send the current market state back to the requesting client
    if not connection:getIsServer() then
        if g_currentMission.globalMarket ~= nil then
            GlobalMarket.debugLog("Server received InitOfflineMarketEvent. Sending Sync to requesting client.")
            connection:sendEvent(SynchOfflineMarketEvent.new())
        end
    end
end
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
    -- If the server receives this request, broadcast the current market state
    if not connection:getIsServer() then
        if g_currentMission.globalMarket ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    end
end
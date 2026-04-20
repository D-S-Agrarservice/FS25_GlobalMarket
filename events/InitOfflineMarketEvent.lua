--
-- FS25 - GlobalMarket - InitOfflineMarketEvent
-- Description: Client-to-Server event. Requests the current market state upon joining a multiplayer session.
--

InitOfflineMarketEvent = {}
local InitOfflineMarketEvent_mt = Class(InitOfflineMarketEvent, Event)

InitEventClass(InitOfflineMarketEvent, "InitOfflineMarketEvent")

-- Creates an empty instance for reading from the network stream
function InitOfflineMarketEvent.emptyNew()
    return Event.new(InitOfflineMarketEvent_mt)
end

-- Creates a new instance for writing to the network stream
function InitOfflineMarketEvent.new()
    return InitOfflineMarketEvent.emptyNew()
end

-- Writes data to the network stream (Empty ping, no payload needed)
function InitOfflineMarketEvent:writeStream(streamId, connection)
    -- No data payload needed for this request event
end

-- Reads data from the network stream
function InitOfflineMarketEvent:readStream(streamId, connection)
    self:run(connection)
end

-- Executes the event logic
function InitOfflineMarketEvent:run(connection)
    -- If the server receives this ping, send the current market state back to the specific client
    if not connection:getIsServer() then
        if g_currentMission.globalMarket ~= nil then
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:info("Network: Server received InitOfflineMarketEvent. Sending Sync payload to requesting client.")
            end
            connection:sendEvent(SynchOfflineMarketEvent.new())
        end
    end
end
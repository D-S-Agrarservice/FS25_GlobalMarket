--
-- FS25 - GlobalMarket - MarketDataSyncEvent
-- Description: Distributes parsed XML market stock levels across the network.
-- Note: Price is omitted to enforce local economic calculation (prevent arbitrage).
--

MarketDataSyncEvent = {}
local MarketDataSyncEvent_mt = Class(MarketDataSyncEvent, Event)

InitEventClass(MarketDataSyncEvent, "MarketDataSyncEvent")

function MarketDataSyncEvent.emptyNew()
    return Event.new(MarketDataSyncEvent_mt)
end

function MarketDataSyncEvent.new(marketData)
    local self = MarketDataSyncEvent.emptyNew()
    self.marketData = marketData or {}
    return self
end

function MarketDataSyncEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, #self.marketData)
    for _, item in ipairs(self.marketData) do
        streamWriteString(streamId, item.fillType)
        streamWriteInt32(streamId, item.fillLevel)
    end
end

function MarketDataSyncEvent:readStream(streamId, connection)
    self.marketData = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        table.insert(self.marketData, {
            fillType = streamReadString(streamId),
            fillLevel = streamReadInt32(streamId)
        })
    end
    self:run(connection)
end

function MarketDataSyncEvent:run(connection)
    if g_currentMission.globalMarket == nil then return end

    if not connection:getIsServer() then
        -- Server processes incoming Data-Host payload and broadcasts it
        g_currentMission.globalMarket:applySyncedMarketData(self.marketData)
        g_server:broadcastEvent(MarketDataSyncEvent.new(self.marketData), nil, connection)
    else
        -- Standard Client receives data
        g_currentMission.globalMarket:applySyncedMarketData(self.marketData)
    end
end
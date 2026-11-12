--
-- FS25 - GlobalMarket - MarketDataSyncEvent
-- Description: Distributes parsed XML market stock levels, trends, and Great Demand flags across the network.
-- Note: Raw price is omitted to enforce local economic calculation (prevent arbitrage).
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
        streamWriteString(streamId, item.fillType or "")
        streamWriteString(streamId, item.status or "APPROVED")
        streamWriteInt32(streamId, item.fillLevel or 0)
        streamWriteFloat32(streamId, item.trend or 0)
        streamWriteBool(streamId, item.isGreatDemand == true)
        streamWriteFloat32(streamId, item.greatDemandBonus or 0)
        streamWriteInt32(streamId, item.greatDemandRemainingLiters or 0)
    end
end

function MarketDataSyncEvent:readStream(streamId, connection)
    self.marketData = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        local ftName = streamReadString(streamId)
        local ftStatus = streamReadString(streamId)
        local ftLevel = streamReadInt32(streamId)
        local ftTrend = streamReadFloat32(streamId)
        local ftGreatDemand = streamReadBool(streamId)
        local ftGdBonus = streamReadFloat32(streamId)
        local ftGdRemaining = streamReadInt32(streamId)

        table.insert(self.marketData, {
            fillType = ftName,
            status = (ftStatus ~= "") and ftStatus or "APPROVED",
            fillLevel = ftLevel,
            trend = (ftTrend > 0) and ftTrend or nil,
            isGreatDemand = ftGreatDemand,
            greatDemandBonus = (ftGdBonus > 0) and ftGdBonus or nil,
            greatDemandRemainingLiters = (ftGdRemaining > 0) and ftGdRemaining or nil
        })
    end
    self:run(connection)
end

function MarketDataSyncEvent:run(connection)
    if g_currentMission.globalMarket == nil then return end

    if not connection:getIsServer() then
        -- Server processes incoming Data-Host payload and broadcasts it to all clients (including Data-Host)
        g_currentMission.globalMarket:applySyncedMarketData(self.marketData)
        g_server:broadcastEvent(MarketDataSyncEvent.new(self.marketData))
    else
        -- Standard Client receives data
        g_currentMission.globalMarket:applySyncedMarketData(self.marketData)
    end
end

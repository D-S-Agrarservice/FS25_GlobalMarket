-- =========================================================================================
-- FS25_GlobalMarket - MarketDataSyncEvent.lua
-- Network event distributing online market stock levels, trends, and Great Demand states.
-- Author: D-S-Agrarservice
-- =========================================================================================

MarketDataSyncEvent = {}
local MarketDataSyncEvent_mt = Class(MarketDataSyncEvent, Event)

InitEventClass(MarketDataSyncEvent, "MarketDataSyncEvent")

function MarketDataSyncEvent.emptyNew()
    return Event.new(MarketDataSyncEvent_mt)
end

function MarketDataSyncEvent.new(marketData, marketName, isPrivateMarket)
    local self = MarketDataSyncEvent.emptyNew()
    self.marketData = marketData or {}
    self.marketName = marketName
    self.isPrivateMarket = isPrivateMarket == true
    return self
end

-- Builds an authoritative Server-to-Client broadcast event including server-computed Map-Spy prices and Hybrid states
function MarketDataSyncEvent.newFromServerState(gm)
    local payload = {}
    if gm ~= nil and gm.offlineMarketFillTypes ~= nil then
        for _, item in ipairs(gm.offlineMarketFillTypes) do
            if item.fillType ~= nil then
                table.insert(payload, {
                    fillType = item.fillType,
                    status = item.onlineStatus or "PENDING",
                    fillLevel = math.floor(item.fillLevel or 0),
                    trend = item.trend,
                    isGreatDemand = (item.isGreatDemand == true),
                    greatDemandBonus = item.onlineGreatDemandBonus,
                    greatDemandRemainingLiters = item.greatDemandRemainingLiters,
                    normalPrice = item.normalPrice or 0,
                    price = item.price or 0
                })
            end
        end
    end
    local mName = gm ~= nil and gm.onlineMarketName or nil
    local mPriv = gm ~= nil and gm.isPrivateOnlineMarket == true or false
    return MarketDataSyncEvent.new(payload, mName, mPriv)
end

function MarketDataSyncEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.marketName or "")
    streamWriteBool(streamId, self.isPrivateMarket == true)
    streamWriteInt32(streamId, #self.marketData)
    for _, item in ipairs(self.marketData) do
        streamWriteString(streamId, item.fillType or "")
        streamWriteString(streamId, item.status or "APPROVED")
        streamWriteInt32(streamId, math.floor(item.fillLevel or 0))
        streamWriteFloat32(streamId, item.trend or 0)
        streamWriteBool(streamId, item.isGreatDemand == true)
        streamWriteFloat32(streamId, item.greatDemandBonus or 0)
        streamWriteInt32(streamId, math.floor(item.greatDemandRemainingLiters or 0))
        streamWriteFloat32(streamId, item.normalPrice or 0)
        streamWriteFloat32(streamId, item.price or 0)
    end
end

function MarketDataSyncEvent:readStream(streamId, connection)
    local rawMarketName = streamReadString(streamId)
    self.marketName = (rawMarketName ~= "") and rawMarketName or nil
    self.isPrivateMarket = streamReadBool(streamId)
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
        local ftNormalPrice = streamReadFloat32(streamId)
        local ftPrice = streamReadFloat32(streamId)

        table.insert(self.marketData, {
            fillType = ftName,
            status = (ftStatus ~= "") and ftStatus or "APPROVED",
            fillLevel = ftLevel,
            trend = (ftTrend > 0) and ftTrend or nil,
            isGreatDemand = ftGreatDemand,
            greatDemandBonus = (ftGdBonus > 0) and ftGdBonus or nil,
            greatDemandRemainingLiters = (ftGdRemaining > 0) and ftGdRemaining or nil,
            normalPrice = (ftNormalPrice > 0) and ftNormalPrice or nil,
            price = (ftPrice > 0) and ftPrice or nil
        })
    end
    self:run(connection)
end

function MarketDataSyncEvent:run(connection)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then return end

    if not connection:getIsServer() then
        -- Server: Only accept online market payloads from the designated Data-Host connection
        if gm.dataHostConnection ~= connection then
            if gm.debugManager ~= nil then
                gm.debugManager:warning("Network (Server): Ignored MarketDataSyncEvent from non-Data-Host client.")
            end
            return
        end

        if gm.applySyncedBranding ~= nil then
            gm:applySyncedBranding(self.marketName, self.isPrivateMarket)
        end
        gm:applySyncedMarketData(self.marketData)
        if g_server ~= nil then
            g_server:broadcastEvent(MarketDataSyncEvent.newFromServerState(gm))
        end
    else
        -- MP Client: Receive authoritative branding, stock levels, and server-computed Map-Spy prices
        if gm.applySyncedBranding ~= nil then
            gm:applySyncedBranding(self.marketName, self.isPrivateMarket)
        end
        gm:applySyncedMarketData(self.marketData)
    end
end

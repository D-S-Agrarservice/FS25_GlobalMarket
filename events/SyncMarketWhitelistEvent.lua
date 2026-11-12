-- =========================================================================================
-- FS25_GlobalMarket - SyncMarketWhitelistEvent.lua
-- Server-to-client event assigning the Data-Host role and transmitting the map whitelist.
-- Author: D-S-Agrarservice
-- =========================================================================================

SyncMarketWhitelistEvent = {}
local SyncMarketWhitelistEvent_mt = Class(SyncMarketWhitelistEvent, Event)

InitEventClass(SyncMarketWhitelistEvent, "SyncMarketWhitelistEvent")

function SyncMarketWhitelistEvent.emptyNew()
    return Event.new(SyncMarketWhitelistEvent_mt)
end

function SyncMarketWhitelistEvent.new(whitelist)
    local self = SyncMarketWhitelistEvent.emptyNew()
    self.whitelist = whitelist or {}
    return self
end

function SyncMarketWhitelistEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, #self.whitelist)
    for i = 1, #self.whitelist do
        local item = self.whitelist[i]
        streamWriteString(streamId, item.name or "")
        streamWriteString(streamId, item.title or "")
        streamWriteString(streamId, item.category or "PRODUCTS_PALLETS")
        streamWriteString(streamId, item.type or "BULK")
        streamWriteFloat32(streamId, item.basePrice or 0)
        streamWriteString(streamId, item.source or "BASEGAME")
    end
end

function SyncMarketWhitelistEvent:readStream(streamId, connection)
    self.whitelist = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        table.insert(self.whitelist, {
            name = streamReadString(streamId),
            title = streamReadString(streamId),
            category = streamReadString(streamId),
            type = streamReadString(streamId),
            basePrice = streamReadFloat32(streamId),
            source = streamReadString(streamId)
        })
    end
    self:run(connection)
end

function SyncMarketWhitelistEvent:run(connection)
    if not connection:getIsServer() then
        if g_currentMission.globalMarket ~= nil then
            g_currentMission.globalMarket:receiveDataHostToken(self.whitelist)
        end
    end
end
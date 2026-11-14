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

function SyncMarketWhitelistEvent.new(whitelist, isAssigned)
    local self = SyncMarketWhitelistEvent.emptyNew()
    self.isAssigned = (isAssigned ~= false)
    self.whitelist = self.isAssigned and (whitelist or {}) or {}
    return self
end

function SyncMarketWhitelistEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isAssigned ~= false)
    local list = (self.isAssigned ~= false and self.whitelist ~= nil) and self.whitelist or {}
    streamWriteInt32(streamId, #list)
    for i = 1, #list do
        local item = list[i]
        streamWriteString(streamId, item.name or "")
        streamWriteString(streamId, item.title or "")
        streamWriteString(streamId, item.category or "PRODUCTS_PALLETS")
        streamWriteString(streamId, item.type or "BULK")
        streamWriteFloat32(streamId, item.basePrice or 0)
        streamWriteString(streamId, item.source or "BASEGAME")
    end
end

function SyncMarketWhitelistEvent:readStream(streamId, connection)
    self.isAssigned = streamReadBool(streamId)
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
    -- Server-to-Client event: connection:getIsServer() is true on the receiving MP/Dedicated client
    if connection:getIsServer() and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil then
        local gm = g_currentMission.globalMarket
        if self.isAssigned then
            gm:receiveDataHostToken(self.whitelist)
        else
            gm.isDataHost = false
            gm:updateHudIconState()
            if gm.refreshBrandingUiIfOpen ~= nil then
                gm:refreshBrandingUiIfOpen()
            end
            if gm.debugManager ~= nil then
                gm.debugManager:info("Sync: Data-Host token revoked by server (switched to Standby).")
            end
        end
    end
end
-- =========================================================================================
-- FS25_GlobalMarket - SyncAnimalMarketEvent.lua
-- Livestock market (#15): server-to-client snapshot of all listings and pickup box entries
-- (on change, hourly while listings exist, and on join). Clients receive a compact view of the
-- animals with server-computed prices; the server keeps the authoritative clusters.
-- Author: D-S-Agrarservice
-- =========================================================================================

SyncAnimalMarketEvent = {}
local SyncAnimalMarketEvent_mt = Class(SyncAnimalMarketEvent, Event)
InitEventClass(SyncAnimalMarketEvent, "SyncAnimalMarketEvent")

function SyncAnimalMarketEvent.emptyNew()
    return Event.new(SyncAnimalMarketEvent_mt)
end

---@param listings table
---@param pickups table
function SyncAnimalMarketEvent.new(listings, pickups)
    local self = SyncAnimalMarketEvent.emptyNew()
    self.listings = listings or {}
    self.pickups = pickups or {}
    return self
end

function SyncAnimalMarketEvent:writeStream(streamId, connection)
    streamWriteUInt16(streamId, #self.listings)
    for _, listing in ipairs(self.listings) do
        streamWriteInt32(streamId, listing.id)
        streamWriteString(streamId, listing.uid or "")
        streamWriteString(streamId, listing.status or "OPEN")
        streamWriteUIntN(streamId, listing.sellerFarmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, listing.sellerName or "")
        streamWriteBool(streamId, listing.isNpc == true)
        streamWriteString(streamId, listing.saleMode or "FIXED")
        streamWriteFloat32(streamId, listing.priceFactor or 1)
        streamWriteFloat32(streamId, listing.monthsRemaining or 0)
        GlobalMarketAnimalListings.writeSnapshotToStream(streamId, listing.snapshot)
    end
    streamWriteUInt16(streamId, #self.pickups)
    for _, entry in ipairs(self.pickups) do
        streamWriteInt32(streamId, entry.id)
        streamWriteUIntN(streamId, entry.farmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, entry.reason or "")
        GlobalMarketAnimalListings.writeSnapshotToStream(streamId, entry.snapshot)
    end
end

function SyncAnimalMarketEvent:readStream(streamId, connection)
    self.listings = {}
    local numListings = streamReadUInt16(streamId)
    for _ = 1, numListings do
        local listing = {
            id = streamReadInt32(streamId),
            uid = streamReadString(streamId),
            status = streamReadString(streamId),
            sellerFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
            sellerName = streamReadString(streamId),
            isNpc = streamReadBool(streamId),
            saleMode = streamReadString(streamId),
            priceFactor = streamReadFloat32(streamId),
            monthsRemaining = streamReadFloat32(streamId)
        }
        listing.snapshot = GlobalMarketAnimalListings.readSnapshotFromStream(streamId)
        table.insert(self.listings, listing)
    end
    self.pickups = {}
    local numPickups = streamReadUInt16(streamId)
    for _ = 1, numPickups do
        local entry = {
            id = streamReadInt32(streamId),
            farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
            reason = streamReadString(streamId)
        }
        entry.snapshot = GlobalMarketAnimalListings.readSnapshotFromStream(streamId)
        table.insert(self.pickups, entry)
    end
    self:run(connection)
end

function SyncAnimalMarketEvent:run(connection)
    -- Server-to-client only
    if not connection:getIsServer() then
        return
    end
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm ~= nil and gm.applyAnimalMarketState ~= nil then
        gm:applyAnimalMarketState(self.listings, self.pickups)
    end
end

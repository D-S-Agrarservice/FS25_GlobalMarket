-- =========================================================================================
-- FS25_GlobalMarket - SyncAnimalMarketEvent.lua
-- Livestock market (#15): server-to-client snapshot of all listings, pickup box entries and the great demand
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
---@param demand table|nil Active great demand for meat animals (Stage 1b)
function SyncAnimalMarketEvent.new(listings, pickups, demand)
    local self = SyncAnimalMarketEvent.emptyNew()
    self.listings = listings or {}
    self.pickups = pickups or {}
    self.demand = demand
    return self
end

---Writes the client view of an auction (Stage 2); reserved amounts stay on the server
---@param streamId number
---@param auction table|nil
function SyncAnimalMarketEvent.writeAuction(streamId, auction)
    streamWriteBool(streamId, auction ~= nil)
    if auction == nil then
        return
    end
    streamWriteFloat32(streamId, auction.startFactor or 1)
    streamWriteFloat32(streamId, auction.buyNowFactor or 0)
    streamWriteFloat32(streamId, auction.hoursRemaining or 0)
    streamWriteFloat32(streamId, auction.highFactor or -1)
    streamWriteUIntN(streamId, auction.highFarmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteBool(streamId, auction.highIsNpc == true)
    streamWriteUInt16(streamId, math.min(auction.bidCount or 0, 65535))
    local bidders = {}
    for farmId in pairs(auction.bidders or {}) do
        table.insert(bidders, farmId)
    end
    streamWriteUInt8(streamId, math.min(#bidders, 255))
    for i = 1, math.min(#bidders, 255) do
        streamWriteUIntN(streamId, bidders[i], FarmManager.FARM_ID_SEND_NUM_BITS)
    end
end

---Reads an auction written by writeAuction
---@param streamId number
---@return table|nil auction
function SyncAnimalMarketEvent.readAuction(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local auction = {
        startFactor = streamReadFloat32(streamId),
        buyNowFactor = streamReadFloat32(streamId),
        hoursRemaining = streamReadFloat32(streamId),
        highFactor = streamReadFloat32(streamId),
        highFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
        highIsNpc = streamReadBool(streamId),
        bidCount = streamReadUInt16(streamId),
        highReserved = 0,
        bidders = {}
    }
    if auction.buyNowFactor <= 0 then
        auction.buyNowFactor = nil
    end
    if auction.highFactor < 0 then
        auction.highFactor = nil
        auction.highFarmId = nil
    end
    for _ = 1, streamReadUInt8(streamId) do
        auction.bidders[streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)] = true
    end
    return auction
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
        SyncAnimalMarketEvent.writeAuction(streamId, listing.auction)
        GlobalMarketAnimalListings.writeSnapshotToStream(streamId, listing.snapshot)
    end
    streamWriteUInt16(streamId, #self.pickups)
    for _, entry in ipairs(self.pickups) do
        streamWriteInt32(streamId, entry.id)
        streamWriteUIntN(streamId, entry.farmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, entry.reason or "")
        GlobalMarketAnimalListings.writeSnapshotToStream(streamId, entry.snapshot)
    end
    local demand = self.demand
    streamWriteBool(streamId, demand ~= nil)
    if demand ~= nil then
        streamWriteString(streamId, demand.typeName or "")
        streamWriteFloat32(streamId, demand.bonus or 0)
        streamWriteFloat32(streamId, demand.hoursRemaining or 0)
        streamWriteUInt16(streamId, math.max(0, math.min(demand.quota or 0, 65535)))
        streamWriteUInt16(streamId, math.max(0, math.min(demand.sold or 0, 65535)))
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
        listing.auction = SyncAnimalMarketEvent.readAuction(streamId)
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
    self.demand = nil
    if streamReadBool(streamId) then
        self.demand = {
            typeName = streamReadString(streamId),
            bonus = streamReadFloat32(streamId),
            hoursRemaining = streamReadFloat32(streamId),
            quota = streamReadUInt16(streamId),
            sold = streamReadUInt16(streamId)
        }
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
        gm:applyAnimalMarketState(self.listings, self.pickups, self.demand)
    end
end

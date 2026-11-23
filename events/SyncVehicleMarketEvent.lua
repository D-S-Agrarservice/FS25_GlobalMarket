-- =========================================================================================
-- FS25_GlobalMarket - SyncVehicleMarketEvent.lua
-- Used vehicle market (#16): server-to-client snapshot of all listings (on change and on join).
-- Carries the full vehicle snapshot so clients can show and preview listings.
-- Author: D-S-Agrarservice
-- =========================================================================================

SyncVehicleMarketEvent = {}
local SyncVehicleMarketEvent_mt = Class(SyncVehicleMarketEvent, Event)
InitEventClass(SyncVehicleMarketEvent, "SyncVehicleMarketEvent")

SyncVehicleMarketEvent.MAX_CONFIGS = 255

function SyncVehicleMarketEvent.emptyNew()
    return Event.new(SyncVehicleMarketEvent_mt)
end

---@param listings table
function SyncVehicleMarketEvent.new(listings)
    local self = SyncVehicleMarketEvent.emptyNew()
    self.listings = listings or {}
    -- Online vehicle market availability (#36), evaluated on the server
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    self.onlineAvailable = gm ~= nil and gm.getAreOnlineVehiclesAvailable ~= nil and gm:getAreOnlineVehiclesAvailable()
    return self
end

---Writes an optional string ("" = nil)
local function writeOptString(streamId, value)
    streamWriteString(streamId, value or "")
end

---Reads an optional string ("" = nil)
local function readOptString(streamId)
    local value = streamReadString(streamId)
    if value == "" then
        return nil
    end
    return value
end

---Writes a vehicle snapshot (also used by VehicleOnlineBridgeEvent)
---@param streamId number
---@param snap table
function SyncVehicleMarketEvent.writeSnapshot(streamId, snap)
    streamWriteString(streamId, snap.xmlFilename or "")
    writeOptString(streamId, snap.modName)
    writeOptString(streamId, snap.modFileHash)
    streamWriteString(streamId, snap.group or "MISC")
    streamWriteInt32(streamId, snap.age or 0)
    streamWriteFloat32(streamId, snap.operatingTime or 0)
    streamWriteFloat32(streamId, snap.damage or 0)
    streamWriteFloat32(streamId, snap.wear or 0)

    local configs = snap.configs or {}
    local count = math.min(#configs, SyncVehicleMarketEvent.MAX_CONFIGS)
    streamWriteUInt8(streamId, count)
    for i = 1, count do
        local entry = configs[i]
        streamWriteString(streamId, entry.name)
        streamWriteString(streamId, entry.saveId)
        streamWriteBool(streamId, entry.isActive == true)
        streamWriteBool(streamId, entry.isBought == true)
        streamWriteBool(streamId, entry.color ~= nil)
        if entry.color ~= nil then
            streamWriteFloat32(streamId, entry.color[1])
            streamWriteFloat32(streamId, entry.color[2])
            streamWriteFloat32(streamId, entry.color[3])
        end
        writeOptString(streamId, entry.materialTemplateName)
    end
end

---Reads a vehicle snapshot written by writeSnapshot
---@param streamId number
---@return table snap
function SyncVehicleMarketEvent.readSnapshot(streamId)
    local snap = {
        xmlFilename = streamReadString(streamId),
        modName = readOptString(streamId),
        modFileHash = readOptString(streamId),
        group = streamReadString(streamId),
        age = streamReadInt32(streamId),
        operatingTime = streamReadFloat32(streamId),
        damage = streamReadFloat32(streamId),
        wear = streamReadFloat32(streamId),
        configs = {}
    }
    local count = streamReadUInt8(streamId)
    for _ = 1, count do
        local entry = {
            name = streamReadString(streamId),
            saveId = streamReadString(streamId),
            isActive = streamReadBool(streamId),
            isBought = streamReadBool(streamId)
        }
        if streamReadBool(streamId) then
            entry.color = { streamReadFloat32(streamId), streamReadFloat32(streamId), streamReadFloat32(streamId) }
        end
        entry.materialTemplateName = readOptString(streamId)
        table.insert(snap.configs, entry)
    end
    return snap
end

function SyncVehicleMarketEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.onlineAvailable == true)
    local listings = self.listings
    streamWriteUInt16(streamId, #listings)
    for _, listing in ipairs(listings) do
        local snap = listing.snapshot
        streamWriteInt32(streamId, listing.id)
        streamWriteString(streamId, listing.uid or "")
        streamWriteString(streamId, listing.status or "OPEN")
        streamWriteUIntN(streamId, listing.sellerFarmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, listing.sellerName or "")
        streamWriteBool(streamId, listing.isNpc == true)
        streamWriteString(streamId, listing.saleMode or "FIXED")
        streamWriteFloat32(streamId, listing.priceFactor or 1)
        streamWriteFloat32(streamId, listing.monthsRemaining or 0)

        SyncVehicleMarketEvent.writeSnapshot(streamId, snap)
    end
end

function SyncVehicleMarketEvent:readStream(streamId, connection)
    self.onlineAvailable = streamReadBool(streamId)
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
        listing.snapshot = SyncVehicleMarketEvent.readSnapshot(streamId)
        table.insert(self.listings, listing)
    end
    self:run(connection)
end

function SyncVehicleMarketEvent:run(connection)
    -- Server-to-client only
    if not connection:getIsServer() then
        return
    end
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm ~= nil and gm.applyOnlineVehiclesAvailable ~= nil then
        gm:applyOnlineVehiclesAvailable(self.onlineAvailable)
    end
    if gm ~= nil and gm.applyVehicleMarketState ~= nil then
        gm:applyVehicleMarketState(self.listings)
    end
end

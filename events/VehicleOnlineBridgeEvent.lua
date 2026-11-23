-- =========================================================================================
-- FS25_GlobalMarket - VehicleOnlineBridgeEvent.lua
-- Cross-server vehicle market (#36): relay between the authoritative server and a remote
-- Data-Host. Server -> Data-Host: vehicleAction payloads to write for the companion client.
-- Data-Host -> server: parsed vehicleData packets (listings, action results, settlements).
-- Author: D-S-Agrarservice
-- =========================================================================================

VehicleOnlineBridgeEvent = {}
local VehicleOnlineBridgeEvent_mt = Class(VehicleOnlineBridgeEvent, Event)
InitEventClass(VehicleOnlineBridgeEvent, "VehicleOnlineBridgeEvent")

VehicleOnlineBridgeEvent.MODE_EXPORT_ACTION = 1
VehicleOnlineBridgeEvent.MODE_SYNC_PACKET = 2

function VehicleOnlineBridgeEvent.emptyNew()
    return Event.new(VehicleOnlineBridgeEvent_mt)
end

---Server -> Data-Host: one outgoing vehicleAction payload
---@param payload table
function VehicleOnlineBridgeEvent.newExportAction(payload)
    local self = VehicleOnlineBridgeEvent.emptyNew()
    self.mode = VehicleOnlineBridgeEvent.MODE_EXPORT_ACTION
    self.payload = payload or {}
    return self
end

---Data-Host -> server: one parsed vehicleData packet
---@param packet table
function VehicleOnlineBridgeEvent.newSyncPacket(packet)
    local self = VehicleOnlineBridgeEvent.emptyNew()
    self.mode = VehicleOnlineBridgeEvent.MODE_SYNC_PACKET
    self.packet = packet or {}
    return self
end

---Writes an optional snapshot
local function writeOptSnapshot(streamId, snapshot)
    streamWriteBool(streamId, snapshot ~= nil)
    if snapshot ~= nil then
        SyncVehicleMarketEvent.writeSnapshot(streamId, snapshot)
    end
end

---Reads an optional snapshot
local function readOptSnapshot(streamId)
    if streamReadBool(streamId) then
        return SyncVehicleMarketEvent.readSnapshot(streamId)
    end
    return nil
end

---Writes a vehicleData packet
local function writePacket(streamId, pkt)
    streamWriteBool(streamId, pkt.hasListings == true)
    local listings = pkt.listings or {}
    streamWriteUInt16(streamId, #listings)
    for _, e in ipairs(listings) do
        streamWriteString(streamId, e.remoteId or "")
        streamWriteString(streamId, e.createActionId or "")
        streamWriteString(streamId, e.saleMode or "FIXED")
        streamWriteString(streamId, e.sellerServerId or "")
        streamWriteUIntN(streamId, e.sellerFarmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, e.sellerName or "")
        streamWriteFloat32(streamId, e.priceFactor or 1)
        streamWriteInt32(streamId, e.remainingSeconds or 0)
        streamWriteString(streamId, e.status or "OPEN")
        SyncVehicleMarketEvent.writeSnapshot(streamId, e.snapshot)
    end
    local results = pkt.actionResults or {}
    streamWriteUInt16(streamId, #results)
    for _, r in ipairs(results) do
        streamWriteString(streamId, r.actionId or "")
        streamWriteString(streamId, r.subAction or "")
        streamWriteString(streamId, r.status or "")
        streamWriteString(streamId, r.reason or "")
        streamWriteString(streamId, r.remoteId or "")
        streamWriteInt32(streamId, r.remainingSeconds or 0)
        writeOptSnapshot(streamId, r.snapshot)
    end
    local settlements = pkt.settlements or {}
    streamWriteUInt16(streamId, #settlements)
    for _, s in ipairs(settlements) do
        streamWriteString(streamId, s.settlementId or "")
        streamWriteString(streamId, s.type or "")
        streamWriteString(streamId, s.targetServerId or "")
        streamWriteUIntN(streamId, s.targetFarmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, s.remoteId or "")
        streamWriteString(streamId, s.createActionId or "")
        streamWriteString(streamId, s.buyActionId or "")
        streamWriteFloat32(streamId, s.priceFactor or 1)
        streamWriteString(streamId, s.otherName or "")
        writeOptSnapshot(streamId, s.snapshot)
    end
end

---Reads a vehicleData packet written by writePacket
local function readPacket(streamId)
    local pkt = { hasListings = streamReadBool(streamId), listings = {}, actionResults = {}, settlements = {} }
    for _ = 1, streamReadUInt16(streamId) do
        local e = {
            remoteId = streamReadString(streamId),
            createActionId = streamReadString(streamId),
            saleMode = streamReadString(streamId),
            sellerServerId = streamReadString(streamId),
            sellerFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
            sellerName = streamReadString(streamId),
            priceFactor = streamReadFloat32(streamId),
            remainingSeconds = streamReadInt32(streamId),
            status = streamReadString(streamId)
        }
        e.snapshot = SyncVehicleMarketEvent.readSnapshot(streamId)
        table.insert(pkt.listings, e)
    end
    for _ = 1, streamReadUInt16(streamId) do
        local r = {
            actionId = streamReadString(streamId),
            subAction = streamReadString(streamId),
            status = streamReadString(streamId),
            reason = streamReadString(streamId),
            remoteId = streamReadString(streamId),
            remainingSeconds = streamReadInt32(streamId)
        }
        r.snapshot = readOptSnapshot(streamId)
        table.insert(pkt.actionResults, r)
    end
    for _ = 1, streamReadUInt16(streamId) do
        local s = {
            settlementId = streamReadString(streamId),
            type = streamReadString(streamId),
            targetServerId = streamReadString(streamId),
            targetFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
            remoteId = streamReadString(streamId),
            createActionId = streamReadString(streamId),
            buyActionId = streamReadString(streamId),
            priceFactor = streamReadFloat32(streamId),
            otherName = streamReadString(streamId)
        }
        s.snapshot = readOptSnapshot(streamId)
        table.insert(pkt.settlements, s)
    end
    return pkt
end

function VehicleOnlineBridgeEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.mode or VehicleOnlineBridgeEvent.MODE_EXPORT_ACTION)
    if self.mode == VehicleOnlineBridgeEvent.MODE_SYNC_PACKET then
        writePacket(streamId, self.packet or {})
        return
    end
    local p = self.payload or {}
    streamWriteString(streamId, p.subAction or "")
    streamWriteString(streamId, p.actionId or "")
    streamWriteString(streamId, p.serverId or "")
    streamWriteUIntN(streamId, p.farmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteString(streamId, p.farmName or "")
    streamWriteString(streamId, p.saleMode or "")
    streamWriteFloat32(streamId, p.priceFactor or 0)
    streamWriteUInt16(streamId, p.durationHours or 0)
    streamWriteString(streamId, p.remoteId or "")
    streamWriteString(streamId, p.createActionId or "")
    streamWriteString(streamId, p.settlementIds or "")
    streamWriteBool(streamId, p.snapshot ~= nil)
    if p.snapshot ~= nil then
        SyncVehicleMarketEvent.writeSnapshot(streamId, p.snapshot)
    end
end

function VehicleOnlineBridgeEvent:readStream(streamId, connection)
    self.mode = streamReadUInt8(streamId)
    if self.mode == VehicleOnlineBridgeEvent.MODE_SYNC_PACKET then
        self.packet = readPacket(streamId)
        self:run(connection)
        return
    end
    local p = {
        subAction = streamReadString(streamId),
        actionId = streamReadString(streamId),
        serverId = streamReadString(streamId),
        farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
        farmName = streamReadString(streamId),
        saleMode = streamReadString(streamId),
        priceFactor = streamReadFloat32(streamId),
        durationHours = streamReadUInt16(streamId),
        remoteId = streamReadString(streamId),
        createActionId = streamReadString(streamId),
        settlementIds = streamReadString(streamId)
    }
    if streamReadBool(streamId) then
        p.snapshot = SyncVehicleMarketEvent.readSnapshot(streamId)
    end
    self.payload = p
    self:run(connection)
end

function VehicleOnlineBridgeEvent:run(connection)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return
    end
    -- Packets are accepted from the active Data-Host only
    if self.mode == VehicleOnlineBridgeEvent.MODE_SYNC_PACKET then
        if not connection:getIsServer() and g_server ~= nil and gm.dataHostConnection == connection then
            gm:applyVehicleSyncPacket(self.packet)
        elseif gm.debugManager ~= nil then
            gm.debugManager:warning("VehicleOnline: Ignored vehicleData relay from a client without Data-Host role.")
        end
        return
    end
    -- Only the server may hand actions to the Data-Host
    if self.mode == VehicleOnlineBridgeEvent.MODE_EXPORT_ACTION and connection:getIsServer() then
        if gm.isDataHost and gm.exportVehicleAction ~= nil then
            gm:exportVehicleAction(self.payload)
        elseif gm.debugManager ~= nil then
            gm.debugManager:warning("VehicleOnline: Received vehicleAction '%s' without Data-Host role, dropped.", tostring(self.payload.subAction))
        end
    end
end

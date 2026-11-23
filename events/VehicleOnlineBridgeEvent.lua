-- =========================================================================================
-- FS25_GlobalMarket - VehicleOnlineBridgeEvent.lua
-- Cross-server vehicle market (#36): relay between the authoritative server and a remote
-- Data-Host. Server -> Data-Host: vehicleAction payloads to write for the companion client.
-- Author: D-S-Agrarservice
-- =========================================================================================

VehicleOnlineBridgeEvent = {}
local VehicleOnlineBridgeEvent_mt = Class(VehicleOnlineBridgeEvent, Event)
InitEventClass(VehicleOnlineBridgeEvent, "VehicleOnlineBridgeEvent")

VehicleOnlineBridgeEvent.MODE_EXPORT_ACTION = 1

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

function VehicleOnlineBridgeEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.mode or VehicleOnlineBridgeEvent.MODE_EXPORT_ACTION)
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
    -- Only the server may hand actions to the Data-Host
    if self.mode == VehicleOnlineBridgeEvent.MODE_EXPORT_ACTION and connection:getIsServer() then
        if gm.isDataHost and gm.exportVehicleAction ~= nil then
            gm:exportVehicleAction(self.payload)
        elseif gm.debugManager ~= nil then
            gm.debugManager:warning("VehicleOnline: Received vehicleAction '%s' without Data-Host role, dropped.", tostring(self.payload.subAction))
        end
    end
end

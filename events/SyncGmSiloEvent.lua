--
-- FS25 - GlobalMarket (SyncGmSiloEvent)
-- Syncs dynamic changes in the GM shadow array (dumping/loading) from Server to Clients.
--

SyncGmSiloEvent = {}
local SyncGmSiloEvent_mt = Class(SyncGmSiloEvent, Event)

InitEventClass(SyncGmSiloEvent, "SyncGmSiloEvent")

function SyncGmSiloEvent.emptyNew()
    return Event.new(SyncGmSiloEvent_mt)
end

function SyncGmSiloEvent.new(storage, farmId, fillTypeIndex, newFillLevel)
    local self = SyncGmSiloEvent.emptyNew()
    self.farmId = farmId
    self.fillTypeIndex = fillTypeIndex
    self.newFillLevel = newFillLevel

    -- FIX: Safe Network Node resolution to prevent transmitting raw Lua tables
    self.targetPlaceable = nil
    self.storageIndex = 1

    if storage ~= nil and type(storage) == "table" then
        if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
            for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                    for i, s in ipairs(placeable.spec_silo.storages) do
                        if s == storage then
                            self.targetPlaceable = placeable
                            self.storageIndex = i
                            break
                        end
                    end
                end
                if self.targetPlaceable ~= nil then break end
            end
        end
    end

    return self
end

function SyncGmSiloEvent:readStream(streamId, connection)
    -- Read the Network Node and Index
    self.targetPlaceable = NetworkUtil.readNodeObject(streamId)
    self.storageIndex = streamReadUIntN(streamId, 8)

    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.fillTypeIndex = streamReadUIntN(streamId, 10)
    self.newFillLevel = streamReadFloat32(streamId)

    -- Reconstruct raw storage for the client UI update
    self.storage = nil
    if self.targetPlaceable ~= nil and self.targetPlaceable.spec_silo ~= nil and self.targetPlaceable.spec_silo.storages ~= nil then
        self.storage = self.targetPlaceable.spec_silo.storages[self.storageIndex]
    end

    self:run(connection)
end

function SyncGmSiloEvent:writeStream(streamId, connection)
    -- Send the Network Node and Index instead of the raw storage table
    NetworkUtil.writeNodeObject(streamId, self.targetPlaceable)
    streamWriteUIntN(streamId, self.storageIndex, 8)

    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.fillTypeIndex, 10)
    streamWriteFloat32(streamId, self.newFillLevel)
end

function SyncGmSiloEvent:run(connection)
    -- Only execute on the Client (Server sends this to Clients)
    if not connection:getIsServer() then
        if self.storage ~= nil then
            self.storage.gmFarmFillLevels = self.storage.gmFarmFillLevels or {}
            self.storage.gmFarmFillLevels[self.farmId] = self.storage.gmFarmFillLevels[self.farmId] or {}
            self.storage.gmFarmFillLevels[self.farmId][self.fillTypeIndex] = self.newFillLevel

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("Network (Client): Received live silo sync for Farm %d. Level: %.2f", self.farmId, self.newFillLevel)
            end
        else
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:error("Network (Client): Live silo sync failed. Storage reconstruction resulted in nil!")
            end
        end
    end
end
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
    self.storage = storage
    self.farmId = farmId
    self.fillTypeIndex = fillTypeIndex
    self.newFillLevel = newFillLevel
    return self
end

function SyncGmSiloEvent:readStream(streamId, connection)
    self.storage = NetworkUtil.readNodeObject(streamId)
    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.fillTypeIndex = streamReadUIntN(streamId, 10)
    self.newFillLevel = streamReadFloat32(streamId)
    self:run(connection)
end

function SyncGmSiloEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.storage)
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
                GlobalMarket.debugManager:trace("Network (Client): Received live silo sync for Farm %d", self.farmId)
            end
        end
    end
end
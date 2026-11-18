-- =========================================================================================
-- FS25_GlobalMarket - SyncGmStorageAgeEvent.lua
-- Server-to-client snapshot of GM storage ages (remaining storage time display, #20).
-- Author: D-S-Agrarservice
-- =========================================================================================

SyncGmStorageAgeEvent = {}
local SyncGmStorageAgeEvent_mt = Class(SyncGmStorageAgeEvent, Event)

InitEventClass(SyncGmStorageAgeEvent, "SyncGmStorageAgeEvent")

SyncGmStorageAgeEvent.MAX_ENTRIES = 4095
SyncGmStorageAgeEvent.COUNT_NUM_BITS = 12

function SyncGmStorageAgeEvent.emptyNew()
    return Event.new(SyncGmStorageAgeEvent_mt)
end

---@param entries table {placeable, storageIndex, farmId, fillTypeIndex, months}
function SyncGmStorageAgeEvent.new(entries)
    local self = SyncGmStorageAgeEvent.emptyNew()
    self.entries = entries or {}
    return self
end

function SyncGmStorageAgeEvent:writeStream(streamId, connection)
    -- Only registered, live placeables can be addressed over the network
    local list = {}
    for _, e in ipairs(self.entries or {}) do
        if e.placeable ~= nil and e.placeable.isRegistered and not e.placeable.isDeleted
            and #list < SyncGmStorageAgeEvent.MAX_ENTRIES then
            table.insert(list, e)
        end
    end

    streamWriteUIntN(streamId, #list, SyncGmStorageAgeEvent.COUNT_NUM_BITS)
    for _, e in ipairs(list) do
        NetworkUtil.writeNodeObject(streamId, e.placeable)
        streamWriteUIntN(streamId, e.storageIndex or 0, 8)
        streamWriteUIntN(streamId, e.farmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteUIntN(streamId, e.fillTypeIndex or 0, FillTypeManager.SEND_NUM_BITS)
        streamWriteFloat32(streamId, e.months or 0)
    end
end

function SyncGmStorageAgeEvent:readStream(streamId, connection)
    self.entries = {}
    local count = streamReadUIntN(streamId, SyncGmStorageAgeEvent.COUNT_NUM_BITS)
    for _ = 1, count do
        local placeable = NetworkUtil.readNodeObject(streamId)
        local entry = {
            placeable = placeable,
            storageIndex = streamReadUIntN(streamId, 8),
            farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS),
            fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS),
            months = streamReadFloat32(streamId)
        }
        if placeable ~= nil then
            table.insert(self.entries, entry)
        end
    end
    self:run(connection)
end

function SyncGmStorageAgeEvent:run(connection)
    -- Server-to-client only
    if not connection:getIsServer() then
        return
    end
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm ~= nil and gm.applyGmStorageAgeEntries ~= nil then
        gm:applyGmStorageAgeEntries(self.entries)
    end
end

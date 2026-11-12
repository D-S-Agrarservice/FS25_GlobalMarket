-- =========================================================================================
-- FS25_GlobalMarket - SyncGmSiloEvent.lua
-- Synchronizes per-farm GM terminal shadow arrays and storage lifecycle notifications.
-- Author: D-S-Agrarservice
-- =========================================================================================

SyncGmSiloEvent = {}
local SyncGmSiloEvent_mt = Class(SyncGmSiloEvent, Event)

InitEventClass(SyncGmSiloEvent, "SyncGmSiloEvent")

function SyncGmSiloEvent.emptyNew()
    return Event.new(SyncGmSiloEvent_mt)
end

function SyncGmSiloEvent.new(storage, farmId, fillTypeIndex, newFillLevel, notifyType, notifyParamA, notifyParamB)
    local self = SyncGmSiloEvent.emptyNew()
    self.farmId = farmId or 0
    self.fillTypeIndex = fillTypeIndex or 1
    self.newFillLevel = newFillLevel or 0
    self.notifyType = notifyType or 0
    self.notifyParamA = notifyParamA or 0
    self.notifyParamB = notifyParamB or 0

    self.targetPlaceable = nil
    self.storageIndex = 1

    if storage ~= nil and type(storage) == "table" then
        -- Fallback 1: Native Engine Reference (FS25 standard)
        if storage.owningPlaceable ~= nil then
            self.targetPlaceable = storage.owningPlaceable
            if self.targetPlaceable.spec_silo ~= nil and self.targetPlaceable.spec_silo.storages ~= nil then
                for i, s in ipairs(self.targetPlaceable.spec_silo.storages) do
                    if s == storage then
                        self.storageIndex = i
                        break
                    end
                end
            end
        end

        -- Fallback 2: Brute-Force loop (in case of Silo Extensions)
        if self.targetPlaceable == nil and g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
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

        if GlobalMarket.debugManager ~= nil then
            if self.targetPlaceable == nil then
                GlobalMarket.debugManager:error("Network (Server): SyncGmSiloEvent FAILED. Could not resolve targetPlaceable for Storage!")
            else
                GlobalMarket.debugManager:trace("Network (Server): SyncGmSiloEvent created successfully. Broadcasting to clients...")
            end
        end
    end

    return self
end

function SyncGmSiloEvent:readStream(streamId, connection)
    local hasStorage = streamReadBool(streamId)
    if hasStorage then
        self.targetPlaceable = NetworkUtil.readNodeObject(streamId)
        self.storageIndex = streamReadUIntN(streamId, 8)
        self.newFillLevel = streamReadFloat32(streamId)
    else
        self.targetPlaceable = nil
        self.storageIndex = 1
        self.newFillLevel = 0
    end

    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.fillTypeIndex = streamReadUIntN(streamId, 10)

    local hasNotify = streamReadBool(streamId)
    if hasNotify then
        self.notifyType = streamReadUIntN(streamId, 8)
        self.notifyParamA = streamReadFloat32(streamId)
        self.notifyParamB = streamReadFloat32(streamId)
    else
        self.notifyType = 0
        self.notifyParamA = 0
        self.notifyParamB = 0
    end

    self.storage = nil
    if hasStorage and self.targetPlaceable ~= nil and self.targetPlaceable.spec_silo ~= nil and self.targetPlaceable.spec_silo.storages ~= nil then
        self.storage = self.targetPlaceable.spec_silo.storages[self.storageIndex]
    end

    self:run(connection)
end

function SyncGmSiloEvent:writeStream(streamId, connection)
    local hasStorage = (self.targetPlaceable ~= nil)
    streamWriteBool(streamId, hasStorage)
    if hasStorage then
        NetworkUtil.writeNodeObject(streamId, self.targetPlaceable)
        streamWriteUIntN(streamId, self.storageIndex, 8)
        streamWriteFloat32(streamId, self.newFillLevel)
    end

    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteUIntN(streamId, self.fillTypeIndex, 10)

    local hasNotify = (self.notifyType ~= nil and self.notifyType > 0)
    streamWriteBool(streamId, hasNotify)
    if hasNotify then
        streamWriteUIntN(streamId, self.notifyType, 8)
        streamWriteFloat32(streamId, self.notifyParamA or 0)
        streamWriteFloat32(streamId, self.notifyParamB or 0)
    end
end

function SyncGmSiloEvent:run(connection)
    -- Relay for Admin Console Command `gmAdvanceStorageAge` from Dedicated Server Client to Server
    if not connection:getIsServer() then
        if self.notifyType == 99 and g_currentMission.globalMarket ~= nil then
            local isMaster = (
                g_currentMission.userManager ~= nil
                and g_currentMission.userManager.getIsConnectionMasterUser ~= nil
                and g_currentMission.userManager:getIsConnectionMasterUser(connection)
            )
            if isMaster and g_currentMission.globalMarket.updateGmStorageFeesAndDecay ~= nil then
                g_currentMission.globalMarket:updateGmStorageFeesAndDecay(self.notifyParamA)
            end
        end
        return
    end

    -- Execute only on clients. g_server is false on dedicated clients.
    if not g_server then
        if self.storage ~= nil then
            self.storage.gmFarmFillLevels = self.storage.gmFarmFillLevels or {}
            self.storage.gmFarmFillLevels[self.farmId] = self.storage.gmFarmFillLevels[self.farmId] or {}
            self.storage.gmFarmFillLevels[self.farmId][self.fillTypeIndex] = self.newFillLevel

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("Network (Client): Received live silo sync for Farm %d. New Level: %.2f", self.farmId, self.newFillLevel)
            end

            -- Force UI update immediately if open
            if g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.ui ~= nil and g_currentMission.globalMarket.ui:getIsVisible() then
                g_currentMission.globalMarket.ui:updateContent()
            end
        end

        -- Display farm-specific HUD notification if this client belongs to self.farmId
        if self.notifyType ~= nil and self.notifyType > 0 and self.notifyType < 90 then
            if g_currentMission ~= nil and g_currentMission:getFarmId() == self.farmId then
                if GlobalMarketFinance ~= nil and GlobalMarketFinance.showStorageNotificationLocal ~= nil then
                    GlobalMarketFinance.showStorageNotificationLocal(self.fillTypeIndex, self.notifyType, self.notifyParamA, self.notifyParamB)
                end
            end
        end
    end
end

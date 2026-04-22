--
-- FS25 - GlobalMarket (Access & Permission Module)
-- Description: Handles engine hooks for multi-farm access to GM Terminals.
-- Note: Modifies native base game permission checks and ObjectStorage handling.
--

GlobalMarketAccess = {}

function GlobalMarketAccess.init()
    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("Initializing GlobalMarket Access & Permission Hooks...")
    end

    -- =========================================================================
    -- Hook 1: AccessHandler Bypass for GM Terminals
    -- Allows any farm to physically interact with GM triggers (Bulk & Object)
    -- =========================================================================

    -- Bypass for player on-foot interaction (e.g., ObjectStorageActivatable)
    local function canPlayerAccessHook(accessHandler, superFunc, object)
        if object ~= nil then
            -- Check if the object itself or its owning placeable is a GM terminal
            local isGmMarket = object.isGmMarket or (object.owningPlaceable ~= nil and object.owningPlaceable.isGmMarket)
            if isGmMarket then
                return true
            end
        end
        return superFunc(accessHandler, object)
    end
    AccessHandler.canPlayerAccess = Utils.overwrittenFunction(AccessHandler.canPlayerAccess, canPlayerAccessHook)

    -- Bypass for farm/vehicle interaction (e.g., UnloadingStation, LoadTrigger)
    local function canFarmAccessHook(accessHandler, superFunc, farmId, object, ...)
        if object ~= nil then
            local isGmMarket = object.isGmMarket or (object.owningPlaceable ~= nil and object.owningPlaceable.isGmMarket)
            if isGmMarket then
                return true
            end
        end
        return superFunc(accessHandler, farmId, object, ...)
    end
    AccessHandler.canFarmAccess = Utils.overwrittenFunction(AccessHandler.canFarmAccess, canFarmAccessHook)

    -- =========================================================================
    -- Hook 2: Prevent Object Merging Across Different Farms
    -- Forces PlaceableObjectStorage to create separate objectInfos per farm
    -- =========================================================================

    local AbstractBaleObject = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"]
    local AbstractPackedBaleObject = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["PackedBale"]
    local AbstractPalletObject = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Vehicle"]

    -- Prevent merging of Bales
    local function baleGetIsIdenticalHook(self, superFunc, otherAbstractObject)
        -- Extract farmId. Fallback to SPECTATOR_FARM_ID if none exists.
        local myFarmId = (self.baleObject ~= nil and self.baleObject.ownerFarmId) or (self.baleAttributes ~= nil and self.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID
        local otherFarmId = (otherAbstractObject.baleObject ~= nil and otherAbstractObject.baleObject.ownerFarmId) or (otherAbstractObject.baleAttributes ~= nil and otherAbstractObject.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID

        if myFarmId ~= otherFarmId then
            return false
        end

        return superFunc(self, otherAbstractObject)
    end

    if AbstractBaleObject ~= nil then
        AbstractBaleObject.getIsIdentical = Utils.overwrittenFunction(AbstractBaleObject.getIsIdentical, baleGetIsIdenticalHook)
    end
    if AbstractPackedBaleObject ~= nil then
        AbstractPackedBaleObject.getIsIdentical = Utils.overwrittenFunction(AbstractPackedBaleObject.getIsIdentical, baleGetIsIdenticalHook)
    end

    -- Prevent merging of Pallets
    local function palletGetIsIdenticalHook(self, superFunc, otherAbstractObject)
        local myFarmId = self.palletAttributes ~= nil and self.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
        local otherFarmId = otherAbstractObject.palletAttributes ~= nil and otherAbstractObject.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID

        if myFarmId ~= otherFarmId then
            return false
        end

        return superFunc(self, otherAbstractObject)
    end

    if AbstractPalletObject ~= nil then
        AbstractPalletObject.getIsIdentical = Utils.overwrittenFunction(AbstractPalletObject.getIsIdentical, palletGetIsIdenticalHook)
    end

    -- =========================================================================
    -- Hook 3: Network Synchronization of farmId for AbstractObjects
    -- Ensures clients know the owner of stored objects for UI filtering
    -- =========================================================================

    -- Bale Stream Hook Write (Object Method: obj:writeStream)
    local function baleWriteStreamHook(self, superFunc, streamId, connection)
        superFunc(self, streamId, connection)
        local farmId = (self.baleObject ~= nil and self.baleObject.ownerFarmId) or (self.baleAttributes ~= nil and self.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID
        streamWriteUIntN(streamId, farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    end

    -- Bale Stream Hook Read (Static Constructor: Class.readStream)
    -- FIX: For static functions, Utils.overwrittenFunction passes the first original argument (streamId)
    -- before the superFunc. Signature adjusted to (streamId, superFunc, connection).
    local function baleReadStreamHook(streamId, superFunc, connection)
        local self = superFunc(streamId, connection)
        self.baleAttributes.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        return self
    end

    if AbstractBaleObject ~= nil then
        AbstractBaleObject.writeStream = Utils.overwrittenFunction(AbstractBaleObject.writeStream, baleWriteStreamHook)
        AbstractBaleObject.readStream = Utils.overwrittenFunction(AbstractBaleObject.readStream, baleReadStreamHook)
    end
    if AbstractPackedBaleObject ~= nil then
        AbstractPackedBaleObject.writeStream = Utils.overwrittenFunction(AbstractPackedBaleObject.writeStream, baleWriteStreamHook)
        AbstractPackedBaleObject.readStream = Utils.overwrittenFunction(AbstractPackedBaleObject.readStream, baleReadStreamHook)
    end

    -- Pallet Stream Hook Write (Object Method: obj:writeStream)
    local function palletWriteStreamHook(self, superFunc, streamId, connection)
        superFunc(self, streamId, connection)
        local farmId = self.palletAttributes ~= nil and self.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
        streamWriteUIntN(streamId, farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    end

    -- Pallet Stream Hook Read (Static Constructor: Class.readStream)
    -- FIX: Same static signature adjustment as baleReadStreamHook.
    local function palletReadStreamHook(streamId, superFunc, connection)
        local self = superFunc(streamId, connection)
        if self.palletAttributes ~= nil then
            self.palletAttributes.ownerFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        end
        return self
    end

    if AbstractPalletObject ~= nil then
        AbstractPalletObject.writeStream = Utils.overwrittenFunction(AbstractPalletObject.writeStream, palletWriteStreamHook)
        AbstractPalletObject.readStream = Utils.overwrittenFunction(AbstractPalletObject.readStream, palletReadStreamHook)
    end

    -- =========================================================================
    -- Hook 4: Object Storage UI Filter (Index Mapped for Desync-Prevention)
    -- Overwrites the Activatable run logic to only display objects belonging to
    -- the current player. Maps the UI index back to the real server index.
    -- =========================================================================

    local function objectStorageActivatableRunHook(self, superFunc)
        self.objectStorage:updateDirtyObjectStorageObjectInfos()
        local allObjectInfos = self.objectStorage:getObjectStorageObjectInfos()

        if allObjectInfos ~= nil and #allObjectInfos > 0 then
            local filteredInfos = {}
            local playerFarmId = g_currentMission:getFarmId()

            -- Filter objectInfos dynamically based on the requesting player's farmId
            for originalIndex, objectInfo in ipairs(allObjectInfos) do
                local obj = objectInfo.objects[1]
                local objFarmId = FarmManager.SPECTATOR_FARM_ID

                if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                    objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID
                elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                    objFarmId = obj.palletAttributes ~= nil and obj.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
                end

                if objFarmId == playerFarmId then
                    -- Save the original index so the server knows exactly what to spawn later
                    objectInfo.gmOriginalIndex = originalIndex
                    table.insert(filteredInfos, objectInfo)
                end
            end

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("ObjectStorage UI opened: Filtered %d total entries down to %d entries for Farm %d.", #allObjectInfos, #filteredInfos, playerFarmId)
            end

            if #filteredInfos > 0 then
                -- Wrap the callback to intercept the filtered index and translate it back
                -- to the real engine index before the event is sent to the server.
                local originalCallback = self.onObjectInfoSelected
                local function customCallback(target, selectedFilteredIndex, ...)
                    if selectedFilteredIndex ~= nil and filteredInfos[selectedFilteredIndex] ~= nil then
                        local realIndex = filteredInfos[selectedFilteredIndex].gmOriginalIndex
                        originalCallback(target, realIndex, ...)
                    else
                        originalCallback(target, selectedFilteredIndex, ...)
                    end
                end

                ObjectStorageDialog.show(customCallback, self, self.objectStorage:getName(), filteredInfos, self.objectStorage.spec_objectStorage.maxUnloadAmount)
                return
            end
        end

        -- Show standard warning if storage is empty for this specific farm
        g_currentMission:showBlinkingWarning(string.format(self.warningText, self.objectStorage:getName()), 2000)
    end

    if PlaceableObjectStorageActivatable ~= nil then
        PlaceableObjectStorageActivatable.run = Utils.overwrittenFunction(PlaceableObjectStorageActivatable.run, objectStorageActivatableRunHook)
    end

    -- =========================================================================
    -- Hook 5: Farm ID Injector for Physical Transactions
    -- Injects the farmId temporarily into target storages so setFillLevel knows
    -- which farm triggered the physical addition/removal.
    -- =========================================================================

    local function unloadingStationAddFillLevelHook(self, superFunc, farmId, deltaFillLevel, fillType, fillInfo, toolType, extraAttributes)
        local actualFarmId = farmId or FarmManager.SPECTATOR_FARM_ID
        if self.targetStorages ~= nil then
            for _, storage in pairs(self.targetStorages) do
                if storage.isGmMarket then
                    storage.gmTempFarmId = actualFarmId
                end
            end
        end

        local movedFillLevel = superFunc(self, farmId, deltaFillLevel, fillType, fillInfo, toolType, extraAttributes)

        -- Clean up immediately
        if self.targetStorages ~= nil then
            for _, storage in pairs(self.targetStorages) do
                storage.gmTempFarmId = nil
            end
        end

        return movedFillLevel
    end

    local function loadingStationRemoveFillLevelHook(self, superFunc, fillTypeIndex, fillDelta, farmId)
        local actualFarmId = farmId or FarmManager.SPECTATOR_FARM_ID
        if self.sourceStorages ~= nil then
            for _, storage in pairs(self.sourceStorages) do
                if storage.isGmMarket then
                    storage.gmTempFarmId = actualFarmId
                end
            end
        end

        local remainingDelta = superFunc(self, fillTypeIndex, fillDelta, farmId)

        -- Clean up immediately
        if self.sourceStorages ~= nil then
            for _, storage in pairs(self.sourceStorages) do
                storage.gmTempFarmId = nil
            end
        end

        return remainingDelta
    end

    if UnloadingStation ~= nil then
        UnloadingStation.addFillLevelFromTool = Utils.overwrittenFunction(UnloadingStation.addFillLevelFromTool, unloadingStationAddFillLevelHook)
    end
    if LoadingStation ~= nil then
        LoadingStation.removeFillLevel = Utils.overwrittenFunction(LoadingStation.removeFillLevel, loadingStationRemoveFillLevelHook)
    end

    -- =========================================================================
    -- Hook 6: Shadow Array Logic (Storage split per farm)
    -- Intercepts setFillLevel. If a GM Market receives a change and a temp 
    -- farmId is present, the change is mapped to the shadow array.
    -- =========================================================================

    local function storageSetFillLevelHook(self, superFunc, fillLevel, fillType, fillInfo)
        local isGmMarket = self.isGmMarket -- FIX: Direktes Flag statt owningPlaceable
        local oldFillLevel = self.fillLevels[fillType] or 0

        -- Run native function to physically add/remove goods
        superFunc(self, fillLevel, fillType, fillInfo)

        -- If the transaction was initiated by our Hook 7 (or later GM UI)
        if isGmMarket and self.gmTempFarmId ~= nil then
            local newFillLevel = self.fillLevels[fillType] or 0
            local delta = newFillLevel - oldFillLevel

            if delta ~= 0 then
                if self.gmFarmFillLevels == nil then self.gmFarmFillLevels = {} end
                if self.gmFarmFillLevels[self.gmTempFarmId] == nil then self.gmFarmFillLevels[self.gmTempFarmId] = {} end

                local currentFarmLevel = self.gmFarmFillLevels[self.gmTempFarmId][fillType] or 0
                self.gmFarmFillLevels[self.gmTempFarmId][fillType] = math.max(0, currentFarmLevel + delta)
            end
        end
    end

    if Storage ~= nil then
        Storage.setFillLevel = Utils.overwrittenFunction(Storage.setFillLevel, storageSetFillLevelHook)
    end

    -- =========================================================================
    -- Hook 7: Loading Station UI Visual Fix
    -- =========================================================================

    local function loadingStationGetFillLevelHook(self, superFunc, fillType, farmId)
        local fillLevel = 0
        local isAnyGmMarket = false

        for _, sourceStorage in pairs(self.sourceStorages) do
            if self:hasFarmAccessToStorage(farmId, sourceStorage) then
                if sourceStorage.isGmMarket then
                    isAnyGmMarket = true
                    if sourceStorage.gmFarmFillLevels ~= nil and sourceStorage.gmFarmFillLevels[farmId] ~= nil then
                        fillLevel = fillLevel + (sourceStorage.gmFarmFillLevels[farmId][fillType] or 0)
                    end
                else
                    fillLevel = fillLevel + sourceStorage:getFillLevel(fillType)
                end
            end
        end

        if isAnyGmMarket then return fillLevel end
        return superFunc(self, fillType, farmId)
    end

    local function loadingStationGetAllFillLevelsHook(self, superFunc, farmId)
        local fillLevels = {}
        local isAnyGmMarket = false

        for _, sourceStorage in pairs(self.sourceStorages) do
            if self:hasFarmAccessToStorage(farmId, sourceStorage) then
                if sourceStorage.isGmMarket then
                    isAnyGmMarket = true
                    if sourceStorage.gmFarmFillLevels ~= nil and sourceStorage.gmFarmFillLevels[farmId] ~= nil then
                        for fillType, level in pairs(sourceStorage.gmFarmFillLevels[farmId]) do
                            fillLevels[fillType] = Utils.getNoNil(fillLevels[fillType], 0) + level
                        end
                    end
                else
                    for fillType, level in pairs(sourceStorage:getFillLevels()) do
                        fillLevels[fillType] = Utils.getNoNil(fillLevels[fillType], 0) + level
                    end
                end
            end
        end

        if isAnyGmMarket then return fillLevels end
        return superFunc(self, farmId)
    end

    if LoadingStation ~= nil then
        LoadingStation.getFillLevel = Utils.overwrittenFunction(LoadingStation.getFillLevel, loadingStationGetFillLevelHook)
        LoadingStation.getAllFillLevels = Utils.overwrittenFunction(LoadingStation.getAllFillLevels, loadingStationGetAllFillLevelsHook)
    end

    -- =========================================================================
    -- Hook 8: Physical Vehicle Loading Limit (Shadow Array Cap)
    -- =========================================================================
    local function loadingStationAddFillLevelToFillableHook(self, superFunc, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
        local isGmMarket = false
        for _, storage in pairs(self.sourceStorages) do
            if storage.isGmMarket then -- FIX: Direktes Flag
                isGmMarket = true
                break
            end
        end

        if not isGmMarket then
            return superFunc(self, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
        end

        local farmId = fillableObject:getOwnerFarmId()
        if fillableObject.getActiveFarm ~= nil then
            farmId = fillableObject:getActiveFarm() or farmId
        end

        local maxAvailableForFarm = 0
        for _, storage in pairs(self.sourceStorages) do
            if storage.isGmMarket then
                if storage.gmFarmFillLevels ~= nil and storage.gmFarmFillLevels[farmId] ~= nil then
                    maxAvailableForFarm = maxAvailableForFarm + (storage.gmFarmFillLevels[farmId][fillTypeIndex] or 0)
                end
            end
        end

        fillDelta = math.min(fillDelta, maxAvailableForFarm)

        if fillDelta <= 0 then
            return 0
        end

        return superFunc(self, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
    end

    if LoadingStation ~= nil then
        LoadingStation.addFillLevelToFillableObject = Utils.overwrittenFunction(LoadingStation.addFillLevelToFillableObject, loadingStationAddFillLevelToFillableHook)
    end

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("GlobalMarket Access Hooks successfully injected.")
    end
end

-- =========================================================================
-- Hook 9: InfoTrigger UI Split (owned goods vs. foreign goods)
-- Manipulates the updateInfo to group foreign items while keeping total capacity accurate
-- =========================================================================

-- FIX: Adjusted signature to account for Specialization superFunc chaining
local function updateInfoHook(self, superFunc, engineSuperFunc, infoTable)
    -- Check if it's a GM Market
    local isGmMarket = self.isGmMarket or (self.owningPlaceable ~= nil and self.owningPlaceable.isGmMarket)

    if not isGmMarket then
        -- Not a GM Terminal, run default behavior
        return superFunc(self, engineSuperFunc, infoTable)
    end

    -- Force engine to update its list BEFORE we mask it
    if self.updateDirtyObjectStorageObjectInfos ~= nil then
        self:updateDirtyObjectStorageObjectInfos()
    end

    local spec = self.spec_objectStorage
    local originalObjectInfos = spec.objectInfos

    -- Split the data
    local playerFarmId = g_currentMission:getFarmId()
    local myInfos = {}
    local foreignCount = 0

    if originalObjectInfos ~= nil then
        for i = 1, #originalObjectInfos do
            local objectInfo = originalObjectInfos[i]
            if objectInfo.objects ~= nil and objectInfo.objects[1] ~= nil then
                local obj = objectInfo.objects[1]
                local objFarmId = FarmManager.SPECTATOR_FARM_ID

                if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                    objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID
                elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                    objFarmId = obj.palletAttributes ~= nil and obj.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
                end

                if objFarmId == playerFarmId then
                    table.insert(myInfos, objectInfo)
                else
                    foreignCount = foreignCount + objectInfo.numObjects
                end
            end
        end
    end

    -- Temporarily mask the objectInfos for the base game function
    spec.objectInfos = myInfos

    -- Run base function: It will print accurate total capacity, but only list the player's items
    superFunc(self, engineSuperFunc, infoTable)

    -- Restore original data immediately to not break game logic
    spec.objectInfos = originalObjectInfos

    -- Append foreign goods summary at the bottom
    if foreignCount > 0 then
        -- Checks if modder provided a translation, otherwise defaults to "Foreign Goods"
        local foreignTitle = g_i18n:hasText("info_gmForeignGoods") and g_i18n:getText("info_gmForeignGoods") or "Foreign Goods"
        table.insert(infoTable, { title = foreignTitle, text = tostring(foreignCount) })
    end
end

if PlaceableObjectStorage ~= nil then
    PlaceableObjectStorage.updateInfo = Utils.overwrittenFunction(PlaceableObjectStorage.updateInfo, updateInfoHook)
end
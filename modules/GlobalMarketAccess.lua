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
    -- Intercepts setFillLevel. Maps volume deltas to specific farms dynamically.
    -- =========================================================================

    local function storageSetFillLevelHook(self, superFunc, fillLevel, fillType, fillInfo)
        local isGmMarket = self.isGmMarket
        local oldFillLevel = self.fillLevels[fillType] or 0

        -- Run native function to physically add/remove goods
        superFunc(self, fillLevel, fillType, fillInfo)

        -- If the transaction was initiated by our Hook 5 (or later GM UI)
        if isGmMarket and self.gmTempFarmId ~= nil then
            local newFillLevel = self.fillLevels[fillType] or 0
            local delta = newFillLevel - oldFillLevel

            if delta ~= 0 then
                self.gmFarmFillLevels = self.gmFarmFillLevels or {}
                self.gmFarmFillLevels[self.gmTempFarmId] = self.gmFarmFillLevels[self.gmTempFarmId] or {}

                local currentFarmLevel = self.gmFarmFillLevels[self.gmTempFarmId][fillType] or 0
                self.gmFarmFillLevels[self.gmTempFarmId][fillType] = math.max(0, currentFarmLevel + delta)

                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:trace("Storage Tracker: Farm %s | FillType: %d | Delta: %.2f | New Owned Total: %.2f", tostring(self.gmTempFarmId), fillType, delta, self.gmFarmFillLevels[self.gmTempFarmId][fillType])
                end

                -- NEW: Broadcast with Network Debounce (Prevents Dedi Spam during tipping)
                if g_server ~= nil and SyncGmSiloEvent ~= nil then
                    self.gmSyncTimer = self.gmSyncTimer or 0
                    self.gmSyncAccumulator = (self.gmSyncAccumulator or 0) + math.abs(delta)

                    -- FIX: Use g_time (real engine uptime ms) for reliable network debouncing instead of mission time
                    local currentTime = g_time
                    if self.gmSyncAccumulator >= 100 or currentTime > (self.gmSyncTimer + 1000) then
                        g_server:broadcastEvent(SyncGmSiloEvent.new(self, self.gmTempFarmId, fillType, self.gmFarmFillLevels[self.gmTempFarmId][fillType]))
                        self.gmSyncTimer = currentTime
                        self.gmSyncAccumulator = 0

                        -- FIX: Local Multiplayer Host UI Update
                        -- The host broadcasts to clients but doesn't receive the event back. Update local UI directly.
                        if not g_dedicatedServer and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.ui ~= nil then
                            g_currentMission.globalMarket.ui:updateContent()
                        end
                    end
                end
            end
        end
    end

    if Storage ~= nil then
        Storage.setFillLevel = Utils.overwrittenFunction(Storage.setFillLevel, storageSetFillLevelHook)
    end

    -- =========================================================================
    -- Hook 7: Loading Station UI Visual Fix
    -- Ensures the player only sees their own fill levels when opening the
    -- loading menu [R], despite the silo physically containing everything.
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
    -- Prevents vehicles from pulling more goods than the farm actually owns.
    -- =========================================================================
    local function loadingStationAddFillLevelToFillableHook(self, superFunc, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
        local isGmMarket = false
        for _, storage in pairs(self.sourceStorages) do
            if storage.isGmMarket then
                isGmMarket = true
                break
            end
        end

        -- If not a GM Terminal, let base game handle it normally
        if not isGmMarket then
            return superFunc(self, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)
        end

        -- Determine which farm is trying to load
        local farmId = fillableObject:getOwnerFarmId()
        if fillableObject.getActiveFarm ~= nil then
            farmId = fillableObject:getActiveFarm() or farmId
        end

        -- Calculate max allowed amount specifically from our Shadow Array
        local maxAvailableForFarm = 0
        for _, storage in pairs(self.sourceStorages) do
            if storage.isGmMarket then
                if storage.gmFarmFillLevels ~= nil and storage.gmFarmFillLevels[farmId] ~= nil then
                    maxAvailableForFarm = maxAvailableForFarm + (storage.gmFarmFillLevels[farmId][fillTypeIndex] or 0)
                end
            end
        end

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:trace("Extraction Auth: Vehicle FarmID: %s | Requested: %.2f | Owned in ShadowArray: %.2f", tostring(farmId), fillDelta, maxAvailableForFarm)
        end

        -- Cap the requested amount to the farm's actual ownership
        fillDelta = math.min(fillDelta, maxAvailableForFarm)

        -- If the farm owns nothing, abort the physical load process completely
        if fillDelta <= 0 then
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("Extraction aborted: Farm owns 0 or requested amount capped to 0.")
            end
            return 0
        end

        local loadedAmount = superFunc(self, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, fillInfo, toolType)

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:trace("Extraction Success: Loaded %.2f into vehicle.", loadedAmount)
        end

        return loadedAmount
    end

    if LoadingStation ~= nil then
        LoadingStation.addFillLevelToFillableObject = Utils.overwrittenFunction(LoadingStation.addFillLevelToFillableObject, loadingStationAddFillLevelToFillableHook)
    end

    -- =========================================================================
    -- Hook 9: Network Synchronization for Shadow Array (Multiplayer Dedi Sync)
    -- Syncs gmFarmFillLevels dynamically when a client joins the server.
    -- =========================================================================

    local function storageWriteStreamHook(self, superFunc, streamId, connection)
        -- First, let the base game write its physical fillLevels
        superFunc(self, streamId, connection)

        -- Write a boolean so the client knows if it should expect shadow array data
        local isGmMarket = self.isGmMarket or false
        streamWriteBool(streamId, isGmMarket)

        if isGmMarket then
            local numFarms = 0
            if self.gmFarmFillLevels ~= nil then
                for _, _ in pairs(self.gmFarmFillLevels) do
                    numFarms = numFarms + 1
                end
            end

            -- Write number of farms that own goods in this specific silo
            streamWriteUIntN(streamId, numFarms, 8) -- 8 bits allows up to 255 farms (very safe)

            if numFarms > 0 then
                for farmId, fillLevels in pairs(self.gmFarmFillLevels) do
                    -- Write FarmID
                    streamWriteUIntN(streamId, farmId, FarmManager.FARM_ID_SEND_NUM_BITS)

                    local numFillTypes = 0
                    for _, level in pairs(fillLevels) do
                        if level > 0.01 then numFillTypes = numFillTypes + 1 end
                    end

                    -- Write amount of fillTypes this farm owns
                    streamWriteUIntN(streamId, numFillTypes, 8)

                    -- Write actual FillType Indexes and their Levels
                    for fillTypeIndex, level in pairs(fillLevels) do
                        if level > 0.01 then
                            streamWriteUIntN(streamId, fillTypeIndex, 10) -- 10 bits allows up to 1024 fillTypes
                            streamWriteFloat32(streamId, level)
                        end
                    end
                end
            end
        end
    end

    local function storageReadStreamHook(self, superFunc, streamId, connection)
        -- First, let the base game read its physical fillLevels
        local state = superFunc(self, streamId, connection)

        -- Read our GM flag
        local isGmMarket = streamReadBool(streamId)
        self.isGmMarket = isGmMarket

        if isGmMarket then
            self.gmFarmFillLevels = {}
            local numFarms = streamReadUIntN(streamId, 8)

            for i = 1, numFarms do
                local farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
                self.gmFarmFillLevels[farmId] = {}

                local numFillTypes = streamReadUIntN(streamId, 8)
                for j = 1, numFillTypes do
                    local fillTypeIndex = streamReadUIntN(streamId, 10)
                    local level = streamReadFloat32(streamId)

                    self.gmFarmFillLevels[farmId][fillTypeIndex] = level
                end
            end

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("Client Initial Sync: Shadow Array reconstructed for GM Storage. Farms synced: %d", numFarms)
            end
        end

        -- Always return the state from the superFunc just in case the engine expects it
        return state
    end

    if Storage ~= nil then
        Storage.writeStream = Utils.overwrittenFunction(Storage.writeStream, storageWriteStreamHook)
        Storage.readStream = Utils.overwrittenFunction(Storage.readStream, storageReadStreamHook)
    end

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("GlobalMarket Access Hooks successfully injected.")
    end
end

    -- =========================================================================
    -- Hook 10: InfoTrigger UI Object Hook (PlaceableObjectStorage)
    -- Handles UI masking for objects (Pallets/Bales) and foreign summary.
    -- Since FS25, this specialization manages the green capacity block.
    -- =========================================================================

local function updateInfoHook(self, superFunc, engineSuperFunc, infoTable)
    -- Check if it's a GM Market
    local isGmMarket = self.isGmMarket == true

    -- Fallback check: Also verify storages
    if not isGmMarket and self.spec_silo ~= nil and self.spec_silo.storages ~= nil then
        for _, storage in ipairs(self.spec_silo.storages) do
            if storage.isGmMarket == true or storage.gmFarmFillLevels ~= nil then
                isGmMarket = true
                break
            end
        end
    end

    if not isGmMarket then
        -- Not a GM Terminal, run default behavior
        return superFunc(self, engineSuperFunc, infoTable)
    end

    -- 1. OBJECT STORAGE MASKING (Pallets/Bales)
    if self.updateDirtyObjectStorageObjectInfos ~= nil then
        self:updateDirtyObjectStorageObjectInfos()
    end

    local spec = self.spec_objectStorage
    local originalObjectInfos = spec.objectInfos
    local playerFarmId = g_currentMission:getFarmId()
    local myInfos = {}
    local foreignObjectsCount = 0

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
                    foreignObjectsCount = foreignObjectsCount + objectInfo.numObjects
                end
            end
        end
    end

    -- Temporarily mask the objectInfos for the base game function
    spec.objectInfos = myInfos

    -- 2. EXECUTE VANILLA LOGIC
    superFunc(self, engineSuperFunc, infoTable)

    -- Restore original data immediately
    spec.objectInfos = originalObjectInfos

    -- 3. APPEND FOREIGN OBJECT SUMMARY
    if foreignObjectsCount > 0 then
        local objTitle = g_i18n:hasText("info_gmForeignGoods") and g_i18n:getText("info_gmForeignGoods") or "Foreign Goods"
        table.insert(infoTable, { title = objTitle, text = tostring(foreignObjectsCount) })
    end
end

if PlaceableObjectStorage ~= nil then
    PlaceableObjectStorage.updateInfo = Utils.overwrittenFunction(PlaceableObjectStorage.updateInfo, updateInfoHook)
end

-- =========================================================================
    -- Hook 11: The "Judo" UI Hook & Achimobil Blocker (FSBaseMission)
    -- Defeats Mod Load Order by hijacking InfoDisplayExtension's own function
    -- table AFTER all mods have loaded (via FSBaseMission.onFinishedLoading).
    -- We block his UI injection for GM silos, allowing our own UI to run.
    -- =========================================================================

    -- 1. OUR CLEAN GM UI (Runs undisturbed because Achimobil gets blocked)
    local function updateInfoSiloHook(self, superFunc, infoTable)
        -- Execute whatever is left in the chain (Vanilla)
        superFunc(self, infoTable)

        local isGmMarket = self.isGmMarket == true
        if not isGmMarket and self.spec_silo ~= nil and self.spec_silo.storages ~= nil then
            for _, storage in ipairs(self.spec_silo.storages) do
                if storage.isGmMarket == true or storage.gmFarmFillLevels ~= nil then
                    isGmMarket = true
                    break
                end
            end
        end

        if isGmMarket and self.spec_objectStorage == nil then
            -- Clean out Vanilla total capacity string
            local vanillaTotal = g_i18n:hasText("ui_silos_totalCapacity") and g_i18n:getText("ui_silos_totalCapacity") or "Total Capacity"

            -- Loop backwards to safely remove elements before onDraw clears them
            for i = #infoTable, 1, -1 do
                if infoTable[i] ~= nil and (infoTable[i].title == vanillaTotal or infoTable[i].title == "Gesamtkapazität") then
                    table.remove(infoTable, i)
                end
            end

            -- Calculate GM Actuals
            local playerFarmId = g_currentMission:getFarmId()
            local foreignBulkLiters = 0
            local totalPhysicalCapacity = 0
            local totalPhysicalUsed = 0

            if self.spec_silo ~= nil and self.spec_silo.storages ~= nil then
                for _, storage in ipairs(self.spec_silo.storages) do
                    totalPhysicalCapacity = totalPhysicalCapacity + (storage.capacity or 0)

                    if storage.fillLevels ~= nil then
                        for _, level in pairs(storage.fillLevels) do
                            totalPhysicalUsed = totalPhysicalUsed + level
                        end
                    end

                    if storage.gmFarmFillLevels ~= nil then
                        for farmId, fillLevels in pairs(storage.gmFarmFillLevels) do
                            if farmId ~= playerFarmId and farmId ~= FarmManager.SPECTATOR_FARM_ID then
                                for _, level in pairs(fillLevels) do
                                    foreignBulkLiters = foreignBulkLiters + level
                                end
                            end
                        end
                    end
                end
            end

            -- Build our UI
            if foreignBulkLiters > 0.1 then
                local bulkTitle = g_i18n:hasText("info_gmForeignGoods") and g_i18n:getText("info_gmForeignGoods") or "Foreign Goods"
                table.insert(infoTable, { title = bulkTitle, text = g_i18n:formatVolume(foreignBulkLiters, 0) })
            end

            local outUsed = (g_i18n:hasText("info_gmUsedCapacity") and g_i18n:getText("info_gmUsedCapacity") or "Used Capacity") .. " "
            local outTotal = (g_i18n:hasText("ui_silos_totalCapacity") and g_i18n:getText("ui_silos_totalCapacity") or "Total Capacity") .. " "

            table.insert(infoTable, { title = outUsed, text = g_i18n:formatVolume(totalPhysicalUsed, 0) })
            table.insert(infoTable, { title = outTotal, text = g_i18n:formatVolume(totalPhysicalCapacity, 0) })
        end
    end

    if PlaceableSilo ~= nil then
        PlaceableSilo.updateInfo = Utils.overwrittenFunction(PlaceableSilo.updateInfo, updateInfoSiloHook)
    end


    -- 2. THE ACHIMOBIL ASSASSIN (Injected at FSBaseMission.onFinishedLoading)
    local function injectAchimobilBlocker()
        if InfoDisplayExtension ~= nil and InfoDisplayExtension.updateInfoPlaceableSilo ~= nil then
            -- Save his original function
            local originalAchimHook = InfoDisplayExtension.updateInfoPlaceableSilo

            -- Overwrite his global table function
            InfoDisplayExtension.updateInfoPlaceableSilo = function(self, superFunc, infoTable)
                local isGmMarket = self.isGmMarket == true
                if not isGmMarket and self.spec_silo ~= nil and self.spec_silo.storages ~= nil then
                    for _, storage in ipairs(self.spec_silo.storages) do
                        if storage.isGmMarket == true or storage.gmFarmFillLevels ~= nil then
                            isGmMarket = true
                            break
                        end
                    end
                end

                if isGmMarket and self.spec_objectStorage == nil then
                    -- IT'S A GM SILO! BLOCK ACHIMOBIL!
                    -- We just pass the call to the next function in his chain and return early.
                    superFunc(self, infoTable)
                    return
                end

                -- Not a GM Silo? Let Achimobil do his normal thing
                originalAchimHook(self, superFunc, infoTable)
            end

            if GlobalMarket and GlobalMarket.debugManager then
                GlobalMarket.debugManager:info("InfoDisplayExtension detected. GM Blocker injected successfully.")
            end
        end
    end

    if FSBaseMission ~= nil then
        FSBaseMission.onFinishedLoading = Utils.appendedFunction(FSBaseMission.onFinishedLoading, injectAchimobilBlocker)
    end
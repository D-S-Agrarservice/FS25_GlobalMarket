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
    -- Note: AccessHandler:canPlayerAccess signature is (object, player, allowEqualAlways)
    local function canPlayerAccessHook(accessHandler, superFunc, object, player, ...)
        if object ~= nil and type(object) == "table" then
            -- Check if the object itself or its owning placeable is a GM terminal
            local isGmMarket = object.isGmMarket
                or (object.owningPlaceable ~= nil and object.owningPlaceable.isGmMarket)
                or (object.target ~= nil and object.target.isGmMarket)
                or (object.source ~= nil and object.source.isGmMarket)
            if isGmMarket then
                return true
            end
        end
        return superFunc(accessHandler, object, player, ...)
    end
    AccessHandler.canPlayerAccess = Utils.overwrittenFunction(AccessHandler.canPlayerAccess, canPlayerAccessHook)

    -- Bypass for farm/vehicle interaction (e.g., UnloadingStation, LoadTrigger)
    local function canFarmAccessHook(accessHandler, superFunc, farmId, object, ...)
        if object ~= nil and type(object) == "table" then
            local isGmMarket = object.isGmMarket
                or (object.owningPlaceable ~= nil and object.owningPlaceable.isGmMarket)
                or (object.target ~= nil and object.target.isGmMarket)
                or (object.source ~= nil and object.source.isGmMarket)
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

                -- Broadcast with Network Debounce (Prevents Dedi Spam during tipping)
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

    -- =========================================================================
    -- Hook 10: Instance-Level Hooks for GM Terminals (Doors, InfoTrigger & UI)
    -- Because TypeManager:finalizeTypes() runs before mod scripts load, instance
    -- methods like updateInfo are copied from the unhooked specialization table.
    -- Furthermore, PlaceableAnimatedObjects:getCanTriggerAnimatedObject checks
    -- canFarmAccessOtherId(playerFarmId, ownerFarmId) without passing the object.
    -- Therefore, we apply instance-level hooks in finalizePlacement & onStartMission.
    -- =========================================================================

    function GlobalMarketAccess.applyGmPlaceableHooks(placeable)
        if placeable == nil or type(placeable) ~= "table" then
            return
        end

        -- Ensure isGmMarket is propagated between placeable and its specializations
        local isGm = placeable.isGmMarket == true
        if not isGm and placeable.spec_silo ~= nil and placeable.spec_silo.isGmMarket then
            isGm = true
        end
        if not isGm and placeable.spec_objectStorage ~= nil and placeable.spec_objectStorage.isGmMarket then
            isGm = true
        end

        if not isGm then
            return
        end

        placeable.isGmMarket = true

        if placeable.spec_silo ~= nil then
            placeable.spec_silo.isGmMarket = true
            if placeable.spec_silo.unloadingStation ~= nil then
                placeable.spec_silo.unloadingStation.isGmMarket = true
            end
            if placeable.spec_silo.loadingStation ~= nil then
                placeable.spec_silo.loadingStation.isGmMarket = true
            end
            if placeable.spec_silo.storages ~= nil then
                for _, storage in ipairs(placeable.spec_silo.storages) do
                    storage.isGmMarket = true
                end
            end
        end

        if placeable.spec_objectStorage ~= nil then
            placeable.spec_objectStorage.isGmMarket = true
            if placeable.spec_objectStorage.storage ~= nil then
                placeable.spec_objectStorage.storage.isGmMarket = true
            end
        end

        -- 1. Door Bypass: Allow all farms to open/close animatedObjects (doors/gates) on GM buildings
        if placeable.getCanTriggerAnimatedObject ~= nil and not placeable.hasGmDoorBypass then
            local function gmInstanceTriggerHook(self, superFunc, animatedObject)
                return true
            end
            placeable.getCanTriggerAnimatedObject = Utils.overwrittenFunction(placeable.getCanTriggerAnimatedObject, gmInstanceTriggerHook)
            placeable.hasGmDoorBypass = true

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:info("Access Hook: Elegant VIP Pass applied to GM Terminal instance.")
            end
        end

        -- 2. InfoTrigger Visibility: Ensure all players see the InfoTrigger HUD regardless of ownerFarmId
        if placeable.spec_infoTrigger ~= nil then
            placeable.spec_infoTrigger.showAllPlayers = true
        end

        -- 3. Instance-Level updateInfo Hook: Route directly to our clean GM multi-farm HUD logic
        if placeable.updateInfo ~= nil and not placeable.hasGmFirewall then
            placeable.hasGmFirewall = true
            local originalUpdateInfo = placeable.updateInfo

            placeable.updateInfo = function(self, infoTable)
                local dummySuperFunc = function(s, t) end

                if self.spec_silo ~= nil and GlobalMarketAccess.cleanSiloUpdateInfo ~= nil then
                    GlobalMarketAccess.cleanSiloUpdateInfo(self, dummySuperFunc, infoTable)
                elseif self.spec_objectStorage ~= nil and GlobalMarketAccess.cleanObjectStorageUpdateInfo ~= nil then
                    GlobalMarketAccess.cleanObjectStorageUpdateInfo(self, dummySuperFunc, infoTable)
                elseif originalUpdateInfo ~= nil then
                    originalUpdateInfo(self, infoTable)
                end
            end
        end
    end

    -- 1. Catch newly placed buildings purchased mid-game (server & client stream) and loaded placeables
    if Placeable ~= nil and Placeable.finalizePlacement ~= nil then
        Placeable.finalizePlacement = Utils.appendedFunction(Placeable.finalizePlacement, function(placeable)
            GlobalMarketAccess.applyGmPlaceableHooks(placeable)
        end)
    end

    -- 2. Retroactively sweep the map when network sync is 100% complete
    local function retroactiveGmDoorSweep(mission)
        if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
            for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                GlobalMarketAccess.applyGmPlaceableHooks(placeable)
            end
        end
    end
    -- Crucial fix for Dedi Servers: onStartMission fires after stream reading!
    FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, retroactiveGmDoorSweep)

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("GlobalMarket Access Hooks successfully injected.")
    end
end

-- =========================================================================
-- Hook 11: InfoTrigger UI Split (owned goods vs. foreign goods)
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
    -- Save a pointer to the clean GM -> Vanilla hook chain BEFORE IDE overwrites it!
    -- This allows the GMCompatibilityManager to bypass the IDE UI injection entirely.
    GlobalMarketAccess.cleanObjectStorageUpdateInfo = PlaceableObjectStorage.updateInfo
end

-- =========================================================================
-- Hook 12: PlaceableSilo InfoTrigger UI Fix (FS25 Adjusted)
-- Adds Capacity (Used/Total) and Foreign Goods summary.
-- Relies on Hook 7 to natively filter the player's owned goods.
-- =========================================================================
local function siloUpdateInfoHook(self, superFunc, engineSuperFunc, infoTable)
    local isGmMarket = self.isGmMarket == true

    -- Aggressive Fallback: Check storages for the flag or shadow array existence
    if not isGmMarket and self.spec_silo ~= nil and self.spec_silo.storages ~= nil then
        for _, storage in ipairs(self.spec_silo.storages) do
            if storage.isGmMarket == true or storage.gmFarmFillLevels ~= nil then
                isGmMarket = true
                break
            end
        end
    end

    -- If it's strictly not our market, run vanilla and exit
    if not isGmMarket then
        return superFunc(self, engineSuperFunc, infoTable)
    end

    -- 1. Run base function FIRST.
    -- In FS25, this natively calls LoadingStation:getAllFillLevels(),
    -- which is already filtered to the player's goods by our GM Hook 7!
    superFunc(self, engineSuperFunc, infoTable)

    -- 2. Calculate our GM specific data
    local playerFarmId = g_currentMission:getFarmId()
    local totalVolume = 0
    local totalCapacity = 0
    local foreignLiters = 0

    if self.spec_silo ~= nil and self.spec_silo.storages ~= nil then
        for _, storage in ipairs(self.spec_silo.storages) do
            totalCapacity = totalCapacity + storage:getCapacity()

            -- Calculate total physical volume for the capacity bar
            for _, level in pairs(storage:getFillLevels()) do
                totalVolume = totalVolume + level
            end

            -- Calculate foreign liters
            if storage.gmFarmFillLevels ~= nil then
                for farmId, fillLevels in pairs(storage.gmFarmFillLevels) do
                    if farmId ~= playerFarmId and farmId ~= FarmManager.SPECTATOR_FARM_ID then
                        for _, level in pairs(fillLevels) do
                            foreignLiters = foreignLiters + level
                        end
                    end
                end
            end
        end
    end

    -- 3. Insert Capacity info at the top (Position 1)
    local capTitle = g_i18n:getText("ui_silos_totalCapacity")
    local capText = string.format("%s / %s", g_i18n:formatVolume(totalVolume, 0), g_i18n:formatVolume(totalCapacity, 0))
    table.insert(infoTable, 1, {
        title = capTitle,
        text = capText
    })

    -- 4. Append foreign goods summary at the bottom
    if foreignLiters > 0.1 then
        local foreignTitle = g_i18n:hasText("info_gmForeignGoods") and g_i18n:getText("info_gmForeignGoods") or "Foreign Goods"
        table.insert(infoTable, {
            title = foreignTitle,
            text = g_i18n:formatVolume(foreignLiters, 0)
        })
    end
end

if PlaceableSilo ~= nil then
    PlaceableSilo.updateInfo = Utils.overwrittenFunction(PlaceableSilo.updateInfo, siloUpdateInfoHook)
    -- Save a pointer to the clean GM -> Vanilla hook chain BEFORE IDE overwrites it!
    -- This allows the GMCompatibilityManager to bypass the IDE UI injection entirely.
    GlobalMarketAccess.cleanSiloUpdateInfo = PlaceableSilo.updateInfo
end
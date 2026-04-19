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
    -- Hook 4: Object Storage UI Filter (Index Mapped)
    -- Overwrites Activatable run logic to only display objects of the current player,
    -- and maps the UI index back to the real server index to prevent spawning wrong items.
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
                    -- Save the true original index so the server knows exactly what to spawn
                    objectInfo.gmOriginalIndex = originalIndex
                    table.insert(filteredInfos, objectInfo)
                end
            end

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("ObjectStorage UI opened: Filtered %d total entries down to %d entries for Farm %d.", #allObjectInfos, #filteredInfos, playerFarmId)
            end

            -- If filtered list has items, show dialog.
            if #filteredInfos > 0 then
                -- Wrap the callback to intercept the filtered index and translate it back to the real engine index
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
    -- Hook 5: InfoTrigger UI Split (owned goods vs. foreign goods)
    -- Manipulates the updateInfo to group foreign items while keeping total capacity accurate
    -- =========================================================================

    local function updateInfoHook(self, superFunc, infoTable)
        -- Check if it's a GM Market
        local isGmMarket = self.isGmMarket or (self.owningPlaceable ~= nil and self.owningPlaceable.isGmMarket)

        if not isGmMarket or infoTable == nil then
            return superFunc(self, infoTable)
        end

        local spec = self.spec_objectStorage
        if spec == nil then
            return superFunc(self, infoTable)
        end

        -- 1. Force the update NOW, before we read and mask the data
        if self.updateDirtyObjectStorageObjectInfos ~= nil then
            self:updateDirtyObjectStorageObjectInfos()
        end

        local originalObjectInfos = spec.objectInfos
        if originalObjectInfos == nil then
            return superFunc(self, infoTable)
        end

        -- 2. Split the data
        local playerFarmId = g_currentMission:getFarmId()
        local myInfos = {}
        local foreignCount = 0

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

        -- 3. Mask the data
        spec.objectInfos = myInfos

        -- 4. CRITICAL FIX: Block the engine from rebuilding the list during the UI generation
        local originalUpdateDirty = self.updateDirtyObjectStorageObjectInfos
        if originalUpdateDirty ~= nil then
            self.updateDirtyObjectStorageObjectInfos = function() end
        end

        -- 5. Run base game UI generation securely
        local status, result = pcall(superFunc, self, infoTable)

        -- 6. Restore EVERYTHING immediately
        if originalUpdateDirty ~= nil then
            self.updateDirtyObjectStorageObjectInfos = originalUpdateDirty
        end
        spec.objectInfos = originalObjectInfos

        -- Log any errors securely without crashing the game
        if not status and GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:error("GlobalMarketAccess: Error in updateInfo superFunc: %s", tostring(result))
        end

        -- 7. Add our custom foreign goods line
        if foreignCount > 0 then
            local foreignTitle = g_i18n:hasText("info_gmForeignGoods") and g_i18n:getText("info_gmForeignGoods") or "Foreign Goods"
            table.insert(infoTable, { title = foreignTitle, text = tostring(foreignCount) })
        end
    end

    if PlaceableObjectStorage ~= nil then
        PlaceableObjectStorage.updateInfo = Utils.overwrittenFunction(PlaceableObjectStorage.updateInfo, updateInfoHook)
    end

    -- =========================================================================
    -- Hook 6: Deterministic Sorting for ObjectStorage
    -- Ensures Client and Server arrays match exactly to prevent MP Desyncs
    -- before UI filtering takes place. Sorts by Width -> FarmId -> XML.
    -- =========================================================================

    local oldUpdateObjectInfos = PlaceableObjectStorage.updateObjectStorageObjectInfos
    if oldUpdateObjectInfos ~= nil then
        PlaceableObjectStorage.updateObjectStorageObjectInfos = function(self)
            oldUpdateObjectInfos(self)

            local spec = self.spec_objectStorage
            if spec.objectInfos ~= nil then
                table.sort(spec.objectInfos, function(a, b)
                    local objA = a.objects[1]
                    local objB = b.objects[1]

                    local _, _, _, widthA = objA:getSpawnInfo()
                    local _, _, _, widthB = objB:getSpawnInfo()

                    -- Priority 1: Width
                    if math.abs(widthA - widthB) > 0.001 then return widthA < widthB end

                    -- Priority 2: FarmId
                    local farmA = (objA.palletAttributes ~= nil and objA.palletAttributes.ownerFarmId) or (objA.baleAttributes ~= nil and objA.baleAttributes.farmId) or (objA.baleObject ~= nil and objA.baleObject.ownerFarmId) or 0
                    local farmB = (objB.palletAttributes ~= nil and objB.palletAttributes.ownerFarmId) or (objB.baleAttributes ~= nil and objB.baleAttributes.farmId) or (objB.baleObject ~= nil and objB.baleObject.ownerFarmId) or 0
                    if farmA ~= farmB then return farmA < farmB end

                    -- Priority 3: XML Filename
                    local xmlA = objA:getXMLFilename() or ""
                    local xmlB = objB:getXMLFilename() or ""
                    return xmlA < xmlB
                end)
            end
        end
    end

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("GlobalMarket Access Hooks successfully injected.")
    end
end
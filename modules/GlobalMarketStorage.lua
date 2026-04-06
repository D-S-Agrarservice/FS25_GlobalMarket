--
-- FS25 - GlobalMarket (Storage Module)
-- Note: Handles physical storage interaction, delivery costs, and GM Terminal logic.
--

-- =========================================================================
-- UI Helper Functions
-- =========================================================================

-- Gets all valid player storages for a specific fillType (Includes Bulk and ObjectStorages)
-- @param fillTypeName string: The name of the fillType (e.g., "MAIZE")
-- @param farmId integer: The ID of the farm requesting the storages
-- @param isSelling boolean: True if player wants to sell to GM, False if buying
function GlobalMarket:getAvailableStorages(fillTypeName, farmId, isSelling)
    local availableStorages = {}
    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(fillTypeName)

    if fillTypeDesc == nil then
        return availableStorages
    end

    local fillTypeIndex = fillTypeDesc.index

    -- 1. Scan regular bulk storages (Silos, Extensions)
    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
        if storage.ownerFarmId == farmId and storage:getIsFillTypeSupported(fillTypeIndex) then
            local level = storage:getFillLevel(fillTypeIndex)
            local freeCapacity = storage:getFreeCapacity(fillTypeIndex)

            local storageName = storage.owningPlaceable ~= nil and storage.owningPlaceable:getName() or "Silo"
            local displayTitle = storageName

            if storage.isGmMarket then
                displayTitle = storageName .. (g_i18n:getText("ui_gm_terminal_hint") or " (GM Terminal)")
            end

            if (isSelling and level > 0.1) or (not isSelling and freeCapacity > 0.1) then
                table.insert(availableStorages, {
                    storage = storage,
                    id = storage.rootNode,
                    title = displayTitle,
                    level = level,
                    freeCapacity = freeCapacity,
                    isGmMarket = storage.isGmMarket or false,
                    isObjectStorage = false
                })
            end
        end
    end

    -- 2. Scan PlaceableObjectStorages (Bales, Pallets)
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.spec_objectStorage ~= nil and placeable:getOwnerFarmId() == farmId then
            local spec = placeable.spec_objectStorage

            -- Skip if GM terminal checking is needed and it's a specific object storage terminal
            local isGmMarket = placeable.isGmMarket or false

            if placeable:getObjectStorageSupportsFillType(fillTypeIndex) then
                local totalFillLevel = 0

                -- Calculate exact fill level from abstract objects
                for _, objectInfo in ipairs(spec.objectInfos) do
                    local obj = objectInfo.objects[1]
                    local objFillType, objLevel = nil, 0
                    local isFermenting = false

                    if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                        objFillType = (obj.baleObject ~= nil) and obj.baleObject:getFillType() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                        objLevel = (obj.baleObject ~= nil) and obj.baleObject:getFillLevel() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillLevel)

                        -- Filter out fermenting bales
                        if obj.baleObject ~= nil and obj.baleObject.isFermenting then isFermenting = true end
                        if obj.baleAttributes ~= nil and obj.baleAttributes.isFermenting then isFermenting = true end
                    elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                        -- AbstractPalletObject
                        objFillType = obj.palletAttributes ~= nil and obj.palletAttributes.fillType
                        objLevel = obj.palletAttributes ~= nil and obj.palletAttributes.fillLevel
                    end

                    if objFillType == fillTypeIndex and not isFermenting then
                        totalFillLevel = totalFillLevel + (objLevel * objectInfo.numObjects)
                    end
                end

                -- Free capacity in ObjectStorages is slot-based, not liter-based.
                -- We approximate a standard 5000L capacity per free slot for UI purposes.
                local freeSlots = math.max(0, spec.capacity - spec.numStoredObjects)
                local approximatedFreeCapacity = freeSlots * 5000

                local displayTitle = placeable:getName()
                if isGmMarket then
                    displayTitle = displayTitle .. (g_i18n:getText("ui_gm_terminal_hint") or " (GM Terminal)")
                end

                if (isSelling and totalFillLevel > 0.1) or (not isSelling and approximatedFreeCapacity > 0.1) then
                    table.insert(availableStorages, {
                        storage = placeable, -- Note: We pass the placeable, not a 'storage' object
                        id = placeable.rootNode,
                        title = displayTitle,
                        level = totalFillLevel,
                        freeCapacity = approximatedFreeCapacity,
                        isGmMarket = isGmMarket,
                        isObjectStorage = true -- Flag to trigger different logic in onSellBuy
                    })
                end
            end
        end
    end

    return availableStorages
end

-- Gets aggregated fill levels for all valid player storages to display in the UI list
-- Separates private farm storages and GM terminals for UI detail view.
function GlobalMarket:getAggregatedStorageData(farmId)
    local aggregatedData = {}
    local fillTypeTotals = {}

    -- Helper to initialize table structure
    local function initFillType(index)
        if fillTypeTotals[index] == nil then
            fillTypeTotals[index] = { total = 0, private = 0, gm = 0 }
        end
    end

    -- 1. Bulk Storages (Silos & GM Terminals)
    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
        if storage.ownerFarmId == farmId then
            local isGM = storage.isGmMarket or false
            for fillTypeIndex, fillLevel in pairs(storage:getFillLevels()) do
                if fillLevel > 0.1 then
                    initFillType(fillTypeIndex)
                    fillTypeTotals[fillTypeIndex].total = fillTypeTotals[fillTypeIndex].total + fillLevel
                    if isGM then
                        fillTypeTotals[fillTypeIndex].gm = fillTypeTotals[fillTypeIndex].gm + fillLevel
                    else
                        fillTypeTotals[fillTypeIndex].private = fillTypeTotals[fillTypeIndex].private + fillLevel
                    end
                end
            end
        end
    end

    -- 2. Object Storages (Bale/Pallet Storages & GM Object Terminals)
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.spec_objectStorage ~= nil and placeable:getOwnerFarmId() == farmId then
            local isGM = placeable.isGmMarket or false
            local spec = placeable.spec_objectStorage
            for _, objectInfo in ipairs(spec.objectInfos) do
                local obj = objectInfo.objects[1]
                local objFillType, objLevel = nil, 0
                local isFermenting = false

                if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                    objFillType = (obj.baleObject ~= nil) and obj.baleObject:getFillType() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                    objLevel = (obj.baleObject ~= nil) and obj.baleObject:getFillLevel() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillLevel)
                    if obj.baleObject ~= nil and obj.baleObject.isFermenting then isFermenting = true end
                    if obj.baleAttributes ~= nil and obj.baleAttributes.isFermenting then isFermenting = true end
                elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                    objFillType = obj.palletAttributes ~= nil and obj.palletAttributes.fillType
                    objLevel = obj.palletAttributes ~= nil and obj.palletAttributes.fillLevel
                end

                if objFillType ~= nil and not isFermenting then
                    initFillType(objFillType)
                    local totalVol = objLevel * objectInfo.numObjects
                    fillTypeTotals[objFillType].total = fillTypeTotals[objFillType].total + totalVol
                    if isGM then
                        fillTypeTotals[objFillType].gm = fillTypeTotals[objFillType].gm + totalVol
                    else
                        fillTypeTotals[objFillType].private = fillTypeTotals[objFillType].private + totalVol
                    end
                end
            end
        end
    end

    -- Convert totals into UI-ready table
    for fillTypeIndex, totals in pairs(fillTypeTotals) do
        local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillTypeDesc ~= nil then
            table.insert(aggregatedData, {
                fillType = fillTypeDesc.name,
                level = totals.total,
                levelPrivate = totals.private,
                levelGM = totals.gm,
                price = self:getOfflinePriceByFillType(fillTypeDesc.name)
            })
        end
    end

    -- Sort alphabetically by title
    table.sort(aggregatedData, function(a, b)
        local titleA = g_fillTypeManager:getFillTypeByName(a.fillType).title
        local titleB = g_fillTypeManager:getFillTypeByName(b.fillType).title
        return titleA < titleB
    end)

    return aggregatedData
end

-- =========================================================================
-- Transaction Logic
-- =========================================================================

-- Main Entry Point for UI Actions (Router)
function GlobalMarket:onSellBuy(mode, filltypeName, level, storageId, count, attributes, objectId, isObjectStorage, playerFarmId)
    -- Fallback for playerFarmId if not provided by older UI calls
    if playerFarmId == nil then
        playerFarmId = g_currentMission:getFarmId()
    end

    if isObjectStorage then
        -- Route to Object backend
        self:onSellBuyObjects(mode, filltypeName, count, storageId, playerFarmId)
    else
        -- Route to Bulk backend
        self:onSellBuyBulk(mode, filltypeName, level, storageId, playerFarmId)
    end
end

-- Handle standard bulk transactions
function GlobalMarket:onSellBuyBulk(mode, filltypeName, level, storageId, playerFarmId)
    GlobalMarket.debugLog("Backend: onSellBuyBulk [Mode: %d, FillType: %s, Level: %f]", mode, filltypeName, level)

    if self:getIsMarketOnline() then
        GlobalMarket.debugLog("  -> Online-Mode: Redirecting to Sync Module (TBD).")
        return
    end

    local targetStorage = nil
    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
        if storage.rootNode == storageId then
            targetStorage = storage
            break
        end
    end

    if targetStorage == nil then
        GlobalMarket.debugLog("ERROR: Bulk Storage ID %s not found!", tostring(storageId))
        return
    end

    -- Security for MP: If storage has no valid farm owner (like a shared GM Terminal), use the requesting player's farm ID
    local targetFarmId = targetStorage.ownerFarmId
    if targetFarmId == nil or targetFarmId == FarmManager.SPECTATOR_FARM_ID then
        targetFarmId = playerFarmId
    end

    local marketPricePerUnit = self:getOfflinePriceByFillType(filltypeName) / 1000
    local totalPrice = marketPricePerUnit * level
    local moneyType = (mode == 2) and MoneyType.BOUGHT_MATERIALS or MoneyType.SOLD_PRODUCTS

    local deliveryCosts = 0
    if not (targetStorage.isGmMarket or false) then
        deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * level) * EconomyManager.getCostMultiplier()
    end

    local finalAccountBalance = (mode == 2) and (totalPrice * -1) or totalPrice

    if g_server ~= nil then
        g_currentMission:addMoney(finalAccountBalance, targetFarmId, moneyType, true, true)

        if deliveryCosts > 0 then
            g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.OTHER, true, true)
        end

        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index
        local currentSiloLevel = targetStorage:getFillLevel(fillTypeIndex)
        local newSiloLevel = (mode == 2) and (currentSiloLevel + level) or (currentSiloLevel - level)
        targetStorage:setFillLevel(newSiloLevel, fillTypeIndex, nil)

        for _, ft in pairs(self.offlineMarketFillTypes) do
            if ft.fillType == filltypeName then
                local marketChange = (mode == 2) and (level * -1) or level
                ft.fillLevel = math.max(ft.fillLevel + marketChange, 0)
                break
            end
        end

        if self.updateOfflinePrices ~= nil then self:updateOfflinePrices() end
        if GlobalMarket.config.useSync and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- CLIENT SEND EVENT (Bulk)
        if GlobalMarket.config.useSync and SellBuyOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(mode, filltypeName, level, targetStorage, 0, false, playerFarmId))
        end
    end
end

-- Handle object transactions (Ballen/Paletten in ObjectStorages)
function GlobalMarket:onSellBuyObjects(mode, filltypeName, count, storageId, playerFarmId)
    GlobalMarket.debugLog("Backend: onSellBuyObjects [Mode: %d, FillType: %s, Count: %d]", mode, filltypeName, count)

    if self:getIsMarketOnline() then
        GlobalMarket.debugLog("  -> Online-Mode: Redirecting to Sync Module (TBD).")
        return
    end

    local targetPlaceable = nil
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.rootNode == storageId and placeable.spec_objectStorage ~= nil then
            targetPlaceable = placeable
            break
        end
    end

    if targetPlaceable == nil then
        GlobalMarket.debugLog("ERROR: ObjectStorage ID %s not found!", tostring(storageId))
        return
    end

    local targetFarmId = targetPlaceable:getOwnerFarmId()
    if targetFarmId == nil or targetFarmId == FarmManager.SPECTATOR_FARM_ID then
        targetFarmId = playerFarmId
    end

    if g_server ~= nil then
        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index
        local spec = targetPlaceable.spec_objectStorage
        local processedCount = 0
        local totalLitersProcessed = 0

        if mode == 1 then
            for i = #spec.storedObjects, 1, -1 do
                if processedCount >= count then break end

                local obj = spec.storedObjects[i]
                local objFillType, objLevel = nil, 0
                local isFermenting = false

                if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                    objFillType = (obj.baleObject ~= nil) and obj.baleObject:getFillType() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                    objLevel = (obj.baleObject ~= nil) and obj.baleObject:getFillLevel() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillLevel)
                    if obj.baleObject ~= nil and obj.baleObject.isFermenting then isFermenting = true end
                    if obj.baleAttributes ~= nil and obj.baleAttributes.isFermenting then isFermenting = true end
                elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                    objFillType = obj.palletAttributes ~= nil and obj.palletAttributes.fillType
                    objLevel = obj.palletAttributes ~= nil and obj.palletAttributes.fillLevel
                end

                if objFillType == fillTypeIndex and not isFermenting then
                    totalLitersProcessed = totalLitersProcessed + objLevel
                    processedCount = processedCount + 1

                    table.remove(spec.storedObjects, i)
                    obj:delete()

                    if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                        g_farmManager:updateFarmStats(targetFarmId, "storedBales", -1)
                    elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                        g_farmManager:updateFarmStats(targetFarmId, "storedPallets", -1)
                    end
                end
            end

            spec.numStoredObjects = #spec.storedObjects
            targetPlaceable:setObjectStorageObjectInfosDirty()

            local marketPricePerUnit = self:getOfflinePriceByFillType(filltypeName) / 1000
            local totalPrice = marketPricePerUnit * totalLitersProcessed

            local deliveryCosts = 0
            if not (targetPlaceable.isGmMarket or false) then
                deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * totalLitersProcessed) * EconomyManager.getCostMultiplier()
            end

            g_currentMission:addMoney(totalPrice, targetFarmId, MoneyType.SOLD_PRODUCTS, true, true)
            if deliveryCosts > 0 then
                g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.OTHER, true, true)
            end

            for _, ft in pairs(self.offlineMarketFillTypes) do
                if ft.fillType == filltypeName then
                    ft.fillLevel = math.max(ft.fillLevel + totalLitersProcessed, 0)
                    break
                end
            end

        elseif mode == 2 then
            GlobalMarket.debugLog("  -> Buying into ObjectStorage currently pending BaleManager implementation.")
        end

        if self.updateOfflinePrices ~= nil then self:updateOfflinePrices() end
        if GlobalMarket.config.useSync and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- CLIENT SEND EVENT (Objects)
        if GlobalMarket.config.useSync and SellBuyOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(mode, filltypeName, 0, targetPlaceable, count, true, playerFarmId))
        end
    end
end

-- =========================================================================
-- Engine Hooks & XML Registration
-- =========================================================================

function GlobalMarket.updateUi(streamId, timestamp, connection)
    if g_currentMission.globalMarketUi ~= nil then
        g_currentMission.globalMarketUi:updateContent()
    end
end

-- UI updates remain on the Storage level, as fill level sync happens here
Storage.readUpdateStream = Utils.appendedFunction(Storage.readUpdateStream, GlobalMarket.updateUi)
PlaceableObjectStorage.onReadUpdateStream = Utils.appendedFunction(PlaceableObjectStorage.onReadUpdateStream, GlobalMarket.updateUi)

-- =========================================================================
-- Loading Logic (Bypassing strict XML schema validation using getBool)
-- =========================================================================

function GlobalMarket.PlaceableObjectStorage_onLoad(self, superFunc, savegame)
    superFunc(self, savegame)
    local spec = self.spec_objectStorage
    if spec ~= nil and self.xmlFile ~= nil then
        -- Using getBool instead of getValue to skip schema validation
        spec.isGmMarket = self.xmlFile:getBool("placeable.objectStorage#isGmMarket", false)

        -- Apply to the placeable itself and its internal storage node
        self.isGmMarket = spec.isGmMarket
        if spec.storage ~= nil then
            spec.storage.isGmMarket = spec.isGmMarket
        end
    end
end
PlaceableObjectStorage.onLoad = Utils.overwrittenFunction(PlaceableObjectStorage.onLoad, GlobalMarket.PlaceableObjectStorage_onLoad)

function GlobalMarket.PlaceableSilo_onLoad(self, superFunc, savegame)
    superFunc(self, savegame)
    local spec = self.spec_silo
    if spec ~= nil and self.xmlFile ~= nil then
        -- Using getBool instead of getValue to skip schema validation
        spec.isGmMarket = self.xmlFile:getBool("placeable.silo#isGmMarket", false)

        -- Pass the flag down to all child storages so the existing getAvailableStorages loop works flawlessly
        if spec.storages ~= nil then
            for _, storage in ipairs(spec.storages) do
                storage.isGmMarket = spec.isGmMarket
            end
        end
    end
end
PlaceableSilo.onLoad = Utils.overwrittenFunction(PlaceableSilo.onLoad, GlobalMarket.PlaceableSilo_onLoad)
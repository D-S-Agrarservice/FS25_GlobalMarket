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
-- Gets all valid player storages for a specific fillType (Includes Bulk and ObjectStorages)
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
            local isGmMarket = placeable.isGmMarket or false

            local supportsPallets = spec.supportsPallets or false
            local supportsBales = spec.supportsBales or false

            if placeable:getObjectStorageSupportsFillType(fillTypeIndex) then
                local totalFillLevel = 0

                -- Count existing objects for selling
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

                    if objFillType == fillTypeIndex and not isFermenting then
                        totalFillLevel = totalFillLevel + (objLevel * objectInfo.numObjects)
                    end
                end

                local freeSlots = math.max(0, spec.capacity - spec.numStoredObjects)
                local approximatedFreeCapacity = freeSlots * 1000

                -- NEW: Dynamic Filter Logic for Buying based on native fillType flags
                local isValidForBuying = true
                if not isSelling then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    if fillType ~= nil then
                        local canBeBale = fillType.isBaleType or false
                        local canBePallet = fillType.isPalletType or false

                        -- The storage is valid if it supports at least one format that the fillType also supports
                        if not ((supportsBales and canBeBale) or (supportsPallets and canBePallet)) then
                            isValidForBuying = false
                        end
                    end
                end

                local displayTitle = placeable:getName()
                if isGmMarket then
                    displayTitle = displayTitle .. (g_i18n:getText("ui_gm_terminal_hint") or " (GM Terminal)")
                end

                -- Apply the filter
                if (isSelling and totalFillLevel > 0.1) or (not isSelling and approximatedFreeCapacity > 0.1 and isValidForBuying) then
                    table.insert(availableStorages, {
                        storage = placeable,
                        id = placeable.rootNode,
                        title = displayTitle,
                        level = totalFillLevel,
                        freeCapacity = approximatedFreeCapacity,
                        isGmMarket = isGmMarket,
                        isObjectStorage = true,
                        supportsPallets = supportsPallets,
                        supportsBales = supportsBales
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

        self:onSellBuyObjects(mode, filltypeName, level, storageId, playerFarmId)
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

    -- Security for MP: If storage has no valid farm owner, use the requesting player's farm ID
    local targetFarmId = targetStorage.ownerFarmId
    if targetFarmId == nil or targetFarmId == FarmManager.SPECTATOR_FARM_ID then
        targetFarmId = playerFarmId
    end

    if g_server ~= nil then
        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index

        -- Get current market item data
        local marketItem = nil
        for _, ft in pairs(self.offlineMarketFillTypes) do
            if ft.fillType == filltypeName then
                marketItem = ft
                break
            end
        end

        if marketItem == nil then return end

        -- =======================================================
        -- SERVER-SIDE SECURITY VALIDATION
        -- =======================================================
        local currentSiloLevel = targetStorage:getFillLevel(fillTypeIndex)
        local freeSiloCapacity = targetStorage:getFreeCapacity(fillTypeIndex)

        if mode == 1 then
            -- SELLING: Player cannot sell more than what is physically in the silo
            level = math.min(level, currentSiloLevel)
        elseif mode == 2 then
            -- BUYING: Player cannot buy more than what fits in the silo OR what the market has
            level = math.min(level, freeSiloCapacity)
            level = math.min(level, marketItem.fillLevel)
        end

        -- Abort if the requested amount is zero or negative after limits applied
        if level <= 0.01 then
            GlobalMarket.debugLog("Backend Validation: Transaction aborted. Invalid amount or capacities.")
            return
        end

        local marketPricePerUnit = marketItem.price / 1000
        local totalPrice = marketPricePerUnit * level

        local deliveryCosts = 0
        if not (targetStorage.isGmMarket or false) then
            deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * level) * EconomyManager.getCostMultiplier()
        end

        -- BUYING MONEY CHECK: Ensure the farm has enough funds including delivery
        if mode == 2 then
            local farm = g_farmManager:getFarmById(targetFarmId)
            local totalCost = totalPrice + deliveryCosts
            if farm == nil or farm.money < totalCost then
                GlobalMarket.debugLog("Backend Validation: Transaction aborted. Insufficient funds.")
                return
            end
        end

        -- =======================================================
        -- EXECUTE TRANSACTION
        -- =======================================================
        local finalAccountBalance = (mode == 2) and (totalPrice * -1) or totalPrice
        local moneyType = (mode == 2) and MoneyType.BOUGHT_MATERIALS or MoneyType.SOLD_PRODUCTS

        g_currentMission:addMoney(finalAccountBalance, targetFarmId, moneyType, true, true)

        if deliveryCosts > 0 then
            g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.OTHER, true, true)
        end

        local newSiloLevel = (mode == 2) and (currentSiloLevel + level) or (currentSiloLevel - level)
        targetStorage:setFillLevel(newSiloLevel, fillTypeIndex, nil)

        local marketChange = (mode == 2) and (level * -1) or level
        marketItem.fillLevel = math.max(marketItem.fillLevel + marketChange, 0)

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
function GlobalMarket:onSellBuyObjects(mode, filltypeName, requestedLiters, storageId, playerFarmId)
    GlobalMarket.debugLog("Backend: onSellBuyObjects [Mode: %d, FillType: %s, Requested Liters: %f]", mode, filltypeName, requestedLiters)

    if requestedLiters <= 0.01 then
        GlobalMarket.debugLog("Backend: Transaction aborted. Requested Liters is 0.")
        return
    end

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

    if targetPlaceable == nil then return end

    local targetFarmId = targetPlaceable:getOwnerFarmId()
    if targetFarmId == nil or targetFarmId == FarmManager.SPECTATOR_FARM_ID then targetFarmId = playerFarmId end

    if g_server ~= nil then
        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index
        local spec = targetPlaceable.spec_objectStorage

        -- ==========================================
        -- MODE 1: SELLING (From Storage to Market)
        -- ==========================================
        if mode == 1 then
            local processedLiters = 0

            for i = #spec.storedObjects, 1, -1 do
                if processedLiters >= requestedLiters then break end

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
                    processedLiters = processedLiters + objLevel
                    table.remove(spec.storedObjects, i)
                    obj:delete()

                    if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                        g_farmManager:updateFarmStats(targetFarmId, "storedBales", -1)
                    elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                        g_farmManager:updateFarmStats(targetFarmId, "storedPallets", -1)
                    end
                end
            end

            if processedLiters <= 0 then return end

            spec.numStoredObjects = #spec.storedObjects
            targetPlaceable:setObjectStorageObjectInfosDirty()

            local marketPricePerUnit = self:getOfflinePriceByFillType(filltypeName) / 1000
            local totalPrice = marketPricePerUnit * processedLiters
            local deliveryCosts = 0
            if not (targetPlaceable.isGmMarket or false) then
                deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * processedLiters) * EconomyManager.getCostMultiplier()
            end

            g_currentMission:addMoney(totalPrice, targetFarmId, MoneyType.SOLD_PRODUCTS, true, true)
            if deliveryCosts > 0 then g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.OTHER, true, true) end

            for _, ft in pairs(self.offlineMarketFillTypes) do
                if ft.fillType == filltypeName then
                    ft.fillLevel = math.max(ft.fillLevel + processedLiters, 0)
                    break
                end
            end

        -- ==========================================
        -- MODE 2: BUYING (From Market to Storage)
        -- ==========================================
        elseif mode == 2 then
            local marketItem = nil
            for _, ft in pairs(self.offlineMarketFillTypes) do
                if ft.fillType == filltypeName then marketItem = ft; break; end
            end
            if marketItem == nil then return end

            local availableLitersToBuy = math.min(requestedLiters, marketItem.fillLevel)
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local xmlFilename = nil
            local isBale = false
            local capacityPerObject = 5000

            -- 1. Try finding a default pallet
            if fillType.palletFilename ~= nil and fillType.palletFilename ~= "" then
                xmlFilename = fillType.palletFilename
                capacityPerObject = fillType.palletCapacity or 5000
            else
                -- 2. Try finding a default bale (FIXED CAPACITY READING)
                for _, bale in pairs(g_baleManager.bales) do
                    local baleFillType = bale.fillTypes and bale.fillTypes[fillTypeIndex]
                    if baleFillType ~= nil then
                        xmlFilename = bale.filename
                        capacityPerObject = baleFillType.capacity -- Korrekter Zugriff auf die Kapazität!
                        isBale = true
                        break
                    end
                end
            end

            if xmlFilename == nil then
                GlobalMarket.debugLog("ERROR: No valid Pallet or Bale XML found for FillType %s", filltypeName)
                return
            end

            local numObjectsToBuy = math.floor(availableLitersToBuy / capacityPerObject)
            local freeSlots = math.max(0, spec.capacity - spec.numStoredObjects)
            numObjectsToBuy = math.min(numObjectsToBuy, freeSlots)

            if numObjectsToBuy <= 0 then
                GlobalMarket.debugLog("Backend: Not enough space or requested amount too small for one full object.")
                return
            end

            local actualLitersBought = numObjectsToBuy * capacityPerObject
            local marketPricePerUnit = marketItem.price / 1000
            local totalPrice = marketPricePerUnit * actualLitersBought

            local deliveryCosts = 0
            if not (targetPlaceable.isGmMarket or false) then
                deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * actualLitersBought) * EconomyManager.getCostMultiplier()
            end

            local farm = g_farmManager:getFarmById(targetFarmId)
            if farm == nil or farm.money < (totalPrice + deliveryCosts) then return end

            -- Execute Payment
            g_currentMission:addMoney(totalPrice * -1, targetFarmId, MoneyType.BOUGHT_MATERIALS, true, true)
            if deliveryCosts > 0 then g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.OTHER, true, true) end
            marketItem.fillLevel = math.max(marketItem.fillLevel - actualLitersBought, 0)

            local className = isBale and "Bale" or "Vehicle"
            local abstractClass = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME[className]

            for i = 1, numObjectsToBuy do
                local abstractObject = abstractClass.new()

                if isBale then
                    abstractObject.baleAttributes = {
                        xmlFilename = xmlFilename,
                        fillLevel = capacityPerObject,
                        fillType = fillTypeIndex,
                        wrappingState = 0,
                        variationIndex = 1
                    }
                else
                    abstractObject.palletAttributes = {
                        configFileName = xmlFilename,
                        isBigBag = false,
                        ownerFarmId = targetFarmId,
                        fillType = fillTypeIndex,
                        fillLevel = capacityPerObject,
                        configurations = {
                            fillUnit = 1
                        }
                    }
                end

                if targetPlaceable.addAbstactObjectToObjectStorage ~= nil then
                    targetPlaceable:addAbstactObjectToObjectStorage(abstractObject)
                end
            end

            if isBale then
                g_farmManager:updateFarmStats(targetFarmId, "storedBales", numObjectsToBuy)
            else
                g_farmManager:updateFarmStats(targetFarmId, "storedPallets", numObjectsToBuy)
            end

            targetPlaceable:setObjectStorageObjectInfosDirty()
        end

        if self.updateOfflinePrices ~= nil then self:updateOfflinePrices() end
        if GlobalMarket.config.useSync and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- CLIENT SEND EVENT
        if GlobalMarket.config.useSync and SellBuyOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(mode, filltypeName, requestedLiters, targetPlaceable, requestedLiters, true, playerFarmId))
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
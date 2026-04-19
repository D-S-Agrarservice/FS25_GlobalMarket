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
        if self.debugManager ~= nil then
            self.debugManager:warning("getAvailableStorages: Unknown fillType '%s' requested.", tostring(fillTypeName))
        end
        return availableStorages
    end

    local fillTypeIndex = fillTypeDesc.index

    -- 1. Scan regular bulk storages (Silos, Extensions)
    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
        if storage.ownerFarmId == farmId and storage:getIsFillTypeSupported(fillTypeIndex) then
            local level = storage:getFillLevel(fillTypeIndex)
            local freeCapacity = storage:getFreeCapacity(fillTypeIndex)

            -- MATCHING LOGIC: Since FS25 does not assign owningPlaceable to Storage objects directly,
            -- we match the storage object against the placeables to extract the custom building name.
            local storageName = "Silo"
            local foundOwner = false

            for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                    for _, s in ipairs(placeable.spec_silo.storages) do
                        if s == storage then
                            storageName = placeable:getName()
                            foundOwner = true
                            break
                        end
                    end
                end
                if foundOwner then break end
            end

            local displayTitle = storageName

            if storage.isGmMarket then
                displayTitle = storageName .. (g_i18n:getText("ui_gm_terminal_hint") or " (GM Terminal)")
            end

            if (isSelling and level > 0.1) or (not isSelling and freeCapacity > 0.1) then
                table.insert(availableStorages, {
                    storage = storage,
                    id = storage, -- FIX: Pass the actual table reference, not the rootNode
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
        local isGmMarket = placeable.isGmMarket or false

        -- FIX: Allow access if the player owns the building OR if it is a GM Terminal
        if placeable.spec_objectStorage ~= nil and (placeable:getOwnerFarmId() == farmId or isGmMarket) then
            local spec = placeable.spec_objectStorage

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

                -- Dynamic Filter Logic for Buying based on native fillType flags
                local isValidForBuying = true
                if not isSelling then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    if fillType ~= nil then
                        local canBeBale = fillType.isBaleType or false
                        local canBePallet = fillType.isPalletType or false

                        -- NATIVE PALLET BRIDGE (FS25 WAY):
                        -- Allow anything that has a valid pallet XML defined by the engine,
                        -- including liquids (IBCs) and bulk (fillable pallets like wooden boxes).
                        if fillType.palletFilename ~= nil and fillType.palletFilename ~= "" then
                            canBePallet = true
                        end

                        if not ((supportsBales and canBeBale) or (supportsPallets and canBePallet)) then
                            isValidForBuying = false
                        end
                    end
                end

                local displayTitle = placeable:getName()
                if isGmMarket then
                    displayTitle = displayTitle .. (g_i18n:getText("ui_gm_terminal_hint") or " (GM Terminal)")
                end

                if (isSelling and totalFillLevel > 0.1) or (not isSelling and approximatedFreeCapacity > 0.1 and isValidForBuying) then
                    table.insert(availableStorages, {
                        storage = placeable,
                        id = placeable, -- FIX: Pass the actual table reference, not the rootNode
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

    if self.debugManager ~= nil then
        self.debugManager:trace("getAvailableStorages: Found %d valid storages for %s.", #availableStorages, fillTypeName)
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
        local isGM = placeable.isGmMarket or false

        -- Process if the player owns the building OR if it's a communal GM terminal
        if placeable.spec_objectStorage ~= nil and (placeable:getOwnerFarmId() == farmId or isGM) then
            local spec = placeable.spec_objectStorage
            for _, objectInfo in ipairs(spec.objectInfos) do

                -- GM FIX: Iterate through ALL objects in the mixed group to ensure we only count the player's property
                if objectInfo.objects ~= nil then
                    for _, obj in ipairs(objectInfo.objects) do
                        local objFillType, objLevel = nil, 0
                        local isFermenting = false
                        local objFarmId = FarmManager.SPECTATOR_FARM_ID

                        if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                            objFillType = (obj.baleObject ~= nil) and obj.baleObject:getFillType() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                            objLevel = (obj.baleObject ~= nil) and obj.baleObject:getFillLevel() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillLevel)
                            objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID

                            if obj.baleObject ~= nil and obj.baleObject.isFermenting then isFermenting = true end
                            if obj.baleAttributes ~= nil and obj.baleAttributes.isFermenting then isFermenting = true end
                        elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                            objFillType = obj.palletAttributes ~= nil and obj.palletAttributes.fillType
                            objLevel = obj.palletAttributes ~= nil and obj.palletAttributes.fillLevel
                            objFarmId = obj.palletAttributes ~= nil and obj.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
                        end

                        -- Strictly filter by the object's farmId, not the building's farmId
                        if objFillType ~= nil and not isFermenting and objFarmId == farmId then
                            initFillType(objFillType)
                            -- Note: Do NOT multiply by objectInfo.numObjects here, as we iterate per object
                            local totalVol = objLevel
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
function GlobalMarket:onSellBuy(mode, filltypeName, level, storageId, count, attributes, objectId, isObjectStorage, playerFarmId, formatXml, capacityPerObject)
    -- Fallback for playerFarmId if not provided by older UI calls
    if playerFarmId == nil then
        playerFarmId = g_currentMission:getFarmId()
    end

    if isObjectStorage then
        self:onSellBuyObjects(mode, filltypeName, level, storageId, playerFarmId, formatXml, capacityPerObject)
    else
        self:onSellBuyBulk(mode, filltypeName, level, storageId, playerFarmId)
    end
end

-- Handle standard bulk transactions
function GlobalMarket:onSellBuyBulk(mode, filltypeName, level, targetStorageObj, playerFarmId)
    if self.debugManager ~= nil then
        self.debugManager:info("Backend: onSellBuyBulk [Mode: %d, FillType: %s, Requested Level: %.2f]", mode, filltypeName, level)
    end

    if self:getIsMarketOnline() then
        if self.debugManager ~= nil then self.debugManager:debug("Online-Mode: Redirecting to Sync Module (TBD).") end
        return
    end

    -- FIX: Use the directly passed object reference instead of iterating over rootNodes
    local targetStorage = targetStorageObj

    if targetStorage == nil or type(targetStorage) ~= "table" then
        if self.debugManager ~= nil then self.debugManager:error("Bulk Transaction aborted: Valid Storage Object not found!") end
        return
    end

    -- Security for MP: If storage has no valid farm owner, use the requesting player's farm ID
    local targetFarmId = targetStorage.ownerFarmId
    if targetFarmId == nil or targetFarmId == FarmManager.SPECTATOR_FARM_ID then
        targetFarmId = playerFarmId
    end

    if g_server ~= nil then
        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index

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

        if level <= 0.01 then
            if self.debugManager ~= nil then self.debugManager:warning("Bulk Transaction aborted: Invalid amount or zero capacities.") end
            return
        end

        -- FIX: Use the identical price resolving function as the UI
        local marketPricePerUnit = self:getOfflinePriceByFillType(filltypeName) / 1000
        local totalPrice = marketPricePerUnit * level

        local deliveryCosts = 0
        if not (targetStorage.isGmMarket or false) then
            deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * level) * EconomyManager.getCostMultiplier()
        end

        if mode == 2 then
            local farm = g_farmManager:getFarmById(targetFarmId)
            local totalCost = totalPrice + deliveryCosts

            if self.debugManager ~= nil then
                local currentFarmMoney = farm ~= nil and farm.money or -1
                self.debugManager:trace("Validation Check -> targetFarmId: %s | Farm Money: %.2f | Cost (totalCost): %.2f", tostring(targetFarmId), currentFarmMoney, totalCost)
            end

            if farm == nil or farm.money < totalCost then
                if self.debugManager ~= nil then self.debugManager:warning("Bulk Transaction aborted: Insufficient funds.") end
                return
            end
        end

        -- =======================================================
        -- EXECUTE TRANSACTION
        -- =======================================================
        local finalAccountBalance = (mode == 2) and (totalPrice * -1) or totalPrice
        local isBuying = (mode == 2)
        local moneyType = GlobalMarketFinance.getMoneyType(fillTypeIndex, isBuying, false, false)

        g_currentMission:addMoney(finalAccountBalance, targetFarmId, moneyType, true, true)

        if deliveryCosts > 0 then
            g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.GM_FEE, true, true)
        end

        local newSiloLevel = (mode == 2) and (currentSiloLevel + level) or (currentSiloLevel - level)
        targetStorage:setFillLevel(newSiloLevel, fillTypeIndex, nil)

        local marketChange = (mode == 2) and (level * -1) or level
        marketItem.fillLevel = math.max(marketItem.fillLevel + marketChange, 0)

        if self.debugManager ~= nil then
            self.debugManager:trace("Bulk transaction completed. Price: %.2f, Delivery: %.2f, New Silo Level: %.2f", math.abs(finalAccountBalance), deliveryCosts, newSiloLevel)
        end

        if self.updateOfflinePrices ~= nil then self:updateOfflinePrices() end
        if SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- CLIENT SEND EVENT (Bulk)
        -- FIX: Decoupled from useSync config to ensure the Offline Market works in MP
        -- even if the external sync tool is disabled or currently unavailable.
        if SellBuyOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(mode, filltypeName, level, targetStorageObj, 0, false, playerFarmId))
        end
    end
end

-- Handle object transactions (Bales/Pallets in ObjectStorages)
function GlobalMarket:onSellBuyObjects(mode, filltypeName, requestedLiters, targetPlaceableObj, playerFarmId, formatXml, capacityPerObject)
    if self.debugManager ~= nil then
        self.debugManager:info("Backend: onSellBuyObjects [Mode: %d, FillType: %s, Requested Liters: %.2f]", mode, filltypeName, requestedLiters)
    end

    if requestedLiters <= 0.01 then
        if self.debugManager ~= nil then self.debugManager:warning("Object Transaction aborted. Requested Liters is 0.") end
        return
    end

    if self:getIsMarketOnline() then
        if self.debugManager ~= nil then self.debugManager:debug("Online-Mode: Redirecting to Sync Module (TBD).") end
        return
    end

    local targetPlaceable = targetPlaceableObj

    if targetPlaceable == nil or type(targetPlaceable) ~= "table" then
        if self.debugManager ~= nil then self.debugManager:error("Object Storage ID transaction aborted: Valid Placeable Object not found!") end
        return
    end

    -- FIX: Money and Ownership MUST strictly belong to the acting player.
    local targetFarmId = playerFarmId

    if g_server ~= nil then
        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index
        local spec = targetPlaceable.spec_objectStorage

        -- ==========================================
        -- MODE 1: SELLING (From Storage to Market)
        -- ==========================================
        if mode == 1 then
            local processedLiters = 0
            local wasBaleSold = false

            -- To safely delete abstract objects, we must use the native Engine function
            -- so that objectInfos and storedObjects are kept in sync.
            -- Since the engine function needs the objectInfoIndex, we iterate over objectInfos.
            for infoIndex = #spec.objectInfos, 1, -1 do
                if processedLiters >= requestedLiters then break end

                local objectInfo = spec.objectInfos[infoIndex]
                if objectInfo == nil or objectInfo.objects == nil or #objectInfo.objects == 0 then
                    continue
                end

                -- Check the properties of the first object in the group
                local sampleObj = objectInfo.objects[1]
                local objFillType, objLevel, objXml = nil, 0, nil
                local isFermenting = false
                local objFarmId = FarmManager.SPECTATOR_FARM_ID
                local isBaleType = false

                if sampleObj.REFERENCE_CLASS_NAME == "Bale" or sampleObj.REFERENCE_CLASS_NAME == "PackedBale" then
                    isBaleType = true
                    wasBaleSold = true
                    objFillType = (sampleObj.baleObject ~= nil) and sampleObj.baleObject:getFillType() or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.fillType)
                    objLevel = (sampleObj.baleObject ~= nil) and sampleObj.baleObject:getFillLevel() or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.fillLevel)
                    objXml = (sampleObj.baleObject ~= nil) and sampleObj.baleObject.xmlFilename or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.xmlFilename)
                    objFarmId = (sampleObj.baleObject ~= nil and sampleObj.baleObject.ownerFarmId) or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID

                    if sampleObj.baleObject ~= nil and sampleObj.baleObject.isFermenting then isFermenting = true end
                    if sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.isFermenting then isFermenting = true end
                elseif sampleObj.REFERENCE_CLASS_NAME == "Vehicle" then
                    objFillType = sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.fillType
                    objLevel = sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.fillLevel
                    objXml = sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.configFileName
                    objFarmId = sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
                end

                -- FIX: Ensure we only sell items that actually belong to the acting player
                if objFillType == fillTypeIndex and not isFermenting and objFarmId == targetFarmId then
                    local isFormatMatch = true

                    if formatXml ~= nil and objXml ~= nil then
                        -- Extract the filename from the absolute path to ensure compatibility with custom mod maps
                        local function getFileName(path)
                            return string.match(path, "([^/\\]+)$") or path
                        end

                        local cleanObjXml = string.lower(getFileName(objXml))
                        local cleanFormatXml = string.lower(getFileName(formatXml))

                        if cleanObjXml ~= cleanFormatXml then
                            isFormatMatch = false
                        end

                        -- Bypass strict XML matching for generic engine pallets (e.g., fillablePallet)
                        -- as they dynamically hold different fillTypes like apples, tomatoes, etc.
                        if string.find(cleanObjXml, "fillablepallet") or string.find(cleanFormatXml, "fillablepallet") then
                            isFormatMatch = true
                        end
                    end

                    if isFormatMatch then
                        -- Calculate how many whole objects we can sell from this group
                        local remainingLitersToSell = requestedLiters - processedLiters
                        local objectsToSell = math.floor(remainingLitersToSell / objLevel)

                        -- Cap at the available objects in this group
                        objectsToSell = math.min(objectsToSell, objectInfo.numObjects)

                        if objectsToSell > 0 then
                            local soldLiters = objectsToSell * objLevel
                            processedLiters = processedLiters + soldLiters

                            if self.debugManager ~= nil then
                                self.debugManager:trace("Selling: Removing %d objects of type %s (%.2f L)", objectsToSell, sampleObj.REFERENCE_CLASS_NAME, soldLiters)
                            end

                            -- Remove the items from the internal tables safely
                            for j = 1, objectsToSell do
                                local objToRemove = objectInfo.objects[1]

                                -- 1. Remove from storedObjects array
                                for k = 1, #spec.storedObjects do
                                    if spec.storedObjects[k] == objToRemove then
                                        table.remove(spec.storedObjects, k)
                                        break
                                    end
                                end

                                -- 2. Remove from the group
                                table.remove(objectInfo.objects, 1)
                            end

                            -- Update group count or remove group if empty
                            objectInfo.numObjects = #objectInfo.objects
                            if objectInfo.numObjects == 0 then
                                table.remove(spec.objectInfos, infoIndex)
                            end

                            -- Update Farm Stats
                            if isBaleType then
                                g_farmManager:updateFarmStats(targetFarmId, "storedBales", -objectsToSell)
                            else
                                g_farmManager:updateFarmStats(targetFarmId, "storedPallets", -objectsToSell)
                            end
                        end
                    end
                end
            end

            if processedLiters <= 0 then
                if self.debugManager ~= nil then self.debugManager:warning("Selling aborted: No matching non-fermenting objects owned by player found.") end
                return
            end

            spec.numStoredObjects = #spec.storedObjects
            targetPlaceable:setObjectStorageObjectInfosDirty()

            local marketPricePerUnit = self:getOfflinePriceByFillType(filltypeName) / 1000
            local totalPrice = marketPricePerUnit * processedLiters
            local deliveryCosts = 0
            if not (targetPlaceable.isGmMarket or false) then
                deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * processedLiters) * EconomyManager.getCostMultiplier()
            end

            local isPalletType = not wasBaleSold
            local moneyType = GlobalMarketFinance.getMoneyType(fillTypeIndex, false, wasBaleSold, isPalletType)

            g_currentMission:addMoney(totalPrice, targetFarmId, moneyType, true, true)

            if deliveryCosts > 0 then
                g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.GM_FEE, true, true)
            end

            for _, ft in pairs(self.offlineMarketFillTypes) do
                if ft.fillType == filltypeName then
                    ft.fillLevel = math.max(ft.fillLevel + processedLiters, 0)
                    break
                end
            end

            if self.debugManager ~= nil then self.debugManager:debug("Sold %.2f Liters of objects. Total Earnings: %.2f (Cost: %.2f)", processedLiters, totalPrice, deliveryCosts) end

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

            local xmlFilename = formatXml
            local actualCapacity = capacityPerObject or 5000

            if xmlFilename == nil then
                if self.debugManager ~= nil then self.debugManager:error("Buying aborted: No valid Pallet or Bale XML provided for FillType %s", filltypeName) end
                return
            end

            -- Determine if the format is a bale by checking the engine's bale manager
            local isBale = false
            if g_baleManager ~= nil then
                for _, bale in ipairs(g_baleManager.bales) do
                    if bale.xmlFilename == xmlFilename then
                        isBale = true
                        break
                    end
                end
            end

            local numObjectsToBuy = math.floor(availableLitersToBuy / actualCapacity)
            local freeSlots = math.max(0, spec.capacity - spec.numStoredObjects)
            numObjectsToBuy = math.min(numObjectsToBuy, freeSlots)

            if numObjectsToBuy <= 0 then
                if self.debugManager ~= nil then self.debugManager:warning("Buying aborted: Not enough free slots or requested amount too small for a full object.") end
                return
            end

            local actualLitersBought = numObjectsToBuy * actualCapacity
            local marketPricePerUnit = marketItem.price / 1000
            local totalPrice = marketPricePerUnit * actualLitersBought

            local deliveryCosts = 0
            if not (targetPlaceable.isGmMarket or false) then
                deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * actualLitersBought) * EconomyManager.getCostMultiplier()
            end

            local farm = g_farmManager:getFarmById(targetFarmId)

            if self.debugManager ~= nil then
                local currentFarmMoney = farm ~= nil and farm.money or -1
                self.debugManager:trace("Validation Check -> targetFarmId: %s | Farm Money: %.2f | Cost (totalCost): %.2f", tostring(targetFarmId), currentFarmMoney, totalPrice + deliveryCosts)
            end

            if farm == nil or farm.money < (totalPrice + deliveryCosts) then
                if self.debugManager ~= nil then self.debugManager:warning("Buying aborted: Insufficient funds.") end
                return
            end

            -- Execute Payment
            local isPallet = not isBale
            local moneyType = GlobalMarketFinance.getMoneyType(fillTypeIndex, true, isBale, isPallet)
            g_currentMission:addMoney(totalPrice * -1, targetFarmId, moneyType, true, true)

            if deliveryCosts > 0 then
                g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.GM_FEE, true, true)
            end
            marketItem.fillLevel = math.max(marketItem.fillLevel - actualLitersBought, 0)

            local className = isBale and "Bale" or "Vehicle"
            local abstractClass = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME[className]

            -- Build AbstractObjects to inject into the storage without rendering them in the world yet
            for i = 1, numObjectsToBuy do
                local abstractObject = abstractClass.new()

                if isBale then
                    abstractObject.baleAttributes = {
                        xmlFilename = xmlFilename,
                        fillLevel = actualCapacity,
                        fillType = fillTypeIndex,
                        variationIndex = 1,
                        farmId = targetFarmId,
                        isMissionBale = false,
                        wrappingState = 0,
                        wrappingColor = {1, 1, 1},
                        isFermenting = false,
                        fermentationTime = 0
                    }
                else
                    abstractObject.palletAttributes = {
                        configFileName = xmlFilename,
                        isBigBag = false,
                        ownerFarmId = targetFarmId,
                        fillType = fillTypeIndex,
                        fillLevel = actualCapacity,
                        configurations = {
                            fillUnit = 1
                        }
                    }
                end

                if targetPlaceable.addAbstactObjectToObjectStorage ~= nil then
                    targetPlaceable:addAbstactObjectToObjectStorage(abstractObject)
                    if self.debugManager ~= nil then self.debugManager:trace("Buying: Spawning AbstractObject %d/%d (%s)", i, numObjectsToBuy, className) end
                end
            end

            if isBale then
                g_farmManager:updateFarmStats(targetFarmId, "storedBales", numObjectsToBuy)
            else
                g_farmManager:updateFarmStats(targetFarmId, "storedPallets", numObjectsToBuy)
            end

            targetPlaceable:setObjectStorageObjectInfosDirty()

            if self.debugManager ~= nil then self.debugManager:debug("Bought %d objects (Total: %.2f L). Total Cost: %.2f (Delivery: %.2f)", numObjectsToBuy, actualLitersBought, totalPrice, deliveryCosts) end
        end

        if self.updateOfflinePrices ~= nil then self:updateOfflinePrices() end
        if SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- CLIENT SEND EVENT (Objects)
        -- FIX: Decoupled from useSync config to ensure the Offline Market works in MP
        -- even if the external sync tool is disabled or currently unavailable.
        if SellBuyOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(mode, filltypeName, requestedLiters, targetPlaceableObj, requestedLiters, true, playerFarmId, formatXml, capacityPerObject))
        end
    end
end

-- =========================================================================
-- Engine Hooks & XML Registration
-- =========================================================================

-- Trigger UI content update when storage levels physically change
function GlobalMarket.updateUi(streamId, timestamp, connection)
    if g_currentMission.globalMarketUi ~= nil then
        g_currentMission.globalMarketUi:updateContent()
    end
end

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

        if spec.isGmMarket and GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:trace("GM Terminal Flag (isGmMarket) successfully applied to ObjectStorage.")
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

        if spec.isGmMarket and GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:trace("GM Terminal Flag (isGmMarket) successfully applied to Silo and child storages.")
        end
    end
end
PlaceableSilo.onLoad = Utils.overwrittenFunction(PlaceableSilo.onLoad, GlobalMarket.PlaceableSilo_onLoad)

-- =========================================================================
-- FS25 ENGINE FIX: The "Bouncer" Anti-Theft Patch for ObjectStorages
-- =========================================================================
-- Instead of fighting the engine's networking desyncs, we allow mixed groups.
-- Right before the basegame blindly spawns the first object in a group,
-- the server sorts the player's property to the front of the array.

local oldRemoveObjects = PlaceableObjectStorage.removeAbstractObjectsFromStorage
if oldRemoveObjects ~= nil then
    PlaceableObjectStorage.removeAbstractObjectsFromStorage = function(self, objectInfoIndex, amount, connection)
        -- Only the server handles physical spawning logic
        if g_server ~= nil then
            local spec = self.spec_objectStorage
            if spec ~= nil and spec.objectInfos ~= nil then
                local objectInfo = spec.objectInfos[objectInfoIndex]

                if objectInfo ~= nil and objectInfo.objects ~= nil then
                    -- 1. Identify which farm requested the physical spawn
                    local requestFarmId = FarmManager.SPECTATOR_FARM_ID
                    if connection ~= nil then
                        local user = g_currentMission.userManager:getUserByConnection(connection)
                        if user ~= nil then
                            -- SAFE CHECK: Check if it's a function or a simple property
                            if type(user.getFarmId) == "function" then
                                requestFarmId = user:getFarmId()
                            else
                                requestFarmId = user.farmId or FarmManager.SPECTATOR_FARM_ID
                            end
                        end
                    else
                        -- Fallback for local host triggering the action
                        if type(g_currentMission.getFarmId) == "function" then
                            requestFarmId = g_currentMission:getFarmId()
                        elseif g_currentMission.player ~= nil then
                            requestFarmId = g_currentMission.player.farmId or FarmManager.SPECTATOR_FARM_ID
                        end
                    end

                    -- 2. Sort the array: Player's items first, everyone else's items behind
                    local playerObjects = {}
                    local otherObjects = {}

                    for _, obj in ipairs(objectInfo.objects) do
                        local objFarmId = FarmManager.SPECTATOR_FARM_ID

                        if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                            objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID
                        elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                            objFarmId = obj.palletAttributes ~= nil and obj.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
                        end

                        if objFarmId == requestFarmId then
                            table.insert(playerObjects, obj)
                        else
                            table.insert(otherObjects, obj)
                        end
                    end

                    -- Rebuild the array seamlessly
                    local sortedObjects = {}
                    for _, obj in ipairs(playerObjects) do table.insert(sortedObjects, obj) end
                    for _, obj in ipairs(otherObjects) do table.insert(sortedObjects, obj) end

                    objectInfo.objects = sortedObjects

                    if GlobalMarket ~= nil and GlobalMarket.debugManager ~= nil then
                        GlobalMarket.debugManager:trace("GM Bouncer: Reordered array prior to spawning for FarmId %d.", requestFarmId)
                    end
                end
            end
        end

        -- Let the native Giants logic execute with our manipulated array
        oldRemoveObjects(self, objectInfoIndex, amount, connection)
    end
end
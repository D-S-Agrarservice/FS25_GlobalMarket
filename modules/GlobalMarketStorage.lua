--
-- FS25 - GlobalMarket (Storage Module)
-- Note: Handles physical storage interaction, delivery costs, and GM Terminal logic.
--

-- =========================================================================
-- UI Helper Functions
-- =========================================================================

-- Checks whether a bulk storage is linked to an Animal Husbandry (Barn) via its stations
function GlobalMarket:getConnectedHusbandryPlaceable(storage)
    if storage == nil then
        return nil
    end

    if storage.unloadingStations ~= nil then
        for _, station in pairs(storage.unloadingStations) do
            if station.owningPlaceable ~= nil and station.owningPlaceable.spec_husbandry ~= nil then
                return station.owningPlaceable
            end
        end
    end

    if storage.loadingStations ~= nil then
        for _, station in pairs(storage.loadingStations) do
            if station.owningPlaceable ~= nil and station.owningPlaceable.spec_husbandry ~= nil then
                return station.owningPlaceable
            end
        end
    end

    return nil
end

-- Resolves the owning Placeable, display name, specialization type, and index for a bulk Storage/ManureHeap
function GlobalMarket:resolveBulkStorageOwner(storage)
    if storage == nil then
        return nil, "Silo", "unknown", 1
    end

    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
            -- 1. Standard Silo (PlaceableSilo)
            if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                for i, s in ipairs(placeable.spec_silo.storages) do
                    if s == storage then
                        return placeable, placeable:getName(), "silo", i
                    end
                end
            end

            -- 2. Silo Extension (PlaceableSiloExtension)
            if placeable.spec_siloExtension ~= nil and placeable.spec_siloExtension.storage == storage then
                return placeable, placeable:getName(), "siloExtension", 1
            end

            -- 3. Animal Husbandry / Barn (PlaceableHusbandry)
            if placeable.spec_husbandry ~= nil and placeable.spec_husbandry.storage == storage then
                return placeable, placeable:getName(), "husbandry", 1
            end

            -- 4. Manure Heap (PlaceableManureHeap)
            if placeable.spec_manureHeap ~= nil and placeable.spec_manureHeap.manureHeap == storage then
                return placeable, placeable:getName(), "manureHeap", 1
            end

            -- 5. Production Point (PlaceableProductionPoint)
            if placeable.spec_productionPoint ~= nil and placeable.spec_productionPoint.productionPoint ~= nil then
                if placeable.spec_productionPoint.productionPoint.storage == storage then
                    return placeable, placeable:getName(), "productionPoint", 1
                end
            end
        end
    end

    -- Fallback: Check connected unloading/loading stations for an owningPlaceable reference
    if storage.unloadingStations ~= nil then
        for _, station in pairs(storage.unloadingStations) do
            if station.owningPlaceable ~= nil then
                return station.owningPlaceable, station.owningPlaceable:getName(), "station", 1
            end
        end
    end

    if storage.loadingStations ~= nil then
        for _, station in pairs(storage.loadingStations) do
            if station.owningPlaceable ~= nil then
                return station.owningPlaceable, station.owningPlaceable:getName(), "station", 1
            end
        end
    end

    return nil, "Silo", "unknown", 1
end

-- Validates whether a bulk storage is accessible by the given farmId (GM Terminal or strictly owned by farmId)
function GlobalMarket:getIsBulkStorageAccessible(storage, ownerPlaceable, farmId)
    if storage == nil or farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID or farmId <= 0 then
        return false, false
    end

    local isGmMarket = storage.isGmMarket or (ownerPlaceable ~= nil and ownerPlaceable.isGmMarket) or false
    if isGmMarket then
        return true, true
    end

    -- Strictly require both the storage and its owning placeable building to belong to farmId
    if storage.ownerFarmId ~= farmId then
        return false, false
    end

    if ownerPlaceable ~= nil and ownerPlaceable:getOwnerFarmId() ~= farmId then
        return false, false
    end

    return true, false
end

-- Enforces Barn (Husbandry) & ManureHeap restrictions:
-- 1. ManureHeaps are completely excluded (no manure buying/selling).
-- 2. Barns (and extensions attached to Barns) never allow buying into the barn, and only allow selling Milk.
function GlobalMarket:getIsBulkFillTypeAllowedForStorage(entry, fillTypeIndex, isSelling)
    if entry == nil or fillTypeIndex == nil then
        return false
    end

    if entry.specType == "manureHeap" then
        return false
    end

    if entry.specType == "husbandry" or entry.husbandryPlaceable ~= nil then
        -- Buying goods from the market directly into a barn is never allowed
        if not isSelling then
            return false
        end

        -- Selling from a barn to the market is strictly limited to Milk fillTypes
        if fillTypeIndex == FillType.MILK or
           (FillType.BUFFALOMILK ~= nil and fillTypeIndex == FillType.BUFFALOMILK) or
           (FillType.GOATMILK ~= nil and fillTypeIndex == FillType.GOATMILK) then
            return true
        end

        local barn = entry.husbandryPlaceable or entry.ownerPlaceable
        if barn ~= nil and barn.spec_husbandryMilk ~= nil and barn.spec_husbandryMilk.fillTypes ~= nil then
            if table.hasElement(barn.spec_husbandryMilk.fillTypes, fillTypeIndex) then
                return true
            end
        end

        return false
    end

    return true
end

-- Collects and deduplicates all bulk storages (StorageSystem + ProductionPoints) accessible by farmId
function GlobalMarket:getBulkStorageEntries(farmId)
    local entries = {}
    local seenStorages = {}

    local function tryAddStorage(storage)
        if storage == nil or seenStorages[storage] then
            return
        end
        seenStorages[storage] = true

        local ownerPlaceable, storageName, specType, storageIndex = self:resolveBulkStorageOwner(storage)

        -- Exclude ManureHeaps completely (no manure trading)
        if specType == "manureHeap" then
            return
        end

        local isAccessible, isGmMarket = self:getIsBulkStorageAccessible(storage, ownerPlaceable, farmId)

        if isAccessible then
            local husbandryPlaceable = (specType == "husbandry") and ownerPlaceable or self:getConnectedHusbandryPlaceable(storage)

            table.insert(entries, {
                storage = storage,
                ownerPlaceable = ownerPlaceable,
                husbandryPlaceable = husbandryPlaceable,
                storageName = storageName,
                specType = specType,
                storageIndex = storageIndex,
                isGmMarket = isGmMarket
            })
        end
    end

    -- 1. Standard StorageSystem storages (Silos, SiloExtensions, Husbandries/Barns)
    if g_currentMission ~= nil and g_currentMission.storageSystem ~= nil and g_currentMission.storageSystem.storages ~= nil then
        for storage, _ in pairs(g_currentMission.storageSystem.storages) do
            tryAddStorage(storage)
        end
    end

    -- 2. ProductionPoint storages (not registered in storageSystem.storages by default)
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil and g_currentMission.placeableSystem.placeables ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
            if placeable.spec_productionPoint ~= nil and placeable.spec_productionPoint.productionPoint ~= nil then
                tryAddStorage(placeable.spec_productionPoint.productionPoint.storage)
            end
        end
    end

    return entries
end

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

    -- Enforce GlobalMarketAPI blacklist/allowance rules
    if GlobalMarketAPI ~= nil and not GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then
        return availableStorages
    end

    local fillTypeIndex = fillTypeDesc.index

    -- 1. Scan bulk storages (Silos, Extensions, Barns [Milk Sell only], ProductionPoints)
    local bulkEntries = self:getBulkStorageEntries(farmId)
    for _, entry in ipairs(bulkEntries) do
        local storage = entry.storage
        local isGmMarket = entry.isGmMarket

        if storage:getIsFillTypeSupported(fillTypeIndex) and self:getIsBulkFillTypeAllowedForStorage(entry, fillTypeIndex, isSelling) then
            local level = 0
            local freeCapacity = storage:getFreeCapacity(fillTypeIndex)

            if isGmMarket then
                -- Extract strictly from the Shadow Array for the requesting farm
                level = (storage.gmFarmFillLevels ~= nil and storage.gmFarmFillLevels[farmId] ~= nil) and (storage.gmFarmFillLevels[farmId][fillTypeIndex] or 0) or 0
            else
                level = storage:getFillLevel(fillTypeIndex)
            end

            local displayTitle = entry.storageName or "Silo"

            if isGmMarket then
                displayTitle = displayTitle .. (g_i18n:getText("ui_gm_terminal_hint") or " (GM Terminal)")
            end

            -- Only insert if the farm actually has stock (or if buying, has free capacity)
            if (isSelling and level > 0.01) or (not isSelling and freeCapacity > 0.01) then
                table.insert(availableStorages, {
                    storage = storage,
                    id = storage,
                    title = displayTitle,
                    level = level,
                    freeCapacity = freeCapacity,
                    isGmMarket = isGmMarket,
                    isObjectStorage = false
                })
            end
        end
    end

    -- 2. Scan PlaceableObjectStorages (Bales, Pallets)
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        local isGmMarket = placeable.isGmMarket or false

        if placeable.spec_objectStorage ~= nil and (placeable:getOwnerFarmId() == farmId or isGmMarket) then
            local spec = placeable.spec_objectStorage

            local supportsPallets = spec.supportsPallets or false
            local supportsBales = spec.supportsBales or false

            if placeable:getObjectStorageSupportsFillType(fillTypeIndex) then
                local totalFillLevel = 0

                for _, objectInfo in ipairs(spec.objectInfos) do
                    local obj = objectInfo.objects ~= nil and objectInfo.objects[1] or nil
                    if obj ~= nil then
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

                        if objFillType == fillTypeIndex and not isFermenting and objFarmId == farmId then
                            totalFillLevel = totalFillLevel + (objLevel * objectInfo.numObjects)
                        end
                    end
                end

                local freeSlots = math.max(0, spec.capacity - spec.numStoredObjects)
                local approximatedFreeCapacity = freeSlots * 1000

                local isValidForBuying = true
                if not isSelling then
                    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
                    if fillType ~= nil then
                        local canBeBale = false
                        if fillType.isBaleType and g_baleManager ~= nil and g_baleManager.bales ~= nil then
                            for _, bale in ipairs(g_baleManager.bales) do
                                if bale.isAvailable and bale.fillTypes ~= nil then
                                    for _, ftData in ipairs(bale.fillTypes) do
                                        if ftData.fillTypeIndex == fillTypeIndex then
                                            canBeBale = true
                                            break
                                        end
                                    end
                                end
                                if canBeBale then break end
                            end
                        end

                        local canBePallet = false
                        if GlobalMarketStoreCache ~= nil then
                            local cachedFormats = GlobalMarketStoreCache.getFormatsForFillType(fillType.name)
                            canBePallet = (cachedFormats ~= nil and #cachedFormats > 0)
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
                        id = placeable,
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

    -- 1. Bulk Storages (Silos, Extensions, Barns [Milk only], ProductionPoints & GM Terminals)
    local bulkEntries = self:getBulkStorageEntries(farmId)
    for _, entry in ipairs(bulkEntries) do
        local storage = entry.storage
        local isGM = entry.isGmMarket

        if isGM then
            -- Only extract values from the shadow array for the requesting farm
            if storage.gmFarmFillLevels ~= nil and storage.gmFarmFillLevels[farmId] ~= nil then
                for fillTypeIndex, fillLevel in pairs(storage.gmFarmFillLevels[farmId]) do
                    if fillLevel > 0.01 and self:getIsBulkFillTypeAllowedForStorage(entry, fillTypeIndex, true) then
                        initFillType(fillTypeIndex)
                        fillTypeTotals[fillTypeIndex].total = fillTypeTotals[fillTypeIndex].total + fillLevel
                        fillTypeTotals[fillTypeIndex].gm = fillTypeTotals[fillTypeIndex].gm + fillLevel
                    end
                end
            end
        else
            -- Native behavior for private farm storages
            for fillTypeIndex, fillLevel in pairs(storage:getFillLevels()) do
                if fillLevel > 0.01 and self:getIsBulkFillTypeAllowedForStorage(entry, fillTypeIndex, true) then
                    initFillType(fillTypeIndex)
                    fillTypeTotals[fillTypeIndex].total = fillTypeTotals[fillTypeIndex].total + fillLevel
                    fillTypeTotals[fillTypeIndex].private = fillTypeTotals[fillTypeIndex].private + fillLevel
                end
            end
        end
    end

    -- 2. Object Storages (Bale/Pallet Storages & GM Object Terminals)
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        local isGM = placeable.isGmMarket or false

        if placeable.spec_objectStorage ~= nil and (placeable:getOwnerFarmId() == farmId or isGM) then
            local spec = placeable.spec_objectStorage
            for _, objectInfo in ipairs(spec.objectInfos) do

                if objectInfo.objects ~= nil and #objectInfo.objects > 0 then
                    local isDediClient = (#objectInfo.objects < objectInfo.numObjects)
                    local loopMax = isDediClient and 1 or #objectInfo.objects

                    for i = 1, loopMax do
                        local obj = objectInfo.objects[i]
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

                        if objFillType ~= nil and not isFermenting and objFarmId == farmId then
                            initFillType(objFillType)

                            local multiplier = isDediClient and objectInfo.numObjects or 1
                            local totalVol = objLevel * multiplier

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

    -- Convert totals into UI-ready table (excluding blacklisted fillTypes such as WATER in barns)
    for fillTypeIndex, totals in pairs(fillTypeTotals) do
        local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillTypeDesc ~= nil and (GlobalMarketAPI == nil or GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc)) then
            table.insert(aggregatedData, {
                fillType = fillTypeDesc.name,
                level = totals.total,
                levelPrivate = totals.private,
                levelGM = totals.gm,
                price = self:getOfflinePriceByFillType(fillTypeDesc.name)
            })
        end
    end

    -- Sort alphabetically by localized title (using umlaut/accent-safe normalization if available)
    table.sort(aggregatedData, function(a, b)
        local descA = g_fillTypeManager:getFillTypeByName(a.fillType)
        local descB = g_fillTypeManager:getFillTypeByName(b.fillType)
        local rawA = descA ~= nil and descA.title or tostring(a.fillType or "")
        local rawB = descB ~= nil and descB.title or tostring(b.fillType or "")
        if GlobalMarketUI ~= nil and GlobalMarketUI.normalizeSortTitle ~= nil then
            local normA = GlobalMarketUI.normalizeSortTitle(rawA)
            local normB = GlobalMarketUI.normalizeSortTitle(rawB)
            if normA ~= normB then
                return normA < normB
            end
        end
        return rawA < rawB
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

    local targetStorage = targetStorageObj

    if targetStorage == nil or type(targetStorage) ~= "table" then
        if self.debugManager ~= nil then self.debugManager:error("Bulk Transaction aborted: Valid Storage Object not found!") end
        return
    end

    -- FIX: Money and Ownership MUST strictly belong to the acting player, regardless of who owns the physical silo building.
    local targetFarmId = playerFarmId

    if g_server ~= nil then
        if self:getIsMarketOnline() and self.checkOnlineTransactionCooldown ~= nil and not self:checkOnlineTransactionCooldown(filltypeName) then
            return
        end

        local fillTypeDesc = g_fillTypeManager:getFillTypeByName(filltypeName)
        if fillTypeDesc == nil or (GlobalMarketAPI ~= nil and not GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc)) then
            if self.debugManager ~= nil then self.debugManager:warning("Bulk Transaction aborted: FillType '%s' is invalid or blacklisted.", tostring(filltypeName)) end
            return
        end

        local fillTypeIndex = fillTypeDesc.index
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
        local ownerPlaceable, storageName, specType, storageIndex = self:resolveBulkStorageOwner(targetStorage)
        local isAccessible, isGmMarket = self:getIsBulkStorageAccessible(targetStorage, ownerPlaceable, targetFarmId)
        if not isAccessible then
            if self.debugManager ~= nil then
                self.debugManager:warning("Bulk Transaction aborted: Farm %d does not own the target storage!", tostring(targetFarmId))
            end
            return
        end

        local husbandryPlaceable = (specType == "husbandry") and ownerPlaceable or self:getConnectedHusbandryPlaceable(targetStorage)
        local validationEntry = {
            storage = targetStorage,
            ownerPlaceable = ownerPlaceable,
            husbandryPlaceable = husbandryPlaceable,
            storageName = storageName,
            specType = specType,
            storageIndex = storageIndex,
            isGmMarket = isGmMarket
        }

        if not self:getIsBulkFillTypeAllowedForStorage(validationEntry, fillTypeIndex, mode == 1) then
            if self.debugManager ~= nil then
                self.debugManager:warning("Bulk Transaction aborted: FillType '%s' is not allowed for storage type '%s' (Mode %d).", tostring(filltypeName), tostring(specType), mode)
            end
            return
        end

        local physicalSiloLevel = targetStorage:getFillLevel(fillTypeIndex)
        local availableForFarm = physicalSiloLevel

        -- If GM Market, validate strictly against the Shadow Array
        if isGmMarket then
            availableForFarm = (targetStorage.gmFarmFillLevels ~= nil and targetStorage.gmFarmFillLevels[playerFarmId] ~= nil) and (targetStorage.gmFarmFillLevels[playerFarmId][fillTypeIndex] or 0) or 0
        end

        if mode == 1 then
            -- SELLING: Player cannot sell more than what they own
            level = math.min(level, availableForFarm)
        elseif mode == 2 then
            -- BUYING: Shared global free capacity
            local freeSiloCapacity = targetStorage:getFreeCapacity(fillTypeIndex)
            level = math.min(level, freeSiloCapacity)
            level = math.min(level, marketItem.fillLevel)
        end

        if level <= 0.01 then
            if self.debugManager ~= nil then self.debugManager:warning("Bulk Transaction aborted: Invalid amount or zero capacities.") end
            return
        end

        local marketPricePerUnit = self:getOfflinePriceByFillType(filltypeName) / 1000

        -- Apply a spread (markup) when buying to prevent instant arbitrage at the terminal
        if mode == 2 then
            marketPricePerUnit = marketPricePerUnit * (1 + (GlobalMarket.DEALER_MARKUP / 100))
        end

        local totalPrice = marketPricePerUnit * level
        local deliveryCosts = 0

        if not isGmMarket then
            deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * level) * EconomyManager.getCostMultiplier()
        end

        if mode == 2 then
            local farm = g_farmManager:getFarmById(targetFarmId)
            local totalCost = totalPrice + deliveryCosts

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

        local newSiloLevel = (mode == 2) and (physicalSiloLevel + level) or (physicalSiloLevel - level)

        -- Inject tempFarmId to force Hook 6 (access.lua) to update the Shadow Array for the BUYING/SELLING farm
        if isGmMarket then
            targetStorage.gmTempFarmId = targetFarmId
        end

        targetStorage:setFillLevel(newSiloLevel, fillTypeIndex, nil)

        if isGmMarket then
            targetStorage.gmTempFarmId = nil
        end

        local marketChange = (mode == 2) and (level * -1) or level
        marketItem.fillLevel = math.max(marketItem.fillLevel + marketChange, 0)
        if mode == 1 and self.onMarketGoodsSold ~= nil then
            self:onMarketGoodsSold(filltypeName, level)
        end

        if self.debugManager ~= nil then
            self.debugManager:trace("Bulk transaction completed. Price: %.2f, Delivery: %.2f, New Silo Level: %.2f", math.abs(finalAccountBalance), deliveryCosts, newSiloLevel)
        end

        if self.refreshMarketPrices ~= nil then self:refreshMarketPrices() end
        if self.dispatchOnlineTransaction ~= nil and self:getIsMarketOnline() then
            self:dispatchOnlineTransaction(filltypeName, level, (mode == 2) and "BUY" or "SELL")
        end
        if SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- CLIENT SEND EVENT (Bulk)
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

    local targetPlaceable = targetPlaceableObj

    if targetPlaceable == nil or type(targetPlaceable) ~= "table" then
        if self.debugManager ~= nil then self.debugManager:error("Object Storage ID transaction aborted: Valid Placeable Object not found!") end
        return
    end

    -- FIX: Money and Ownership MUST strictly belong to the acting player.
    local targetFarmId = playerFarmId

    if g_server ~= nil then
        if self:getIsMarketOnline() and self.checkOnlineTransactionCooldown ~= nil and not self:checkOnlineTransactionCooldown(filltypeName) then
            return
        end

        local fillTypeDesc = g_fillTypeManager:getFillTypeByName(filltypeName)
        if fillTypeDesc == nil or (GlobalMarketAPI ~= nil and not GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc)) then
            if self.debugManager ~= nil then self.debugManager:warning("Object Transaction aborted: FillType '%s' is invalid or blacklisted.", tostring(filltypeName)) end
            return
        end

        local isGmMarket = targetPlaceable.isGmMarket or false
        if not isGmMarket and targetPlaceable:getOwnerFarmId() ~= targetFarmId then
            if self.debugManager ~= nil then self.debugManager:warning("Object Transaction aborted: Farm %d does not own the target ObjectStorage!", tostring(targetFarmId)) end
            return
        end

        local fillTypeIndex = fillTypeDesc.index
        local spec = targetPlaceable.spec_objectStorage

        -- =========================================================
        -- PRE-PROCESS: Decode Network Payload (Number -> String)
        -- formatXml can be an Integer (Dedi Client Event) or String (SP/Host UI / Pallet)
        -- =========================================================
        local rawInput = formatXml
        local xmlFilename = nil
        local isTargetBale = false

        -- 1. Input is a Number (Bale Index received via Network Event from a Dedicated Client)
        if type(rawInput) == "number" and rawInput > 0 then
            if g_baleManager ~= nil then
                xmlFilename = g_baleManager:getBaleXMLFilenameByIndex(rawInput)
                if xmlFilename ~= nil then isTargetBale = true end
            end

        -- 2. Input is a String (Direct call from UI in SP/Host, OR it is a Pallet)
        elseif type(rawInput) == "string" and rawInput ~= "" then
            local decodedFilename = rawInput
            if NetworkUtil ~= nil and NetworkUtil.convertFromNetworkFilename ~= nil then
                decodedFilename = NetworkUtil.convertFromNetworkFilename(rawInput) or rawInput
            end
            if g_baleManager ~= nil and g_baleManager:getBaleTypeIndexByXMLFilename(decodedFilename) ~= nil then
                isTargetBale = true
            end
            xmlFilename = decodedFilename
        end

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

                    -- FIX: Compare against decoded xmlFilename, not the raw integer payload
                    if xmlFilename ~= nil and objXml ~= nil then
                        -- Extract the filename from the absolute path to ensure compatibility with custom mod maps
                        local function getFileName(path)
                            return string.match(path, "([^/\\]+)$") or path
                        end

                        local cleanObjXml = string.lower(getFileName(objXml))
                        local cleanFormatXml = string.lower(getFileName(xmlFilename))

                        if cleanObjXml ~= cleanFormatXml then
                            isFormatMatch = false
                        end

                        -- Bypass strict XML matching for generic engine pallets (e.g., fillablePallet, vegetablesPallet)
                        -- as they dynamically hold different fillTypes like apples, tomatoes, root crops, etc.
                        if string.find(cleanObjXml, "fillablepallet", 1, true) or string.find(cleanFormatXml, "fillablepallet", 1, true)
                            or string.find(cleanObjXml, "vegetablespallet", 1, true) or string.find(cleanFormatXml, "vegetablespallet", 1, true) then
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
            if self.onMarketGoodsSold ~= nil then
                self:onMarketGoodsSold(filltypeName, processedLiters)
            end

            if self.debugManager ~= nil then self.debugManager:debug("Sold %.2f Liters of objects. Total Earnings: %.2f (Cost: %.2f)", processedLiters, totalPrice, deliveryCosts) end
            if self.dispatchOnlineTransaction ~= nil and self:getIsMarketOnline() then
                self:dispatchOnlineTransaction(filltypeName, processedLiters, "SELL")
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
            local actualCapacity = capacityPerObject or 5000

            if xmlFilename == nil then
                if self.debugManager ~= nil then self.debugManager:error("Buying aborted: No valid Pallet or Bale XML provided for FillType %s", filltypeName) end
                return
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

            -- Apply a spread (markup) when buying objects to prevent instant arbitrage
            marketPricePerUnit = marketPricePerUnit * (1 + (GlobalMarket.DEALER_MARKUP / 100))

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
            local isPallet = not isTargetBale
            local moneyType = GlobalMarketFinance.getMoneyType(fillTypeIndex, true, isTargetBale, isPallet)
            g_currentMission:addMoney(totalPrice * -1, targetFarmId, moneyType, true, true)

            if deliveryCosts > 0 then
                g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.GM_FEE, true, true)
            end
            marketItem.fillLevel = math.max(marketItem.fillLevel - actualLitersBought, 0)

            local className = isTargetBale and "Bale" or "Vehicle"
            local abstractClass = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME[className]

            -- Build AbstractObjects to inject into the storage without rendering them in the world yet
            for i = 1, numObjectsToBuy do
                local abstractObject = abstractClass.new()

                if isTargetBale then
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
                    local lowerXml = string.lower(xmlFilename)
                    local isBigBag = (string.find(lowerXml, "bigbag", 1, true) ~= nil and string.find(lowerXml, "bigbagpallet", 1, true) == nil)

                    abstractObject.palletAttributes = {
                        configFileName = xmlFilename,
                        isBigBag = isBigBag,
                        ownerFarmId = targetFarmId,
                        fillType = fillTypeIndex,
                        fillLevel = actualCapacity,
                        configurations = {
                            fillUnit = 1
                        }
                    }
                end

                if abstractClass.getSize ~= nil then
                    abstractClass.getSize(xmlFilename)
                end

                if targetPlaceable.addAbstactObjectToObjectStorage ~= nil then
                    targetPlaceable:addAbstactObjectToObjectStorage(abstractObject)
                    if self.debugManager ~= nil then self.debugManager:trace("Buying: Spawning AbstractObject %d/%d (%s)", i, numObjectsToBuy, className) end
                end
            end

            if isTargetBale then
                g_farmManager:updateFarmStats(targetFarmId, "storedBales", numObjectsToBuy)
            else
                g_farmManager:updateFarmStats(targetFarmId, "storedPallets", numObjectsToBuy)
            end

            targetPlaceable:setObjectStorageObjectInfosDirty()
            if self.dispatchOnlineTransaction ~= nil and self:getIsMarketOnline() then
                self:dispatchOnlineTransaction(filltypeName, actualLitersBought, "BUY")
            end
        end

        if self.refreshMarketPrices ~= nil then self:refreshMarketPrices() end
        if SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- CLIENT SEND EVENT (Objects)
        -- FIX: Decoupled from useSync config to ensure the Offline Market works in MP
        -- even if the external sync tool is disabled or currently unavailable.
        if SellBuyOfflineMarketEvent ~= nil then

            -- SMART TRANSMISSION: Default to the original string (for pallets)
            local payloadData = formatXml

            -- If it's a bale, overwrite the string with the synchronized integer index
            if formatXml ~= nil and g_baleManager ~= nil then
                local foundIndex = g_baleManager:getBaleTypeIndexByXMLFilename(formatXml)
                if foundIndex ~= nil then
                    payloadData = foundIndex
                end
            end

            -- Normalize pallet XML paths for Dedicated Server compatibility ($moddir$ / $pdlcdir$ / $data)
            if type(payloadData) == "string" and payloadData ~= "" and NetworkUtil ~= nil and NetworkUtil.convertToNetworkFilename ~= nil then
                payloadData = NetworkUtil.convertToNetworkFilename(payloadData)
            end

            -- Pass payloadData (which is now either a String for Pallets or a Number for Bales)
            g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(mode, filltypeName, requestedLiters, targetPlaceableObj, requestedLiters, true, playerFarmId, payloadData, capacityPerObject))
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

        if spec.isGmMarket then
            if GlobalMarketAccess ~= nil and GlobalMarketAccess.applyGmPlaceableHooks ~= nil then
                GlobalMarketAccess.applyGmPlaceableHooks(self)
            end
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("GM Terminal Flag (isGmMarket) successfully applied to ObjectStorage.")
            end
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

        self.isGmMarket = spec.isGmMarket

        if spec.unloadingStation ~= nil then
            spec.unloadingStation.isGmMarket = spec.isGmMarket
        end
        if spec.loadingStation ~= nil then
            spec.loadingStation.isGmMarket = spec.isGmMarket
        end

        -- Pass the flag down to all child storages so the existing getAvailableStorages loop works flawlessly
        if spec.storages ~= nil then
            for _, storage in ipairs(spec.storages) do
                storage.isGmMarket = spec.isGmMarket
            end
        end

        if spec.isGmMarket then
            if GlobalMarketAccess ~= nil and GlobalMarketAccess.applyGmPlaceableHooks ~= nil then
                GlobalMarketAccess.applyGmPlaceableHooks(self)
            end
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("GM Terminal Flag (isGmMarket) successfully applied to Silo and child storages.")
            end
        end
    end
end
PlaceableSilo.onLoad = Utils.overwrittenFunction(PlaceableSilo.onLoad, GlobalMarket.PlaceableSilo_onLoad)

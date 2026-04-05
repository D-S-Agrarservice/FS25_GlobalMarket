--
-- FS25 - GlobalMarket (Storage Module)
-- Note: Handles physical storage interaction, delivery costs, and GM Terminal logic.
--

-- =========================================================================
-- UI Helper Functions
-- =========================================================================

-- Gets all valid player storages for a specific fillType
-- @param fillTypeName string: The name of the fillType (e.g., "MAIZE")
-- @param farmId integer: The ID of the farm requesting the storages
-- @param isSelling boolean: True if player wants to sell to GM (needs stock), False if buying (needs free capacity)
function GlobalMarket:getAvailableStorages(fillTypeName, farmId, isSelling)
    local availableStorages = {}

    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(fillTypeName)
    if fillTypeDesc == nil then
        return availableStorages
    end

    local fillTypeIndex = fillTypeDesc.index

    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
        -- Filter: Only owned storages
        if storage.ownerFarmId == farmId then
            if storage:getIsFillTypeSupported(fillTypeIndex) then

                local level = storage:getFillLevel(fillTypeIndex)
                local freeCapacity = storage:getFreeCapacity(fillTypeIndex)

                -- Improved name detection for FS25 placeables
                local storageName = "Silo"
                if storage.owningPlaceable ~= nil then
                    storageName = storage.owningPlaceable:getName()
                end

                -- LOGISTIC PACK: If it's a GM Terminal, we flag it in the UI title using l10n
                local displayTitle = storageName
                if storage.isGmMarket then
                    local hint = g_i18n:getText("ui_gm_terminal_hint") or " (GM Terminal)"
                    displayTitle = storageName .. hint
                end

                -- Use the rootNode as a reliable unique ID across the network
                local uniqueId = storage.rootNode

                if isSelling and level > 0.1 then
                    table.insert(availableStorages, {
                        storage = storage,
                        id = uniqueId,
                        title = displayTitle,
                        level = level,
                        freeCapacity = freeCapacity,
                        isGmMarket = storage.isGmMarket or false
                    })
                elseif not isSelling and freeCapacity > 0.1 then
                    table.insert(availableStorages, {
                        storage = storage,
                        id = uniqueId,
                        title = displayTitle,
                        level = level,
                        freeCapacity = freeCapacity,
                        isGmMarket = storage.isGmMarket or false
                    })
                end
            end
        end
    end

    return availableStorages
end

-- Gets aggregated fill levels for all valid player storages to display in the UI list
function GlobalMarket:getAggregatedStorageData(farmId)
    local aggregatedData = {}
    local fillTypeTotals = {}

    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
        -- We exclude GM Terminals from the "Owned Stock" summary to keep it clean
        if storage.ownerFarmId == farmId and not (storage.isGmMarket or false) then
            for fillTypeIndex, fillLevel in pairs(storage:getFillLevels()) do
                if fillLevel > 0.1 then
                    fillTypeTotals[fillTypeIndex] = (fillTypeTotals[fillTypeIndex] or 0) + fillLevel
                end
            end
        end
    end

    for fillTypeIndex, totalLevel in pairs(fillTypeTotals) do
        local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
        if fillTypeDesc ~= nil then
            table.insert(aggregatedData, {
                fillType = fillTypeDesc.name,
                level = totalLevel,
                price = self:getOfflinePriceByFillType(fillTypeDesc.name) -- Fetches from the new Offline module
            })
        end
    end

    -- Sort alphabetically
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

-- Main Entry Point for UI Actions
function GlobalMarket:onSellBuy(mode, filltypeName, level, storageId, count, attributes, objectId)
    GlobalMarket.debugLog("UI Action: onSellBuy [Mode: %d, FillType: %s, Level: %f]", mode, filltypeName, level)

    local isOnline = self:getIsMarketOnline()

    if isOnline then
        -- Placeholder for future Online-Service communication via GMSync
        GlobalMarket.debugLog("  -> Online-Mode: Redirecting to Sync Module (TBD).")
    else
        -- OFFLINE MODE
        GlobalMarket.debugLog("  -> Offline-Mode: Processing transaction...")

        -- 1. Find the target storage object
        local targetStorage = nil
        for storage, _ in pairs(g_currentMission.storageSystem.storages) do
            if storage.rootNode == storageId then
                targetStorage = storage
                break
            end
        end

        if targetStorage == nil then
            GlobalMarket.debugLog("ERROR: Storage ID %s not found!", tostring(storageId))
            return
        end

        -- 2. Calculate Prices and Fees
        local marketPricePerUnit = self:getOfflinePriceByFillType(filltypeName) / 1000
        local totalPrice = marketPricePerUnit * level
        local moneyType = (mode == 2) and MoneyType.BOUGHT_MATERIALS or MoneyType.SOLD_PRODUCTS

        -- FIX: The old playerFarmId is nil, which causes addMoney to silently fail.
        -- We extract the correct Farm ID from the storage owner.
        local targetFarmId = targetStorage.ownerFarmId or g_currentMission:getFarmId()

        -- LOGISTIC PACK: Check if we charge delivery fees
        local deliveryCosts = 0
        if not (targetStorage.isGmMarket or false) then
            -- Charging fees for delivery to private farm silos
            deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * level) * EconomyManager.getCostMultiplier()
        else
            GlobalMarket.debugLog("  -> GM Terminal: Skipping delivery fees.")
        end

        -- Final balance (Buying = negative, Selling = positive)
        local finalAccountBalance = (mode == 2) and (totalPrice * -1) or totalPrice

        -- If this debug line doesn't show up in the log, the file wasn't saved!
        GlobalMarket.debugLog("  -> Booking Money: %f to FarmID: %s", finalAccountBalance, tostring(targetFarmId))

        if g_server ~= nil then
            -- Execute on Server
            g_currentMission:addMoney(finalAccountBalance, targetFarmId, moneyType, true, true)

            if deliveryCosts > 0 then
                g_currentMission:addMoney(deliveryCosts * -1, targetFarmId, MoneyType.OTHER, true, true)
            end

            -- Update Physical Storage
            local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index
            local currentSiloLevel = targetStorage:getFillLevel(fillTypeIndex)
            local newSiloLevel = (mode == 2) and (currentSiloLevel + level) or (currentSiloLevel - level)
            targetStorage:setFillLevel(newSiloLevel, fillTypeIndex, nil)

            -- Update Offline Market Saturation (Supply/Demand)
            for _, ft in pairs(self.offlineMarketFillTypes) do
                if ft.fillType == filltypeName then
                    -- If player sells, market level increases. If player buys, market level decreases.
                    local marketChange = (mode == 2) and (level * -1) or level
                    ft.fillLevel = math.max(ft.fillLevel + marketChange, 0)
                    break
                end
            end

            -- Recalculate Prices after transaction
            if self.updateOfflinePrices ~= nil then
                self:updateOfflinePrices()
            end

            -- Broadcast to Clients (Only if Sync is enabled)
            if GlobalMarket.config.useSync and SynchOfflineMarketEvent ~= nil then
                g_server:broadcastEvent(SynchOfflineMarketEvent.new())
            end
        else
            -- Send to Server if we are a Client (Only if Sync is enabled)
            if GlobalMarket.config.useSync and SellBuyOfflineMarketEvent ~= nil then
                g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(finalAccountBalance, targetFarmId, level, filltypeName, targetStorage, g_currentMission.playerUserId))
            end
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

-- 1. XML Path Registration (Directly injecting into the global Placeable schema)
if Placeable.xmlSchema ~= nil then
    Placeable.xmlSchema:register(XMLValueType.BOOL, "placeable.objectStorage#isGmMarket", "ObjectStorage is GlobalMarketPlaceable", false)
    Placeable.xmlSchema:register(XMLValueType.BOOL, "placeable.silo#isGmMarket", "Silo is GlobalMarketPlaceable", false)
else
    GlobalMarket.debugLog("ERROR: Placeable.xmlSchema is nil! Cannot register XML paths.")
end

-- 2. Loading Logic (Read XML and pass the flag to the physical storages)
function GlobalMarket.PlaceableObjectStorage_onLoad(self, superFunc, savegame)
    superFunc(self, savegame)
    local spec = self.spec_objectStorage
    if spec ~= nil and self.xmlFile ~= nil then
        spec.isGmMarket = self.xmlFile:getValue("placeable.objectStorage#isGmMarket", false)

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
        spec.isGmMarket = self.xmlFile:getValue("placeable.silo#isGmMarket", false)

        -- Pass the flag down to all child storages so the existing getAvailableStorages loop works flawlessly
        if spec.storages ~= nil then
            for _, storage in ipairs(spec.storages) do
                storage.isGmMarket = spec.isGmMarket
            end
        end
    end
end
PlaceableSilo.onLoad = Utils.overwrittenFunction(PlaceableSilo.onLoad, GlobalMarket.PlaceableSilo_onLoad)
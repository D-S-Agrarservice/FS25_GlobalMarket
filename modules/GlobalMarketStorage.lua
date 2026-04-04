--
-- FS25 - GlobalMarket (Storage Module)
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
        GlobalMarket.debugLog("Storage: FillType '%s' not found.", tostring(fillTypeName))
        return availableStorages 
    end

    local fillTypeIndex = fillTypeDesc.index

    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
        -- Check ownership and ensure it's not the GM market itself
        if storage.ownerFarmId == farmId and not storage.isGmMarket then
            if storage:getIsFillTypeSupported(fillTypeIndex) then
                
                local level = storage:getFillLevel(fillTypeIndex)
                local freeCapacity = storage:getFreeCapacity(fillTypeIndex)

                -- Attempt to get a human-readable name
                local placeable = storage.owningPlaceable
                local storageName = placeable ~= nil and placeable:getName() or "Unknown Silo"

                -- Filter based on transaction context
                if isSelling and level > 0 then
                    table.insert(availableStorages, {
                        storage = storage,
                        id = storage.id,
                        title = storageName,
                        level = level,
                        freeCapacity = freeCapacity
                    })
                elseif not isSelling and freeCapacity > 0 then
                    table.insert(availableStorages, {
                        storage = storage,
                        id = storage.id,
                        title = storageName,
                        level = level,
                        freeCapacity = freeCapacity
                    })
                end
            end
        end
    end

    GlobalMarket.debugLog("Storage: Found %d valid storages for %s (isSelling: %s)", #availableStorages, fillTypeName, tostring(isSelling))
    return availableStorages
end

function GlobalMarket:sellSilo(price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
    self:sellBuySilo(MoneyType.SOLD_PRODUCTS, price, playerFarmId, fillTypeName, fillLevel * -1, storage, playerUserId)
end

function GlobalMarket:buySilo(price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
    self:sellBuySilo(MoneyType.BOUGHT_MATERIALS, price * -1, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
end

function GlobalMarket:sellBuySilo(moneyType, price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
    GlobalMarket.debugLog("Storage: Silo Transaction [Farm: %d, Type: %s, Price: %f, Amount: %f]", playerFarmId, fillTypeName, price, fillLevel)

    if g_server ~= nil then
        g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, moneyType, true, true)

        if storage ~= nil and not storage.isGmMarket then
            local deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * math.abs(fillLevel)) * EconomyManager.getCostMultiplier() * -1
            g_currentMission:addMoney(deliveryCosts, playerFarmId, MoneyType.OTHER, true, true)
            GlobalMarket.debugLog("  -> Delivery costs applied: %f", deliveryCosts)
        end

        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(fillTypeName).index
        if storage ~= nil then
            storage:setFillLevel(storage:getFillLevel(fillTypeIndex) + fillLevel, fillTypeIndex, nil)
            if storage.storageDirtyFlag ~= nil then
                storage:raiseDirtyFlags(storage.storageDirtyFlag)
            end
        end
    end

    if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
        self:handleUiClosures()
    end
end

function GlobalMarket:sellObject(price, playerFarmId, count, attributes, storage, playerUserId)
    self:sellBuyObject(MoneyType.SOLD_PRODUCTS, price, playerFarmId, count, attributes, storage, playerUserId, true)
end

function GlobalMarket:buyObject(price, playerFarmId, count, attributes, storage, playerUserId)
    self:sellBuyObject(MoneyType.BOUGHT_MATERIALS, price * -1, playerFarmId, count, attributes, storage, playerUserId, false)
end

function GlobalMarket:sellBuyObject(moneyType, price, playerFarmId, count, attributes, storage, playerUserId, isSelling)
    GlobalMarket.debugLog("Storage: Object Transaction [Farm: %d, Selling: %s, Count: %d]", playerFarmId, tostring(isSelling), count)

    if g_server ~= nil then
        g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, moneyType, true, true)

        if storage ~= nil and not storage.isGmMarket then
            local deliveryCosts = (GlobalMarket.DELIVER_COST + (150 * count)) * EconomyManager.getCostMultiplier() * -1
            g_currentMission:addMoney(deliveryCosts, playerFarmId, MoneyType.OTHER, true, true)
            GlobalMarket.debugLog("  -> Delivery costs applied: %f", deliveryCosts)
        end

        if storage ~= nil then
            if isSelling then
                -- Note: FS25 Object removal logic. Exact implementation depends on PlaceableObjectStorage API
                if type(storage.removeObjectByAttributes) == "function" then
                    for i = 1, count do
                        storage:removeObjectByAttributes(attributes)
                    end
                end
            else
                if type(storage.addObjectByAttributes) == "function" then
                    for i = 1, count do
                        storage:addObjectByAttributes(attributes)
                    end
                end
            end
        end
    end

    if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
        self:handleUiClosures()
    end
end

function GlobalMarket:sellBuyOfflineMarket(price, moneyType, playerFarmId, level, filltypeName, storage, playerUserId)
    GlobalMarket.debugLog("Storage: Offline Market Action [Price: %f, Level: %f, FillType: %s]", price, level, filltypeName)

    if g_server ~= nil then
        for _, ft in pairs(self.offlineMarketFillTypes) do
            if ft.fillType == filltypeName then
                ft.fillLevel = math.max(ft.fillLevel + (level * -1), 0)
                ft.price = GlobalMarket.calcOfflinePrice(ft.normalPrice, ft.fillLevel)
            end
        end

        g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, moneyType, true, true)

        if storage ~= nil and not storage.isGmMarket then
            local deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * math.abs(level)) * EconomyManager.getCostMultiplier() * -1
            g_currentMission:addMoney(deliveryCosts, playerFarmId, MoneyType.OTHER, true, true)
        end

        local fillTypeDesc = g_fillTypeManager:getFillTypeByName(filltypeName)
        if fillTypeDesc ~= nil and storage ~= nil then
            local fillTypeIndex = fillTypeDesc.index
            storage:setFillLevel(storage:getFillLevel(fillTypeIndex) + level, fillTypeIndex, nil)
        end

        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
    end

    if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
        if g_currentMission.globalMarketSelectLevelUi ~= nil then
            g_currentMission.globalMarketSelectLevelUi:close()
        end
    end
end

function GlobalMarket:onSellBuy(mode, filltypeName, level, storageId, count, attributes, objectId)
    GlobalMarket.debugLog("UI Action: onSellBuy [Mode: %d, FillType: %s, Level: %f]", mode, filltypeName, level)

    local isOnline = self:getIsMarketOnline()

    if isOnline then
        -- ONLINE MODE LOGIC (Prepared, but dormant since isOnline is forced to false currently)
        GlobalMarket.debugLog("  -> Routing to Online Market logic...")
        if filltypeName ~= nil then
            for storage, _ in pairs(g_currentMission.storageSystem.storages) do
                if storage.id == storageId then
                    g_client:getServerConnection():sendEvent(SellBuySiloGlobalMarketEvent.new(mode, filltypeName, level, storage, g_currentMission.playerUserId))
                    break
                end
            end
        elseif attributes ~= nil then
            for storage, _ in pairs(g_currentMission.storageSystem.storages) do
                if storage.id == storageId then
                    -- Requires SellBuyObjectGlobalMarketEvent to exist
                    if SellBuyObjectGlobalMarketEvent ~= nil then
                        g_client:getServerConnection():sendEvent(SellBuyObjectGlobalMarketEvent.new(mode, count, attributes, storage, g_currentMission.playerUserId))
                    end
                    break
                end
            end
        end
    else
        -- OFFLINE MODE LOGIC
        GlobalMarket.debugLog("  -> Routing to Offline Market logic...")
        if filltypeName ~= nil then
            for _, ft in pairs(self.offlineMarketFillTypes) do
                if ft.fillType == filltypeName then
                    local price = ft.price * level
                    local moneyType = MoneyType.SOLD_PRODUCTS

                    if mode == 2 then  -- Assuming 2 is BUY mode
                        price = price * -1
                        moneyType = MoneyType.BOUGHT_MATERIALS
                    else 
                        level = level * -1
                    end

                    for storage, _ in pairs(g_currentMission.storageSystem.storages) do
                        if storage.id == storageId then
                            if not g_currentMission.missionDynamicInfo.isMultiplayer then
                                self:sellBuyOfflineMarket(price, moneyType, g_currentMission.inGameMenu.playerFarmId, level, filltypeName, storage, g_currentMission.playerUserId)
                            else
                                g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(price, g_currentMission.inGameMenu.playerFarmId, level, filltypeName, storage, g_currentMission.playerUserId))
                            end
                            break
                        end
                    end
                    break
                end
            end
        elseif attributes ~= nil then
            GlobalMarket.debugLog("  -> Offline Object trading logic reached (Currently unhandled).")
        end
    end
end

function GlobalMarket:handleUiClosures()
    if self.closeSelectLevelUi == 1 then
        self.closeSelectLevelUi = 2
    elseif self.closeSelectLevelUi == 3 then
        if g_currentMission.globalMarketSelectLevelUi ~= nil then
            g_currentMission.globalMarketSelectLevelUi:close()
        end
        self.closeSelectLevelUi = 0
    end
end

-- =========================================================================
-- Hook functions for UI Updates & XML Registrations
-- =========================================================================

function GlobalMarket.updateUi(streamId, timestamp, connection)
    if g_currentMission.globalMarketUi ~= nil then
        g_currentMission.globalMarketUi:updateContent()
    end
end

Storage.readUpdateStream = Utils.appendedFunction(Storage.readUpdateStream, GlobalMarket.updateUi)
PlaceableObjectStorage.onReadUpdateStream = Utils.appendedFunction(PlaceableObjectStorage.onReadUpdateStream, GlobalMarket.updateUi)

function GlobalMarket.PlaceableObjectStorage_registerXMLPaths(schema, basePath)
    schema:register(XMLValueType.BOOL, basePath .. ".objectStorage#isGmMarket", "ObjectStorage is GlobalMarketPlaceable", false)
end
PlaceableObjectStorage.registerXMLPaths = Utils.appendedFunction(PlaceableObjectStorage.registerXMLPaths, GlobalMarket.PlaceableObjectStorage_registerXMLPaths)

function GlobalMarket.Storage_registerXMLPaths(schema, basePath)
    schema:register(XMLValueType.BOOL, basePath .. "#isGmMarket", "Storage is GlobalMarketPlaceable", false)
end
Storage.registerXMLPaths = Utils.appendedFunction(Storage.registerXMLPaths, GlobalMarket.Storage_registerXMLPaths)

function GlobalMarket:PlaceableObjectStorage_onLoad(savegame)
    local spec = self.spec_objectStorage
    if spec ~= nil and self.xmlFile ~= nil then
        spec.isGmMarket = self.xmlFile:getValue("placeable.objectStorage#isGmMarket", false)
    end
end
PlaceableObjectStorage.onLoad = Utils.appendedFunction(PlaceableObjectStorage.onLoad, GlobalMarket.PlaceableObjectStorage_onLoad)

function GlobalMarket:Storage_load(components, xmlFile, key, i3dMappings)
    if xmlFile ~= nil then
        self.isGmMarket = xmlFile:getValue(key .. "#isGmMarket", false)
    end
end
Storage.load = Utils.appendedFunction(Storage.load, GlobalMarket.Storage_load)
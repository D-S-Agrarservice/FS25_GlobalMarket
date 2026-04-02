--
-- FS25 - GlobalMarket (Storage Module)
--

function GlobalMarket:sellSilo(price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
    self:sellBuySilo(MoneyType.SOLD_PRODUCTS, price, playerFarmId, fillTypeName, fillLevel * -1, storage, playerUserId)
end

function GlobalMarket:buySilo(price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
    self:sellBuySilo(MoneyType.BOUGHT_MATERIALS, price * -1, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
end

function GlobalMarket:sellBuySilo(moneyType, price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
    self:debugLog("Storage: Silo Transaction [Farm: %d, Type: %s, Price: %f, Amount: %f]", playerFarmId, fillTypeName, price, fillLevel)

    if g_server ~= nil then
        g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, moneyType, true, true)

        if not storage.isGmMarket then
            local deliveryCosts = (GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * math.abs(fillLevel)) * EconomyManager.getCostMultiplier() * -1
            g_currentMission:addMoney(deliveryCosts, playerFarmId, MoneyType.OTHER, true, true)
            self:debugLog("  -> Delivery costs applied: %f", deliveryCosts)
        end

        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(fillTypeName).index
        storage:setFillLevel(storage:getFillLevel(fillTypeIndex) + fillLevel, fillTypeIndex, nil)
        storage:raiseDirtyFlags(storage.storageDirtyFlag)
    end

    if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
        self:handleUiClosures()
    end
end

function GlobalMarket:sellObject(price, playerFarmId, count, attributes, storage, playerUserId)
    self:debugLog("Storage: Selling Object(s) [Farm: %d, Count: %d, Price: %f]", playerFarmId, count, price)

    if g_server ~= nil then
        g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, MoneyType.SOLD_PRODUCTS, true, true)

        local attributesParsed = self:parseAttributes(attributes)
        local spec = storage.spec_objectStorage

        if not spec.isGmMarket then
            g_currentMission:addMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * attributesParsed.fillLevel * count) * EconomyManager.getCostMultiplier() * -1, playerFarmId, MoneyType.OTHER, true, true)
        end

        for i=1, count do
            for j = 1, #spec.storedObjects do
                local object = spec.storedObjects[j]
                if object ~= nil then
                    if object.palletAttributes ~= nil then
                        if object.palletAttributes.configFileName == attributesParsed.configFileName
                            and object.palletAttributes.fillLevel == attributesParsed.fillLevel
                            and object.palletAttributes.isBigBag == attributesParsed.isBigBag
                            and object.palletAttributes.fillType == attributesParsed.fillType then

                            g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedPallets", -1)
                            table.remove(spec.storedObjects, j)
                            break
                        end
                    elseif object.baleAttributes ~= nil then
                        if object.baleAttributes.xmlFilename == attributesParsed.xmlFilename
                            and object.baleAttributes.fillLevel == attributesParsed.fillLevel
                            and object.baleAttributes.baleValueScale == attributesParsed.baleValueScale
                            and object.baleAttributes.wrappingState == attributesParsed.wrappingState
                            and object.baleAttributes.fillType == attributesParsed.fillType then

                            g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedBales", -1)
                            table.remove(spec.storedObjects, j)
                            break
                        end
                    end
                end
            end
        end

        spec.numStoredObjects = #spec.storedObjects
        storage:setObjectStorageObjectInfosDirty()
        storage:updateObjectStorageObjectInfos()
        storage:raiseDirtyFlags(spec.dirtyFlag)
    end

    if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
        self:handleUiClosures()
    end
end

function GlobalMarket:buyObject(price, playerFarmId, count, attributes, storage, playerUserId)
    self:debugLog("Storage: Buying Object(s) [Farm: %d, Count: %d, Price: %f]", playerFarmId, count, price)

    if g_server ~= nil then
        g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier() * -1, playerFarmId, MoneyType.BOUGHT_MATERIALS, true, true)
        local attributesParsed = self:parseAttributes(attributes)
        local spec = storage.spec_objectStorage

        if not spec.isGmMarket then
            g_currentMission:addMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * attributesParsed.fillLevel * count) * EconomyManager.getCostMultiplier() * -1, playerFarmId, MoneyType.OTHER, true, true)
        end

        for i=1, count do
            if self:objectIsBale(attributes) then
                local abstractObjectClass = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"]
                local abstractBale = abstractObjectClass.new()
                abstractBale.baleAttributes = attributesParsed
                abstractBale.baleAttributes.farmId = playerFarmId
                g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedBales", 1)
                storage:addAbstactObjectToObjectStorage(abstractBale)
            else
                local abstractObjectClass = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Vehicle"]
                local abstractPallet = abstractObjectClass.new()
                abstractPallet.palletAttributes = attributesParsed
                abstractPallet.palletAttributes.ownerFarmId = playerFarmId
                g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedPallets", 1)
                storage:addAbstactObjectToObjectStorage(abstractPallet)
            end

            storage:setObjectStorageObjectInfosDirty()
            storage:updateObjectStorageObjectInfos()
            storage:raiseDirtyFlags(storage.spec_objectStorage.dirtyFlag)
        end
    end

    if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
        self:handleUiClosures()
    end
end

function GlobalMarket:sellBuyOfflineMarket(price, moneyType, playerFarmId, level, filltypeName, storage, playerUserId)
    self:debugLog("Storage: Offline Market Action [Price: %f, Level: %f, FillType: %s]", price, level, filltypeName)

    if g_server ~= nil then
        for _,ft in pairs(self.offlineMarketFillTypes) do
            if ft.fillType == filltypeName then
                ft.fillLevel = ft.fillLevel + (level * -1)
                ft.price = GlobalMarket.calcOfflinePrice(ft.normalPrice, ft.fillLevel)
            end
        end

        g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, moneyType, true, true)

        if not storage.isGmMarket then
            g_currentMission:addMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * level) * EconomyManager.getCostMultiplier() * -1, playerFarmId, MoneyType.OTHER, true, true)
        end

        local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index
        storage:setFillLevel(storage:getFillLevel(fillTypeIndex) + level, fillTypeIndex, nil)

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
    self:debugLog("UI Action: onSellBuy [Mode: %d, FillType: %s, Level: %f]", mode, filltypeName, level)

    if self:getIsMarketOnline() then
        local freeFile = ""
        local i = 0
        while true do
            local searchPath = string.format("%s/%s.xml", self.writeFolder, i)
            if not fileExists(searchPath) then
                freeFile = searchPath
                break
            end
            i = i + 1
        end

        local xmlFile = XMLFile.create("gmDataSync", freeFile, "gmDataSync")
        local action = "sell"
        if mode == SelectLevel.MODE_MARKET then action = "buy" end
        if mode == SelectLevel.MODE_MARKET_OBJECT then action = "buyObject" end
        if mode == SelectLevel.MODE_STORAGE_OBJECT then action = "sellObject" end

        xmlFile:setString("gmDataSync#action", action)
        xmlFile:setString("gmDataSync#fillType", filltypeName)
        xmlFile:setInt("gmDataSync#fillLevel", level)
        xmlFile:setInt("gmDataSync#storageId", storageId)

        if mode == SelectLevel.MODE_STORAGE_OBJECT then
            xmlFile:setInt("gmDataSync#count", count)
            xmlFile:setString("gmDataSync#attributes", attributes)
        elseif mode == SelectLevel.MODE_MARKET_OBJECT then
            xmlFile:setInt("gmDataSync#count", count)
            xmlFile:setInt("gmDataSync#objectId", objectId)
        end

        xmlFile:save()
        xmlFile:delete()
        self.closeSelectLevelUi = 1
    else
        for _,ft in pairs(self.offlineMarketFillTypes) do
            if ft.fillType == filltypeName then
                local price = ft.price * level
                local moneyType = MoneyType.SOLD_PRODUCTS

                if mode == SelectLevel.MODE_MARKET then
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

function GlobalMarket:parseAttributes(strData)
    local data = {}
    local resTable = {}
    local splitData = GlobalMarket.splitString(strData, ";")

    for _,e in pairs(splitData) do
        local eSplit = GlobalMarket.splitString(e, "=")
        if eSplit[1] ~= nil then
            data[eSplit[1]] = eSplit[2]
        end
    end

    if data['isBigBag'] ~= nil then
        resTable.isBigBag = GlobalMarket.convertToBool(data['isBigBag'])
        resTable.configurations = {}
        resTable.configurations.fillUnit = tonumber(data['configurationsFillUnit'])
        resTable.fillLevel = tonumber(data['fillLevel'])
        resTable.configFileName = data['configFileName']
        resTable.fillType = g_fillTypeManager:getFillTypeByName(data['fillTypeName']).index
    else
        resTable.fillLevel = tonumber(data['fillLevel'])
        resTable.isFermenting = false
        resTable.baleValueScale = tonumber(data['baleValueScale'])
        resTable.xmlFilename = data['xmlFilename']
        resTable.wrappingColor = {tonumber(data['wrappingColor[1]']), tonumber(data['wrappingColor[2]']), tonumber(data['wrappingColor[3]']), tonumber(data['wrappingColor[4]'])}
        resTable.wrappingState = tonumber(data['wrappingState'])
        resTable.isMissionBale = false
        resTable.fillType = g_fillTypeManager:getFillTypeByName(data['fillTypeName']).index
    end

    return resTable
end

function GlobalMarket:objectIsBale(strData)
    return string.find(strData, "baleValueScale") ~= nil
end

-- Engine Appended Functions
function GlobalMarket:updateUi(streamId, timestamp, connection)
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
    spec.isGmMarket = self.xmlFile:getValue("placeable.objectStorage#isGmMarket", false)
end
PlaceableObjectStorage.onLoad = Utils.appendedFunction(PlaceableObjectStorage.onLoad, GlobalMarket.PlaceableObjectStorage_onLoad)

function GlobalMarket:Storage_load(components, xmlFile, key, i3dMappings)
    self.isGmMarket = xmlFile:getValue(key .. "#isGmMarket", false)
end
Storage.load = Utils.appendedFunction(Storage.load, GlobalMarket.Storage_load)
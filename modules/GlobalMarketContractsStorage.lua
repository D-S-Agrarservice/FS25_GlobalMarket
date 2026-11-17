-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractsStorage.lua
-- Physical storage withdrawals/deposits and unified Pickup Inbox for contracts & offers.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketContractsStorage = {}

---Calculates shipping fee for contract/offer/inbox transfers (0 EUR for GM Logistics Terminals)
---@param liters number
---@param isGmMarket boolean|nil
---@return number shippingCost
function GlobalMarket:computeContractShippingCost(liters, isGmMarket)
    if isGmMarket == true or liters == nil or liters <= 0 then
        return 0
    end
    local costMult = (EconomyManager ~= nil and EconomyManager.getCostMultiplier ~= nil)
        and EconomyManager.getCostMultiplier() or 1.0
    local baseFee = GlobalMarket.DELIVER_COST or 0
    local literFee = GlobalMarket.DELIVER_COST_PERLITER or 0
    return (baseFee + (literFee * liters)) * costMult
end

---Decodes a format payload (bale index or network pallet path) into a local XML filename
---@param rawInput number|string|nil
---@return string|nil xmlFilename
---@return boolean isTargetBale
function GlobalMarket:resolveObjectStorageXmlFilename(rawInput)
    if type(rawInput) == "number" and rawInput > 0 then
        if g_baleManager ~= nil and g_baleManager.getBaleXMLFilenameByIndex ~= nil then
            local baleXml = g_baleManager:getBaleXMLFilenameByIndex(rawInput)
            if baleXml ~= nil then
                return baleXml, true
            end
        end
        return nil, false
    end

    if type(rawInput) == "string" and rawInput ~= "" then
        local decoded = rawInput
        if NetworkUtil ~= nil and NetworkUtil.convertFromNetworkFilename ~= nil then
            decoded = NetworkUtil.convertFromNetworkFilename(rawInput) or rawInput
        end
        local isTargetBale = false
        if g_baleManager ~= nil and g_baleManager.getBaleTypeIndexByXMLFilename ~= nil then
            isTargetBale = (g_baleManager:getBaleTypeIndexByXMLFilename(decoded) ~= nil)
        end
        return decoded, isTargetBale
    end

    return nil, false
end

---Checks if a stored object XML matches the requested format XML (allowing generic engine pallets)
---@param objXml string|nil
---@param formatXml string|nil
---@return boolean
function GlobalMarket:matchesObjectStorageFormat(objXml, formatXml)
    if formatXml == nil or objXml == nil then
        return true
    end
    local cleanObj = string.lower(string.match(objXml, "([^/\\]+)$") or objXml)
    local cleanReq = string.lower(string.match(formatXml, "([^/\\]+)$") or formatXml)
    if cleanObj == cleanReq then
        return true
    end
    if string.find(cleanObj, "fillablepallet", 1, true)
        or string.find(cleanReq, "fillablepallet", 1, true)
        or string.find(cleanObj, "vegetablespallet", 1, true)
        or string.find(cleanReq, "vegetablespallet", 1, true) then
        return true
    end
    return false
end

---Extracts metadata from one ObjectStorage objectInfo entry
---@param objectInfo table
---@return number|nil objFillType
---@return number objLevel
---@return string|nil objXml
---@return number objFarmId
---@return boolean isFermenting
---@return boolean isBaleType
function GlobalMarket:inspectObjectInfoEntry(objectInfo)
    if objectInfo == nil or objectInfo.objects == nil or #objectInfo.objects == 0 then
        return nil, 0, nil, FarmManager.SPECTATOR_FARM_ID, false, false
    end

    local sampleObj = objectInfo.objects[1]
    if sampleObj == nil then
        return nil, 0, nil, FarmManager.SPECTATOR_FARM_ID, false, false
    end

    local objFillType, objLevel, objXml = nil, 0, nil
    local isFermenting = false
    local objFarmId = FarmManager.SPECTATOR_FARM_ID
    local isBaleType = false

    if sampleObj.REFERENCE_CLASS_NAME == "Bale" or sampleObj.REFERENCE_CLASS_NAME == "PackedBale" then
        isBaleType = true
        objFillType = (sampleObj.baleObject ~= nil)
            and sampleObj.baleObject:getFillType()
            or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.fillType)
        objLevel = (sampleObj.baleObject ~= nil)
            and sampleObj.baleObject:getFillLevel()
            or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.fillLevel) or 0
        objXml = (sampleObj.baleObject ~= nil)
            and sampleObj.baleObject.xmlFilename
            or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.xmlFilename)
        objFarmId = (sampleObj.baleObject ~= nil and sampleObj.baleObject.ownerFarmId)
            or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.farmId)
            or FarmManager.SPECTATOR_FARM_ID
        if (sampleObj.baleObject ~= nil and sampleObj.baleObject.isFermenting)
            or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.isFermenting) then
            isFermenting = true
        end
    elseif sampleObj.REFERENCE_CLASS_NAME == "Vehicle" then
        objFillType = sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.fillType
        objLevel = (sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.fillLevel) or 0
        objXml = sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.configFileName
        objFarmId = (sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.ownerFarmId)
            or FarmManager.SPECTATOR_FARM_ID
    end

    return objFillType, objLevel, objXml, objFarmId, isFermenting, isBaleType
end

---Withdraws bulk or object goods from a farm's accessible storage and bills shipping if non-terminal
---@return boolean success
---@return number actualLiters
---@return number shippingCost
---@return boolean wasBale
---@return boolean wasPallet
function GlobalMarket:withdrawGoodsFromFarmStorage(
    farmId, fillTypeName, requestedLiters, targetStorage, isObjectStorage,
    formatXml, allowSingleOverfillObject, requireShippingLiquidity
)
    if g_server == nil or targetStorage == nil or requestedLiters == nil or requestedLiters <= 0.01 then
        return false, 0, 0, false, false
    end
    if farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false, 0, 0, false, false
    end

    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(fillTypeName)
    if fillTypeDesc == nil or (GlobalMarketAPI ~= nil and not GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc)) then
        return false, 0, 0, false, false
    end
    local fillTypeIndex = fillTypeDesc.index

    if not isObjectStorage then
        local ownerPlaceable, storageName, specType, storageIndex = self:resolveBulkStorageOwner(targetStorage)
        local isAccessible, isGmMarket = self:getIsBulkStorageAccessible(targetStorage, ownerPlaceable, farmId)
        if not isAccessible then
            return false, 0, 0, false, false
        end

        local husbandryPlaceable = (specType == "husbandry") and ownerPlaceable
            or (self.getConnectedHusbandryPlaceable ~= nil and self:getConnectedHusbandryPlaceable(targetStorage) or nil)
        local validationEntry = {
            storage = targetStorage,
            ownerPlaceable = ownerPlaceable,
            husbandryPlaceable = husbandryPlaceable,
            storageName = storageName,
            specType = specType,
            storageIndex = storageIndex,
            isGmMarket = isGmMarket
        }
        if not self:getIsBulkFillTypeAllowedForStorage(validationEntry, fillTypeIndex, true) then
            return false, 0, 0, false, false
        end

        local physicalLevel = targetStorage:getFillLevel(fillTypeIndex) or 0
        local available = physicalLevel
        if isGmMarket then
            available = (targetStorage.gmFarmFillLevels ~= nil and targetStorage.gmFarmFillLevels[farmId] ~= nil)
                and (targetStorage.gmFarmFillLevels[farmId][fillTypeIndex] or 0) or 0
        end

        local actualLiters = math.min(requestedLiters, available)
        if actualLiters <= 0.01 then
            return false, 0, 0, false, false
        end

        local shippingCost = self:computeContractShippingCost(actualLiters, isGmMarket)
        if requireShippingLiquidity and shippingCost > 0 then
            local farm = g_farmManager:getFarmById(farmId)
            if farm == nil or farm.money < shippingCost then
                return false, 0, 0, false, false
            end
        end

        if shippingCost > 0 then
            g_currentMission:addMoney(shippingCost * -1, farmId, MoneyType.GM_FEE, true, true)
        end
        if isGmMarket then
            targetStorage.gmTempFarmId = farmId
        end
        targetStorage:setFillLevel(math.max(0, physicalLevel - actualLiters), fillTypeIndex, nil)
        if isGmMarket then
            targetStorage.gmTempFarmId = nil
        end

        return true, actualLiters, shippingCost, false, false
    end

    -- ObjectStorage withdrawal (two-pass so liquidity validation never leaves partial removals)
    local isGmMarket = (targetStorage.isGmMarket == true)
    if not isGmMarket and targetStorage:getOwnerFarmId() ~= farmId then
        return false, 0, 0, false, false
    end

    local spec = targetStorage.spec_objectStorage
    if spec == nil or spec.objectInfos == nil or spec.storedObjects == nil then
        return false, 0, 0, false, false
    end

    local xmlFilename, _ = self:resolveObjectStorageXmlFilename(formatXml)
    local removalPlan = {}
    local countedLiters = 0
    local wasBale = false
    local wasPallet = false

    for infoIndex = #spec.objectInfos, 1, -1 do
        if countedLiters >= requestedLiters then
            break
        end
        local objectInfo = spec.objectInfos[infoIndex]
        local objFillType, objLevel, objXml, objFarmId, isFermenting, isBaleType = self:inspectObjectInfoEntry(objectInfo)

        if objFillType == fillTypeIndex and not isFermenting and objFarmId == farmId and objLevel > 0 then
            if self:matchesObjectStorageFormat(objXml, xmlFilename) then
                local remaining = requestedLiters - countedLiters
                local objectsToTake = math.floor((remaining + 0.01) / objLevel)
                if objectsToTake == 0 and allowSingleOverfillObject and countedLiters == 0 and remaining > 0.01 then
                    objectsToTake = 1
                end
                objectsToTake = math.min(objectsToTake, objectInfo.numObjects or #objectInfo.objects)

                if objectsToTake > 0 then
                    countedLiters = countedLiters + (objectsToTake * objLevel)
                    if isBaleType then
                        wasBale = true
                    else
                        wasPallet = true
                    end
                    table.insert(removalPlan, {
                        infoIndex = infoIndex,
                        count = objectsToTake,
                        isBale = isBaleType
                    })
                end
            end
        end
    end

    if countedLiters <= 0.01 or #removalPlan == 0 then
        return false, 0, 0, false, false
    end

    local shippingCost = self:computeContractShippingCost(countedLiters, isGmMarket)
    if requireShippingLiquidity and shippingCost > 0 then
        local farm = g_farmManager:getFarmById(farmId)
        if farm == nil or farm.money < shippingCost then
            return false, 0, 0, false, false
        end
    end

    local removedBales = 0
    local removedPallets = 0
    for _, step in ipairs(removalPlan) do
        local objectInfo = spec.objectInfos[step.infoIndex]
        if objectInfo ~= nil and objectInfo.objects ~= nil then
            for _ = 1, step.count do
                local objToRemove = objectInfo.objects[1]
                if objToRemove ~= nil then
                    for k = 1, #spec.storedObjects do
                        if spec.storedObjects[k] == objToRemove then
                            table.remove(spec.storedObjects, k)
                            break
                        end
                    end
                    table.remove(objectInfo.objects, 1)
                end
            end
            objectInfo.numObjects = #objectInfo.objects
            if objectInfo.numObjects == 0 then
                table.remove(spec.objectInfos, step.infoIndex)
            end
            if step.isBale then
                removedBales = removedBales + step.count
            else
                removedPallets = removedPallets + step.count
            end
        end
    end

    if removedBales > 0 then
        g_farmManager:updateFarmStats(farmId, "storedBales", -removedBales)
    end
    if removedPallets > 0 then
        g_farmManager:updateFarmStats(farmId, "storedPallets", -removedPallets)
    end
    spec.numStoredObjects = #spec.storedObjects
    targetStorage:setObjectStorageObjectInfosDirty()

    if shippingCost > 0 then
        g_currentMission:addMoney(shippingCost * -1, farmId, MoneyType.GM_FEE, true, true)
    end

    return true, countedLiters, shippingCost, wasBale, wasPallet
end

---Deposits bulk or object goods into a farm's accessible storage, enforcing liquidity upfront
---@return boolean success
---@return number actualLiters
---@return number shippingCost
---@return boolean wasBale
---@return boolean wasPallet
function GlobalMarket:depositGoodsToFarmStorage(
    farmId, fillTypeName, requestedLiters, targetStorage, isObjectStorage,
    formatXml, capacityPerObject, unitCostPerLiter, requireFullAmount
)
    if g_server == nil or targetStorage == nil or requestedLiters == nil or requestedLiters <= 0.01 then
        return false, 0, 0, false, false
    end
    if farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false, 0, 0, false, false
    end

    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(fillTypeName)
    if fillTypeDesc == nil or (GlobalMarketAPI ~= nil and not GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc)) then
        return false, 0, 0, false, false
    end
    local fillTypeIndex = fillTypeDesc.index

    if not isObjectStorage then
        local ownerPlaceable, storageName, specType, storageIndex = self:resolveBulkStorageOwner(targetStorage)
        local isAccessible, isGmMarket = self:getIsBulkStorageAccessible(targetStorage, ownerPlaceable, farmId)
        if not isAccessible then
            return false, 0, 0, false, false
        end

        local husbandryPlaceable = (specType == "husbandry") and ownerPlaceable
            or (self.getConnectedHusbandryPlaceable ~= nil and self:getConnectedHusbandryPlaceable(targetStorage) or nil)
        local validationEntry = {
            storage = targetStorage,
            ownerPlaceable = ownerPlaceable,
            husbandryPlaceable = husbandryPlaceable,
            storageName = storageName,
            specType = specType,
            storageIndex = storageIndex,
            isGmMarket = isGmMarket
        }
        if not self:getIsBulkFillTypeAllowedForStorage(validationEntry, fillTypeIndex, false) then
            return false, 0, 0, false, false
        end

        local freeCap = targetStorage:getFreeCapacity(fillTypeIndex) or 0
        local actualLiters = math.min(requestedLiters, freeCap)
        if actualLiters <= 0.01 then
            return false, 0, 0, false, false
        end
        if requireFullAmount and actualLiters < (requestedLiters - 0.5) then
            return false, 0, 0, false, false
        end

        local shippingCost = self:computeContractShippingCost(actualLiters, isGmMarket)
        local extraCash = (unitCostPerLiter or 0) * actualLiters
        local farm = g_farmManager:getFarmById(farmId)
        if farm == nil or farm.money < (shippingCost + extraCash) then
            return false, 0, 0, false, false
        end

        if shippingCost > 0 then
            g_currentMission:addMoney(shippingCost * -1, farmId, MoneyType.GM_FEE, true, true)
        end
        local currentPhysical = targetStorage:getFillLevel(fillTypeIndex) or 0
        if isGmMarket then
            targetStorage.gmTempFarmId = farmId
        end
        targetStorage:setFillLevel(currentPhysical + actualLiters, fillTypeIndex, nil)
        if isGmMarket then
            targetStorage.gmTempFarmId = nil
        end

        return true, actualLiters, shippingCost, false, false
    end

    -- ObjectStorage deposit
    local isGmMarket = (targetStorage.isGmMarket == true)
    if not isGmMarket and targetStorage:getOwnerFarmId() ~= farmId then
        return false, 0, 0, false, false
    end

    local spec = targetStorage.spec_objectStorage
    if spec == nil then
        return false, 0, 0, false, false
    end

    local xmlFilename, isTargetBale = self:resolveObjectStorageXmlFilename(formatXml)
    local actualCapacity = capacityPerObject or 5000
    if xmlFilename == nil or actualCapacity <= 0 then
        return false, 0, 0, false, false
    end

    local numObjects = math.floor((requestedLiters + 0.01) / actualCapacity)
    local freeSlots = math.max(0, (spec.capacity or 250) - (spec.numStoredObjects or 0))
    local maxPerTx = (GlobalMarketDialog ~= nil and GlobalMarketDialog.MAX_OBJECTS_PER_TX) or 50
    numObjects = math.min(numObjects, freeSlots, maxPerTx)
    if numObjects <= 0 then
        return false, 0, 0, false, false
    end

    local actualLiters = numObjects * actualCapacity
    if requireFullAmount and actualLiters < (requestedLiters - 0.5) then
        return false, 0, 0, false, false
    end

    local shippingCost = self:computeContractShippingCost(actualLiters, isGmMarket)
    local extraCash = (unitCostPerLiter or 0) * actualLiters
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.money < (shippingCost + extraCash) then
        return false, 0, 0, false, false
    end

    local className = isTargetBale and "Bale" or "Vehicle"
    local abstractClass = PlaceableObjectStorage ~= nil
        and PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME ~= nil
        and PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME[className] or nil
    if abstractClass == nil then
        return false, 0, 0, false, false
    end

    if shippingCost > 0 then
        g_currentMission:addMoney(shippingCost * -1, farmId, MoneyType.GM_FEE, true, true)
    end

    for _ = 1, numObjects do
        local abstractObject = abstractClass.new()
        if isTargetBale then
            abstractObject.baleAttributes = {
                xmlFilename = xmlFilename,
                fillLevel = actualCapacity,
                fillType = fillTypeIndex,
                variationIndex = 1,
                farmId = farmId,
                isMissionBale = false,
                wrappingState = 0,
                wrappingColor = {1, 1, 1},
                isFermenting = false,
                fermentationTime = 0
            }
        else
            local lowerXml = string.lower(xmlFilename)
            local isBigBag = (string.find(lowerXml, "bigbag", 1, true) ~= nil
                and string.find(lowerXml, "bigbagpallet", 1, true) == nil)
            abstractObject.palletAttributes = {
                configFileName = xmlFilename,
                isBigBag = isBigBag,
                ownerFarmId = farmId,
                fillType = fillTypeIndex,
                fillLevel = actualCapacity,
                configurations = { fillUnit = 1 }
            }
        end

        if abstractClass.getSize ~= nil then
            abstractClass.getSize(xmlFilename)
        end
        if targetStorage.addAbstactObjectToObjectStorage ~= nil then
            targetStorage:addAbstactObjectToObjectStorage(abstractObject)
        end
    end

    if isTargetBale then
        g_farmManager:updateFarmStats(farmId, "storedBales", numObjects)
    else
        g_farmManager:updateFarmStats(farmId, "storedPallets", numObjects)
    end
    targetStorage:setObjectStorageObjectInfosDirty()

    return true, actualLiters, shippingCost, isTargetBale, not isTargetBale
end

---Initializes unified Pickup Inbox state
function GlobalMarket:initPickupInbox()
    self.pickupInbox = {}
    self.nextInboxId = 1
end

---Adds or merges goods into a farm's Pickup Inbox with a weighted 2-month grace timer
---@param farmId number
---@param fillTypeName string
---@param liters number
---@param sourceType string
---@param sourceLabel string|nil
function GlobalMarket:addPickupInboxItem(farmId, fillTypeName, liters, sourceType, sourceLabel)
    if farmId == nil or farmId <= 0 or fillTypeName == nil or liters == nil or liters <= 0.01 then
        return
    end
    self.pickupInbox = self.pickupInbox or {}
    self.nextInboxId = self.nextInboxId or 1

    local cleanSource = sourceType or "EXPIRED"
    local graceMonths = (GlobalMarketContracts ~= nil and GlobalMarketContracts.INBOX_GRACE_MONTHS) or 2.0

    for _, entry in ipairs(self.pickupInbox) do
        if entry.farmId == farmId and entry.fillType == fillTypeName and entry.sourceType == cleanSource then
            local oldLiters = entry.liters or 0
            local newTotal = oldLiters + liters
            entry.monthsRemaining = ((oldLiters * (entry.monthsRemaining or graceMonths)) + (liters * graceMonths))
                / math.max(1, newTotal)
            entry.liters = newTotal
            if sourceLabel ~= nil and sourceLabel ~= "" then
                entry.sourceLabel = sourceLabel
            end
            return
        end
    end

    local id = self.nextInboxId
    self.nextInboxId = id + 1
    table.insert(self.pickupInbox, {
        id = id,
        farmId = farmId,
        fillType = fillTypeName,
        liters = liters,
        sourceType = cleanSource,
        sourceLabel = sourceLabel or "",
        monthsRemaining = graceMonths
    })
end

---Claims goods from a farm's Pickup Inbox into an owned silo, object storage, or GM Terminal
---@return boolean success
---@return number actualLiters
function GlobalMarket:claimPickupInboxItem(
    farmId, inboxId, requestedLiters, targetStorage, isObjectStorage, formatXml, capacityPerObject
)
    if g_server == nil or self.pickupInbox == nil then
        return false, 0
    end

    local targetIdx, entry = nil, nil
    for i, item in ipairs(self.pickupInbox) do
        if item.id == inboxId then
            targetIdx = i
            entry = item
            break
        end
    end
    if entry == nil or entry.farmId ~= farmId or (entry.liters or 0) <= 0.01 then
        return false, 0
    end

    local reqLiters = math.min(requestedLiters or entry.liters, entry.liters)
    local ok, actualLiters = self:depositGoodsToFarmStorage(
        farmId, entry.fillType, reqLiters, targetStorage, isObjectStorage, formatXml, capacityPerObject, 0, false
    )
    if not ok or actualLiters <= 0.01 then
        return false, 0
    end

    entry.liters = math.max(0, entry.liters - actualLiters)
    if entry.liters <= 0.5 then
        table.remove(self.pickupInbox, targetIdx)
    end
    if self.broadcastContractsState ~= nil then
        self:broadcastContractsState()
    end
    return true, actualLiters
end

---Decrements Pickup Inbox timers and auto-liquidates overdue items at -15% market price
---@param monthDelta number
---@return boolean changed
function GlobalMarket:tickPickupInbox(monthDelta)
    if g_server == nil or self.pickupInbox == nil or monthDelta <= 0 then
        return false
    end

    local anyChanged = false
    local liqFactor = (GlobalMarketContracts ~= nil and GlobalMarketContracts.INBOX_LIQUIDATION_FACTOR) or 0.85

    for i = #self.pickupInbox, 1, -1 do
        local entry = self.pickupInbox[i]
        entry.monthsRemaining = (entry.monthsRemaining or 2.0) - monthDelta
        if entry.monthsRemaining <= 0 then
            local refPrice = (self.getContractReferencePricePer1000 ~= nil)
                and self:getContractReferencePricePer1000(entry.fillType) or 500
            local payout = math.floor(((entry.liters / 1000) * refPrice * liqFactor) + 0.5)
            local txMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_SELL
            if payout > 0 and entry.farmId ~= nil and entry.farmId > 0 then
                g_currentMission:addMoney(payout, entry.farmId, txMoneyType, true, true)
            end

            if self.offlineMarketFillTypes ~= nil then
                local cap = GlobalMarket.MARKET_CAPACITY or 2000000
                for _, ft in pairs(self.offlineMarketFillTypes) do
                    if ft.fillType == entry.fillType then
                        ft.fillLevel = math.clamp((ft.fillLevel or 0) + entry.liters, 0, cap)
                        break
                    end
                end
            end

            if self.debugManager ~= nil then
                self.debugManager:info(
                    "PickupInbox: Auto-liquidated %.0f L of %s for Farm %d (%d EUR at -15%%).",
                    entry.liters, tostring(entry.fillType), entry.farmId or 0, payout
                )
            end
            table.remove(self.pickupInbox, i)
            anyChanged = true
        end
    end

    return anyChanged
end

---Collects buyable bale and pallet/BigBag/IBC formats compatible with a target ObjectStorage
function GlobalMarketContractsStorage.collectBuyableFormats(fillTypeName, selectedSilo)
    local formats = {}
    local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
    if fillType == nil or selectedSilo == nil or not selectedSilo.isObjectStorage then
        return formats
    end

    if selectedSilo.supportsBales and fillType.isBaleType and g_baleManager ~= nil and g_baleManager.bales ~= nil then
        local seenMapSizes, seenSizeCap, baleFormats, titleCounts = {}, {}, {}, {}
        local mapCustomEnv = (g_currentMission ~= nil and g_currentMission.missionInfo ~= nil)
            and g_currentMission.missionInfo.customEnvironment or nil
        local mapBaseDir = g_currentMission ~= nil and g_currentMission.baseDirectory or nil

        for _, bale in ipairs(g_baleManager.bales) do
            if bale.isAvailable and bale.fillTypes ~= nil then
                for _, ftData in ipairs(bale.fillTypes) do
                    if ftData.fillTypeIndex == fillType.index then
                        local isRound, width, _, length, diameter = g_baleManager:getBaleInfoByXMLFilename(bale.xmlFilename)
                        local sizeKey = isRound
                            and string.format("ROUND_%.2f_%.2f", diameter or 0, width or 0)
                            or string.format("SQUARE_%.2f_%.2f", length or 0, width or 0)
                        local capInt = math.floor((ftData.capacity or 0) + 0.5)
                        local sizeCapKey = string.format("%s_%d", sizeKey, capInt)
                        local isMapOrBase = (bale.customEnvironment == nil)
                            or (mapCustomEnv ~= nil and bale.customEnvironment == mapCustomEnv)
                            or (mapBaseDir ~= nil and mapBaseDir ~= "" and bale.baseDirectory == mapBaseDir)

                        local shouldAdd = false
                        if isMapOrBase then
                            if not seenMapSizes[sizeKey] and not seenSizeCap[sizeCapKey] then
                                seenMapSizes[sizeKey] = true
                                seenSizeCap[sizeCapKey] = true
                                shouldAdd = true
                            end
                        elseif not seenSizeCap[sizeCapKey] then
                            seenSizeCap[sizeCapKey] = true
                            shouldAdd = true
                        end

                        if shouldAdd then
                            local key = isRound and "ui_gm_format_roundbale" or "ui_gm_format_squarebale"
                            local title = string.format("%s (%.2fm)", g_i18n:getText(key), isRound and (diameter or width or 1.25) or (length or 2.40))
                            titleCounts[title] = (titleCounts[title] or 0) + 1
                            table.insert(baleFormats, {
                                title = title,
                                xml = bale.xmlFilename,
                                capacity = ftData.capacity,
                                unitKey = "ui_gm_unit_bale"
                            })
                        end
                    end
                end
            end
        end

        for _, bf in ipairs(baleFormats) do
            if (titleCounts[bf.title] or 0) > 1 then
                bf.title = string.format("%s - %s L", bf.title, g_i18n:formatVolume(bf.capacity or 0, 0))
            end
            table.insert(formats, bf)
        end
    end

    if selectedSilo.supportsPallets and GlobalMarketStoreCache ~= nil then
        for _, f in ipairs(GlobalMarketStoreCache.getFormatsForFillType(fillTypeName) or {}) do
            table.insert(formats, f)
        end
    end

    return formats
end

---Collects non-fermenting owned stacks from an ObjectStorage matching fillTypeName
function GlobalMarketContractsStorage.collectOwnedFormats(fillTypeName, selectedSilo, farmId)
    local formats = {}
    local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
    if fillType == nil or selectedSilo == nil or not selectedSilo.isObjectStorage or selectedSilo.storage == nil then
        return formats
    end

    local spec = selectedSilo.storage.spec_objectStorage
    if spec == nil or spec.objectInfos == nil then
        return formats
    end

    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local tracker = {}
    for _, objectInfo in ipairs(spec.objectInfos) do
        local objFt, objCap, objXml, objFarm, isFerm, isBale = nil, 0, nil, FarmManager.SPECTATOR_FARM_ID, false, false
        if gm ~= nil and gm.inspectObjectInfoEntry ~= nil then
            objFt, objCap, objXml, objFarm, isFerm, isBale = gm:inspectObjectInfoEntry(objectInfo)
        end
        if objFt == fillType.index and objXml ~= nil and not isFerm and objFarm == farmId and objCap > 0 then
            if tracker[objXml] == nil then
                local title = g_i18n:getText("ui_gm_unit_piece")
                local unitKey = isBale and "ui_gm_unit_bale" or "ui_gm_unit_pallet"
                if isBale and g_baleManager ~= nil then
                    local isRound, width, _, length, diameter = g_baleManager:getBaleInfoByXMLFilename(objXml)
                    local key = isRound and "ui_gm_format_roundbale" or "ui_gm_format_squarebale"
                    title = string.format("%s (%.2fm)", g_i18n:getText(key), isRound and (diameter or width or 1.25) or (length or 2.40))
                else
                    local storeItem = g_storeManager ~= nil and g_storeManager:getItemByXMLFilename(objXml) or nil
                    title = (storeItem ~= nil and storeItem.name) or g_i18n:getText("ui_gm_format_pallet")
                end
                tracker[objXml] = {
                    title = title,
                    xml = objXml,
                    capacity = objCap,
                    unitKey = unitKey,
                    actualCount = objectInfo.numObjects or #objectInfo.objects
                }
            else
                tracker[objXml].actualCount = tracker[objXml].actualCount + (objectInfo.numObjects or #objectInfo.objects)
            end
        end
    end

    for _, f in pairs(tracker) do
        table.insert(formats, f)
    end
    return formats
end

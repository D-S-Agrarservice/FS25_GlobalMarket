--
-- FS25 - GlobalMarketDialog
-- Description: Interactive popup dialog handling user input for transactions.
-- Manages bulk/liquid inputs as well as dynamic format selection (Bales/Pallets).
--

GlobalMarketDialog = {}
local GlobalMarketDialog_mt = Class(GlobalMarketDialog, YesNoDialog)

-- SAFETY CAP: Maximum physical objects per transaction to prevent engine crashes
GlobalMarketDialog.MAX_OBJECTS_PER_TX = 50

function GlobalMarketDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketDialog_mt)

    self.actionType = "SELL"
    self.fillTypeTitle = ""
    self.fillTypeName = ""
    self.pricePer1000 = 0
    self.maxAmount = 0
    self.currentAmount = 0
    self.selectedStorageIndex = 1
    self.storageLocations = {}

    return self
end

-- Initializes the dialog with data from the main UI and triggers the display
function GlobalMarketDialog:show(target, callbackFunc, actionType, fillTypeTitle, fillTypeName, price, silos)
    self.target = target
    self.callbackFunc = callbackFunc
    self.actionType = actionType
    self.fillTypeTitle = fillTypeTitle
    self.fillTypeName = fillTypeName
    self.pricePer1000 = price
    self.currentAmount = 0
    self.storageLocations = silos or {}

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:trace("Dialog opened: %s %s (Price: %.2f). Available Storages: %d", actionType, tostring(fillTypeName), price, #self.storageLocations)
    end

    -- We completely rely on the custom GM dialog to handle both bulk
    -- and object storages seamlessly via liter/piece inputs.
    g_gui:showDialog("GlobalMarketDialog")
end

-- Triggers the native FS25 ObjectStorageDialog for Bales/Pallets (Fallback for generic interactions)
function GlobalMarketDialog:showNativeObjectStorageDialog(storage)
    local p = g_currentMission.placeableSystem.placeables[storage.id]
    if p ~= nil and p.spec_objectStorage ~= nil then
        local spec = p.spec_objectStorage

        -- Filter objectInfos for the requested fillType
        local filteredInfos = {}
        for _, info in ipairs(spec.objectInfos) do
            local obj = info.objects[1]
            local fillType = nil
            if obj.baleObject ~= nil then fillType = obj.baleObject:getFillType()
            elseif obj.baleAttributes ~= nil then fillType = obj.baleAttributes.fillType
            elseif obj.palletAttributes ~= nil then fillType = obj.palletAttributes.fillType end

            if fillType == g_fillTypeManager:getFillTypeByName(self.fillTypeName).index then
                table.insert(filteredInfos, info)
            end
        end

        if #filteredInfos > 0 then
            ObjectStorageDialog.show(self.onNativeObjectStorageCallback, self, self.fillTypeTitle, filteredInfos)
        end
    end
end

-- Callback receiver for the native Giants Dialog
function GlobalMarketDialog:onNativeObjectStorageCallback(selectedInfoIndex, amount)
    if selectedInfoIndex ~= nil and amount ~= nil and amount > 0 then
        -- Native dialog returns amount of objects. Total liters must be calculated by the backend.
        if self.callbackFunc ~= nil then
            self.callbackFunc(self.target, amount, self.storageLocations[1].id, self.actionType, self.fillTypeName)
        end
    end
end

-- Native UI hook triggered right before the dialog becomes visible
function GlobalMarketDialog:onOpen()
    GlobalMarketDialog:superClass().onOpen(self)

    -- Variables for format logic
    self.currentCountFactor = 1
    self.currentFormatXml = nil
    self.availableFormats = {}

    -- Reset the sticky input field immediately
    if self.amountInput ~= nil then
        self.amountInput:setText("0")
    end

    local titlePrefix = self.actionType == "SELL" and (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderStorage") .. ": ") or (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderMarket") .. ": ")
    self.dialogTitleElement:setText(titlePrefix .. tostring(self.fillTypeTitle))

    local actionText = self.actionType == "SELL" and g_i18n:getText("ui_btn_sell") or g_i18n:getText("ui_btn_buy")
    if self.yesButton ~= nil then
        self.yesButton:setText(actionText)
    end

    local storageNames = {}
    for _, loc in ipairs(self.storageLocations) do
        table.insert(storageNames, loc.title)
    end

    self.storageSelectionElement:setTexts(storageNames)
    self.storageSelectionElement:setState(1, true)
    self:onClickStorage(1)

    FocusManager:setFocus(self.amountInput)
end

-- Triggered when the user selects a different storage from the dropdown
function GlobalMarketDialog:onClickStorage(state)
    self.selectedStorageIndex = state
    local selectedSilo = self.storageLocations[state]

    -- Hide the format selection by default and reset variables
    if self.formatSelectionElement ~= nil then
        self.formatSelectionElement:setVisible(false)
    end
    self.currentCountFactor = 1
    self.currentFormatXml = nil
    self.availableFormats = {}

    if selectedSilo ~= nil then
        -- 1. Calculate maxAmount for the storage as usual
        if self.actionType == "SELL" then
            self.maxAmount = selectedSilo.level
        else
            local marketStock = 0
            local gm = g_currentMission.globalMarket
            local marketData = gm:getIsMarketOnline() and gm.fillTypes or gm.offlineMarketFillTypes

            if marketData ~= nil then
                for _, data in pairs(marketData) do
                    if data.fillType == self.fillTypeName then
                        marketStock = data.fillLevel or 0
                        break
                    end
                end
            end
            self.maxAmount = math.min(selectedSilo.freeCapacity, marketStock)
        end

        -- 2. Handle format selection for ObjectStorages (Bales / Pallets)
        if selectedSilo.isObjectStorage then
            local fillType = g_fillTypeManager:getFillTypeByName(self.fillTypeName)

            if fillType ~= nil then
                if self.actionType == "BUY" then
                    -- BUYING: Scan engine for all possible supported formats
                    if selectedSilo.supportsBales and fillType.isBaleType and g_baleManager ~= nil then
                        for _, bale in ipairs(g_baleManager.bales) do
                            if bale.isAvailable then
                                for _, ftData in ipairs(bale.fillTypes) do
                                    if ftData.fillTypeIndex == fillType.index then
                                        local isRound, width, height, length, diameter = g_baleManager:getBaleInfoByXMLFilename(bale.xmlFilename)
                                        local title = isRound and string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_roundbale"), diameter or width or 1.25) or string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_squarebale"), length or 2.40)
                                        table.insert(self.availableFormats, {title = title, xml = bale.xmlFilename, capacity = ftData.capacity, unitKey = "ui_gm_unit_bale"})
                                    end
                                end
                            end
                        end
                    -- GM STORE CACHE BRIDGE:
                    -- Strictly fetches dynamically parsed formats (Pallets, BigBags, IBCs)
                    -- from our RAM dictionary. Fallback to native engine logic is removed.
                    elseif selectedSilo.supportsPallets then
                        if GlobalMarketStoreCache ~= nil then
                            local cachedFormats = GlobalMarketStoreCache.getFormatsForFillType(self.fillTypeName)
                            for _, formatData in ipairs(cachedFormats) do
                                table.insert(self.availableFormats, formatData)
                            end
                        end
                    end

                elseif self.actionType == "SELL" then
                    -- SELLING: Scan the actual storage for formats and count physical objects
                    local spec = selectedSilo.storage.spec_objectStorage
                    if spec ~= nil and spec.objectInfos ~= nil then
                        local formatTracker = {}

                        for _, objectInfo in ipairs(spec.objectInfos) do
                            local obj = objectInfo.objects[1]
                            local objFillType, objXml, objCapacity = nil, nil, 0
                            local isFermenting = false
                            local objFarmId = FarmManager.SPECTATOR_FARM_ID

                            if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                                objFillType = (obj.baleObject ~= nil) and obj.baleObject:getFillType() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                                objCapacity = (obj.baleObject ~= nil) and obj.baleObject:getFillLevel() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillLevel)
                                objXml = (obj.baleObject ~= nil) and obj.baleObject.xmlFilename or (obj.baleAttributes ~= nil and obj.baleAttributes.xmlFilename)
                                objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID

                                if obj.baleObject ~= nil and obj.baleObject.isFermenting then isFermenting = true end
                                if obj.baleAttributes ~= nil and obj.baleAttributes.isFermenting then isFermenting = true end
                            elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                                objFillType = obj.palletAttributes ~= nil and obj.palletAttributes.fillType
                                objCapacity = obj.palletAttributes ~= nil and obj.palletAttributes.fillLevel
                                objXml = obj.palletAttributes ~= nil and obj.palletAttributes.configFileName
                                objFarmId = obj.palletAttributes ~= nil and obj.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
                            end

                            local playerFarmId = g_currentMission:getFarmId()

                            -- Only count non-fermenting objects of the selected fillType that belong to the player
                            if objFillType == fillType.index and objXml ~= nil and not isFermenting and objFarmId == playerFarmId then
                                if formatTracker[objXml] == nil then
                                    local title = g_i18n:getText("ui_gm_unit_piece")
                                    local unitKey = "ui_gm_unit_piece"

                                    if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                                        unitKey = "ui_gm_unit_bale"
                                        if g_baleManager ~= nil then
                                            local isRound, width, height, length, diameter = g_baleManager:getBaleInfoByXMLFilename(objXml)
                                            title = isRound and string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_roundbale"), diameter or width or 1.25) or string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_squarebale"), length or 2.40)
                                        end
                                    else
                                        unitKey = "ui_gm_unit_pallet"
                                        local storeItem = g_storeManager:getItemByXMLFilename(objXml)
                                        title = storeItem ~= nil and storeItem.name or g_i18n:getText("ui_gm_format_pallet")
                                    end

                                    formatTracker[objXml] = {
                                        title = title,
                                        xml = objXml,
                                        capacity = objCapacity,
                                        unitKey = unitKey,
                                        actualCount = objectInfo.numObjects -- Store physical count
                                    }
                                else
                                    -- Add up amounts if there are multiple stacks of the exact same XML format
                                    formatTracker[objXml].actualCount = formatTracker[objXml].actualCount + objectInfo.numObjects
                                end
                            end
                        end

                        -- Move tracker data to our standard availableFormats table
                        for _, formatData in pairs(formatTracker) do
                            table.insert(self.availableFormats, formatData)
                        end
                    end
                end

                -- If formats exist, populate the dropdown texts and show it
                if #self.availableFormats > 0 then
                    local texts = {}
                    for _, format in ipairs(self.availableFormats) do
                        table.insert(texts, format.title)
                    end
                    self.formatSelectionElement:setTexts(texts)
                    self.formatSelectionElement:setVisible(true)
                end
            end
        end

        -- 3. Update the info text below the title
        local infoText = string.format("%s: %s L | %s: %s / 1000L",
            g_i18n:getText("ui_ingameMenuGlobalMarketAvailable"),
            g_i18n:formatVolume(self.maxAmount, 0),
            g_i18n:getText("ui_ingameMenuGlobalMarketPrice"),
            g_i18n:formatMoney(self.pricePer1000, 0, true, true))

        self.dialogInfoTextElement:setText(infoText)

        -- 4. Trigger follow-up logic
        if #self.availableFormats > 0 then
            self.formatSelectionElement:setState(1, true)
            if self.onClickFormat ~= nil then
                self:onClickFormat(1)
            end
        else
            self:onAmountChanged()
        end
    end
end

-- Triggered when the user changes the object format dropdown (Bales/Pallets)
function GlobalMarketDialog:onClickFormat(state)
    local selectedFormat = self.availableFormats[state]
    if selectedFormat ~= nil then
        self.currentFormatXml = selectedFormat.xml
        self.currentCountFactor = selectedFormat.capacity or 1000
        self.currentUnitKey = selectedFormat.unitKey or "ui_gm_unit_piece"

        local selectedSilo = self.storageLocations[self.selectedStorageIndex]
        local maxPieces = 0

        if selectedSilo ~= nil and selectedSilo.isObjectStorage then
            if self.actionType == "SELL" then
                -- SELLING: Maximum is exactly the number of physical objects in storage
                maxPieces = selectedFormat.actualCount or 0
            else
                -- BUYING: Maximum is determined by free slots and market stock
                local spec = selectedSilo.storage.spec_objectStorage
                local maxCapacity = spec.capacity or 250
                local numStored = spec.numStoredObjects or 0
                local freeSlots = math.max(0, maxCapacity - numStored)

                -- Determine how many pieces we can actually afford from the market stock
                local marketStock = 0
                local gm = g_currentMission.globalMarket
                local marketData = gm:getIsMarketOnline() and gm.fillTypes or gm.offlineMarketFillTypes
                if marketData ~= nil then
                    for _, data in pairs(marketData) do
                        if data.fillType == self.fillTypeName then
                            marketStock = data.fillLevel or 0
                            break
                        end
                    end
                end

                local maxPiecesFromMarket = math.floor(marketStock / self.currentCountFactor)
                maxPieces = math.min(freeSlots, maxPiecesFromMarket)
            end
        end

        self.currentMaxPieces = maxPieces

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:debug("Dialog: Format selected '%s' (Capacity: %d, MaxPieces: %d)", selectedFormat.title, self.currentCountFactor, self.currentMaxPieces)
        end

        -- Update info text using strict translation system
        local infoText = string.format(g_i18n:getText("ui_gm_format_info"), selectedFormat.title, self.currentMaxPieces, self.currentCountFactor)
        self.dialogInfoTextElement:setText(infoText)

        -- Reset input field and trigger calculation
        if self.amountInput ~= nil then
            self.amountInput:setText("0")
        end
        self:onAmountChanged()
    end
end

-- Triggered when the user clicks the 'MAX' button next to the input field
function GlobalMarketDialog:onClickMaxAmount()
    local fillAmount = self.maxAmount

    -- If we are in object mode, default fillAmount is the max pieces
    if self.currentCountFactor > 1 and self.currentMaxPieces ~= nil then
        fillAmount = self.currentMaxPieces

        -- SAFETY CAP: Prevent Engine Crash / Spawn Lag
        if fillAmount > GlobalMarketDialog.MAX_OBJECTS_PER_TX then
            fillAmount = GlobalMarketDialog.MAX_OBJECTS_PER_TX
        end
    end

    if self.actionType == "BUY" then
        local currentMoney = g_currentMission:getMoney()
        local selectedSilo = self.storageLocations[self.selectedStorageIndex]
        local isGmMarket = selectedSilo ~= nil and selectedSilo.isGmMarket

        if currentMoney <= 0 then
            fillAmount = 0
        else
            -- BUGFIX/QOL: Account for delivery costs in max calculation to avoid liquidity overshoot
            local baseDeliveryFee = isGmMarket and 0 or ((GlobalMarket.DELIVER_COST or 0) * EconomyManager.getCostMultiplier())
            local feePerLiter = isGmMarket and 0 or ((GlobalMarket.DELIVER_COST_PERLITER or 0) * EconomyManager.getCostMultiplier())

            -- Combine commodity price and delivery fee to get total cost per liter
            local costPerLiter = (self.pricePer1000 / 1000) + feePerLiter
            local maxAffordableLiters = 0

            if currentMoney > baseDeliveryFee and costPerLiter > 0 then
                maxAffordableLiters = (currentMoney - baseDeliveryFee) / costPerLiter
            end

            if self.currentCountFactor > 1 then
                local maxAffordablePieces = math.floor(maxAffordableLiters / self.currentCountFactor)
                fillAmount = math.min(fillAmount, maxAffordablePieces)
            else
                fillAmount = math.min(fillAmount, maxAffordableLiters)
            end
        end
    end

    -- Update the input field and trigger the calculation logic
    if self.amountInput ~= nil then
        self.amountInput:setText(string.format("%d", math.floor(fillAmount)))
        self:onAmountChanged()
    end
end

-- Handles user keyboard input and validates against limits (No logging to prevent spam)
function GlobalMarketDialog:onAmountChanged()
    local text = self.amountInput:getText()
    local amount = tonumber(text) or 0

    local effectiveMax = self.maxAmount

    -- If we are in object mode, use the exactly calculated maxPieces limit
    if self.currentCountFactor > 1 and self.currentMaxPieces ~= nil then
        effectiveMax = self.currentMaxPieces

        -- SAFETY CAP: Prevent Engine Crash / Spawn Lag
        if effectiveMax > GlobalMarketDialog.MAX_OBJECTS_PER_TX then
            effectiveMax = GlobalMarketDialog.MAX_OBJECTS_PER_TX
        end
    end

    if amount > effectiveMax then
        amount = effectiveMax
        self.amountInput:setText(tostring(amount))
    end
    self.currentAmount = amount

    -- Update the dynamic unit text next to the MAX button based on the current format
    if self.inputUnitText ~= nil then
        if self.currentCountFactor > 1 and self.currentUnitKey ~= nil then
            self.inputUnitText:setText(g_i18n:getText(self.currentUnitKey))
        else
            self.inputUnitText:setText(g_i18n:getText("ui_gm_unit_liter"))
        end
    end

    -- Trigger the total value calculation, UI text update, and button state
    self:updateTotalValue()
end

-- Calculates the final price and toggles the OK button based on funds
function GlobalMarketDialog:updateTotalValue()
    -- Calculate total liters respecting the format (bulk vs pieces)
    local totalLiters = self.currentAmount * self.currentCountFactor
    local total = (totalLiters / 1000) * self.pricePer1000

    -- QOL FEATURE: Real-time calculation of dynamic delivery costs
    local deliveryCosts = 0
    local selectedSilo = self.storageLocations[self.selectedStorageIndex]

    if selectedSilo ~= nil and not selectedSilo.isGmMarket and totalLiters > 0 then
        local baseCost = GlobalMarket.DELIVER_COST or 0
        local costPerLiter = GlobalMarket.DELIVER_COST_PERLITER or 0
        deliveryCosts = (baseCost + (costPerLiter * totalLiters)) * EconomyManager.getCostMultiplier()
    end

    -- Update the delivery cost text visually
    if self.deliveryCostText ~= nil then
        if deliveryCosts > 0 then
            local deliveryLabel = g_i18n:getText("ui_gm_delivery_costs") or "Delivery"
            local deliveryText = string.format("%s: %s", deliveryLabel, g_i18n:formatMoney(deliveryCosts, 0, true, true))
            self.deliveryCostText:setText(deliveryText)
            self.deliveryCostText:setVisible(true)
        else
            self.deliveryCostText:setVisible(false)
        end
    end

    -- BUGFIX: Ensure liquidity validation considers total value AND delivery costs when buying
    local hasEnoughMoney = true
    if self.actionType == "BUY" then
        hasEnoughMoney = g_currentMission:getMoney() >= (total + deliveryCosts)
    end

    if not hasEnoughMoney then
        self.totalValueText:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderNotEnoughMoney"))
        self.totalValueText:setTextColor(0.8, 0.05, 0.05, 1) -- Turn text red
        self.yesButton:setDisabled(true)
    else
        local totalValueHeader = self.actionType == "SELL" and g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderSellPrice") or g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderBuyPrice")

        local baseText = string.format("%s %s (%s L)",
            totalValueHeader,
            g_i18n:formatMoney(total, 0, true, true),
            g_i18n:formatVolume(totalLiters, 0))

        -- CRITICAL UX FEATURE: Show Engine Limit Warning
        if self.currentCountFactor > 1 and self.currentAmount == GlobalMarketDialog.MAX_OBJECTS_PER_TX and self.currentMaxPieces > GlobalMarketDialog.MAX_OBJECTS_PER_TX then
            local limitWarning = string.format(g_i18n:getText("ui_gm_warning_engineLimit"), GlobalMarketDialog.MAX_OBJECTS_PER_TX)

            self.totalValueText:setText(baseText .. limitWarning)
            self.totalValueText:setTextColor(0.9, 0.6, 0.1, 1) -- Turn text Orange/Yellow
        else
            self.totalValueText:setText(baseText)
            self.totalValueText:setTextColor(1, 1, 1, 1) -- Reset to white
        end

        self.yesButton:setDisabled(self.currentAmount <= 0)
    end
end

-- Triggered when the user confirms the transaction popup
function GlobalMarketDialog:onClickOk()
    local selectedStorage = self.storageLocations[self.storageSelectionElement:getState()]

    if self.callbackFunc ~= nil and selectedStorage ~= nil then
        -- BUGFIX: Backend expects Liters! Convert pieces to total liters before sending.
        local litersToProcess = self.currentAmount
        if self.currentCountFactor > 1 then
            litersToProcess = self.currentAmount * self.currentCountFactor
        end

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("Dialog Confirmed: Dispatching %s transaction for %.2f L of %s.", self.actionType, litersToProcess, tostring(self.fillTypeName))
        end

        -- Pass the calculated liters to the main UI callback
        self.callbackFunc(self.target, litersToProcess, selectedStorage.id, self.actionType, self.fillTypeName, selectedStorage.isObjectStorage, self.currentFormatXml, self.currentCountFactor)
    end

    GlobalMarketDialog:superClass().onClickOk(self)
    self:close()

    return false
end

function GlobalMarketDialog:onClickBack()
    GlobalMarketDialog:superClass().onClickBack(self)
    self:close()
    return false
end
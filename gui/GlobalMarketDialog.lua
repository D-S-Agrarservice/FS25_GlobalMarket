--
-- FS25 - GlobalMarketDialog
--

GlobalMarketDialog = {}
local GlobalMarketDialog_mt = Class(GlobalMarketDialog, YesNoDialog)

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

function GlobalMarketDialog:show(target, callbackFunc, actionType, fillTypeTitle, fillTypeName, price, silos)
    self.target = target
    self.callbackFunc = callbackFunc
    self.actionType = actionType
    self.fillTypeTitle = fillTypeTitle
    self.fillTypeName = fillTypeName
    self.pricePer1000 = price
    self.currentAmount = 0
    self.storageLocations = silos or {}

    -- Hijack block removed. We completely rely on the custom GM dialog
    -- to handle both bulk and object storages seamlessly via liter inputs.
    g_gui:showDialog("GlobalMarketDialog")
end

-- Triggers the native FS25 ObjectStorageDialog for Bales/Pallets
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
        -- Native dialog returns amount of objects. We need to calculate the total liters for the backend.
        -- Note: This is a simplified calculation, assuming standard capacities per object.
        -- For Global Market transaction, we pass the "amount" (count) if the backend supports it,
        -- or multiply by capacity. Let's stick to the callback structure:
        if self.callbackFunc ~= nil then
            -- We pass the count as "amount" and the backend must handle it if storage.isObjectStorage is true
            self.callbackFunc(self.target, amount, self.storageLocations[1].id, self.actionType, self.fillTypeName)
        end
    end
end

function GlobalMarketDialog:onOpen()
    GlobalMarketDialog:superClass().onOpen(self)

    -- NEW: Variables for format logic
    self.currentCountFactor = 1
    self.currentFormatXml = nil
    self.availableFormats = {}

    -- FIX 1: Reset the sticky input field immediately
    if self.amountInput ~= nil then
        self.amountInput:setText("0")
    end

    local titlePrefix = self.actionType == "SELL" and (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderStorage") .. ": ") or (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderMarket") .. ": ")
    self.dialogTitleElement:setText(titlePrefix .. tostring(self.fillTypeTitle))

    local actionText = self.actionType == "SELL" and (g_i18n:getText("ui_btn_sell") or "SELL") or (g_i18n:getText("ui_btn_buy") or "BUY")
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

        -- 2. NEW: Scan engine for formats if it's an ObjectStorage and we are BUYING
        if selectedSilo.isObjectStorage and self.actionType == "BUY" then
            local fillType = g_fillTypeManager:getFillTypeByName(self.fillTypeName)

            if fillType ~= nil then
                if selectedSilo.supportsBales and fillType.isBaleType and g_baleManager ~= nil then
                    -- Scan FS25 BaleManager for matching bales
                    for _, bale in ipairs(g_baleManager.bales) do
                        if bale.isAvailable then
                            for _, ftData in ipairs(bale.fillTypes) do
                                if ftData.fillTypeIndex == fillType.index then
                                    local isRound, width, height, length, diameter = g_baleManager:getBaleInfoByXMLFilename(bale.xmlFilename)
                                    local title = ""
                                    if isRound then
                                        title = string.format("Roundbale (%.2fm)", diameter or width or 1.25)
                                    else
                                        title = string.format("Squarebale (%.2fm)", length or 2.40)
                                    end
                                    table.insert(self.availableFormats, {title = title, xml = bale.xmlFilename, capacity = ftData.capacity})
                                end
                            end
                        end
                    end
                elseif selectedSilo.supportsPallets and fillType.isPalletType then
                    -- Fallback for pallets
                    table.insert(self.availableFormats, {title = "Pallet", xml = fillType.palletFilename, capacity = 1000})
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

function GlobalMarketDialog:onClickFormat(state)
    local selectedFormat = self.availableFormats[state]
    if selectedFormat ~= nil then
        self.currentFormatXml = selectedFormat.xml
        self.currentCountFactor = selectedFormat.capacity or 1000

        local selectedSilo = self.storageLocations[self.selectedStorageIndex]
        local maxPieces = 0

        if selectedSilo ~= nil and selectedSilo.isObjectStorage then
            local spec = selectedSilo.storage.spec_objectStorage

            -- Safely get capacity with Giants default fallback of 250 if not defined in XML
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

            -- The absolute maximum pieces is the lower of the two limits
            maxPieces = math.min(freeSlots, maxPiecesFromMarket)
        end

        -- Store the calculated max pieces so onAmountChanged can use it
        self.currentMaxPieces = maxPieces

        -- Update info text using translation system
        local l10nString = g_i18n:getText("ui_gm_format_info")
        -- Fallback just in case the translation is missing
        if l10nString == nil or l10nString == "ui_gm_format_info" then
            l10nString = "Format: %s | Max: %d | 1 = %d L"
        end

        local infoText = string.format(l10nString, selectedFormat.title, self.currentMaxPieces, self.currentCountFactor)
        self.dialogInfoTextElement:setText(infoText)

        -- Reset input field and trigger calculation
        if self.amountInput ~= nil then
            self.amountInput:setText("0")
        end
        self:onAmountChanged()
    end
end

function GlobalMarketDialog:onClickMaxAmount()
    local fillAmount = self.maxAmount

    -- If we are in object mode, default fillAmount is the max pieces
    if self.currentCountFactor > 1 and self.currentMaxPieces ~= nil then
        fillAmount = self.currentMaxPieces
    end

    if self.actionType == "BUY" then
        local currentMoney = g_currentMission:getMoney()
        if currentMoney <= 0 then
            fillAmount = 0
        else
            -- Calculate how many liters we can afford
            local maxAffordableLiters = (currentMoney / self.pricePer1000) * 1000

            if self.currentCountFactor > 1 then
                -- Convert affordable liters to pieces
                local maxAffordablePieces = math.floor(maxAffordableLiters / self.currentCountFactor)
                fillAmount = math.min(fillAmount, maxAffordablePieces)
            else
                fillAmount = math.min(fillAmount, maxAffordableLiters)
            end
        end
    end

    self.amountInput:setText(string.format("%d", math.floor(fillAmount)))
    self:onAmountChanged()
end

function GlobalMarketDialog:onAmountChanged()
    local text = self.amountInput:getText()
    local amount = tonumber(text) or 0

    -- Cap the input to the maximum allowed value (Default is maxAmount for Bulk)
    local effectiveMax = self.maxAmount

    -- If we are in object mode, use the exactly calculated maxPieces limit
    if self.currentCountFactor > 1 and self.currentMaxPieces ~= nil then
        effectiveMax = self.currentMaxPieces
    end

    if amount > effectiveMax then
        amount = effectiveMax
        self.amountInput:setText(tostring(amount))
    end
    self.currentAmount = amount

    -- Price calculation: pieces * litersPerPiece * pricePer1000
    local totalLiters = self.currentAmount * self.currentCountFactor
    local totalPrice = (totalLiters / 1000) * self.pricePer1000

    -- Update the total value text display (FIX: Used g_i18n instead of g_currentMission)
    if self.totalValueText ~= nil then
        self.totalValueText:setText(string.format("Total: %s (%s L)",
            g_i18n:formatMoney(totalPrice, 0, true, true),
            g_i18n:formatVolume(totalLiters, 0)))
    end

    -- Enable or disable the confirm button based on the input amount
    self.yesButton:setDisabled(amount <= 0)
end

function GlobalMarketDialog:updateTotalValue()
    local total = (self.currentAmount / 1000) * self.pricePer1000

    -- FIX 3: Check funds when manually typing a number
    local hasEnoughMoney = true
    if self.actionType == "BUY" then
        hasEnoughMoney = g_currentMission:getMoney() >= total
    end

    if not hasEnoughMoney then
        self.totalValueText:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderNotEnoughMoney"))
        self.totalValueText:setTextColor(0.8, 0.05, 0.05, 1) -- Turn text red
        self.yesButton:setDisabled(true)
    else
        local totalValueHeader = self.actionType == "SELL" and g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderSellPrice") or g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderBuyPrice")
        self.totalValueText:setText(string.format("%s %s", totalValueHeader, g_i18n:formatMoney(total, 0, true, true)))
        self.totalValueText:setTextColor(1, 1, 1, 1) -- Reset to white
        self.yesButton:setDisabled(self.currentAmount <= 0)
    end
end

function GlobalMarketDialog:onClickOk()
    local selectedStorage = self.storageLocations[self.storageSelectionElement:getState()]

    if self.callbackFunc ~= nil and selectedStorage ~= nil then
        -- Pass the new format parameters to the backend
        -- Signature: target, amount, storageId, actionType, fillTypeName, isObjectStorage, formatXml, capacityPerObject
        self.callbackFunc(self.target, self.currentAmount, selectedStorage.id, self.actionType, self.fillTypeName, selectedStorage.isObjectStorage, self.currentFormatXml, self.currentCountFactor)
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
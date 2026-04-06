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

    -- Check if we are dealing with ObjectStorage (Bales/Pallets)
    -- We assume if the first available storage is an ObjectStorage, we use the native dialog
    local firstStorage = self.storageLocations[1]
    if firstStorage ~= nil and firstStorage.isObjectStorage then
        self:showNativeObjectStorageDialog(firstStorage)
        return -- Do not show the custom GlobalMarketDialog
    end

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

    local titlePrefix = self.actionType == "SELL" and (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderStorage") .. ": ") or (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderMarket") .. ": ")
    self.dialogTitleElement:setText(titlePrefix .. tostring(self.fillTypeTitle))

    local actionText = self.actionType == "SELL" and (g_i18n:getText("ui_btn_sell") or "VERKAUFEN") or (g_i18n:getText("ui_btn_buy") or "KAUFEN")
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

    if selectedSilo ~= nil then
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

        local infoText = string.format("%s: %s L | %s: %s / 1000L",
            g_i18n:getText("ui_ingameMenuGlobalMarketAvailable"),
            g_i18n:formatVolume(self.maxAmount, 0),
            g_i18n:getText("ui_ingameMenuGlobalMarketPrice"),
            g_i18n:formatMoney(self.pricePer1000, 0, true, true))

        self.dialogInfoTextElement:setText(infoText)
        self:onAmountChanged()
    end
end

function GlobalMarketDialog:onClickMaxAmount()
    -- Native-like behavior: Formatting numbers correctly
    self.amountInput:setText(string.format("%d", math.floor(self.maxAmount)))
    self:onAmountChanged()
end

function GlobalMarketDialog:onAmountChanged(...)
    local text = self.amountInput:getText()
    local amount = tonumber(text)

    if amount == nil then
        self.currentAmount = 0
    else
        if amount > self.maxAmount then
            amount = self.maxAmount
            self.amountInput:setText(string.format("%d", math.floor(amount)))
        end
        self.currentAmount = amount
    end

    self:updateTotalValue()
end

function GlobalMarketDialog:updateTotalValue()
    local total = (self.currentAmount / 1000) * self.pricePer1000
    local totalValueHeader = self.actionType == "SELL" and g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderSellPrice") or g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderBuyPrice")

    self.totalValueText:setText(string.format("%s %s", totalValueHeader, g_i18n:formatMoney(total, 0, true, true)))
    self.yesButton:setDisabled(self.currentAmount <= 0)
end

function GlobalMarketDialog:onClickOk()
    local selectedStorage = self.storageLocations[self.storageSelectionElement:getState()]
    if self.callbackFunc ~= nil and selectedStorage ~= nil then
        self.callbackFunc(self.target, self.currentAmount, selectedStorage.id, self.actionType, self.fillTypeName)
    end
    GlobalMarketDialog:superClass().onClickOk(self)
end

function GlobalMarketDialog:onClickBack()
    GlobalMarketDialog:superClass().onClickBack(self)
end
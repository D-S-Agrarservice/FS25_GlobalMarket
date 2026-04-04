--
-- FS25 - GlobalMarketDialog
--

GlobalMarketDialog = {}
local GlobalMarketDialog_mt = Class(GlobalMarketDialog, YesNoDialog)

function GlobalMarketDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketDialog_mt)

    self.actionType = "SELL"
    self.fillTypeTitle = ""
    self.fillTypeName = "" -- Store the raw fillType name (e.g., "MAIZE") for the backend transaction
    self.pricePer1000 = 0
    self.maxAmount = 0
    self.currentAmount = 0
    self.selectedStorageIndex = 1
    self.storageLocations = {}

    return self
end

-- Call this to open the dialog from outside
-- @param target table: The calling UI instance
-- @param callbackFunc function: The function to execute on OK
-- @param actionType string: "SELL" or "BUY"
-- @param fillTypeTitle string: Localized name of the fruit
-- @param fillTypeName string: Raw name of the fruit
-- @param price number: Current price per 1000L
-- @param silos table: List of available storages from the backend
function GlobalMarketDialog:show(target, callbackFunc, actionType, fillTypeTitle, fillTypeName, price, silos)
    self.target = target
    self.callbackFunc = callbackFunc
    self.actionType = actionType
    self.fillTypeTitle = fillTypeTitle
    self.fillTypeName = fillTypeName
    self.pricePer1000 = price
    self.currentAmount = 0
    self.storageLocations = silos or {}

    g_gui:showDialog("GlobalMarketDialog")
end

function GlobalMarketDialog:onOpen()
    GlobalMarketDialog:superClass().onOpen(self)

    -- Set localized Title based on action
    local titlePrefix = self.actionType == "SELL" and (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderStorage") .. ": ") or (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderMarket") .. ": ")
    self.dialogTitleElement:setText(titlePrefix .. tostring(self.fillTypeTitle))

    -- Set Action Button Text (using l10n strings)
    local actionText = self.actionType == "SELL" and (g_i18n:getText("ui_btn_sell") or "VERKAUFEN") or (g_i18n:getText("ui_btn_buy") or "KAUFEN")
    if self.yesButton ~= nil then
        self.yesButton:setText(actionText)
    end

    -- Setup Storage Dropdown from actual backend data
    local storageNames = {}
    for _, loc in ipairs(self.storageLocations) do
        table.insert(storageNames, loc.title)
    end

    self.storageSelectionElement:setTexts(storageNames)

    -- Initialize with the first silo to trigger UI updates
    self.storageSelectionElement:setState(1, true)
    self:onClickStorage(1)

    -- Focus input immediately
    FocusManager:setFocus(self.amountInput)
end

function GlobalMarketDialog:onClickStorage(state)
    self.selectedStorageIndex = state
    local selectedSilo = self.storageLocations[state]

    if selectedSilo ~= nil then
        -- Update max amount based on action context (stock vs free capacity)
        self.maxAmount = self.actionType == "SELL" and selectedSilo.level or selectedSilo.freeCapacity

        -- Build localized info string
        local availableText = g_i18n:getText("ui_ingameMenuGlobalMarketAvailable") or "Verfuegbare Menge"
        local priceText = g_i18n:getText("ui_ingameMenuGlobalMarketPrice") or "Preis"
        local infoText = string.format("%s: %s L | %s: %s / 1000L", availableText, g_i18n:formatVolume(self.maxAmount, 0), priceText, g_i18n:formatMoney(self.pricePer1000, 0, true, true))

        self.dialogInfoTextElement:setText(infoText)

        -- Re-evaluate current input to clamp it if it exceeds the new max capacity
        self:onAmountChanged()
    end
end

function GlobalMarketDialog:onClickMaxAmount()
    self.amountInput:setText(tostring(self.maxAmount))
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
            self.amountInput:setText(tostring(amount))
        end
        self.currentAmount = amount
    end

    self:updateTotalValue()
end

function GlobalMarketDialog:updateTotalValue()
    local total = (self.currentAmount / 1000) * self.pricePer1000

    -- Use l10n strings for the total value header
    local totalValueHeader = self.actionType == "SELL" and (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderSellPrice") or "Voraussichtlicher Verkaufspreis:") or (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderBuyPrice") or "Voraussichtlicher Kaufpreis:")

    self.totalValueText:setText(string.format("%s %s", totalValueHeader, g_i18n:formatMoney(total, 0, true, true)))

    -- Disable OK button if amount is 0 or less
    self.yesButton:setDisabled(self.currentAmount <= 0)
end

function GlobalMarketDialog:onClickOk()
    local selectedStorage = self.storageLocations[self.storageSelectionElement:getState()]

    if self.callbackFunc ~= nil and selectedStorage ~= nil then
        -- Return Data: Target, Amount, StorageID, ActionType, RawFillTypeName
        self.callbackFunc(self.target, self.currentAmount, selectedStorage.id, self.actionType, self.fillTypeName)
    end

    GlobalMarketDialog:superClass().onClickOk(self)
end

function GlobalMarketDialog:onClickBack()
    GlobalMarketDialog:superClass().onClickBack(self)
end
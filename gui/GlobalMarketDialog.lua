--
-- FS25 - GlobalMarketDialog
--

GlobalMarketDialog = {}
local GlobalMarketDialog_mt = Class(GlobalMarketDialog, YesNoDialog)

function GlobalMarketDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketDialog_mt)

    self.actionType = "SELL"
    self.fillTypeTitle = ""
    self.pricePer1000 = 0
    self.maxAmount = 0
    self.currentAmount = 0
    self.selectedStorageIndex = 1
    self.storageLocations = {}

    return self
end

-- Call this to open the dialog from outside
function GlobalMarketDialog:show(target, callbackFunc, actionType, fillTypeTitle, availableAmount, price)
    self.target = target
    self.callbackFunc = callbackFunc
    self.actionType = actionType
    self.fillTypeTitle = fillTypeTitle
    self.maxAmount = availableAmount
    self.pricePer1000 = price
    self.currentAmount = 0

    -- Load dummy locations
    if GlobalMarketDummyData ~= nil then
        self.storageLocations = GlobalMarketDummyData.getStorageLocations()
    else
        self.storageLocations = { {id = 1, name = "Dummy Farm 1"} }
    end

    g_gui:showDialog("GlobalMarketDialog")
end

function GlobalMarketDialog:onOpen()
    GlobalMarketDialog:superClass().onOpen(self)

    -- Set Title
    local titlePrefix = self.actionType == "SELL" and "Verkaufen: " or "Kaufen: "
    self.dialogTitleElement:setText(titlePrefix .. tostring(self.fillTypeTitle))

    -- Set Action Button Text (Dynamically replace "START")
    local actionText = self.actionType == "SELL" and (g_i18n:getText("ui_btn_sell") or "VERKAUFEN") or (g_i18n:getText("ui_btn_buy") or "KAUFEN")
    if self.yesButton ~= nil then
        self.yesButton:setText(actionText)
    end

    -- Set Info Text
    local infoText = string.format("Menge verfügbar: %s L | Preis: %s / 1000L", g_i18n:formatVolume(self.maxAmount, 0), g_i18n:formatMoney(self.pricePer1000, 0, true, true))
    self.dialogInfoTextElement:setText(infoText)

    -- Setup Storage Dropdown
    local storageNames = {}
    for i, loc in ipairs(self.storageLocations) do
        table.insert(storageNames, loc.name)
    end
    self.storageSelectionElement:setTexts(storageNames)
    self.storageSelectionElement:setState(1, true)

    -- Reset Input
    self.amountInput:setText("0")
    self:updateTotalValue()

    -- Focus input immediately
    FocusManager:setFocus(self.amountInput)
end

function GlobalMarketDialog:onClickStorage(state)
    self.selectedStorageIndex = state
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
    self.totalValueText:setText(string.format("Gesamtwert: %s", g_i18n:formatMoney(total, 0, true, true)))

    -- Disable OK button if amount is 0
    self.yesButton:setDisabled(self.currentAmount <= 0)
end

function GlobalMarketDialog:onClickOk()
    local selectedStorage = self.storageLocations[self.storageSelectionElement:getState()]

    if self.callbackFunc ~= nil then
        -- Return Data: Amount, StorageID, ActionType
        self.callbackFunc(self.target, self.currentAmount, selectedStorage.id, self.actionType)
    end

    GlobalMarketDialog:superClass().onClickOk(self)
end

function GlobalMarketDialog:onClickBack()
    GlobalMarketDialog:superClass().onClickBack(self)
end
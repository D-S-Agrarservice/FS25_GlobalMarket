--
-- FS25 - GlobalMarketUI
--

GlobalMarketUI = {}
local GlobalMarketUI_mt = Class(GlobalMarketUI, TabbedMenuFrameElement)

function GlobalMarketUI.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or GlobalMarketUI_mt)

    self.storageData = {}
    self.marketData = {}
    self.i18n = g_i18n
    self.currentListFocus = "storage"
    self.isUpdatingSelection = false

    return self
end

function GlobalMarketUI:onGuiSetupFinished()
    GlobalMarketUI:superClass().onGuiSetupFinished(self)

    if self.gmTableStorage ~= nil then
        self.gmTableStorage:setDataSource(self)
        self.gmTableStorage:setDelegate(self)
    end

    if self.gmTableMarket ~= nil then
        self.gmTableMarket:setDataSource(self)
        self.gmTableMarket:setDelegate(self)
    end
end

function GlobalMarketUI:onFrameOpen()
    GlobalMarketUI:superClass().onFrameOpen(self)
    self:updateContent()

    local backButton = { inputAction = InputAction.MENU_BACK }
    self.actionButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = self.i18n:getText("ui_btn_sell") or "Verkaufen",
        callback = function() self:onButtonAction() end,
        disabled = true
    }

    self:setMenuButtonInfo({ backButton, self.actionButtonInfo })

    if self.gmTableStorage ~= nil then
        FocusManager:setFocus(self.gmTableStorage)
    end
end

function GlobalMarketUI:updateContent()
    local gm = g_currentMission.globalMarket

    -- Update balance
    if self.currentBalanceText ~= nil and g_currentMission ~= nil then
        self.currentBalanceText:setText(self.i18n:formatMoney(g_currentMission:getMoney(), 0, true, true))
    end

    local farmId = g_currentMission:getFarmId()

    -- Load storage data
    self.storageData = gm:getAggregatedStorageData(farmId)

    -- Calculate total volume for footer display
    local totalVolume = 0
    for _, data in ipairs(self.storageData) do
        totalVolume = totalVolume + (data.level or 0)
    end
    if self.totalStorageDisplay ~= nil then
        self.totalStorageDisplay:setText(self.i18n:formatVolume(totalVolume, 0))
    end

    -- Load market data
    if gm:getIsMarketOnline() then
        self.marketData = gm.fillTypes or {}
    else
        self.marketData = gm.offlineMarketFillTypes or {}
    end

    if self.gmTableStorage ~= nil then self.gmTableStorage:reloadData() end
    if self.gmTableMarket ~= nil then self.gmTableMarket:reloadData() end
end

-- =========================================================================
-- LIST CALLBACKS (Data Source)
-- =========================================================================

function GlobalMarketUI:getNumberOfSections(list)
    return 1
end

function GlobalMarketUI:getNumberOfItemsInSection(list, section)
    if list == self.gmTableStorage then return #self.storageData end
    if list == self.gmTableMarket then return #self.marketData end
    return 0
end

function GlobalMarketUI:populateCellForItemInSection(list, section, index, cell)
    local data = (list == self.gmTableStorage) and self.storageData[index] or self.marketData[index]
    if not data then return end

    local icon = cell:getAttribute("icon")
    local name = cell:getAttribute("name")
    local amount = cell:getAttribute("amount")
    local price = cell:getAttribute("price")
    local trend = cell:getAttribute("trend")

    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)

    if name and fillTypeDesc then
        name:setText(fillTypeDesc.title)
    end

    if icon and fillTypeDesc then
        icon:setImageFilename(fillTypeDesc.hudOverlayFilename)
    end

    if amount then
        local val = (list == self.gmTableStorage) and data.level or data.fillLevel
        amount:setText(self.i18n:formatVolume(val, 0))
    end

    if price then
        price:setText(self.i18n:formatMoney(data.price, 0, true, true))
    end

    if trend then
        trend:setVisible(true)
    end
end

-- =========================================================================
-- SELECTION & ACTIONS
-- =========================================================================

-- Fix for line 140: Ensure actionButtonInfo exists before modifying its properties
function GlobalMarketUI:onListSelectionChanged(list, section, index)
    if self.isUpdatingSelection then return end
    self.isUpdatingSelection = true

    if list == self.gmTableStorage then
        self.currentListFocus = "storage"
        if self.actionButtonInfo ~= nil then
            self.actionButtonInfo.text = self.i18n:getText("ui_btn_sell") or "Verkaufen"
        end
        if self.gmTableMarket then self.gmTableMarket:setSelectedIndex(0) end
    else
        self.currentListFocus = "market"
        if self.actionButtonInfo ~= nil then
            self.actionButtonInfo.text = self.i18n:getText("ui_btn_buy") or "Kaufen"
        end
        if self.gmTableStorage then self.gmTableStorage:setSelectedIndex(0) end
    end

    if self.actionButtonInfo ~= nil then
        self.actionButtonInfo.disabled = (index <= 0)
        self:setMenuButtonInfoDirty()
    end

    self.isUpdatingSelection = false
end

-- Connects perfectly to your existing GMDialog.lua signature
function GlobalMarketUI:onButtonAction()
    local gm = g_currentMission.globalMarket
    local list = (self.currentListFocus == "storage") and self.gmTableStorage or self.gmTableMarket
    local _, index = list:getSelectedPath()
    local data = (self.currentListFocus == "storage") and self.storageData[index] or self.marketData[index]

    if data and gm.dialog ~= nil then
        local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)
        local isSelling = (self.currentListFocus == "storage")
        local actionType = isSelling and "SELL" or "BUY"

        local silos = gm:getAvailableStorages(data.fillType, g_currentMission:getFarmId(), isSelling)

        if #silos > 0 then
            -- Calls your GMDialog exactly as structured in your script
            gm.dialog:show(self, self.onDialogResult, actionType, fillTypeDesc.title, data.fillType, data.price, silos)
        else
            GlobalMarket.debugLog("Action failed: No suitable storage found.")
        end
    end
end

-- Callback receiver from your GMDialog.lua
-- Fixed parameter shift: Removed 'target' as explicit parameter, 
-- because Lua's ':' syntax implicitly handles 'self.target' as 'self'.
function GlobalMarketUI:onDialogResult(amount, storageId, actionType, fillTypeName)
    if amount > 0 then
        local mode = (actionType == "SELL") and 1 or 2
        g_currentMission.globalMarket:onSellBuy(mode, fillTypeName, amount, storageId)
        self:updateContent()
    end
end
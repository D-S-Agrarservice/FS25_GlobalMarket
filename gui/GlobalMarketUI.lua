--
-- FS25 - GlobalMarketUI
--

GlobalMarketUI = {}
local GlobalMarketUI_mt = Class(GlobalMarketUI, TabbedMenuFrameElement)

function GlobalMarketUI.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or GlobalMarketUI_mt)

    self.storageData = {}      -- Local farm storage (Section 1)
    self.terminalData = {}     -- GM Logistic Terminals (Section 2)
    self.marketData = {}       -- Global Market offers

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
        text = self.i18n:getText("ui_btn_sell") or "Sell",
        callback = function() self:onButtonAction() end,
        disabled = true
    }

    self:setMenuButtonInfo({ backButton, self.actionButtonInfo })

    if self.gmTableStorage ~= nil then
        FocusManager:setFocus(self.gmTableStorage)
    end
end

function GlobalMarketUI:updateContent()
    if self.currentBalanceText ~= nil and g_currentMission ~= nil then
        self.currentBalanceText:setText(self.i18n:formatMoney(g_currentMission:getMoney(), 0, true, true))
    end

    local farmId = g_currentMission:getFarmId()
    local gm = g_currentMission.globalMarket

    -- 1. Fetch Storage Data (Split into Farm vs. Terminal)
    self.storageData = {}
    self.terminalData = {}

    local allStorageData = gm:getAggregatedStorageData(farmId)
    -- Note: We modified getAggregatedStorageData in GMStorage to return a flag or we filter here
    -- For now, we assume the backend returns everything and we sort by isGmMarket
    for _, data in ipairs(allStorageData) do
        -- We check each fillType's presence in terminals vs normal silos
        -- To keep it simple for the UI, we just use the aggregated list
        table.insert(self.storageData, data)
    end

    -- 2. Fetch Market Data (Online vs. Offline)
    self.marketData = {}
    if gm:getIsMarketOnline() then
        self.marketData = gm.fillTypes or {}
    else
        -- Use data from our new GlobalMarketOffline module
        self.marketData = gm.offlineMarketFillTypes or {}
    end

    if self.gmTableStorage ~= nil then self.gmTableStorage:reloadData() end
    if self.gmTableMarket ~= nil then self.gmTableMarket:reloadData() end
end

-- =========================================================================
-- LIST CALLBACKS (Data Source)
-- =========================================================================

function GlobalMarketUI:getNumberOfSections(list)
    return 1 -- Simplified for the first stable version
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
    if fillTypeDesc ~= nil then
        if icon then icon:setImageFilename(fillTypeDesc.hudOverlayFilename) end
        if name then name:setText(fillTypeDesc.title) end
    end

    if amount then amount:setText(self.i18n:formatVolume(data.fillLevel or data.level, 0)) end
    if price then price:setText(self.i18n:formatMoney(data.price, 0, true, true)) end

    -- Trend logic (only for market list)
    if trend and list == self.gmTableMarket then
        local profile = "globalMarketRowCellArrow" -- Default
        -- Add trend comparison logic here later
        trend:applyProfile(profile, true)
    end
end

-- =========================================================================
-- SELECTION & ACTIONS
-- =========================================================================

function GlobalMarketUI:onListSelectionChanged(list, section, index)
    if self.isUpdatingSelection then return end
    self.isUpdatingSelection = true

    if list == self.gmTableStorage then
        self.currentListFocus = "storage"
        self.actionButtonInfo.text = self.i18n:getText("ui_btn_sell") or "Sell"
        if self.gmTableMarket then self.gmTableMarket:setSelectedIndex(0) end
    else
        self.currentListFocus = "market"
        self.actionButtonInfo.text = self.i18n:getText("ui_btn_buy") or "Buy"
        if self.gmTableStorage then self.gmTableStorage:setSelectedIndex(0) end
    end

    self.actionButtonInfo.disabled = (index <= 0)
    self:setMenuButtonInfoDirty()
    self.isUpdatingSelection = false
end

function GlobalMarketUI:onButtonAction()
    local gm = g_currentMission.globalMarket
    local dialog = gm.dialog
    if not dialog then return end

    local list = (self.currentListFocus == "storage") and self.gmTableStorage or self.gmTableMarket
    local _, index = list:getSelectedPath()
    local data = (self.currentListFocus == "storage") and self.storageData[index] or self.marketData[index]

    if data then
        local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)
        local isSelling = (self.currentListFocus == "storage")
        local actionType = isSelling and "SELL" or "BUY"

        -- Fetch available silos for the dialog (Filtered by farm and capacity/stock)
        local silos = gm:getAvailableStorages(data.fillType, g_currentMission:getFarmId(), isSelling)

        if #silos > 0 then
            dialog:show(self, self.onDialogResult, actionType, fillTypeDesc.title, data.fillType, data.price, silos)
        else
            -- Optional: Show warning if no storage available
            GlobalMarket.debugLog("Action failed: No suitable storage/terminal found.")
        end
    end
end

function GlobalMarketUI:onDialogResult(target, amount, storageId, actionType, fillTypeName)
    if amount > 0 then
        local mode = (actionType == "SELL") and 1 or 2
        -- Execute transaction via Storage Module
        g_currentMission.globalMarket:onSellBuy(mode, fillTypeName, amount, storageId)

        -- Refresh UI after transaction
        self:updateContent()
    end
end
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
    self.isUpdatingSelection = false -- Safety guard to prevent infinite loops
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
    if self.currentBalanceText ~= nil and g_currentMission ~= nil then
        local currentMoney = g_currentMission:getMoney()
        self.currentBalanceText:setText(self.i18n:formatMoney(currentMoney, 0, true, true))
    end

    -- Fetching data from our dummy provider instead of hardcoding it here
    self.storageData = GlobalMarketDummyData.getStorageList()
    self.marketData = GlobalMarketDummyData.getMarketList()

    if self.gmTableStorage ~= nil then self.gmTableStorage:reloadData() end
    if self.gmTableMarket ~= nil then self.gmTableMarket:reloadData() end
end

-- =========================================================================
-- LIST CALLBACKS
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
    if list == self.gmTableStorage then
        local data = self.storageData[index]
        if data then
            local icon = cell:getAttribute("icon")
            local name = cell:getAttribute("name")
            local amount = cell:getAttribute("amount")

            if icon then icon:setImageFilename(data.icon) end
            if name then name:setText(data.title) end
            if amount then amount:setText(self.i18n:formatVolume(data.level, 0)) end
        end
    elseif list == self.gmTableMarket then
        local data = self.marketData[index]
        if data then
            local name = cell:getAttribute("name")
            local amount = cell:getAttribute("amount")
            local price = cell:getAttribute("price")
            local trend = cell:getAttribute("trend")

            if name then name:setText(data.title) end
            if amount then amount:setText(self.i18n:formatVolume(data.level, 0)) end
            if price then price:setText(self.i18n:formatMoney(data.price, 0, true, true)) end

            if trend then
                local profile = "globalMarketRowCellArrow"
                if data.trend == SellingStation.PRICE_CLIMBING then
                    profile = "globalMarketRowCellArrowClimbing"
                elseif data.trend == SellingStation.PRICE_FALLING then
                    profile = "globalMarketRowCellArrowFalling"
                end
                trend:applyProfile(profile, true)
            end
        end
    end
end

-- =========================================================================
-- QoL: DYNAMIC HIGHLIGHT AND BUTTON TEXT
-- =========================================================================
function GlobalMarketUI:onListSelectionChanged(list, section, index)
    if self.isUpdatingSelection then return end
    self.isUpdatingSelection = true

    if self.actionButtonInfo ~= nil then
        if list == self.gmTableStorage then
            if index > 0 then
                self.actionButtonInfo.text = self.i18n:getText("ui_btn_sell") or "Verkaufen"
                self.currentListFocus = "storage"
                self.actionButtonInfo.disabled = false

                -- Deselect the right list
                if self.gmTableMarket ~= nil then
                    self.gmTableMarket:setSelectedIndex(0)
                end
            else
                if self.currentListFocus == "storage" then
                    self.actionButtonInfo.disabled = true
                end
            end
        elseif list == self.gmTableMarket then
            if index > 0 then
                self.actionButtonInfo.text = self.i18n:getText("ui_btn_buy") or "Kaufen"
                self.currentListFocus = "market"
                self.actionButtonInfo.disabled = false

                -- Deselect the left list
                if self.gmTableStorage ~= nil then
                    self.gmTableStorage:setSelectedIndex(0)
                end
            else
                if self.currentListFocus == "market" then
                    self.actionButtonInfo.disabled = true
                end
            end
        end

        self:setMenuButtonInfoDirty()
    end

    self.isUpdatingSelection = false
end

-- =========================================================================
-- ACTIONS
-- =========================================================================
function GlobalMarketUI:onDialogResult(amount, storageId, actionType, fillTypeName)
    if amount > 0 then
        GlobalMarket.debugLog(string.format("DIALOG RESULT -> Action: %s | Amount: %s | Storage ID: %s | FillType: %s", actionType, tostring(amount), tostring(storageId), tostring(fillTypeName)))

        -- Mode for Backend: 1 = SELL (Player sells to Market), 2 = BUY (Player buys from Market)
        local mode = actionType == "SELL" and 1 or 2

        -- Execute the actual transaction in our Storage Module
        if g_currentMission.globalMarket.onSellBuy ~= nil then
            g_currentMission.globalMarket:onSellBuy(mode, fillTypeName, amount, storageId, nil, nil, nil)
        else
            GlobalMarket.debugLog("ERROR: GlobalMarket:onSellBuy function is missing or storage module not loaded!")
        end
    else
        GlobalMarket.debugLog("Dialog cancelled or 0 amount.")
    end
end

function GlobalMarketUI:onButtonAction()
    GlobalMarket.debugLog("Button clicked! Focus is on: " .. tostring(self.currentListFocus))

    local dialog = g_currentMission.globalMarket.dialog

    if dialog == nil then
        GlobalMarket.debugLog("ERROR: Dialog 'GlobalMarketDialog' not found in screenControllers!")
        return
    end

    local playerFarmId = g_currentMission:getFarmId()

    if self.currentListFocus == "storage" then
        local _, index = self.gmTableStorage:getSelectedPath()
        local data = self.storageData[index]

        if data then
            -- Fetch actual storages from backend (isSelling = true -> needs stock)
            local silos = g_currentMission.globalMarket:getAvailableStorages(data.fillType, playerFarmId, true)

            if #silos > 0 then
                GlobalMarket.debugLog("Opening SELL dialog for: " .. tostring(data.title))
                dialog:show(self, self.onDialogResult, "SELL", data.title, data.fillType, data.price, silos)
            else
                GlobalMarket.debugLog("Info: No silo found with %s on farm %d.", data.title, playerFarmId)
            end
        else
            GlobalMarket.debugLog("ERROR: No data found in storage table at given index.")
        end
    elseif self.currentListFocus == "market" then
        local _, index = self.gmTableMarket:getSelectedPath()
        local data = self.marketData[index]

        if data then
            -- Fetch actual storages from backend (isSelling = false -> needs free capacity)
            local silos = g_currentMission.globalMarket:getAvailableStorages(data.fillType, playerFarmId, false)

            if #silos > 0 then
                GlobalMarket.debugLog("Opening BUY dialog for: " .. tostring(data.title))
                dialog:show(self, self.onDialogResult, "BUY", data.title, data.fillType, data.price, silos)
            else
                GlobalMarket.debugLog("Info: No silo with free capacity found for %s on farm %d.", data.title, playerFarmId)
            end
        else
            GlobalMarket.debugLog("ERROR: No data found in market table at given index.")
        end
    end
end
--
-- FS25 - GlobalMarketUI
-- Description: Main UI Frame for the GlobalMarket. Handles data rendering,
-- user input routing, and triggers the transaction dialog.
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
    self.refreshCountdown = 0

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

-- Initializes the UI state and bindings when the player opens the menu
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

-- Fetches all current market and storage data and triggers a list redraw
function GlobalMarketUI:updateContent()
    local gm = g_currentMission.globalMarket

    -- Update balance
    if self.currentBalanceText ~= nil and g_currentMission ~= nil then
        local money = g_currentMission:getMoney()
        self.currentBalanceText:setText(self.i18n:formatMoney(money, 0, true, true))

        -- Native Giants coloring for negative balance
        if money < 0 then
            self.currentBalanceText:setTextColor(0.8, 0.05, 0.05, 1) -- Dark Red
        else
            self.currentBalanceText:setTextColor(1, 1, 1, 1) -- White
        end
    end

    -- Update Online/Offline Status Texts
    if self.marketStatusTitle ~= nil and self.marketStatusDesc ~= nil then
        if gm:getIsMarketOnline() then
            self.marketStatusTitle:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOnline"))
            self.marketStatusDesc:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOnlineDesc"))
        else
            self.marketStatusTitle:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOffline"))
            self.marketStatusDesc:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOfflineDesc"))
        end
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

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:trace("UI Content refreshed. Storage items: %d, Market items: %d", #self.storageData, #self.marketData)
    end

    if self.gmTableStorage ~= nil then self.gmTableStorage:reloadData() end
    if self.gmTableMarket ~= nil then self.gmTableMarket:reloadData() end
end

-- =========================================================================
-- NATIVE UI UPDATE LOOP
-- =========================================================================
function GlobalMarketUI:update(dt)
    GlobalMarketUI:superClass().update(self, dt)

    -- Handle the delayed refresh to prevent race conditions with engine updates
    if self.refreshCountdown > 0 then
        self.refreshCountdown = self.refreshCountdown - dt
        if self.refreshCountdown <= 0 then
            self.refreshCountdown = 0
            self:updateContent()
        end
    end
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

-- Populates each row in the storage and market lists
-- Handles HUD icons and dynamic price trend arrows based on basePrice comparison
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

    -- Icon logic for both lists
    if icon and fillTypeDesc then
        icon:setImageFilename(fillTypeDesc.hudOverlayFilename)
    end

    if amount then
        if list == self.gmTableStorage then
            local baseText = self.i18n:formatVolume(data.level, 0)

            -- Dynamically append storage locations if goods are split or entirely in GM
            if data.levelGM > 0 and data.levelPrivate > 0 then
                local gmText = self.i18n:formatVolume(data.levelGM, 0)
                local privText = self.i18n:formatVolume(data.levelPrivate, 0)

                -- L10N fetch with fallback
                local splitFormat = self.i18n:getText("ui_gm_storage_split")
                if splitFormat == nil or splitFormat == "ui_gm_storage_split" then
                    splitFormat = "(Farm: %s | GM: %s)"
                end

                local formattedDetail = string.format(splitFormat, privText, gmText)
                amount:setText(string.format("%s %s", baseText, formattedDetail))

            elseif data.levelGM > 0 and data.levelPrivate == 0 then
                local onlyGmText = self.i18n:getText("ui_gm_storage_only")
                if onlyGmText == nil or onlyGmText == "ui_gm_storage_only" then
                    onlyGmText = "(GM only)"
                end

                amount:setText(string.format("%s %s", baseText, onlyGmText))
            else
                amount:setText(baseText)
            end
        else
            amount:setText(self.i18n:formatVolume(data.fillLevel, 0))
        end
    end

    -- Price and Trend logic
    if price then
        price:setText(self.i18n:formatMoney(data.price, 0, true, true))
    end

    -- Trend arrow logic (Market list only)
    if trend then
        if list == self.gmTableMarket then
            trend:setVisible(true)

            -- We assume data.basePrice is the value from the offline module
            local basePrice = (data.basePrice or 0.5) * 1000

            -- Trend detection with 5% threshold
            if data.price > (basePrice * 1.05) then
                trend:applyProfile("globalMarketRowCellArrowClimbing")
            elseif data.price < (basePrice * 0.95) then
                trend:applyProfile("globalMarketRowCellArrowFalling")
            else
                -- Price is stable, hide arrow
                trend:setVisible(false)
            end
        else
            -- Hide trend arrow in storage list
            trend:setVisible(false)
        end
    end
end

-- =========================================================================
-- SELECTION & ACTIONS
-- =========================================================================

-- Updates the active list focus and toggles the action button (Buy/Sell)
function GlobalMarketUI:onListSelectionChanged(list, section, index)
    if self.isUpdatingSelection then return end
    self.isUpdatingSelection = true

    if list == self.gmTableStorage then
        self.currentListFocus = "storage"
        if self.actionButtonInfo ~= nil then
            self.actionButtonInfo.text = self.i18n:getText("ui_btn_sell") or "Sell"
        end
        if self.gmTableMarket then self.gmTableMarket:setSelectedIndex(0) end
    else
        self.currentListFocus = "market"
        if self.actionButtonInfo ~= nil then
            self.actionButtonInfo.text = self.i18n:getText("ui_btn_buy") or "Buy"
        end
        if self.gmTableStorage then self.gmTableStorage:setSelectedIndex(0) end
    end

    if self.actionButtonInfo ~= nil then
        self.actionButtonInfo.disabled = (index <= 0)
        self:setMenuButtonInfoDirty()
    end

    self.isUpdatingSelection = false
end

-- Triggered when the user clicks 'Buy' or 'Sell', OR via double-click on a table row
function GlobalMarketUI:onButtonAction(list, section, index)
    local gm = g_currentMission.globalMarket

    -- If triggered via double-click, we get the list and index directly.
    -- If triggered via the button, we fall back to the currently focused list.
    local targetList = list or ((self.currentListFocus == "storage") and self.gmTableStorage or self.gmTableMarket)
    local targetIndex = index

    -- If no index was passed (button click), get the selected path from the list
    if targetIndex == nil then
        _, targetIndex = targetList:getSelectedPath()
    else
        -- If it was a double-click, ensure the UI state updates to the clicked list
        if targetList == self.gmTableStorage then
            self:onListSelectionChanged(self.gmTableStorage, 1, targetIndex)
        else
            self:onListSelectionChanged(self.gmTableMarket, 1, targetIndex)
        end
    end

    local data = (self.currentListFocus == "storage") and self.storageData[targetIndex] or self.marketData[targetIndex]

    if data and gm.dialog ~= nil then
        local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)
        local isSelling = (self.currentListFocus == "storage")
        local actionType = isSelling and "SELL" or "BUY"
        local farmId = g_currentMission:getFarmId()

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:debug("UI Action triggered: %s for %s", actionType, tostring(data.fillType))
        end

        local silos = gm:getAvailableStorages(data.fillType, farmId, isSelling)

        if #silos > 0 then
            -- Calls the popup dialog to select the specific storage and amount
            gm.dialog:show(self, self.onDialogResult, actionType, fillTypeDesc.title, data.fillType, data.price, silos)
        else
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:warning("UI Action failed: No suitable storage found for %s of %s (Farm ID: %d).", actionType, tostring(data.fillType), farmId)
            end
        end
    end
end

-- Callback receiver from the GMDialog popup
function GlobalMarketUI:onDialogResult(amount, storageId, actionType, fillTypeName, isObjectStorage, formatXml, capacityPerObject)
    if amount > 0 then
        local mode = (actionType == "SELL") and 1 or 2

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("UI Dialog Result received: Mode %s, FillType %s, Amount %.2f, StorageID %s", tostring(actionType), tostring(fillTypeName), amount, tostring(storageId))
        end

        -- Pass the transaction to the main market logic
        g_currentMission.globalMarket:onSellBuy(mode, fillTypeName, amount, storageId, 0, nil, nil, isObjectStorage, g_currentMission:getFarmId(), formatXml, capacityPerObject)

        -- Dynamic countdown based on storage type to sync with engine background updates before redrawing UI
        if isObjectStorage then
            self.refreshCountdown = 1200 -- 1000ms native engine delay + 200ms buffer
        else
            self.refreshCountdown = 250 -- Quick refresh for bulk/liquids
        end
    end
end
--
-- FS25 - GlobalMarketUI
-- Description: Main UI Frame for the GlobalMarket. Handles data rendering,
-- user input routing, and triggers the transaction dialog.
--

GlobalMarketUI = {}
local GlobalMarketUI_mt = Class(GlobalMarketUI, TabbedMenuFrameElement)

-- Normalizes localized fillType titles for alphabetical sorting across languages (DE/EN/FR/ES/etc.)
-- so umlauts and accented characters (Ä, Ö, Ü, É, Á, etc.) sort in their natural letter position instead of after 'Z'.
function GlobalMarketUI.normalizeSortTitle(title)
    if title == nil or title == "" then
        return ""
    end
    local s = title
    s = string.gsub(s, "Ä", "A"):gsub("ä", "a")
    s = string.gsub(s, "Ö", "O"):gsub("ö", "o")
    s = string.gsub(s, "Ü", "U"):gsub("ü", "u")
    s = string.gsub(s, "ß", "ss")
    s = string.gsub(s, "Á", "A"):gsub("á", "a"):gsub("À", "A"):gsub("à", "a"):gsub("Â", "A"):gsub("â", "a")
    s = string.gsub(s, "É", "E"):gsub("é", "e"):gsub("È", "E"):gsub("è", "e"):gsub("Ê", "E"):gsub("ê", "e")
    s = string.gsub(s, "Í", "I"):gsub("í", "i"):gsub("Ì", "I"):gsub("ì", "i"):gsub("Î", "I"):gsub("î", "i")
    s = string.gsub(s, "Ó", "O"):gsub("ó", "o"):gsub("Ò", "O"):gsub("ò", "o"):gsub("Ô", "O"):gsub("ô", "o")
    s = string.gsub(s, "Ú", "U"):gsub("ú", "u"):gsub("Ù", "U"):gsub("ù", "u"):gsub("Û", "U"):gsub("û", "u")
    s = string.gsub(s, "Ñ", "N"):gsub("ñ", "n"):gsub("Ç", "C"):gsub("ç", "c")
    return string.lower(s)
end

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
        local farm = g_farmManager:getFarmById(g_localPlayer.farmId)
        local moneyText = self.i18n:formatMoney(farm.money, 0, true, true)

        -- Clean Giants profile application
        if farm.money <= -1 then
            self.currentBalanceText:applyProfile(ShopMenu.GUI_PROFILE.SHOP_MONEY_NEGATIVE, nil, true)
        else
            self.currentBalanceText:applyProfile(ShopMenu.GUI_PROFILE.SHOP_MONEY, nil, true)
        end

        self.currentBalanceText:setText(moneyText)

        -- Dynamically resize the background box based on text length (Giants Native Method)
        if self.shopMoneyBox ~= nil then
            self.shopMoneyBox:invalidateLayout()
            if self.shopMoneyBoxBg ~= nil then
                self.shopMoneyBoxBg:setSize(self.shopMoneyBox.flowSizes[1] + 60 * g_pixelSizeScaledX)
            end
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

    -- Ensure local map prices reflect the latest difficulty and station prices before rendering on server/SP
    if g_currentMission:getIsServer() and gm.refreshMarketPrices ~= nil then
        gm:refreshMarketPrices(true)
    end

    -- Load and alphabetically sort market data by the client's active localized FillType title
    local rawMarketData = (gm:getIsMarketOnline() and gm.fillTypes ~= nil and #gm.fillTypes > 0) and gm.fillTypes or (gm.offlineMarketFillTypes or {})
    self.marketData = {}
    for _, item in ipairs(rawMarketData) do
        table.insert(self.marketData, item)
    end

    table.sort(self.marketData, function(a, b)
        local descA = a ~= nil and g_fillTypeManager:getFillTypeByName(a.fillType) or nil
        local descB = b ~= nil and g_fillTypeManager:getFillTypeByName(b.fillType) or nil
        local titleA = GlobalMarketUI.normalizeSortTitle(descA ~= nil and descA.title or (a and a.fillType or ""))
        local titleB = GlobalMarketUI.normalizeSortTitle(descB ~= nil and descB.title or (b and b.fillType or ""))
        if titleA == titleB then
            return tostring(a and a.fillType or "") < tostring(b and b.fillType or "")
        end
        return titleA < titleB
    end)

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:trace("UI Content refreshed. Storage items: %d, Market items: %d", #self.storageData, #self.marketData)
    end

    -- =========================================================================
    -- STATE SAVE & RESTORE (Fixes scroll jumping during live updates)
    -- =========================================================================

    -- 1. Enable the shield to prevent onListSelectionChanged from firing recursively
    self.isUpdatingSelection = true

    -- 2. Save current list focus and exact scroll/selection index
    local activeList = self.currentListFocus
    local activeIndex = 0

    if activeList == "storage" and self.gmTableStorage ~= nil then
        _, activeIndex = self.gmTableStorage:getSelectedPath()
    elseif activeList == "market" and self.gmTableMarket ~= nil then
        _, activeIndex = self.gmTableMarket:getSelectedPath()
    end

    -- 3. Blindly reload data (Engine tries to reset focus, but shield blocks the event)
    if self.gmTableStorage ~= nil then self.gmTableStorage:reloadData() end
    if self.gmTableMarket ~= nil then self.gmTableMarket:reloadData() end

    -- 4. Restore the exact previous state silently
    if activeList == "storage" and self.gmTableStorage ~= nil then
        -- Restore storage index, ensure it does not exceed current data length
        local safeIndex = math.min(activeIndex or 1, #self.storageData)
        if safeIndex > 0 then
            self.gmTableStorage:setSelectedIndex(safeIndex)
        end
        -- Keep market deselected visually
        if self.gmTableMarket ~= nil then self.gmTableMarket:setSelectedIndex(0) end
        -- Force the engine's FocusManager to explicitly re-target the active list
        FocusManager:setFocus(self.gmTableStorage)

    elseif activeList == "market" and self.gmTableMarket ~= nil then
        -- Restore market index, ensure it does not exceed current data length
        local safeIndex = math.min(activeIndex or 1, #self.marketData)
        if safeIndex > 0 then
            self.gmTableMarket:setSelectedIndex(safeIndex)
        end
        -- Keep storage deselected visually
        if self.gmTableStorage ~= nil then self.gmTableStorage:setSelectedIndex(0) end
        -- Force the engine's FocusManager to explicitly re-target the active list
        FocusManager:setFocus(self.gmTableMarket)

    end

    -- 5. Drop the shield so user inputs are processed normally again
    self.isUpdatingSelection = false
end

-- =========================================================================
-- NATIVE UI UPDATE LOOP
-- =========================================================================
function GlobalMarketUI:update(dt)
    GlobalMarketUI:superClass().update(self, dt)

    -- Handle the delayed refresh to prevent race conditions with engine updates
    if self.refreshCountdown > 0 then
        self.refreshCountdown = self.refreshCountdown - dt

        -- Trigger exactly ONCE when the countdown hits zero or falls slightly below
        if self.refreshCountdown <= 0 then
            -- Set to a permanent negative value to prevent the loop from refiring every frame
            self.refreshCountdown = -1
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

            -- Compare current market price against the neutral (1.0x) map baseline price for this difficulty/season
            local normalPrice = (data.normalPrice ~= nil and data.normalPrice > 0)
                and data.normalPrice
                or ((data.basePrice or 0.5) * 1000 * (EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil and EconomyManager.getPriceMultiplier() or 1))

            -- Trend detection with 5% threshold
            if data.price > (normalPrice * 1.05) then
                trend:applyProfile("globalMarketRowCellArrowClimbing")
            elseif data.price < (normalPrice * 0.95) then
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
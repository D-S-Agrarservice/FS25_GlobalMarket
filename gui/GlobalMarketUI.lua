-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketUI.lua
-- Main InGameMenu frame controller for storage/market lists, search, and category views.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketUI = {}
local GlobalMarketUI_mt = Class(GlobalMarketUI, TabbedMenuFrameElement)

function GlobalMarketUI.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or GlobalMarketUI_mt)

    self.rawStorageData = {}
    self.rawMarketData = {}
    self.storageData = {}
    self.marketData = {}
    self.storageSections = {}
    self.marketSections = {}

    self.searchFilterText = ""
    self.categoryMode = GlobalMarketUI.CATEGORY_MODE_DETAILED
    self.activeSubTab = 1

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

    if self.initContractsSubTab ~= nil then
        self:initContractsSubTab()
    end
    if self.initVehiclesSubTab ~= nil then
        self:initVehiclesSubTab()
    end
end

-- Returns the localized label for the currently active category mode
function GlobalMarketUI:getCategoryModeText()
    if self.categoryMode == GlobalMarketUI.CATEGORY_MODE_COMPACT then
        local text = self.i18n:getText("ui_gm_cat_mode_compact")
        return (text ~= nil and text ~= "ui_gm_cat_mode_compact") and text or "Categories: Compact"
    elseif self.categoryMode == GlobalMarketUI.CATEGORY_MODE_FLAT then
        local text = self.i18n:getText("ui_gm_cat_mode_flat")
        return (text ~= nil and text ~= "ui_gm_cat_mode_flat") and text or "Categories: Off (A-Z)"
    else
        local text = self.i18n:getText("ui_gm_cat_mode_detailed")
        return (text ~= nil and text ~= "ui_gm_cat_mode_detailed") and text or "Categories: Detailed"
    end
end

function GlobalMarketUI:updateCategoryModeButtonVisuals()
    local modeText = self:getCategoryModeText()
    if self.btnCategoryMode ~= nil then
        self.btnCategoryMode:setText(modeText)
    end
    if self.categoryModeButtonInfo ~= nil then
        self.categoryModeButtonInfo.text = modeText
        self:setMenuButtonInfoDirty()
    end
end

-- Initializes the UI state and bindings when the player opens the menu
function GlobalMarketUI:onFrameOpen()
    GlobalMarketUI:superClass().onFrameOpen(self)

    if self.searchTextInput ~= nil then
        self.searchTextInput:setText(self.searchFilterText or "")
    end

    local backButton = { inputAction = InputAction.MENU_BACK }
    self.actionButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = self.i18n:getText("ui_btn_sell") or "Sell",
        callback = function() self:onButtonAction() end,
        disabled = true
    }
    self.categoryModeButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = self:getCategoryModeText(),
        callback = function() self:onClickToggleCategoryMode() end,
        disabled = false
    }

    if self.onContractsFrameOpen ~= nil then
        self:onContractsFrameOpen()
    else
        self:setMenuButtonInfo({ backButton, self.actionButtonInfo, self.categoryModeButtonInfo })
        self:updateCategoryModeButtonVisuals()
        self:updateContent()

        if self.gmTableStorage ~= nil then
            FocusManager:setFocus(self.gmTableStorage)
        end
    end
end

-- Filters, sorts alphabetically, and groups raw items into SmoothList sections
function GlobalMarketUI:buildSectionsForData(rawItems)
    local filteredItems = {}
    local normalizedQuery = GlobalMarketUI.normalizeSortTitle(self.searchFilterText or "")
    local hasQuery = (normalizedQuery ~= "")

    for _, item in ipairs(rawItems or {}) do
        if item ~= nil then
            local desc = g_fillTypeManager:getFillTypeByName(item.fillType)
            local localizedTitle = (desc ~= nil and desc.title) or item.fillType or ""

            if not hasQuery then
                table.insert(filteredItems, item)
            else
                local normTitle = GlobalMarketUI.normalizeSortTitle(localizedTitle)
                local normInternal = GlobalMarketUI.normalizeSortTitle(item.fillType or "")
                if string.find(normTitle, normalizedQuery, 1, true) ~= nil
                    or string.find(normInternal, normalizedQuery, 1, true) ~= nil then
                    table.insert(filteredItems, item)
                end
            end
        end
    end

    -- Sort alphabetically by localized title (with umlaut/accent normalization)
    table.sort(filteredItems, function(a, b)
        local descA = a ~= nil and g_fillTypeManager:getFillTypeByName(a.fillType) or nil
        local descB = b ~= nil and g_fillTypeManager:getFillTypeByName(b.fillType) or nil
        local titleA = GlobalMarketUI.normalizeSortTitle(descA ~= nil and descA.title or (a and a.fillType or ""))
        local titleB = GlobalMarketUI.normalizeSortTitle(descB ~= nil and descB.title or (b and b.fillType or ""))
        if titleA == titleB then
            return tostring(a and a.fillType or "") < tostring(b and b.fillType or "")
        end
        return titleA < titleB
    end)

    local sections = {}

    if self.categoryMode == GlobalMarketUI.CATEGORY_MODE_FLAT then
        if #filteredItems > 0 then
            table.insert(sections, { title = nil, items = filteredItems })
        end
        return sections, filteredItems
    end

    local catDefs = (self.categoryMode == GlobalMarketUI.CATEGORY_MODE_COMPACT)
        and GlobalMarketUI.COMPACT_CATEGORIES
        or GlobalMarketUI.DETAILED_CATEGORIES

    local buckets = {}
    for i = 1, #catDefs do
        buckets[i] = {}
    end

    for _, item in ipairs(filteredItems) do
        local catIndex
        if self.categoryMode == GlobalMarketUI.CATEGORY_MODE_COMPACT then
            catIndex = GlobalMarketUI.getCompactCategoryIndex(item.fillType)
        else
            catIndex = GlobalMarketUI.getDetailedCategoryIndex(item.fillType)
        end
        catIndex = math.clamp(catIndex or 1, 1, #catDefs)
        table.insert(buckets[catIndex], item)
    end

    for i, def in ipairs(catDefs) do
        local bucketItems = buckets[i]
        if #bucketItems > 0 then
            local catTitle = self.i18n:getText(def.l10n)
            if catTitle == nil or catTitle == def.l10n then
                catTitle = def.fallback
            end
            table.insert(sections, {
                id = def.id,
                title = catTitle,
                items = bucketItems
            })
        end
    end

    return sections, filteredItems
end

-- Finds the (section, index) of a given fillType in a sections table, or returns the first available item
function GlobalMarketUI.findSelectionInSections(sections, preferredFillType, fallbackSection, fallbackIndex)
    if sections == nil or #sections == 0 then
        return 0, 0
    end

    if preferredFillType ~= nil then
        for sIdx, sec in ipairs(sections) do
            for iIdx, item in ipairs(sec.items) do
                if item.fillType == preferredFillType then
                    return sIdx, iIdx
                end
            end
        end
    end

    local safeSection = math.clamp(fallbackSection or 1, 1, #sections)
    local secItems = sections[safeSection].items
    if secItems ~= nil and #secItems > 0 then
        local safeIndex = math.clamp(fallbackIndex or 1, 1, #secItems)
        return safeSection, safeIndex
    end

    return 1, 1
end

-- Applies current search filter and category grouping to rawStorageData & rawMarketData and reloads both SmoothLists
function GlobalMarketUI:applyFilterAndCategories(restoreTableFocus)
    if restoreTableFocus == nil then
        restoreTableFocus = true
    end

    -- 1. Enable the shield to prevent onListSelectionChanged from firing recursively
    self.isUpdatingSelection = true

    -- 2. Save current list focus, selected path, and selected fillType before rebuilding sections
    local activeList = self.currentListFocus
    local activeSection, activeIndex = 1, 0
    local activeFillType = nil

    if activeList == "storage" and self.gmTableStorage ~= nil then
        activeSection, activeIndex = self.gmTableStorage:getSelectedPath()
        if self.storageSections[activeSection] ~= nil and self.storageSections[activeSection].items ~= nil then
            local curItem = self.storageSections[activeSection].items[activeIndex]
            activeFillType = curItem and curItem.fillType or nil
        end
    elseif activeList == "market" and self.gmTableMarket ~= nil then
        activeSection, activeIndex = self.gmTableMarket:getSelectedPath()
        if self.marketSections[activeSection] ~= nil and self.marketSections[activeSection].items ~= nil then
            local curItem = self.marketSections[activeSection].items[activeIndex]
            activeFillType = curItem and curItem.fillType or nil
        end
    end

    -- 3. Build filtered and categorized sections
    self.storageSections, self.storageData = self:buildSectionsForData(self.rawStorageData)
    self.marketSections, self.marketData = self:buildSectionsForData(self.rawMarketData)

    -- 4. Reload SmoothList data
    if self.gmTableStorage ~= nil then self.gmTableStorage:reloadData() end
    if self.gmTableMarket ~= nil then self.gmTableMarket:reloadData() end

    -- 5. Restore selection state
    local hasValidSelection = false
    local selectedStorageRow = nil

    if activeList == "storage" and self.gmTableStorage ~= nil then
        local newSec, newIdx = GlobalMarketUI.findSelectionInSections(self.storageSections, activeFillType, activeSection, activeIndex)
        if newSec > 0 and newIdx > 0 then
            self.gmTableStorage:setSelectedItem(newSec, newIdx)
            hasValidSelection = true
            selectedStorageRow = self.storageSections[newSec].items[newIdx]
        else
            self.gmTableStorage:setSelectedItem(1, 0)
            self.gmTableStorage:clearElementSelection()
        end
        if self.gmTableMarket ~= nil then
            self.gmTableMarket:setSelectedItem(1, 0)
            self.gmTableMarket:clearElementSelection()
        end
        if restoreTableFocus and self:getIsVisible() and FocusManager:getFocusedElement() ~= self.searchTextInput then
            FocusManager:setFocus(self.gmTableStorage)
        end

    elseif activeList == "market" and self.gmTableMarket ~= nil then
        local newSec, newIdx = GlobalMarketUI.findSelectionInSections(self.marketSections, activeFillType, activeSection, activeIndex)
        if newSec > 0 and newIdx > 0 then
            self.gmTableMarket:setSelectedItem(newSec, newIdx)
            hasValidSelection = true
        else
            self.gmTableMarket:setSelectedItem(1, 0)
            self.gmTableMarket:clearElementSelection()
        end
        if self.gmTableStorage ~= nil then
            self.gmTableStorage:setSelectedItem(1, 0)
            self.gmTableStorage:clearElementSelection()
        end
        if restoreTableFocus and self:getIsVisible() and FocusManager:getFocusedElement() ~= self.searchTextInput then
            FocusManager:setFocus(self.gmTableMarket)
        end
    end

    if self.actionButtonInfo ~= nil then
        self.actionButtonInfo.text = (activeList == "storage")
            and (self.i18n:getText("ui_btn_sell") or "Sell")
            or (self.i18n:getText("ui_btn_buy") or "Buy")
        self.actionButtonInfo.disabled = not hasValidSelection
        self:setMenuButtonInfoDirty()
    end

    GlobalMarketStorageAge.updateSelectionHint(self, selectedStorageRow)

    -- 6. Drop the shield so user inputs are processed normally again
    self.isUpdatingSelection = false
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

    -- Update Online/Offline Status Header & 3-Tier Market Branding (Name + Local Logo)
    if GlobalMarketBranding ~= nil then
        GlobalMarketBranding.updateMenuHeader(self, gm)
    end

    local farmId = g_currentMission:getFarmId()

    -- Load storage data
    self.rawStorageData = gm:getAggregatedStorageData(farmId) or {}

    -- Calculate total volume for footer display (across all owned storage items)
    local totalVolume = 0
    for _, data in ipairs(self.rawStorageData) do
        totalVolume = totalVolume + (data.level or 0)
    end
    if self.totalStorageDisplay ~= nil then
        self.totalStorageDisplay:setText(self.i18n:formatVolume(totalVolume, 0))
    end

    -- Ensure local map prices reflect the latest difficulty and station prices before rendering on server/SP
    if g_currentMission:getIsServer() and gm.refreshMarketPrices ~= nil then
        gm:refreshMarketPrices(true)
    end

    -- Load raw market data
    local sourceMarketData = (gm:getIsMarketOnline() and gm.fillTypes ~= nil and #gm.fillTypes > 0) and gm.fillTypes or (gm.offlineMarketFillTypes or {})
    self.rawMarketData = {}
    for _, item in ipairs(sourceMarketData) do
        table.insert(self.rawMarketData, item)
    end

    self:applyFilterAndCategories(true)
    if self.updateContractsSubTabContent ~= nil then self:updateContractsSubTabContent() end
    if self.updateVehiclesSubTabContent ~= nil then self:updateVehiclesSubTabContent() end

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:trace("UI Content refreshed. Storage items: %d (%d sections), Market items: %d (%d sections)",
            #self.storageData, #self.storageSections, #self.marketData, #self.marketSections)
    end
end

-- =========================================================================
-- SEARCH & CATEGORY TOOLBAR CALLBACKS
-- =========================================================================

function GlobalMarketUI:onSearchTextChanged(element, text)
    self.searchFilterText = text or ""
    self:applyFilterAndCategories(false)
    self:applySubTabSearch(false)
end

function GlobalMarketUI:onSearchEnterPressed(element)
    local targetList = self:getSubTabFocusList()
    if targetList ~= nil then FocusManager:setFocus(targetList) end
end

function GlobalMarketUI:onClickClearSearch()
    self.searchFilterText = ""
    if self.searchTextInput ~= nil then
        self.searchTextInput:setText("")
    end
    self:applyFilterAndCategories(true)
    self:applySubTabSearch(true)
end

function GlobalMarketUI:onClickToggleCategoryMode()
    if self.categoryMode == GlobalMarketUI.CATEGORY_MODE_DETAILED then
        self.categoryMode = GlobalMarketUI.CATEGORY_MODE_COMPACT
    elseif self.categoryMode == GlobalMarketUI.CATEGORY_MODE_COMPACT then
        self.categoryMode = GlobalMarketUI.CATEGORY_MODE_FLAT
    else
        self.categoryMode = GlobalMarketUI.CATEGORY_MODE_DETAILED
    end

    self:updateCategoryModeButtonVisuals()
    self:applyFilterAndCategories(true)
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
    if list == self.gmTableStorage then return #self.storageSections end
    if list == self.gmTableMarket then return #self.marketSections end
    return 0
end

function GlobalMarketUI:getTitleForSectionHeader(list, section)
    local sections = (list == self.gmTableStorage) and self.storageSections or self.marketSections
    local sec = sections and sections[section]
    return sec and sec.title or nil
end

function GlobalMarketUI:getNumberOfItemsInSection(list, section)
    local sections = (list == self.gmTableStorage) and self.storageSections or self.marketSections
    local sec = sections and sections[section]
    return sec and #sec.items or 0
end

-- Populates each row in the storage and market lists
-- Handles HUD icons and dynamic price trend arrows based on normalPrice comparison
function GlobalMarketUI:populateCellForItemInSection(list, section, index, cell)
    local sections = (list == self.gmTableStorage) and self.storageSections or self.marketSections
    local sec = sections and sections[section]
    local data = sec and sec.items[index]
    if not data then return end

    local icon = cell:getAttribute("icon")
    local name = cell:getAttribute("name")
    local amount = cell:getAttribute("amount")
    local price = cell:getAttribute("price")
    local trend = cell:getAttribute("trend")

    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil

    if name and fillTypeDesc then
        local displayTitle = fillTypeDesc.title or data.fillType
        name:setTextColor(1, 1, 1, 1)

        if list == self.gmTableMarket and gm ~= nil and gm:getIsMarketOnline() then
            local onlineStatus = data.onlineStatus or (gm.getFillTypeOnlineStatus ~= nil and gm:getFillTypeOnlineStatus(data.fillType)) or "PENDING"
            if onlineStatus == "REJECTED" then
                local suffix = self.i18n:hasText("ui_gm_online_rejected_short") and self.i18n:getText("ui_gm_online_rejected_short") or "(Offline only)"
                displayTitle = string.format("%s %s", displayTitle, suffix)
                name:setTextColor(0.72, 0.72, 0.72, 1.0)
            elseif onlineStatus ~= "APPROVED" then
                local suffix = self.i18n:hasText("ui_gm_online_pending_short") and self.i18n:getText("ui_gm_online_pending_short") or "(Pending)"
                displayTitle = string.format("%s %s", displayTitle, suffix)
                name:setTextColor(1.0, 0.82, 0.45, 1.0)
            end
        end

        name:setText(displayTitle)
    end

    -- Icon logic for both lists
    if icon and fillTypeDesc then
        icon:setImageFilename(fillTypeDesc.hudOverlayFilename)
    end
    GlobalMarketStorageAge.decorateCell(cell, (list == self.gmTableStorage) and data or nil)

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

            -- Great Demand (blue arrow) or Trend detection with 5% threshold
            local gdThreshold = (GlobalMarketOffline ~= nil and GlobalMarketOffline.GREAT_DEMAND_THRESHOLD) or 1.25
            local isGreatDemand = (data.isGreatDemand == true) or (normalPrice > 0 and data.price >= (normalPrice * (gdThreshold - 0.001)))
            if isGreatDemand then
                trend:applyProfile("globalMarketRowCellArrowGreatDemand")
            elseif data.price > (normalPrice * 1.05) then
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
        if self.gmTableMarket then
            self.gmTableMarket:setSelectedItem(1, 0)
            self.gmTableMarket:clearElementSelection()
        end
    else
        self.currentListFocus = "market"
        if self.actionButtonInfo ~= nil then
            self.actionButtonInfo.text = self.i18n:getText("ui_btn_buy") or "Buy"
        end
        if self.gmTableStorage then
            self.gmTableStorage:setSelectedItem(1, 0)
            self.gmTableStorage:clearElementSelection()
        end
    end

    local sections = (self.currentListFocus == "storage") and self.storageSections or self.marketSections
    local hasValidItem = (section ~= nil and index ~= nil and section > 0 and index > 0
        and sections[section] ~= nil and sections[section].items ~= nil and sections[section].items[index] ~= nil)
    local selectedItem = hasValidItem and sections[section].items[index] or nil
    if self.currentListFocus == "market" then
        GlobalMarketMapPriceHint.updateSelectionHint(self, selectedItem)
    else
        GlobalMarketStorageAge.updateSelectionHint(self, selectedItem)
    end

    if self.actionButtonInfo ~= nil then
        self.actionButtonInfo.disabled = not hasValidItem
        self:setMenuButtonInfoDirty()
    end

    self.isUpdatingSelection = false
end

-- Triggered when the user clicks 'Buy' or 'Sell', OR via double-click on a table row
function GlobalMarketUI:onButtonAction(list, section, index)
    local gm = g_currentMission.globalMarket

    -- If triggered via double-click, we get the list, section, and index directly.
    -- If triggered via the button, we fall back to the currently focused list.
    local targetList = list or ((self.currentListFocus == "storage") and self.gmTableStorage or self.gmTableMarket)
    local targetSection = section
    local targetIndex = index

    -- If no index was passed (button click), get the selected path from the list
    if targetIndex == nil or targetSection == nil then
        targetSection, targetIndex = targetList:getSelectedPath()
    else
        -- If it was a double-click, ensure the UI state updates to the clicked list
        if targetList == self.gmTableStorage then
            self:onListSelectionChanged(self.gmTableStorage, targetSection, targetIndex)
        else
            self:onListSelectionChanged(self.gmTableMarket, targetSection, targetIndex)
        end
    end

    local sections = (self.currentListFocus == "storage") and self.storageSections or self.marketSections
    local sec = sections and sections[targetSection]
    local data = sec and sec.items and sec.items[targetIndex] or nil

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
            local dialogTitle = (fillTypeDesc ~= nil and fillTypeDesc.title) or data.fillType
            if gm:getIsMarketOnline() then
                local onlineStatus = (gm.getFillTypeOnlineStatus ~= nil and gm:getFillTypeOnlineStatus(data.fillType)) or data.onlineStatus
                if onlineStatus == "REJECTED" then
                    local tag = self.i18n:hasText("ui_gm_online_rejected_dialog") and self.i18n:getText("ui_gm_online_rejected_dialog") or "(Offline only)"
                    dialogTitle = string.format("%s %s", dialogTitle, tag)
                elseif onlineStatus ~= nil and onlineStatus ~= "APPROVED" then
                    local tag = self.i18n:hasText("ui_gm_online_pending_dialog") and self.i18n:getText("ui_gm_online_pending_dialog") or "(Pending review / Offline)"
                    dialogTitle = string.format("%s %s", dialogTitle, tag)
                end
            end

            -- Calls the popup dialog to select the specific storage and amount
            gm.dialog:show(self, self.onDialogResult, actionType, dialogTitle, data.fillType, data.price, silos)
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

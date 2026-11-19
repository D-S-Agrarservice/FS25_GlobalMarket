-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehiclesUI.lua
-- Sub-tab controller for the used vehicle market (#16): own vehicles & listings (left),
-- market listings grouped by store category type (right), footer actions and hints.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketVehiclesUI = {}
GlobalMarketVehiclesUI.activeUi = nil

GlobalMarketUI.VEHICLE_SORT_PRICE = 1
GlobalMarketUI.VEHICLE_SORT_HOURS = 2
GlobalMarketUI.VEHICLE_SORT_AGE   = 3
GlobalMarketUI.VEHICLE_SORT_KEYS = {
    "ui_gm_vehicles_sort_price", "ui_gm_vehicles_sort_hours", "ui_gm_vehicles_sort_age"
}

local COLOR_ACTIVE_TAB_TEXT = { 0.004, 0.005, 0.004, 1 }
local COLOR_WHITE_TEXT      = { 1, 1, 1, 1 }
local COLOR_BARGAIN         = { 0.46, 0.80, 0.15, 1 }
local COLOR_MARKUP          = { 0.95, 0.68, 0.20, 1 }
local COLOR_BLOCKED         = { 0.92, 0.28, 0.22, 1 }
local COLOR_MUTED           = { 0.65, 0.67, 0.70, 1 }

-- =========================================================================
-- SETUP & SUB-TAB INTEGRATION
-- =========================================================================

---Binds the vehicle lists to GlobalMarketVehiclesUI (called from onGuiSetupFinished)
function GlobalMarketUI:initVehiclesSubTab()
    GlobalMarketVehiclesUI.activeUi = self
    self.vehicleListFocus = "left"
    self.vehicleSortMode = self.vehicleSortMode or GlobalMarketUI.VEHICLE_SORT_PRICE
    self.myVehicleSections = {}
    self.marketVehicleSections = {}
    for _, list in ipairs({ self.gmTableMyVehicles, self.gmTableVehicleMarket }) do
        if list ~= nil then
            list:setDataSource(GlobalMarketVehiclesUI)
            list:setDelegate(GlobalMarketVehiclesUI)
        end
    end
end

---Creates the footer button infos of the vehicles sub-tab (called on frame open)
function GlobalMarketUI:initVehiclesButtonInfos()
    self.vehiclesPrimaryButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = self.i18n:getText("ui_gm_vehicles_action_list"),
        callback = function() self:onVehiclePrimaryAction() end,
        disabled = true
    }
    self.vehiclesCancelButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = self.i18n:getText("ui_gm_vehicles_action_withdraw"),
        callback = function() self:onVehicleCancelAction() end,
        disabled = false
    }
    self.vehiclesSortButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = self:getVehicleSortText(),
        callback = function() self:onClickCycleVehicleSort() end,
        disabled = false
    }
end

---Shows or hides the vehicles container and styles its sub-tab button
---@param isVehicles boolean
function GlobalMarketUI:applyVehiclesSubTabVisuals(isVehicles)
    if self.subTabVehiclesContainer ~= nil then self.subTabVehiclesContainer:setVisible(isVehicles) end
    if self.bgSubTabVehiclesActive ~= nil then self.bgSubTabVehiclesActive:setVisible(isVehicles) end
    if self.bgSubTabVehiclesInactive ~= nil then self.bgSubTabVehiclesInactive:setVisible(not isVehicles) end
    if self.btnSubTabVehicles ~= nil then
        local col = isVehicles and COLOR_ACTIVE_TAB_TEXT or COLOR_WHITE_TEXT
        self.btnSubTabVehicles:setTextColor(col[1], col[2], col[3], col[4])
    end
end

function GlobalMarketUI:onClickSubTabVehicles()
    self:setActiveSubTab(GlobalMarketUI.SUBTAB_VEHICLES, true)
end

---Re-applies the search text to the list of the active sub-tab
---@param allowListFocus boolean
function GlobalMarketUI:applySubTabSearch(allowListFocus)
    if self.activeSubTab == GlobalMarketUI.SUBTAB_CONTRACTS and self.applyContractsListsFilter ~= nil then
        self:applyContractsListsFilter(allowListFocus)
    elseif self.activeSubTab == GlobalMarketUI.SUBTAB_VEHICLES then
        self:applyVehicleListsFilter(allowListFocus)
    end
end

---Returns the list that should receive focus in the active sub-tab
---@return table|nil list
function GlobalMarketUI:getSubTabFocusList()
    if self.activeSubTab == GlobalMarketUI.SUBTAB_VEHICLES then
        return (self.vehicleListFocus == "right") and self.gmTableVehicleMarket or self.gmTableMyVehicles
    elseif self.activeSubTab == GlobalMarketUI.SUBTAB_CONTRACTS then
        return (self.contractsListFocus == "right") and self.gmTableContractBoard or self.gmTableMyContracts
    end
    return (self.currentListFocus == "storage") and self.gmTableStorage or self.gmTableMarket
end

function GlobalMarketUI:updateVehiclesSubTabContent()
    if self.activeSubTab == GlobalMarketUI.SUBTAB_VEHICLES then
        self:applyVehicleListsFilter(false)
    end
end

---Called by GlobalMarket whenever the synced listing state changed
function GlobalMarketUI:onVehicleMarketChanged()
    if self:getIsVisible() and self.activeSubTab == GlobalMarketUI.SUBTAB_VEHICLES then
        self:applyVehicleListsFilter(false)
    end
end

-- =========================================================================
-- FORMATTING HELPERS
-- =========================================================================

function GlobalMarketUI:getVehicleSortText()
    return self.i18n:getText(GlobalMarketUI.VEHICLE_SORT_KEYS[self.vehicleSortMode or 1])
end

---Returns the store item of a (network) xml filename
local function getStoreItem(xmlFilename)
    if xmlFilename == nil then
        return nil
    end
    return g_storeManager:getItemByXMLFilename(NetworkUtil.convertFromNetworkFilename(xmlFilename))
end

---Returns the short condition text "123 h | 14 mo."
function GlobalMarketUI:formatVehicleConditionShort(snapshot)
    return string.format(self.i18n:getText("ui_gm_vehicles_condition_short"),
        (snapshot.operatingTime or 0) / 3600000, snapshot.age or 0)
end

---Returns the full condition text incl. damage and wear
function GlobalMarketUI:formatVehicleConditionFull(snapshot)
    return string.format(self.i18n:getText("ui_gm_vehicles_condition_full"),
        (snapshot.operatingTime or 0) / 3600000, snapshot.age or 0,
        math.floor((snapshot.damage or 0) * 100 + 0.5), math.floor((snapshot.wear or 0) * 100 + 0.5))
end

---Returns the color of a price factor (bargain / markup / neutral)
local function getPriceFactorColor(priceFactor)
    if priceFactor < 0.95 then
        return COLOR_BARGAIN
    elseif priceFactor > 1.05 then
        return COLOR_MARKUP
    end
    return COLOR_WHITE_TEXT
end

---Returns the status text of an own listing
function GlobalMarketUI:getVehicleListingStatusText(listing)
    local S = GlobalMarket.VEHICLE_LISTING_STATUS
    if listing.status == S.BUYING then
        return self.i18n:getText("ui_gm_vehicles_status_buying")
    elseif listing.status == S.RETURN_PENDING then
        return self.i18n:getText("ui_gm_vehicles_status_returnPending")
    end
    return string.format(self.i18n:getText("ui_gm_vehicles_status_open"),
        string.format(self.i18n:getText("ui_gm_months_short"), math.max(0, listing.monthsRemaining or 0)))
end

-- =========================================================================
-- LIST BUILDING
-- =========================================================================

---Returns true if a text matches the shared search field
function GlobalMarketUI:matchesVehicleQuery(text)
    local q = GlobalMarketUI.normalizeSortTitle(self.searchFilterText or "")
    return q == "" or string.find(GlobalMarketUI.normalizeSortTitle(text or ""), q, 1, true) ~= nil
end

---Returns a comparable key of a row (kind + listing ID or vehicle object)
local function getRowKey(row)
    if row == nil or row.data == nil then
        return nil
    end
    if row.kind == "MY_VEHICLE" then
        return row.data.vehicle
    end
    return row.data.id
end

---Rebuilds both vehicle lists from the synced listings and the farm's vehicles
---@param allowListFocus boolean
function GlobalMarketUI:applyVehicleListsFilter(allowListFocus)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if gm == nil then
        return
    end

    local isRight = (self.vehicleListFocus == "right")
    local activeList = isRight and self.gmTableVehicleMarket or self.gmTableMyVehicles
    local activeSections = isRight and self.marketVehicleSections or self.myVehicleSections
    local activeSec, activeIdx = 1, 0
    if activeList ~= nil then
        activeSec, activeIdx = activeList:getSelectedPath()
    end
    local curRow = activeSections[activeSec] and activeSections[activeSec].items[activeIdx] or nil
    local activeKind, activeKey = curRow ~= nil and curRow.kind or nil, getRowKey(curRow)

    -- Left: own listings and own vehicles
    local myListings, myVehicles, marketByGroup = {}, {}, {}
    local marketCount = 0
    for _, listing in ipairs(gm.vehicleListings or {}) do
        local name = GlobalMarketVehicleListings.getDisplayName(listing.snapshot.xmlFilename)
        if not listing.isNpc and listing.sellerFarmId == farmId then
            if self:matchesVehicleQuery(name) then
                table.insert(myListings, { kind = "MY_LISTING", data = listing, name = name,
                    price = GlobalMarketVehicleListings.getListingPrice(listing) })
            end
        elseif listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.OPEN then
            local resolved = GlobalMarketVehicleListings.resolveSnapshot(listing.snapshot)
            if resolved ~= nil and self:matchesVehicleQuery(name) then
                local value = GlobalMarketVehicleListings.getDealerValue(listing.snapshot, resolved)
                local group = listing.snapshot.group or "MISC"
                marketByGroup[group] = marketByGroup[group] or {}
                table.insert(marketByGroup[group], { kind = "MARKET_LISTING", data = listing, name = name,
                    value = value, price = math.floor(value * (listing.priceFactor or 1) + 0.5), storeItem = resolved.storeItem })
                marketCount = marketCount + 1
            end
        end
    end
    for _, vehicle in ipairs(gm:getVehicleMarketFarmVehicles(farmId)) do
        local name = (vehicle.getFullName ~= nil) and vehicle:getFullName() or tostring(vehicle.configFileName)
        if self:matchesVehicleQuery(name) then
            local isEligible, reason = GlobalMarketVehicleListings.getEligibility(vehicle, farmId, nil)
            local snapshot = GlobalMarketVehicleListings.captureSnapshot(vehicle)
            local resolved = (snapshot ~= nil) and GlobalMarketVehicleListings.resolveSnapshot(snapshot) or nil
            table.insert(myVehicles, { kind = "MY_VEHICLE", name = name,
                data = { vehicle = vehicle, isEligible = isEligible, reason = reason, snapshot = snapshot,
                    value = (resolved ~= nil) and GlobalMarketVehicleListings.getDealerValue(snapshot, resolved) or 0 } })
        end
    end
    table.sort(myVehicles, function(a, b) return a.name < b.name end)

    self.myVehicleSections = {}
    if #myListings > 0 then
        table.insert(self.myVehicleSections, { title = self.i18n:getText("ui_gm_vehicles_sec_myListings"), items = myListings })
    end
    if #myVehicles > 0 then
        table.insert(self.myVehicleSections, { title = self.i18n:getText("ui_gm_vehicles_sec_myVehicles"), items = myVehicles })
    end
    if #self.myVehicleSections == 0 then
        table.insert(self.myVehicleSections, { title = nil, items = { { kind = "EMPTY_MY" } } })
    end

    -- Right: market listings per group, sorted by the chosen mode
    local sortMode = self.vehicleSortMode or GlobalMarketUI.VEHICLE_SORT_PRICE
    local function compare(a, b)
        local sa, sb = a.data.snapshot, b.data.snapshot
        if sortMode == GlobalMarketUI.VEHICLE_SORT_HOURS and sa.operatingTime ~= sb.operatingTime then
            return (sa.operatingTime or 0) < (sb.operatingTime or 0)
        elseif sortMode == GlobalMarketUI.VEHICLE_SORT_AGE and sa.age ~= sb.age then
            return (sa.age or 0) < (sb.age or 0)
        elseif a.price ~= b.price then
            return a.price < b.price
        end
        return a.data.id < b.data.id
    end
    self.marketVehicleSections = {}
    for _, group in ipairs(GlobalMarketVehicleListings.GROUP_ORDER) do
        local items = marketByGroup[group]
        if items ~= nil and #items > 0 then
            table.sort(items, compare)
            table.insert(self.marketVehicleSections, { title = GlobalMarketVehicleListings.getGroupTitle(group), items = items })
        end
    end
    if #self.marketVehicleSections == 0 then
        table.insert(self.marketVehicleSections, { title = nil, items = { { kind = "EMPTY_MARKET" } } })
    end

    if self.myVehiclesSubtitle ~= nil then
        self.myVehiclesSubtitle:setText(string.format(self.i18n:getText("ui_gm_vehicles_mySub"),
            #myListings, GlobalMarket.VEHICLE_MARKET.MAX_PER_FARM, #myVehicles))
    end
    if self.marketVehiclesSubtitle ~= nil then
        self.marketVehiclesSubtitle:setText(string.format(self.i18n:getText("ui_gm_vehicles_marketSub"), marketCount))
    end
    if self.btnVehicleSort ~= nil then
        self.btnVehicleSort:setText(self:getVehicleSortText())
    end

    self.isUpdatingSelection = true
    local wasSearchFocused = (self.searchTextInput ~= nil and FocusManager:getFocusedElement() == self.searchTextInput)
    if self.gmTableMyVehicles ~= nil then self.gmTableMyVehicles:reloadData() end
    if self.gmTableVehicleMarket ~= nil then self.gmTableVehicleMarket:reloadData() end
    self:restoreVehicleListSelection(activeKind, activeKey, activeSec, activeIdx, allowListFocus and not wasSearchFocused)
    if wasSearchFocused and self.searchTextInput ~= nil then
        FocusManager:setFocus(self.searchTextInput)
    end
    self.isUpdatingSelection = false
    self:updateActiveSubTabMenuButtons()
end

---Restores the selection after a rebuild (same row if it still exists, otherwise the same position)
function GlobalMarketUI:restoreVehicleListSelection(kind, key, sec, idx, setFocus)
    local isRight = (self.vehicleListFocus == "right")
    local list = isRight and self.gmTableVehicleMarket or self.gmTableMyVehicles
    local otherList = isRight and self.gmTableMyVehicles or self.gmTableVehicleMarket
    local sections = isRight and self.marketVehicleSections or self.myVehicleSections
    if list == nil then
        return
    end
    local newSec, newIdx = 0, 0
    if kind ~= nil and key ~= nil then
        for sIdx, section in ipairs(sections) do
            for iIdx, row in ipairs(section.items) do
                if row.kind == kind and getRowKey(row) == key then
                    newSec, newIdx = sIdx, iIdx
                end
            end
        end
    end
    if newSec == 0 and #sections > 0 then
        newSec = math.clamp(sec or 1, 1, #sections)
        newIdx = math.clamp(idx or 1, 1, math.max(1, #sections[newSec].items))
    end
    list:setSelectedItem(math.max(1, newSec), math.max(1, newIdx))
    if otherList ~= nil then
        otherList:setSelectedItem(1, 0)
        otherList:clearElementSelection()
    end
    if setFocus and self:getIsVisible() then
        FocusManager:setFocus(list)
    end
end

---Returns the selected row of the focused vehicle list
function GlobalMarketUI:getSelectedVehicleRow(overrideSection, overrideIndex)
    local isRight = (self.vehicleListFocus == "right")
    local list = isRight and self.gmTableVehicleMarket or self.gmTableMyVehicles
    local sections = isRight and self.marketVehicleSections or self.myVehicleSections
    local sec, idx = overrideSection, overrideIndex
    if (sec == nil or idx == nil) and list ~= nil then
        sec, idx = list:getSelectedPath()
    end
    return sections[sec] and sections[sec].items and sections[sec].items[idx] or nil
end

-- =========================================================================
-- FOOTER BUTTONS & HINT
-- =========================================================================

function GlobalMarketUI:updateVehiclesMenuButtons()
    local row = self:getSelectedVehicleRow()
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    local isSpectator = (farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID)
    local list = { { inputAction = InputAction.MENU_BACK } }

    if self.vehiclesPrimaryButtonInfo ~= nil and row ~= nil and not isSpectator then
        if row.kind == "MY_VEHICLE" then
            self.vehiclesPrimaryButtonInfo.text = self.i18n:getText("ui_gm_vehicles_action_list")
            self.vehiclesPrimaryButtonInfo.disabled = not row.data.isEligible
            table.insert(list, self.vehiclesPrimaryButtonInfo)
        elseif row.kind == "MARKET_LISTING" then
            self.vehiclesPrimaryButtonInfo.text = self.i18n:getText("ui_gm_vehicles_action_buy")
            self.vehiclesPrimaryButtonInfo.disabled = false
            table.insert(list, self.vehiclesPrimaryButtonInfo)
        end
    end
    if self.switchSubTabButtonInfo ~= nil then
        table.insert(list, self.switchSubTabButtonInfo)
    end
    if self.vehiclesSortButtonInfo ~= nil then
        self.vehiclesSortButtonInfo.text = self:getVehicleSortText()
        table.insert(list, self.vehiclesSortButtonInfo)
    end
    if self.vehiclesCancelButtonInfo ~= nil and row ~= nil and row.kind == "MY_LISTING" and not isSpectator
        and row.data.status == GlobalMarket.VEHICLE_LISTING_STATUS.OPEN then
        table.insert(list, self.vehiclesCancelButtonInfo)
    end
    self:setMenuButtonInfo(list)
    self:setMenuButtonInfoDirty()
    self:updateVehicleSelectionHint(row)
end

function GlobalMarketUI:updateVehicleSelectionHint(row)
    if self.vehiclesSelectionHint == nil then
        return
    end
    local text = ""
    if row ~= nil and row.kind == "MY_VEHICLE" then
        if row.data.isEligible then
            text = string.format(self.i18n:getText("ui_gm_vehicles_hint_vehicle"), row.name,
                self.i18n:formatMoney(row.data.value, 0, true, true))
        else
            text = string.format("%s | %s", row.name, GlobalMarket.getVehicleMarketReasonText(row.data.reason or "invalid"))
        end
    elseif row ~= nil and (row.kind == "MY_LISTING" or row.kind == "MARKET_LISTING") then
        local listing = row.data
        local priceText = (row.price ~= nil) and self.i18n:formatMoney(row.price, 0, true, true) or "-"
        text = string.format(self.i18n:getText("ui_gm_vehicles_hint_listing"), row.name,
            listing.isNpc and self.i18n:getText("ui_gm_vehicles_npcSeller") or tostring(listing.sellerName),
            self:formatVehicleConditionFull(listing.snapshot), priceText,
            math.floor((listing.priceFactor or 1) * 100 + 0.5),
            string.format(self.i18n:getText("ui_gm_months_short"), math.max(0, listing.monthsRemaining or 0)))
    end
    self.vehiclesSelectionHint:setText(text)
end

-- =========================================================================
-- ACTIONS
-- =========================================================================

function GlobalMarketUI:onClickCycleVehicleSort()
    self.vehicleSortMode = (self.vehicleSortMode or 1) % #GlobalMarketUI.VEHICLE_SORT_KEYS + 1
    self:applyVehicleListsFilter(false)
end

---Primary action: list an own vehicle (dialog) or buy a market listing (confirmation)
function GlobalMarketUI:onVehiclePrimaryAction(overrideSection, overrideIndex)
    local row = self:getSelectedVehicleRow(overrideSection, overrideIndex)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if row == nil or gm == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end
    if row.kind == "MY_VEHICLE" then
        if not row.data.isEligible then
            InfoDialog.show(GlobalMarket.getVehicleMarketReasonText(row.data.reason or "invalid"), nil, nil, DialogElement.TYPE_WARNING)
        elseif gm.vehicleDialog ~= nil then
            gm.vehicleDialog:show(row.data.vehicle, row.name, row.data.snapshot, row.data.value, farmId)
        end
    elseif row.kind == "MARKET_LISTING" then
        local listing = row.data
        local text = string.format(self.i18n:getText("ui_gm_vehicles_confirmBuy"), row.name,
            self.i18n:formatMoney(row.price, 0, true, true))
        -- target == nil: YesNoDialog calls callback(yes, args)
        YesNoDialog.show(function(yes)
            if yes == true then
                VehicleMarketActionEvent.dispatch(VehicleMarketActionEvent.ACTION_BUY, farmId, nil, listing.id, 1, 1)
            end
        end, nil, text)
    end
end

---Cancel action: withdraw an own open listing (confirmation)
function GlobalMarketUI:onVehicleCancelAction(overrideSection, overrideIndex)
    local row = self:getSelectedVehicleRow(overrideSection, overrideIndex)
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if row == nil or row.kind ~= "MY_LISTING" or row.data.status ~= GlobalMarket.VEHICLE_LISTING_STATUS.OPEN then
        return
    end
    local listing = row.data
    YesNoDialog.show(function(yes)
        if yes == true then
            VehicleMarketActionEvent.dispatch(VehicleMarketActionEvent.ACTION_CANCEL, farmId, nil, listing.id, 1, 1)
        end
    end, nil, string.format(self.i18n:getText("ui_gm_vehicles_confirmWithdraw"), row.name))
end

---Double-click/Enter on the left list (element ~= nil means mouse double-click)
function GlobalMarketUI:onVehicleLeftAction(_, section, index, element)
    local row = self:getSelectedVehicleRow(section, index)
    if row ~= nil and row.kind == "MY_LISTING" then
        if element ~= nil then
            self:onVehicleCancelAction(section, index)
        end
        return
    end
    self:onVehiclePrimaryAction(section, index)
end

function GlobalMarketUI:onVehicleRightAction(_, section, index)
    self:onVehiclePrimaryAction(section, index)
end

-- =========================================================================
-- SMOOTHLIST DATA SOURCE & DELEGATE
-- =========================================================================

local function getSections(ui, list)
    return (list == ui.gmTableMyVehicles) and ui.myVehicleSections or ui.marketVehicleSections
end

function GlobalMarketVehiclesUI:getNumberOfSections(list)
    local ui = GlobalMarketVehiclesUI.activeUi
    return (ui ~= nil) and #getSections(ui, list) or 0
end

function GlobalMarketVehiclesUI:getTitleForSectionHeader(list, section)
    local ui = GlobalMarketVehiclesUI.activeUi
    local sec = (ui ~= nil) and getSections(ui, list)[section] or nil
    return sec and sec.title or nil
end

function GlobalMarketVehiclesUI:getNumberOfItemsInSection(list, section)
    local ui = GlobalMarketVehiclesUI.activeUi
    local sec = (ui ~= nil) and getSections(ui, list)[section] or nil
    return sec and #sec.items or 0
end

---Sets a text cell and its color
local function setCellText(cell, name, text, color)
    local element = cell:getAttribute(name)
    if element ~= nil then
        element:setText(text or "")
        local c = color or COLOR_WHITE_TEXT
        element:setTextColor(c[1], c[2], c[3], c[4])
    end
end

function GlobalMarketVehiclesUI:populateCellForItemInSection(list, section, index, cell)
    local ui = GlobalMarketVehiclesUI.activeUi
    local sec = (ui ~= nil) and getSections(ui, list)[section] or nil
    local row = sec ~= nil and sec.items[index] or nil
    if row == nil then
        return
    end
    local icon = cell:getAttribute("icon")
    local storeItem = nil
    if row.kind == "MY_VEHICLE" then
        storeItem = g_storeManager:getItemByXMLFilename(row.data.vehicle.configFileName)
    elseif row.data ~= nil and row.data.snapshot ~= nil then
        storeItem = getStoreItem(row.data.snapshot.xmlFilename)
    end
    if icon ~= nil then
        local hasImage = (storeItem ~= nil and storeItem.imageFilename ~= nil)
        icon:setVisible(hasImage)
        if hasImage then
            icon:setImageFilename(storeItem.imageFilename)
        end
    end

    local i18n = ui.i18n
    if row.kind == "EMPTY_MY" or row.kind == "EMPTY_MARKET" then
        setCellText(cell, "name", i18n:getText(row.kind == "EMPTY_MY" and "ui_gm_vehicles_empty_my" or "ui_gm_vehicles_empty_market"), COLOR_MUTED)
        setCellText(cell, "status", "")
        setCellText(cell, "value", "")
        setCellText(cell, "condition", "")
        setCellText(cell, "price", "")
    elseif row.kind == "MY_VEHICLE" then
        setCellText(cell, "name", row.name)
        setCellText(cell, "status", i18n:getText(row.data.isEligible and "ui_gm_vehicles_state_ready" or "ui_gm_vehicles_state_blocked"),
            row.data.isEligible and COLOR_BARGAIN or COLOR_BLOCKED)
        setCellText(cell, "value", i18n:formatMoney(row.data.value, 0, true, true))
    elseif row.kind == "MY_LISTING" then
        setCellText(cell, "name", row.name)
        local isPending = (row.data.status == GlobalMarket.VEHICLE_LISTING_STATUS.RETURN_PENDING)
        setCellText(cell, "status", ui:getVehicleListingStatusText(row.data), isPending and COLOR_BLOCKED or COLOR_WHITE_TEXT)
        setCellText(cell, "value", row.price ~= nil and i18n:formatMoney(row.price, 0, true, true) or "-",
            getPriceFactorColor(row.data.priceFactor or 1))
    elseif row.kind == "MARKET_LISTING" then
        setCellText(cell, "name", row.name)
        setCellText(cell, "condition", ui:formatVehicleConditionShort(row.data.snapshot))
        setCellText(cell, "price", string.format("%s (%d %%)", i18n:formatMoney(row.price, 0, true, true),
            math.floor((row.data.priceFactor or 1) * 100 + 0.5)), getPriceFactorColor(row.data.priceFactor or 1))
    end
end

function GlobalMarketVehiclesUI:onListSelectionChanged(list, section, index)
    local ui = GlobalMarketVehiclesUI.activeUi
    if ui == nil or ui.isUpdatingSelection then
        return
    end
    ui.isUpdatingSelection = true
    local otherList
    if list == ui.gmTableMyVehicles then
        ui.vehicleListFocus = "left"
        otherList = ui.gmTableVehicleMarket
    else
        ui.vehicleListFocus = "right"
        otherList = ui.gmTableMyVehicles
    end
    if otherList ~= nil then
        otherList:setSelectedItem(1, 0)
        otherList:clearElementSelection()
    end
    ui.isUpdatingSelection = false
    ui:updateActiveSubTabMenuButtons()
end

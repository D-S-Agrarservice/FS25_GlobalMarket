-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalsUI.lua
-- Livestock market view (#15) inside the marketplace sub-tab (vehicles/animals toggle):
-- own listings, pickup box and barn/trailer animals (left), market listings grouped by
-- animal type (right), sorting, filters, footer actions and the selection hint.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketAnimalsUI = {}
GlobalMarketAnimalsUI.activeUi = nil

GlobalMarketUI.MARKET_MODE_VEHICLES = 1
GlobalMarketUI.MARKET_MODE_ANIMALS  = 2

GlobalMarketUI.ANIMAL_SORT_PRICE  = 1
GlobalMarketUI.ANIMAL_SORT_AGE    = 2
GlobalMarketUI.ANIMAL_SORT_HEALTH = 3
GlobalMarketUI.ANIMAL_SORT_KEYS = {
    "ui_gm_vehicles_sort_price", "ui_gm_vehicles_sort_age", "ui_gm_animals_sort_health"
}

GlobalMarketUI.ANIMAL_FILTER_ALL      = 1
GlobalMarketUI.ANIMAL_FILTER_PREGNANT = 2
GlobalMarketUI.ANIMAL_FILTER_BREEDING = 3
GlobalMarketUI.ANIMAL_FILTER_AUCTIONS = 4
GlobalMarketUI.ANIMAL_FILTER_KEYS = {
    "ui_gm_filter_all", "ui_gm_animals_filter_pregnant", "ui_gm_animals_filter_breeding", "ui_gm_animals_filter_auctions"
}

local COLOR_WHITE_TEXT = { 1, 1, 1, 1 }
local COLOR_BARGAIN    = { 0.46, 0.80, 0.15, 1 }
local COLOR_MARKUP     = { 0.95, 0.68, 0.20, 1 }
local COLOR_BLOCKED    = { 0.92, 0.28, 0.22, 1 }
local COLOR_MUTED      = { 0.65, 0.67, 0.70, 1 }

-- =========================================================================
-- SETUP & MODE TOGGLE
-- =========================================================================

---Binds the animal lists to GlobalMarketAnimalsUI (called from initVehiclesSubTab)
function GlobalMarketUI:initAnimalsSubTab()
    GlobalMarketAnimalsUI.activeUi = self
    self.marketMode = self.marketMode or GlobalMarketUI.MARKET_MODE_VEHICLES
    self.animalListFocus = "left"
    self.animalSortMode = self.animalSortMode or GlobalMarketUI.ANIMAL_SORT_PRICE
    self.animalFilter = self.animalFilter or GlobalMarketUI.ANIMAL_FILTER_ALL
    self.myAnimalSections = {}
    self.marketAnimalSections = {}
    for _, list in ipairs({ self.gmTableMyAnimals, self.gmTableAnimalMarket }) do
        if list ~= nil then
            list:setDataSource(GlobalMarketAnimalsUI)
            list:setDelegate(GlobalMarketAnimalsUI)
        end
    end
end

---Creates the footer button infos of the animal view (called from initVehiclesButtonInfos)
function GlobalMarketUI:initAnimalsButtonInfos()
    self.animalsPrimaryButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = self.i18n:getText("ui_gm_vehicles_action_list"),
        callback = function() self:onAnimalPrimaryAction() end,
        disabled = true
    }
    self.animalsDemandButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = self.i18n:getText("ui_gm_animals_action_demandSell"),
        callback = function() self:onAnimalDemandAction() end,
        disabled = false
    }
    self.animalsCancelButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = self.i18n:getText("ui_gm_vehicles_action_withdraw"),
        callback = function() self:onAnimalCancelAction() end,
        disabled = false
    }
    self.animalsSortButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = self:getAnimalSortText(),
        callback = function() self:onClickCycleAnimalSort() end,
        disabled = false
    }
    self.animalsFilterButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = self:getAnimalFilterText(),
        callback = function() self:onClickCycleAnimalFilter() end,
        disabled = false
    }
end

---Returns true while the marketplace sub-tab shows the animals
---@return boolean
function GlobalMarketUI:getIsAnimalMode()
    return self.activeSubTab == GlobalMarketUI.SUBTAB_VEHICLES and self.marketMode == GlobalMarketUI.MARKET_MODE_ANIMALS
end

---Shows or hides the animals container (the marketplace sub-tab button is styled by the vehicles view)
---@param isVisible boolean
function GlobalMarketUI:applyAnimalsSubTabVisuals(isVisible)
    if self.subTabAnimalsContainer ~= nil then
        self.subTabAnimalsContainer:setVisible(isVisible)
    end
end

---Switches the marketplace sub-tab between vehicles and animals
function GlobalMarketUI:onClickToggleMarketMode()
    if self.marketMode == GlobalMarketUI.MARKET_MODE_ANIMALS then
        self.marketMode = GlobalMarketUI.MARKET_MODE_VEHICLES
    else
        self.marketMode = GlobalMarketUI.MARKET_MODE_ANIMALS
    end
    self:setActiveSubTab(GlobalMarketUI.SUBTAB_VEHICLES, true)
end

---Called by GlobalMarket whenever the synced animal market state changed
function GlobalMarketUI:onAnimalMarketChanged()
    if self:getIsVisible() and self:getIsAnimalMode() then
        self:applyAnimalListsFilter(false)
    end
end

function GlobalMarketUI:getAnimalSortText()
    return self.i18n:getText(GlobalMarketUI.ANIMAL_SORT_KEYS[self.animalSortMode or 1])
end

function GlobalMarketUI:getAnimalFilterText()
    return self.i18n:getText(GlobalMarketUI.ANIMAL_FILTER_KEYS[self.animalFilter or 1])
end

-- =========================================================================
-- FORMATTING HELPERS
-- =========================================================================

---Returns the color of a price factor (bargain / markup / neutral)
local function getPriceFactorColor(priceFactor)
    if priceFactor < 0.95 then
        return COLOR_BARGAIN
    elseif priceFactor > 1.05 then
        return COLOR_MARKUP
    end
    return COLOR_WHITE_TEXT
end

---Returns the row title: "4x Holstein" or "Name (Breed)" for single animals with a name
---@param info table GlobalMarketAnimalListings.getInfo result
---@return string
local function getAnimalTitle(info)
    if info.name ~= nil and info.name ~= "" then
        return string.format("%s (%s)", info.name, info.title)
    end
    return string.format("%dx %s", info.numAnimals or 0, info.title)
end

---Returns the condition text "20 mo. | 4 % | pregnant 10 %"
---@param info table
---@return string
function GlobalMarketUI:formatAnimalCondition(info)
    local text = string.format(self.i18n:getText("ui_gm_animals_condition"), math.floor(info.age or 0), math.floor(info.health or 0))
    if info.isPregnant then
        text = text .. " | " .. string.format(self.i18n:getText("ui_gm_animals_pregnant"), math.floor(info.reproduction or 0))
    elseif info.isBreedingReady then
        text = text .. " | " .. self.i18n:getText("ui_gm_animals_breedingReady")
    end
    return text
end

---Returns the store image of a subtype at an age (nil if unknown)
---@param info table
---@return string|nil
local function getAnimalImage(info)
    if info.subTypeIndex == nil or g_currentMission == nil or g_currentMission.animalSystem == nil then
        return nil
    end
    local visual = g_currentMission.animalSystem:getVisualByAge(info.subTypeIndex, math.floor(info.age or 0))
    return (visual ~= nil and visual.store ~= nil) and visual.store.imageFilename or nil
end

---Returns the section title of an animal type ("Cows", "Pigs", ...)
---@param typeIndex number
---@return string
local function getAnimalTypeTitle(typeIndex)
    local animalType = g_currentMission.animalSystem:getTypeByIndex(typeIndex)
    if animalType ~= nil and animalType.groupTitle ~= nil and animalType.groupTitle ~= "" then
        return animalType.groupTitle
    end
    return (animalType ~= nil and animalType.name) or "?"
end

---Returns true if an info table passes the active filter
---@param ui table
---@param info table
---@return boolean
local function passesFilter(ui, info, listing)
    if ui.animalFilter == GlobalMarketUI.ANIMAL_FILTER_AUCTIONS then
        return GlobalMarket.getIsAnimalAuction(listing)
    elseif ui.animalFilter == GlobalMarketUI.ANIMAL_FILTER_PREGNANT then
        return info.isPregnant
    elseif ui.animalFilter == GlobalMarketUI.ANIMAL_FILTER_BREEDING then
        return info.isBreedingReady
    end
    return true
end

-- =========================================================================
-- LIST BUILDING
-- =========================================================================

---Returns a comparable key of a row (kind-specific ID)
local function getRowKey(row)
    if row == nil or row.data == nil then
        return nil
    end
    if row.kind == "MY_GROUP" then
        return row.data.clusterId
    end
    return row.data.id
end

---Adds the animal groups of one barn or trailer as a section
---@param ui table
---@param sections table
---@param source table Barn or livestock trailer
---@param title string
---@param farmId number
---@return number count Number of groups added
local function addSourceSection(ui, sections, source, title, farmId)
    local items = {}
    for _, cluster in ipairs(source:getClusterSystem():getClusters()) do
        local numAnimals = cluster:getNumAnimals()
        if numAnimals > 0 then
            local snapshotLike = { cluster = cluster }
            local info = GlobalMarketAnimalListings.getInfo(snapshotLike)
            local name = getAnimalTitle(info)
            if ui:matchesVehicleQuery(name) then
                local isEligible, reason = GlobalMarketAnimalListings.getEligibility(source, farmId, cluster.id, numAnimals)
                local data = { source = source, clusterId = cluster.id, isEligible = isEligible, reason = reason,
                    value = GlobalMarketAnimalListings.getDealerValue(snapshotLike) or 0,
                    newPrice = GlobalMarketAnimalListings.getDealerNewPrice(snapshotLike) }
                -- Great demand (Stage 1b): one animal is enough to qualify, the count is chosen in the dialog
                local gm = g_currentMission.globalMarket
                if isEligible and gm ~= nil and gm.animalDemand ~= nil then
                    data.demandOk, data.demandReason = gm:getAnimalDemandEligibility(source, farmId, cluster.id, 1)
                end
                table.insert(items, { kind = "MY_GROUP", name = name, info = info, data = data })
            end
        end
    end
    if #items > 0 then
        table.insert(sections, { title = title, items = items })
    end
    return #items
end

---Rebuilds both animal lists from the synced market state and the farm's barns and trailers
---@param allowListFocus boolean
function GlobalMarketUI:applyAnimalListsFilter(allowListFocus)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if gm == nil then
        return
    end

    local isRight = (self.animalListFocus == "right")
    local activeList = isRight and self.gmTableAnimalMarket or self.gmTableMyAnimals
    local activeSections = isRight and self.marketAnimalSections or self.myAnimalSections
    local activeSec, activeIdx = 1, 0
    if activeList ~= nil then
        activeSec, activeIdx = activeList:getSelectedPath()
    end
    local curRow = activeSections[activeSec] and activeSections[activeSec].items[activeIdx] or nil
    local activeKind, activeKey = curRow ~= nil and curRow.kind or nil, getRowKey(curRow)

    local isAvailable = GlobalMarketAnimalListings.getIsAvailable()
    local isPlayerFarm = GlobalMarketAnimalListings.getIsPlayerFarm(farmId)
    local myListings, myBids, pickups, marketByType = {}, {}, {}, {}
    local marketCount, groupCount = 0, 0

    if isAvailable then
        for _, listing in ipairs(gm.animalListings or {}) do
            local snapshot = listing.snapshot
            if GlobalMarketAnimalListings.getIsResolved(snapshot) then
                local info = GlobalMarketAnimalListings.getInfo(snapshot)
                local name = getAnimalTitle(info)
                local row = { kind = "MARKET_LISTING", data = listing, name = name, info = info,
                    price = GlobalMarketAnimalListings.getListingPrice(listing) or 0 }
                if not listing.isNpc and listing.sellerFarmId == farmId then
                    if self:matchesVehicleQuery(name) then
                        row.kind = "MY_LISTING"
                        table.insert(myListings, row)
                    end
                elseif self:matchesVehicleQuery(name) and passesFilter(self, info, listing) then
                    -- Auctions this farm took part in are also listed on the left ("My bids")
                    if GlobalMarket.getIsAnimalAuction(listing) and listing.auction.bidders ~= nil and listing.auction.bidders[farmId] then
                        table.insert(myBids, { kind = "MY_BID", data = listing, name = name, info = info, price = row.price })
                    end
                    local typeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(info.subTypeIndex) or 0
                    marketByType[typeIndex] = marketByType[typeIndex] or {}
                    table.insert(marketByType[typeIndex], row)
                    marketCount = marketCount + 1
                end
            end
        end
        for _, entry in ipairs(gm.animalPickups or {}) do
            if entry.farmId == farmId and GlobalMarketAnimalListings.getNumAnimals(entry.snapshot) > 0 then
                local info = GlobalMarketAnimalListings.getInfo(entry.snapshot)
                local name = getAnimalTitle(info)
                if self:matchesVehicleQuery(name) then
                    table.insert(pickups, { kind = "PICKUP", data = entry, name = name, info = info,
                        value = GlobalMarketAnimalListings.getDealerValue(entry.snapshot) or 0 })
                end
            end
        end
    end

    -- Left: own listings, pickup box, then every own barn and livestock trailer
    self.myAnimalSections = {}
    if #myListings > 0 then
        table.insert(self.myAnimalSections, { title = self.i18n:getText("ui_gm_animals_sec_myListings"), items = myListings })
    end
    if #myBids > 0 then
        table.insert(self.myAnimalSections, { title = self.i18n:getText("ui_gm_animals_sec_myBids"), items = myBids })
    end
    if #pickups > 0 then
        table.insert(self.myAnimalSections, { title = self.i18n:getText("ui_gm_animals_sec_pickup"), items = pickups })
    end
    if isAvailable and isPlayerFarm then
        for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farmId, nil)) do
            local title = string.format("%s (%d/%d)", barn:getName(), barn:getNumOfAnimals(), barn:getMaxNumOfAnimals())
            groupCount = groupCount + addSourceSection(self, self.myAnimalSections, barn, title, farmId)
        end
        for _, trailer in ipairs(g_currentMission.husbandrySystem.livestockTrailers or {}) do
            if trailer:getOwnerFarmId() == farmId then
                local name = (trailer.getFullName ~= nil) and trailer:getFullName() or "?"
                if GlobalMarketAnimalListings.getIsTrailerAtDealer(trailer) then
                    name = string.format(self.i18n:getText("ui_gm_animals_atDealer"), name)
                end
                groupCount = groupCount + addSourceSection(self, self.myAnimalSections, trailer, name, farmId)
            end
        end
    end
    if not isAvailable then
        self.myAnimalSections = { { title = nil, items = { { kind = "DISABLED" } } } }
    elseif #self.myAnimalSections == 0 then
        table.insert(self.myAnimalSections, { title = nil, items = { { kind = "EMPTY_MY" } } })
    end

    -- Right: market listings per animal type, sorted by the chosen mode
    local sortMode = self.animalSortMode or GlobalMarketUI.ANIMAL_SORT_PRICE
    local function compare(a, b)
        if sortMode == GlobalMarketUI.ANIMAL_SORT_AGE and a.info.age ~= b.info.age then
            return a.info.age < b.info.age
        elseif sortMode == GlobalMarketUI.ANIMAL_SORT_HEALTH and a.info.health ~= b.info.health then
            return a.info.health > b.info.health
        elseif a.price ~= b.price then
            return a.price < b.price
        end
        return a.data.id < b.data.id
    end
    local typeIndices = {}
    for typeIndex in pairs(marketByType) do
        table.insert(typeIndices, typeIndex)
    end
    table.sort(typeIndices)
    self.marketAnimalSections = {}
    for _, typeIndex in ipairs(typeIndices) do
        local items = marketByType[typeIndex]
        table.sort(items, compare)
        table.insert(self.marketAnimalSections, { title = getAnimalTypeTitle(typeIndex), items = items })
    end
    if not isAvailable then
        self.marketAnimalSections = { { title = nil, items = { { kind = "DISABLED" } } } }
    elseif #self.marketAnimalSections == 0 then
        table.insert(self.marketAnimalSections, { title = nil, items = { { kind = "EMPTY_MARKET" } } })
    end

    if self.animalDemandBanner ~= nil then
        self.animalDemandBanner:setText(isAvailable and self:getAnimalDemandBannerText() or "")
    end
    if self.myAnimalsSubtitle ~= nil then
        local text
        if not isAvailable then
            text = self:getAnimalMarketDisabledText()
        else
            text = string.format(self.i18n:getText("ui_gm_animals_mySub"), #myListings, GlobalMarket.ANIMAL_MARKET.MAX_PER_FARM, groupCount)
        end
        self.myAnimalsSubtitle:setText(text)
    end
    if self.animalMarketSubtitle ~= nil then
        self.animalMarketSubtitle:setText(string.format(self.i18n:getText("ui_gm_vehicles_marketSub"), marketCount))
    end
    if self.btnAnimalSort ~= nil then
        self.btnAnimalSort:setText(self:getAnimalSortText())
    end
    if self.btnAnimalFilter ~= nil then
        self.btnAnimalFilter:setText(self:getAnimalFilterText())
    end

    self.isUpdatingSelection = true
    local wasSearchFocused = (self.searchTextInput ~= nil and FocusManager:getFocusedElement() == self.searchTextInput)
    if self.gmTableMyAnimals ~= nil then self.gmTableMyAnimals:reloadData() end
    if self.gmTableAnimalMarket ~= nil then self.gmTableAnimalMarket:reloadData() end
    self:restoreAnimalListSelection(activeKind, activeKey, activeSec, activeIdx, allowListFocus and not wasSearchFocused)
    if wasSearchFocused and self.searchTextInput ~= nil then
        FocusManager:setFocus(self.searchTextInput)
    end
    self.isUpdatingSelection = false
    self:updateActiveSubTabMenuButtons()
end

---Restores the selection after a rebuild (same row if it still exists, otherwise the same position)
function GlobalMarketUI:restoreAnimalListSelection(kind, key, sec, idx, setFocus)
    local isRight = (self.animalListFocus == "right")
    local list = isRight and self.gmTableAnimalMarket or self.gmTableMyAnimals
    local otherList = isRight and self.gmTableMyAnimals or self.gmTableAnimalMarket
    local sections = isRight and self.marketAnimalSections or self.myAnimalSections
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

---Returns the list that has the focus in the animal view
---@return table|nil list
function GlobalMarketUI:getAnimalFocusList()
    return (self.animalListFocus == "right") and self.gmTableAnimalMarket or self.gmTableMyAnimals
end

---Returns the selected row of the focused animal list
function GlobalMarketUI:getSelectedAnimalRow(overrideSection, overrideIndex)
    local isRight = (self.animalListFocus == "right")
    local list = isRight and self.gmTableAnimalMarket or self.gmTableMyAnimals
    local sections = isRight and self.marketAnimalSections or self.myAnimalSections
    local sec, idx = overrideSection, overrideIndex
    if (sec == nil or idx == nil) and list ~= nil then
        sec, idx = list:getSelectedPath()
    end
    return sections[sec] and sections[sec].items and sections[sec].items[idx] or nil
end

-- =========================================================================
-- FOOTER BUTTONS & HINT
-- =========================================================================

function GlobalMarketUI:updateAnimalsMenuButtons()
    local row = self:getSelectedAnimalRow()
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    local isSpectator = (farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID)
    local list = { { inputAction = InputAction.MENU_BACK } }

    local primary = self.animalsPrimaryButtonInfo
    if primary ~= nil and row ~= nil and not isSpectator then
        if row.kind == "MY_GROUP" then
            primary.text = self.i18n:getText("ui_gm_vehicles_action_list")
            primary.disabled = not row.data.isEligible
            table.insert(list, primary)
        elseif row.kind == "MARKET_LISTING" or row.kind == "MY_BID" then
            local isAuction = GlobalMarket.getIsAnimalAuction(row.data)
            primary.text = self.i18n:getText(isAuction and "ui_gm_animals_action_bid" or "ui_gm_animals_action_buy")
            primary.disabled = false
            table.insert(list, primary)
        elseif row.kind == "PICKUP" then
            primary.text = self.i18n:getText("ui_gm_animals_action_load")
            primary.disabled = GlobalMarket.getAnimalMarketTrailerAtDealer(farmId) == nil
            table.insert(list, primary)
        end
    end
    if self.switchSubTabButtonInfo ~= nil then
        table.insert(list, self.switchSubTabButtonInfo)
    end
    if self.animalsSortButtonInfo ~= nil then
        self.animalsSortButtonInfo.text = self:getAnimalSortText()
        table.insert(list, self.animalsSortButtonInfo)
    end
    if self.animalsFilterButtonInfo ~= nil then
        self.animalsFilterButtonInfo.text = self:getAnimalFilterText()
        table.insert(list, self.animalsFilterButtonInfo)
    end
    if self.animalsCancelButtonInfo ~= nil and row ~= nil and row.kind == "MY_LISTING" and not isSpectator
        and GlobalMarket.getAnimalAuctionCancelBlock(row.data) == nil then
        table.insert(list, self.animalsCancelButtonInfo)
    elseif self.animalsDemandButtonInfo ~= nil and row ~= nil and row.kind == "MY_GROUP" and row.data.demandOk and not isSpectator then
        table.insert(list, self.animalsDemandButtonInfo)
    end
    self:setMenuButtonInfo(list)
    self:setMenuButtonInfoDirty()
    self:updateAnimalSelectionHint(row)
end

---Returns a remaining time text ("2.5 days" or "5 h")
---@param hours number
---@return string
function GlobalMarketUI:formatAnimalHours(hours)
    hours = hours or 0
    if hours >= 24 then
        return string.format(self.i18n:getText("ui_gm_animals_demand_days"), hours / 24)
    end
    return string.format(self.i18n:getText("ui_gm_animals_demand_hours"), math.max(1, math.ceil(hours)))
end

---Returns true if the local farm holds the highest bid of an auction listing
---@param listing table
---@return boolean
local function getIsOwnHighBid(listing)
    local auction = listing.auction
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    return auction ~= nil and auction.highFactor ~= nil and not auction.highIsNpc and auction.highFarmId == farmId
end

---Returns the auction status text "4 bids | 5 h left"
---@param listing table
---@return string
function GlobalMarketUI:formatAnimalAuctionStatus(listing)
    return string.format(self.i18n:getText("ui_gm_animals_auctionStatus"), GlobalMarketAuction.getBidCount(listing.auction),
        self:formatAnimalHours(listing.auction.hoursRemaining))
end

---Returns the great demand banner text ("" without an active demand)
---@return string
function GlobalMarketUI:getAnimalDemandBannerText()
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local demand = (gm ~= nil) and gm.animalDemand or nil
    if demand == nil then
        return ""
    end
    local timeText = self:formatAnimalHours(demand.hoursRemaining)
    return string.format(self.i18n:getText("ui_gm_animals_demandBanner"), GlobalMarket.getAnimalDemandTypeTitle(demand.typeName),
        math.floor((demand.bonus or 0) * 100 + 0.5), timeText, gm:getAnimalDemandRemaining())
end

---Returns why the animal market is disabled (incompatible mod named if known)
---@return string
function GlobalMarketUI:getAnimalMarketDisabledText()
    local modName = GlobalMarketAnimalListings.getIncompatibleMod()
    if modName ~= nil then
        return string.format(self.i18n:getText("ui_gm_animals_disabledByMod"), modName)
    end
    return GlobalMarket.getAnimalMarketReasonText("unavailable")
end

---Returns the great demand part of a group hint ("" if the group does not match the demand)
---@param row table MY_GROUP row
---@return string
function GlobalMarketUI:getAnimalDemandHintSuffix(row)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil or gm.animalDemand == nil then
        return ""
    end
    if row.data.demandOk then
        local cluster = row.data.source:getClusterById(row.data.clusterId)
        if cluster == nil then
            return ""
        end
        local count = math.min(cluster:getNumAnimals(), gm:getAnimalDemandRemaining())
        return " | " .. string.format(self.i18n:getText("ui_gm_animals_hint_demand"),
            self.i18n:formatMoney(gm:getAnimalDemandPayout(cluster, count), 0, true, true), count,
            math.floor((gm.animalDemand.bonus or 0) * 100 + 0.5))
    elseif row.data.demandReason ~= nil and row.data.demandReason ~= "demandWrongType" then
        return " | " .. GlobalMarket.getAnimalMarketReasonText(row.data.demandReason)
    end
    return ""
end

---Returns the dealer's new price text ("not available at the dealer" if the dealer does not sell this age)
---@param newPrice number|nil
---@return string
function GlobalMarketUI:formatAnimalNewPrice(newPrice)
    if newPrice == nil then
        return self.i18n:getText("ui_gm_animals_notAtDealerShop")
    end
    return self.i18n:formatMoney(newPrice, 0, true, true)
end

function GlobalMarketUI:updateAnimalSelectionHint(row)
    if self.animalsSelectionHint == nil then
        return
    end
    local text = ""
    if row ~= nil and row.kind == "MY_GROUP" then
        if row.data.isEligible then
            text = string.format(self.i18n:getText("ui_gm_animals_hint_group"), row.name, self:formatAnimalCondition(row.info),
                self.i18n:formatMoney(row.data.value, 0, true, true), self:formatAnimalNewPrice(row.data.newPrice))
            text = text .. self:getAnimalDemandHintSuffix(row)
        else
            text = string.format("%s | %s", row.name, GlobalMarket.getAnimalMarketReasonText(row.data.reason or "invalid"))
        end
    elseif row ~= nil and row.kind == "PICKUP" then
        local isReturn = (row.data.reason == GlobalMarket.ANIMAL_PICKUP_REASON.RETURN)
        text = string.format(self.i18n:getText(isReturn and "ui_gm_animals_hint_pickupReturn" or "ui_gm_animals_hint_pickupBought"),
            row.name)
    elseif row ~= nil and (row.kind == "MY_LISTING" or row.kind == "MARKET_LISTING" or row.kind == "MY_BID")
        and GlobalMarket.getIsAnimalAuction(row.data) then
        local listing = row.data
        local auction = listing.auction
        local baseValue = GlobalMarketAnimalListings.getDealerValue(listing.snapshot) or 0
        local buyNowText = self.i18n:getText("ui_gm_animals_buyNowNone")
        if GlobalMarketAuction.getIsBuyNowAvailable(auction) then
            buyNowText = self.i18n:formatMoney(GlobalMarketAuction.getAmount(auction.buyNowFactor, baseValue), 0, true, true)
        end
        text = string.format(self.i18n:getText("ui_gm_animals_hint_auction"), row.name,
            listing.isNpc and self.i18n:getText("ui_gm_animals_npcName") or tostring(listing.sellerName),
            self:formatAnimalCondition(row.info), self.i18n:formatMoney(row.price, 0, true, true),
            GlobalMarketAuction.getBidCount(auction),
            self.i18n:formatMoney(GlobalMarketAuction.getAmount(GlobalMarketAuction.getMinBidFactor(auction), baseValue), 0, true, true),
            buyNowText, self:formatAnimalHours(auction.hoursRemaining))
        if getIsOwnHighBid(listing) then
            text = text .. " | " .. self.i18n:getText("ui_gm_animals_bidState_high")
        end
    elseif row ~= nil and (row.kind == "MY_LISTING" or row.kind == "MARKET_LISTING") then
        local listing = row.data
        text = string.format(self.i18n:getText("ui_gm_animals_hint_listing"), row.name,
            listing.isNpc and self.i18n:getText("ui_gm_animals_npcName") or tostring(listing.sellerName),
            self:formatAnimalCondition(row.info), self.i18n:formatMoney(row.price, 0, true, true),
            math.floor((listing.priceFactor or 1) * 100 + 0.5),
            self:formatAnimalNewPrice(GlobalMarketAnimalListings.getDealerNewPrice(listing.snapshot)),
            self.i18n:formatMoney(GlobalMarketAnimalListings.getTransportFee(listing.snapshot) or 0, 0, true, true),
            string.format(self.i18n:getText("ui_gm_months_short"), math.max(0, listing.monthsRemaining or 0)))
    end
    self.animalsSelectionHint:setText(text)
end

-- =========================================================================
-- ACTIONS
-- =========================================================================

function GlobalMarketUI:onClickCycleAnimalSort()
    self.animalSortMode = (self.animalSortMode or 1) % #GlobalMarketUI.ANIMAL_SORT_KEYS + 1
    self:applyAnimalListsFilter(false)
end

function GlobalMarketUI:onClickCycleAnimalFilter()
    self.animalFilter = (self.animalFilter or 1) % #GlobalMarketUI.ANIMAL_FILTER_KEYS + 1
    self:applyAnimalListsFilter(false)
end

---Cancel action: withdraw an own listing (confirmation)
function GlobalMarketUI:onAnimalCancelAction(overrideSection, overrideIndex)
    local row = self:getSelectedAnimalRow(overrideSection, overrideIndex)
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if row == nil or row.kind ~= "MY_LISTING" then
        return
    end
    local listing = row.data
    -- target == nil: YesNoDialog calls callback(yes, args)
    YesNoDialog.show(function(yes)
        if yes == true then
            AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_CANCEL, farmId, { targetId = listing.id })
        end
    end, nil, string.format(self.i18n:getText("ui_gm_animals_confirmWithdraw"), row.name))
end

---Primary action: list an own group (dialog), buy a listing (dialog) or load the pickup box onto the trailer
function GlobalMarketUI:onAnimalPrimaryAction(overrideSection, overrideIndex)
    local row = self:getSelectedAnimalRow(overrideSection, overrideIndex)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if row == nil or gm == nil or not GlobalMarketAnimalListings.getIsPlayerFarm(farmId) then
        return
    end
    if row.kind == "MY_GROUP" then
        if not row.data.isEligible then
            InfoDialog.show(GlobalMarket.getAnimalMarketReasonText(row.data.reason or "invalid"), nil, nil, DialogElement.TYPE_WARNING)
            return
        end
        local cluster = row.data.source:getClusterById(row.data.clusterId)
        if cluster ~= nil and gm.animalDialog ~= nil then
            gm.animalDialog:showList({ source = row.data.source, cluster = cluster, title = row.name,
                condition = self:formatAnimalCondition(row.info), image = getAnimalImage(row.info), farmId = farmId })
        end
    elseif (row.kind == "MARKET_LISTING" or row.kind == "MY_BID") and GlobalMarket.getIsAnimalAuction(row.data) then
        if gm.animalDialog ~= nil then
            gm.animalDialog:showBid({ listing = row.data, title = row.name,
                condition = self:formatAnimalCondition(row.info), image = getAnimalImage(row.info), farmId = farmId })
        end
    elseif row.kind == "MARKET_LISTING" then
        if gm.animalDialog ~= nil then
            gm.animalDialog:showBuy({ listing = row.data, title = row.name,
                condition = self:formatAnimalCondition(row.info), image = getAnimalImage(row.info), farmId = farmId })
        end
    elseif row.kind == "PICKUP" then
        local trailer = GlobalMarket.getAnimalMarketTrailerAtDealer(farmId)
        if trailer == nil then
            InfoDialog.show(GlobalMarket.getAnimalMarketReasonText("noTrailer"), nil, nil, DialogElement.TYPE_WARNING)
            return
        end
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_LOAD, farmId, { object = trailer, targetId = row.data.id })
    end
end

---Great demand action: sell animals of an own group to the active great demand (dialog)
function GlobalMarketUI:onAnimalDemandAction(overrideSection, overrideIndex)
    local row = self:getSelectedAnimalRow(overrideSection, overrideIndex)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if row == nil or row.kind ~= "MY_GROUP" or not row.data.demandOk or gm == nil or gm.animalDialog == nil then
        return
    end
    local cluster = row.data.source:getClusterById(row.data.clusterId)
    if cluster ~= nil then
        gm.animalDialog:showDemand({ source = row.data.source, cluster = cluster, title = row.name,
            condition = self:formatAnimalCondition(row.info), image = getAnimalImage(row.info), farmId = farmId })
    end
end

---Double-click/Enter on the left list (element ~= nil means mouse double-click)
function GlobalMarketUI:onAnimalLeftAction(_, section, index, element)
    local row = self:getSelectedAnimalRow(section, index)
    if row ~= nil and row.kind == "MY_LISTING" then
        if element ~= nil then
            self:onAnimalCancelAction(section, index)
        end
        return
    end
    self:onAnimalPrimaryAction(section, index)
end

---Double-click/Enter on the market list
function GlobalMarketUI:onAnimalRightAction(_, section, index)
    self:onAnimalPrimaryAction(section, index)
end

-- =========================================================================
-- SMOOTHLIST DATA SOURCE & DELEGATE
-- =========================================================================

local function getSections(ui, list)
    return (list == ui.gmTableMyAnimals) and ui.myAnimalSections or ui.marketAnimalSections
end

function GlobalMarketAnimalsUI:getNumberOfSections(list)
    local ui = GlobalMarketAnimalsUI.activeUi
    return (ui ~= nil) and #getSections(ui, list) or 0
end

function GlobalMarketAnimalsUI:getTitleForSectionHeader(list, section)
    local ui = GlobalMarketAnimalsUI.activeUi
    local sec = (ui ~= nil) and getSections(ui, list)[section] or nil
    return sec and sec.title or nil
end

function GlobalMarketAnimalsUI:getNumberOfItemsInSection(list, section)
    local ui = GlobalMarketAnimalsUI.activeUi
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

function GlobalMarketAnimalsUI:populateCellForItemInSection(list, section, index, cell)
    local ui = GlobalMarketAnimalsUI.activeUi
    local sec = (ui ~= nil) and getSections(ui, list)[section] or nil
    local row = sec ~= nil and sec.items[index] or nil
    if row == nil then
        return
    end
    local icon = cell:getAttribute("icon")
    if icon ~= nil then
        local image = (row.info ~= nil) and getAnimalImage(row.info) or nil
        icon:setVisible(image ~= nil)
        if image ~= nil then
            icon:setImageFilename(image)
        end
    end

    local i18n = ui.i18n
    setCellText(cell, "condition", "")
    setCellText(cell, "value", "")
    setCellText(cell, "price", "")
    if row.kind == "DISABLED" then
        setCellText(cell, "name", ui:getAnimalMarketDisabledText(), COLOR_BLOCKED)
    elseif row.kind == "EMPTY_MY" or row.kind == "EMPTY_MARKET" then
        setCellText(cell, "name", i18n:getText(row.kind == "EMPTY_MY" and "ui_gm_animals_empty_my" or "ui_gm_animals_empty_market"), COLOR_MUTED)
    elseif row.kind == "MY_GROUP" then
        local nameColor = row.data.isEligible and COLOR_WHITE_TEXT or COLOR_MUTED
        if row.data.demandOk then
            nameColor = COLOR_BARGAIN
        end
        setCellText(cell, "name", row.name, nameColor)
        if row.data.isEligible then
            setCellText(cell, "condition", ui:formatAnimalCondition(row.info))
        else
            setCellText(cell, "condition", i18n:getText("ui_gm_vehicles_state_blocked"), COLOR_BLOCKED)
        end
        setCellText(cell, "value", i18n:formatMoney(row.data.value, 0, true, true), row.data.isEligible and COLOR_WHITE_TEXT or COLOR_MUTED)
    elseif row.kind == "PICKUP" then
        setCellText(cell, "name", row.name)
        local isReturn = (row.data.reason == GlobalMarket.ANIMAL_PICKUP_REASON.RETURN)
        setCellText(cell, "condition", i18n:getText(isReturn and "ui_gm_animals_pickup_return" or "ui_gm_animals_pickup_bought"),
            isReturn and COLOR_MARKUP or COLOR_BARGAIN)
        setCellText(cell, "value", i18n:formatMoney(row.value, 0, true, true))
    elseif row.kind == "MY_LISTING" then
        setCellText(cell, "name", row.name)
        if GlobalMarket.getIsAnimalAuction(row.data) then
            setCellText(cell, "condition", ui:formatAnimalAuctionStatus(row.data), COLOR_MARKUP)
        else
            setCellText(cell, "condition", string.format(i18n:getText("ui_gm_vehicles_status_open"),
                string.format(i18n:getText("ui_gm_months_short"), math.max(0, row.data.monthsRemaining or 0))))
        end
        setCellText(cell, "value", i18n:formatMoney(row.price, 0, true, true), getPriceFactorColor(row.data.priceFactor or 1))
    elseif row.kind == "MY_BID" then
        setCellText(cell, "name", row.name)
        local isHigh = getIsOwnHighBid(row.data)
        setCellText(cell, "condition", string.format("%s | %s", i18n:getText(isHigh and "ui_gm_animals_bidState_high" or "ui_gm_animals_bidState_outbid"),
            ui:formatAnimalHours(row.data.auction.hoursRemaining)), isHigh and COLOR_BARGAIN or COLOR_BLOCKED)
        setCellText(cell, "value", i18n:formatMoney(row.price, 0, true, true))
    elseif row.kind == "MARKET_LISTING" then
        setCellText(cell, "name", row.name)
        setCellText(cell, "condition", ui:formatAnimalCondition(row.info))
        if GlobalMarket.getIsAnimalAuction(row.data) then
            setCellText(cell, "price", string.format(i18n:getText("ui_gm_animals_auctionPrice"), i18n:formatMoney(row.price, 0, true, true),
                ui:formatAnimalHours(row.data.auction.hoursRemaining)), getIsOwnHighBid(row.data) and COLOR_BARGAIN or COLOR_MARKUP)
        else
            setCellText(cell, "price", string.format("%s (%d %%)", i18n:formatMoney(row.price, 0, true, true),
                math.floor((row.data.priceFactor or 1) * 100 + 0.5)), getPriceFactorColor(row.data.priceFactor or 1))
        end
    end
end

function GlobalMarketAnimalsUI:onListSelectionChanged(list, section, index)
    local ui = GlobalMarketAnimalsUI.activeUi
    if ui == nil or ui.isUpdatingSelection then
        return
    end
    ui.isUpdatingSelection = true
    local otherList
    if list == ui.gmTableMyAnimals then
        ui.animalListFocus = "left"
        otherList = ui.gmTableAnimalMarket
    else
        ui.animalListFocus = "right"
        otherList = ui.gmTableMyAnimals
    end
    if otherList ~= nil then
        otherList:setSelectedItem(1, 0)
        otherList:clearElementSelection()
    end
    ui.isUpdatingSelection = false
    ui:updateActiveSubTabMenuButtons()
end

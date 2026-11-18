-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketStorageAge.lua
-- Remaining storage time of goods in GM Logistics Centers (#20):
-- server-side tracker snapshot, client cache (SyncGmStorageAgeEvent) and UI helpers.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketStorageAge = {}

GlobalMarketStorageAge.URGENCY_NONE      = 0 -- No tracked stock (or decay disabled)
GlobalMarketStorageAge.URGENCY_NORMAL    = 1 -- Regular storage time
GlobalMarketStorageAge.URGENCY_EXPENSIVE = 2 -- Final 2 months: increased storage fees
GlobalMarketStorageAge.URGENCY_FINAL     = 3 -- Final quarter month: clearance imminent

-- Countdown icon colors per urgency (green = GM receipt green)
GlobalMarketStorageAge.ICON_COLORS = {
    [1] = { 0.46, 0.80, 0.15, 1.0 },
    [2] = { 1.0, 0.65, 0.15, 1.0 },
    [3] = { 0.95, 0.25, 0.2, 1.0 }
}

-- Same thresholds as the fee/warning logic in GlobalMarketFinance
GlobalMarketStorageAge.EXPENSIVE_MONTHS_LEFT = 2
GlobalMarketStorageAge.FINAL_MONTHS_LEFT = 0.25

-- =========================================================================
-- DATA (Server snapshot / Client cache)
-- =========================================================================

---Resolves the GM placeable and silo storage index of a bulk storage
---@param storage table
---@return table|nil placeable
---@return number storageIndex
function GlobalMarketStorageAge.resolveBulkStorage(storage)
    if storage == nil then
        return nil, 0
    end
    local function findIn(placeable)
        if placeable ~= nil and placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
            for i, s in ipairs(placeable.spec_silo.storages) do
                if s == storage then
                    return i
                end
            end
        end
        return nil
    end

    local index = findIn(storage.owningPlaceable)
    if index ~= nil then
        return storage.owningPlaceable, index
    end
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
            if placeable.isGmMarket then
                index = findIn(placeable)
                if index ~= nil then
                    return placeable, index
                end
            end
        end
    end
    return nil, 0
end

---Server: collects all GM storage trackers as flat entries
---storageIndex 0 marks an object storage (bales/pallets), >0 a silo storage of the placeable.
---@return table entries {placeable, storageIndex, farmId, fillTypeIndex, months}
function GlobalMarket:collectGmStorageAgeEntries()
    local entries = {}
    if g_currentMission == nil or g_currentMission.placeableSystem == nil or g_currentMission.placeableSystem.placeables == nil then
        return entries
    end

    local function addTrackers(placeable, storageIndex, trackers)
        if trackers == nil then
            return
        end
        for farmId, ftTrackers in pairs(trackers) do
            for fillTypeIndex, tracker in pairs(ftTrackers) do
                if tracker ~= nil and tracker.months ~= nil then
                    table.insert(entries, {
                        placeable = placeable,
                        storageIndex = storageIndex,
                        farmId = farmId,
                        fillTypeIndex = fillTypeIndex,
                        months = tracker.months
                    })
                end
            end
        end
    end

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.isGmMarket then
            if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                for i, storage in ipairs(placeable.spec_silo.storages) do
                    addTrackers(placeable, i, storage.gmStorageTracker)
                end
            end
            addTrackers(placeable, 0, placeable.gmObjectTracker)
        end
    end
    return entries
end

---Server: rebuilds the snapshot after the hourly fee/decay pass and pushes it to all clients
function GlobalMarket:refreshGmStorageAges()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    local hadEntries = self.gmStorageAgeEntries ~= nil and #self.gmStorageAgeEntries > 0
    self.gmStorageAgeEntries = self:collectGmStorageAgeEntries()
    -- Skip the hourly broadcast while no GM storage holds any goods
    if not hadEntries and #self.gmStorageAgeEntries == 0 then
        return
    end
    if g_server ~= nil and SyncGmStorageAgeEvent ~= nil then
        g_server:broadcastEvent(SyncGmStorageAgeEvent.new(self.gmStorageAgeEntries))
    end
end

---Client: applies a received snapshot and refreshes the open menu
---@param entries table
function GlobalMarket:applyGmStorageAgeEntries(entries)
    self.gmStorageAgeEntries = entries or {}
    local ui = self.ui or (g_currentMission ~= nil and g_currentMission.globalMarketUi) or nil
    if ui ~= nil and ui.getIsVisible ~= nil and ui:getIsVisible() and ui.updateContent ~= nil then
        ui:updateContent()
    end
end

---Returns the current snapshot (server builds it lazily, e.g. right after loading a savegame)
---@return table entries
function GlobalMarket:getGmStorageAgeEntries()
    if self.gmStorageAgeEntries == nil and g_currentMission ~= nil and g_currentMission:getIsServer() then
        self.gmStorageAgeEntries = self:collectGmStorageAgeEntries()
    end
    return self.gmStorageAgeEntries or {}
end

---Returns the remaining storage time of the oldest matching stack of a farm's goods in GM storages
---@param farmId number
---@param fillTypeIndex number
---@param placeable table|nil Restrict to this GM placeable
---@param storageIndex number|nil Restrict to this storage (0 = object storage)
---@return number|nil monthsLeft nil if nothing is tracked or decay is disabled
---@return number urgency GlobalMarketStorageAge.URGENCY_*
function GlobalMarket:getGmStorageTimeLeft(farmId, fillTypeIndex, placeable, storageIndex)
    local maxMonths = GlobalMarket.STORAGE_DECAY_MONTHS or 6
    if maxMonths <= 0 or farmId == nil or fillTypeIndex == nil then
        return nil, GlobalMarketStorageAge.URGENCY_NONE
    end

    local oldest = nil
    for _, e in ipairs(self:getGmStorageAgeEntries()) do
        if e.farmId == farmId and e.fillTypeIndex == fillTypeIndex
            and (placeable == nil or e.placeable == placeable)
            and (storageIndex == nil or e.storageIndex == storageIndex)
            and (oldest == nil or e.months > oldest) then
            oldest = e.months
        end
    end
    if oldest == nil then
        return nil, GlobalMarketStorageAge.URGENCY_NONE
    end

    local monthsLeft = math.max(0, maxMonths - oldest)
    local urgency = GlobalMarketStorageAge.URGENCY_NORMAL
    if monthsLeft <= GlobalMarketStorageAge.FINAL_MONTHS_LEFT then
        urgency = GlobalMarketStorageAge.URGENCY_FINAL
    elseif monthsLeft <= GlobalMarketStorageAge.EXPENSIVE_MONTHS_LEFT then
        urgency = GlobalMarketStorageAge.URGENCY_EXPENSIVE
    end
    return monthsLeft, urgency
end

-- =========================================================================
-- UI HELPERS
-- =========================================================================

---Builds "GM storage: cleared in X mo." (+ fee hint in the expensive phase)
---@param monthsLeft number
---@param urgency number
---@return string
function GlobalMarketStorageAge.formatTimeLeft(monthsLeft, urgency)
    local durFmt = g_i18n:hasText("ui_gm_months_short") and g_i18n:getText("ui_gm_months_short") or "%.1f mo."
    local text = string.format(g_i18n:getText("ui_gm_storage_clearIn"), string.format(durFmt, monthsLeft))
    if urgency >= GlobalMarketStorageAge.URGENCY_EXPENSIVE then
        text = text .. " | " .. g_i18n:getText("ui_gm_storage_feesHigh")
    end
    return text
end

---Returns time left and urgency for an aggregated storage list row of the local farm
---@param data table|nil Row data from getAggregatedStorageData
---@return number|nil monthsLeft
---@return number urgency
function GlobalMarketStorageAge.getRowTimeLeft(data)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil or data == nil or (data.levelGM or 0) <= 0 then
        return nil, GlobalMarketStorageAge.URGENCY_NONE
    end
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(data.fillType)
    return gm:getGmStorageTimeLeft(g_currentMission:getFarmId(), fillTypeIndex)
end

---Shows/colors the clock icon of a storage list row (no-op for rows without the icon)
---@param cell table
---@param data table|nil Row data, nil for market rows
function GlobalMarketStorageAge.decorateCell(cell, data)
    local icon = cell:getAttribute("ageIcon")
    if icon == nil then
        return
    end
    local monthsLeft, urgency = GlobalMarketStorageAge.getRowTimeLeft(data)
    local color = GlobalMarketStorageAge.ICON_COLORS[urgency]
    icon:setVisible(monthsLeft ~= nil and color ~= nil)
    if monthsLeft ~= nil and color ~= nil then
        -- Same color in all row states, otherwise a selected/hovered row would fall back to the profile color
        local states = { GuiOverlay.STATE_NORMAL, GuiOverlay.STATE_SELECTED, GuiOverlay.STATE_HIGHLIGHTED, GuiOverlay.STATE_FOCUSED }
        for _, state in ipairs(states) do
            icon:setImageColor(state, color[1], color[2], color[3], color[4])
        end
    end
end

---Updates the spot market footer hint for the selected storage row
---@param frame table GlobalMarketUI
---@param data table|nil Selected storage row data (nil clears the hint)
function GlobalMarketStorageAge.updateSelectionHint(frame, data)
    local hint = frame.storageAgeHint
    if hint == nil then
        return
    end
    local monthsLeft, urgency = GlobalMarketStorageAge.getRowTimeLeft(data)
    if monthsLeft == nil then
        hint:setText("")
        return
    end
    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)
    local title = (fillTypeDesc ~= nil and fillTypeDesc.title) or tostring(data.fillType)
    hint:setText(string.format("%s | %s", title, GlobalMarketStorageAge.formatTimeLeft(monthsLeft, urgency)))
    local color = (urgency >= GlobalMarketStorageAge.URGENCY_EXPENSIVE) and GlobalMarketStorageAge.ICON_COLORS[urgency] or { 0.88, 0.90, 0.92, 1 }
    hint:setTextColor(color[1], color[2], color[3], 1)
end

---Returns the info text suffix for a GM storage selected as source in the sell dialog ("" otherwise)
---@param location table|nil Entry from getAvailableStorages
---@param fillTypeName string
---@return string suffix
---@return number urgency
function GlobalMarketStorageAge.getDialogSuffix(location, fillTypeName)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil or location == nil or not location.isGmMarket then
        return "", GlobalMarketStorageAge.URGENCY_NONE
    end
    local placeable, storageIndex
    if location.isObjectStorage then
        placeable, storageIndex = location.storage, 0
    else
        placeable, storageIndex = GlobalMarketStorageAge.resolveBulkStorage(location.storage)
    end
    if placeable == nil then
        return "", GlobalMarketStorageAge.URGENCY_NONE
    end
    local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
    local monthsLeft, urgency = gm:getGmStorageTimeLeft(g_currentMission:getFarmId(), fillTypeIndex, placeable, storageIndex)
    if monthsLeft == nil then
        return "", GlobalMarketStorageAge.URGENCY_NONE
    end
    return " | " .. GlobalMarketStorageAge.formatTimeLeft(monthsLeft, urgency), urgency
end

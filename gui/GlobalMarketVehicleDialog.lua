-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleDialog.lua
-- Used vehicle market (#16): modal dialog to list an own vehicle with an asking price
-- (percent of the dealer value) and a duration: locally in in-game months or, while the
-- online vehicle market is available (#36), across servers in real-time hours.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketVehicleDialog = {}
local GlobalMarketVehicleDialog_mt = Class(GlobalMarketVehicleDialog, YesNoDialog)

GlobalMarketVehicleDialog.PRICE_STEP = 0.05
GlobalMarketVehicleDialog.DEFAULT_DURATION = 3
GlobalMarketVehicleDialog.DEFAULT_ONLINE_HOURS = 72
GlobalMarketVehicleDialog.MODE_LOCAL = 1
GlobalMarketVehicleDialog.MODE_ONLINE = 2

local COLOR_LABEL = { 0.78, 0.80, 0.82, 1 }
local COLOR_WHITE = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.85, 0.85, 0.85, 1 }
local COLOR_GREEN = { 0.46, 0.80, 0.15, 1 }
local COLOR_AMBER = { 0.95, 0.68, 0.20, 1 }

function GlobalMarketVehicleDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketVehicleDialog_mt)
    self.vehicle = nil
    self.vehicleName = ""
    self.snapshot = nil
    self.dealerValue = 0
    self.farmId = 0
    self.priceOptions = {}
    self.durationOptions = {}
    self.isOnlineAvailable = false
    return self
end

---Opens the dialog for an own, eligible vehicle
---@param vehicle table
---@param vehicleName string
---@param snapshot table Snapshot from GlobalMarketVehicleListings.captureSnapshot
---@param dealerValue number
---@param farmId number
function GlobalMarketVehicleDialog:show(vehicle, vehicleName, snapshot, dealerValue, farmId)
    self.vehicle = vehicle
    self.vehicleName = vehicleName or ""
    self.snapshot = snapshot
    self.dealerValue = dealerValue or 0
    self.farmId = farmId or 0
    g_gui:showDialog("GlobalMarketVehicleDialog")
end

function GlobalMarketVehicleDialog:onOpen()
    GlobalMarketVehicleDialog:superClass().onOpen(self)
    local cfg = GlobalMarket.VEHICLE_MARKET

    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(string.format(g_i18n:getText("ui_gm_vehicles_dialog_title"), self.vehicleName))
    end
    if self.dialogVehicleIcon ~= nil then
        local storeItem = (self.vehicle ~= nil) and g_storeManager:getItemByXMLFilename(self.vehicle.configFileName) or nil
        local hasImage = (storeItem ~= nil and storeItem.imageFilename ~= nil)
        self.dialogVehicleIcon:setVisible(hasImage)
        if hasImage then
            self.dialogVehicleIcon:setImageFilename(storeItem.imageFilename)
        end
    end
    if self.headerBoxLayout ~= nil then
        self.headerBoxLayout:invalidateLayout()
    end
    if self.dialogInfoTextElement ~= nil and self.snapshot ~= nil then
        self.dialogInfoTextElement:setText(string.format(g_i18n:getText("ui_gm_vehicles_condition_full"),
            (self.snapshot.operatingTime or 0) / 3600000, self.snapshot.age or 0,
            math.floor((self.snapshot.damage or 0) * 100 + 0.5), math.floor((self.snapshot.wear or 0) * 100 + 0.5)))
    end

    -- Price options in 5 % steps across the allowed band, default 100 %
    self.priceOptions = {}
    local texts, defaultIndex = {}, 1
    local steps = math.floor((cfg.PRICE_FACTOR_MAX - cfg.PRICE_FACTOR_MIN) / GlobalMarketVehicleDialog.PRICE_STEP + 0.5)
    for i = 0, steps do
        local factor = cfg.PRICE_FACTOR_MIN + i * GlobalMarketVehicleDialog.PRICE_STEP
        table.insert(self.priceOptions, factor)
        table.insert(texts, string.format(g_i18n:getText("ui_gm_vehicles_priceOption"),
            math.floor(factor * 100 + 0.5), g_i18n:formatMoney(self.dealerValue * factor, 0, true, true)))
        if math.abs(factor - 1) < 0.001 then
            defaultIndex = #self.priceOptions
        end
    end
    if self.selectorPrice ~= nil then
        self.selectorPrice:setTexts(texts)
        self.selectorPrice:setState(defaultIndex, false)
    end

    -- Local / online (#36): the online entry only exists while the online vehicle market is available
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    self.isOnlineAvailable = gm ~= nil and gm.getAreOnlineVehiclesAvailable ~= nil and gm:getAreOnlineVehiclesAvailable()
    if self.selectorMode ~= nil then
        local modeTexts = { g_i18n:getText("ui_gm_vehicles_mode_local") }
        if self.isOnlineAvailable then
            table.insert(modeTexts, g_i18n:getText("ui_gm_vehicles_mode_online"))
        end
        self.selectorMode:setTexts(modeTexts)
        self.selectorMode:setState(GlobalMarketVehicleDialog.MODE_LOCAL, false)
        self.selectorMode:setDisabled(not self.isOnlineAvailable)
    end
    self:updateDurationOptions()

    self:updateReceipt()
    if self.selectorPrice ~= nil then
        FocusManager:setFocus(self.selectorPrice)
    end
end

function GlobalMarketVehicleDialog:getSelectedPriceFactor()
    local index = (self.selectorPrice ~= nil) and self.selectorPrice:getState() or 1
    return self.priceOptions[index] or 1
end

function GlobalMarketVehicleDialog:getSelectedDuration()
    local index = (self.selectorDuration ~= nil) and self.selectorDuration:getState() or 1
    return self.durationOptions[index] or self.durationOptions[1] or GlobalMarketVehicleDialog.DEFAULT_DURATION
end

---Returns true if the online mode is selected (#36)
---@return boolean
function GlobalMarketVehicleDialog:getIsOnlineSelected()
    return self.isOnlineAvailable and self.selectorMode ~= nil
        and self.selectorMode:getState() == GlobalMarketVehicleDialog.MODE_ONLINE
end

---Returns the display text of a duration option for the selected mode
---@param value number Months (local) or hours (online)
---@return string
function GlobalMarketVehicleDialog:formatDuration(value)
    if self:getIsOnlineSelected() then
        return string.format(g_i18n:getText("ui_gm_vehicles_durationHours"), value)
    end
    return string.format(g_i18n:getText("ui_gm_vehicles_durationOption"), value)
end

---Fills the duration selector: in-game months (local) or real-time hours (online)
function GlobalMarketVehicleDialog:updateDurationOptions()
    local cfg = GlobalMarket.VEHICLE_MARKET
    local values, default = {}, GlobalMarketVehicleDialog.DEFAULT_DURATION
    if self:getIsOnlineSelected() then
        values = GlobalMarket.VEHICLE_ONLINE.DURATION_HOURS
        default = GlobalMarketVehicleDialog.DEFAULT_ONLINE_HOURS
    else
        for months = cfg.DURATION_MIN, cfg.DURATION_MAX do
            table.insert(values, months)
        end
    end
    self.durationOptions = {}
    local texts, defaultIndex = {}, 1
    for _, value in ipairs(values) do
        table.insert(self.durationOptions, value)
        table.insert(texts, self:formatDuration(value))
        if value == default then
            defaultIndex = #self.durationOptions
        end
    end
    if self.selectorDuration ~= nil then
        self.selectorDuration:setTexts(texts)
        self.selectorDuration:setState(defaultIndex, false)
    end
end

function GlobalMarketVehicleDialog:onClickMode(state)
    self:updateDurationOptions()
    self:updateReceipt()
end

function GlobalMarketVehicleDialog:onClickPrice(state)
    self:updateReceipt()
end

function GlobalMarketVehicleDialog:onClickDuration(state)
    self:updateReceipt()
end

---Sets a receipt row (label + value with colors)
function GlobalMarketVehicleDialog:setReceiptRow(labelElem, valueElem, labelText, valueText, valueColor, labelColor)
    if labelElem ~= nil then
        local lc = labelColor or COLOR_LABEL
        labelElem:setText(labelText or "")
        labelElem:setTextColor(lc[1], lc[2], lc[3], lc[4])
    end
    if valueElem ~= nil then
        local vc = valueColor or COLOR_WHITE
        valueElem:setText(valueText or "")
        valueElem:setTextColor(vc[1], vc[2], vc[3], vc[4])
    end
end

---Renders dealer value, NPC payout, duration and the asking price
function GlobalMarketVehicleDialog:updateReceipt()
    local factor = self:getSelectedPriceFactor()
    local asking = math.floor(self.dealerValue * factor + 0.5)
    local npcPayout = math.floor(asking * (1 - GlobalMarket.VEHICLE_MARKET.NPC_COMMISSION) + 0.5)
    local askingColor = COLOR_WHITE
    if factor < 0.95 then
        askingColor = COLOR_GREEN
    elseif factor > 1.05 then
        askingColor = COLOR_AMBER
    end

    self:setReceiptRow(self.receiptRow1Label, self.receiptRow1Value,
        g_i18n:getText("ui_gm_vehicles_receipt_dealer"), g_i18n:formatMoney(self.dealerValue, 0, true, true), COLOR_MUTED)
    if self:getIsOnlineSelected() then
        -- Online: NPC dealers never buy, every server prices the vehicle by its own dealer value
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value,
            g_i18n:getText("ui_gm_vehicles_receipt_onlinePrice"),
            string.format(g_i18n:getText("ui_gm_vehicles_receipt_onlinePriceValue"), math.floor(factor * 100 + 0.5)), COLOR_MUTED)
    else
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value,
            string.format(g_i18n:getText("ui_gm_vehicles_receipt_npc"), math.floor(GlobalMarket.VEHICLE_MARKET.NPC_COMMISSION * 100 + 0.5)),
            g_i18n:formatMoney(npcPayout, 0, true, true), COLOR_MUTED)
    end
    self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value,
        g_i18n:getText("ui_gm_vehicles_receipt_duration"), self:formatDuration(self:getSelectedDuration()), COLOR_WHITE)
    self:setReceiptRow(self.receiptTotalLabel, self.receiptTotalValue,
        g_i18n:getText("ui_gm_vehicles_receipt_asking"), g_i18n:formatMoney(asking, 0, true, true), askingColor, COLOR_WHITE)
end

function GlobalMarketVehicleDialog:onClickOk()
    if self.vehicle ~= nil and VehicleMarketActionEvent ~= nil then
        VehicleMarketActionEvent.dispatch(VehicleMarketActionEvent.ACTION_CREATE, self.farmId, self.vehicle, 0,
            self:getSelectedPriceFactor(), self:getSelectedDuration(), nil, self:getIsOnlineSelected())
    end
    GlobalMarketVehicleDialog:superClass().onClickOk(self)
    self:close()
    return false
end

function GlobalMarketVehicleDialog:onClickBack()
    GlobalMarketVehicleDialog:superClass().onClickBack(self)
    self:close()
    return false
end

function GlobalMarketVehicleDialog:onClose()
    GlobalMarketVehicleDialog:superClass().onClose(self)
    self.vehicle = nil
    self.snapshot = nil
end

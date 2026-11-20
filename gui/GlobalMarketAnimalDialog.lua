-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalDialog.lua
-- Livestock market (#15): modal dialog with two modes.
--   LIST: list animals of an own group (count, asking price in percent of the dealer value, duration)
--   BUY:  buy a listing with barn delivery (automatic or chosen barn, plus transport fee) or dealer pickup
--   DEMAND: sell animals of an own group to the active great demand (count, dealer value plus bonus)
-- The server validates every request again; the dialog only prevents obviously impossible requests.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketAnimalDialog = {}
local GlobalMarketAnimalDialog_mt = Class(GlobalMarketAnimalDialog, YesNoDialog)

GlobalMarketAnimalDialog.MODE_LIST = 1
GlobalMarketAnimalDialog.MODE_BUY = 2
GlobalMarketAnimalDialog.MODE_DEMAND = 3
GlobalMarketAnimalDialog.PRICE_STEP = 0.05
GlobalMarketAnimalDialog.DEFAULT_DURATION = 1

local COLOR_LABEL = { 0.78, 0.80, 0.82, 1 }
local COLOR_WHITE = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.85, 0.85, 0.85, 1 }
local COLOR_GREEN = { 0.46, 0.80, 0.15, 1 }
local COLOR_AMBER = { 0.95, 0.68, 0.20, 1 }
local COLOR_RED   = { 0.92, 0.28, 0.22, 1 }

function GlobalMarketAnimalDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketAnimalDialog_mt)
    self.mode = GlobalMarketAnimalDialog.MODE_LIST
    self.args = {}
    self.options1, self.options2, self.options3 = {}, {}, {}
    self.blockReason = nil
    return self
end

---Opens the dialog to list animals of an own group
---@param args table { source, cluster, title, condition, image, farmId }
function GlobalMarketAnimalDialog:showList(args)
    self.mode = GlobalMarketAnimalDialog.MODE_LIST
    self.args = args or {}
    g_gui:showDialog("GlobalMarketAnimalDialog")
end

---Opens the dialog to buy a market listing
---@param args table { listing, title, condition, image, farmId }
function GlobalMarketAnimalDialog:showBuy(args)
    self.mode = GlobalMarketAnimalDialog.MODE_BUY
    self.args = args or {}
    g_gui:showDialog("GlobalMarketAnimalDialog")
end

---Opens the dialog to sell animals of an own group to the active great demand
---@param args table { source, cluster, title, condition, image, farmId }
function GlobalMarketAnimalDialog:showDemand(args)
    self.mode = GlobalMarketAnimalDialog.MODE_DEMAND
    self.args = args or {}
    g_gui:showDialog("GlobalMarketAnimalDialog")
end

-- =========================================================================
-- OPTION BUILDERS
-- =========================================================================

---Returns the selectable animal counts: 1-10 single, then steps of 5 up to 50, then steps of 10, always incl. the maximum
---@param maxCount number
---@return table counts
local function buildCountOptions(maxCount)
    local counts = {}
    local count = 1
    while count <= maxCount do
        table.insert(counts, count)
        if count < 10 then
            count = count + 1
        elseif count < 50 then
            count = count + 5
        else
            count = count + 10
        end
    end
    if counts[#counts] ~= maxCount and maxCount > 0 then
        table.insert(counts, maxCount)
    end
    return counts
end

---Fills a selector with texts and selects an index without firing its callback
local function setSelector(selector, texts, index)
    if selector == nil then
        return
    end
    selector:setTexts(texts)
    selector:setState(math.max(1, math.min(index, #texts)), false)
end

---Returns the selected value of a selector
local function getSelected(selector, options, default)
    local index = (selector ~= nil) and selector:getState() or 1
    local value = options[index]
    if value == nil then
        return default
    end
    return value
end

function GlobalMarketAnimalDialog:onOpen()
    GlobalMarketAnimalDialog:superClass().onOpen(self)
    local args = self.args
    local isList = (self.mode == GlobalMarketAnimalDialog.MODE_LIST)
    local isDemand = (self.mode == GlobalMarketAnimalDialog.MODE_DEMAND)
    local titleKey, okKey = "ui_gm_animals_dialog_titleBuy", "ui_gm_animals_action_buy"
    if isList then
        titleKey, okKey = "ui_gm_animals_dialog_titleList", "ui_gm_vehicles_action_list"
    elseif isDemand then
        titleKey, okKey = "ui_gm_animals_dialog_titleDemand", "ui_gm_animals_action_demandSellShort"
    end

    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(string.format(g_i18n:getText(titleKey), tostring(args.title)))
    end
    if self.dialogAnimalIcon ~= nil then
        self.dialogAnimalIcon:setVisible(args.image ~= nil)
        if args.image ~= nil then
            self.dialogAnimalIcon:setImageFilename(args.image)
        end
    end
    if self.headerBoxLayout ~= nil then
        self.headerBoxLayout:invalidateLayout()
    end
    if self.yesButton ~= nil then
        self.yesButton:setText(g_i18n:getText(okKey))
    end

    if isList then
        self:setupListMode()
    elseif isDemand then
        self:setupDemandMode()
    else
        self:setupBuyMode()
    end
    self:updateReceipt()
    if self.selector1 ~= nil then
        FocusManager:setFocus(self.selector1)
    end
end

---LIST: count, price and duration selectors
function GlobalMarketAnimalDialog:setupListMode()
    local cfg = GlobalMarket.ANIMAL_MARKET
    local cluster = self.args.cluster
    local maxCount = (cluster ~= nil) and cluster:getNumAnimals() or 0
    if cluster ~= nil and not cluster:getSupportsMerging() then
        maxCount = math.min(maxCount, 1)
    end

    self.options1 = buildCountOptions(maxCount)
    local countTexts = {}
    for _, count in ipairs(self.options1) do
        table.insert(countTexts, string.format(g_i18n:getText("ui_gm_animals_countOption"), count, maxCount))
    end
    setSelector(self.selector1, countTexts, #self.options1)

    self.options2 = {}
    local steps = math.floor((cfg.PRICE_FACTOR_MAX - cfg.PRICE_FACTOR_MIN) / GlobalMarketAnimalDialog.PRICE_STEP + 0.5)
    local defaultPrice = 1
    for i = 0, steps do
        local factor = cfg.PRICE_FACTOR_MIN + i * GlobalMarketAnimalDialog.PRICE_STEP
        table.insert(self.options2, factor)
        if math.abs(factor - 1) < 0.001 then
            defaultPrice = #self.options2
        end
    end
    self:updatePriceTexts(defaultPrice)

    self.options3 = {}
    local durationTexts, durationDefault = {}, 1
    for months = cfg.DURATION_MIN, cfg.DURATION_MAX do
        table.insert(self.options3, months)
        table.insert(durationTexts, string.format(g_i18n:getText("ui_gm_vehicles_durationOption"), months))
        if months == GlobalMarketAnimalDialog.DEFAULT_DURATION then
            durationDefault = #self.options3
        end
    end
    setSelector(self.selector3, durationTexts, durationDefault)
    for _, selector in ipairs({ self.selector1, self.selector2, self.selector3 }) do
        selector:setVisible(true)
        selector:setDisabled(false)
    end
    self.selector1:setDisabled(#self.options1 <= 1)
end

---LIST: rewrites the price texts for the selected count (keeps the selected price)
---@param index number|nil Price index to select (default: current)
function GlobalMarketAnimalDialog:updatePriceTexts(index)
    if self.selector2 == nil then
        return
    end
    local value = self:getListDealerValue()
    local texts = {}
    for _, factor in ipairs(self.options2) do
        table.insert(texts, string.format(g_i18n:getText("ui_gm_vehicles_priceOption"),
            math.floor(factor * 100 + 0.5), g_i18n:formatMoney(value * factor, 0, true, true)))
    end
    setSelector(self.selector2, texts, index or self.selector2:getState())
end

---LIST: dealer value of the selected count (what the dealer would pay)
---@return number
function GlobalMarketAnimalDialog:getListDealerValue()
    local cluster = self.args.cluster
    if cluster == nil then
        return 0
    end
    return cluster:getSellPrice() * getSelected(self.selector1, self.options1, 1)
end

---LIST: dealer's new price of the selected count incl. transport fee (nil if the dealer does not sell this age)
---@return number|nil
function GlobalMarketAnimalDialog:getListDealerNewPrice()
    local cluster = self.args.cluster
    if cluster == nil then
        return nil
    end
    local animalSystem = g_currentMission.animalSystem
    local subTypeIndex = cluster:getSubTypeIndex()
    local visual = animalSystem:getVisualByAge(subTypeIndex, cluster.age)
    if visual == nil or visual.store == nil or not visual.store.canBeBought then
        return nil
    end
    local count = getSelected(self.selector1, self.options1, 1)
    return (animalSystem:getAnimalBuyPrice(subTypeIndex, cluster.age) or 0) * count + cluster:getTranportationFee(count)
end

---DEMAND: count selector only (up to the group size and the remaining quota)
function GlobalMarketAnimalDialog:setupDemandMode()
    local gm = g_currentMission.globalMarket
    local cluster = self.args.cluster
    local maxCount = math.min(cluster ~= nil and cluster:getNumAnimals() or 0, gm:getAnimalDemandRemaining())
    self.options1 = buildCountOptions(maxCount)
    local countTexts = {}
    for _, count in ipairs(self.options1) do
        table.insert(countTexts, string.format(g_i18n:getText("ui_gm_animals_countOption"), count, maxCount))
    end
    if #countTexts == 0 then
        self.options1 = { 0 }
        countTexts = { string.format(g_i18n:getText("ui_gm_animals_countOption"), 0, 0) }
    end
    setSelector(self.selector1, countTexts, #self.options1)
    self.selector1:setVisible(true)
    self.selector1:setDisabled(#self.options1 <= 1)
    self.selector2:setVisible(false)
    self.selector3:setVisible(false)
end

---BUY: delivery and barn selectors
function GlobalMarketAnimalDialog:setupBuyMode()
    local D = GlobalMarket.ANIMAL_DELIVERY
    local snapshot = self.args.listing.snapshot
    local fee = GlobalMarketAnimalListings.getTransportFee(snapshot) or 0

    self.options1 = { D.BARN }
    local deliveryTexts = { string.format(g_i18n:getText("ui_gm_animals_delivery_barn"), g_i18n:formatMoney(fee, 0, true, true)) }
    if GlobalMarket.getHasAnimalDealer() then
        table.insert(self.options1, D.PICKUP)
        table.insert(deliveryTexts, g_i18n:getText("ui_gm_animals_delivery_pickup"))
    end
    setSelector(self.selector1, deliveryTexts, 1)
    self.selector1:setVisible(true)
    self.selector1:setDisabled(#self.options1 <= 1)

    self:updateBarnOptions()
    self.selector3:setVisible(false)
end

---BUY: rebuilds the barn options (automatic plus every own barn with space for all animals)
function GlobalMarketAnimalDialog:updateBarnOptions()
    local farmId = self.args.farmId
    local snapshot = self.args.listing.snapshot
    local numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot)
    local isBarn = (getSelected(self.selector1, self.options1, GlobalMarket.ANIMAL_DELIVERY.BARN) == GlobalMarket.ANIMAL_DELIVERY.BARN)

    self.options2 = {}
    local texts = {}
    if not isBarn then
        table.insert(self.options2, false)
        table.insert(texts, g_i18n:getText("ui_gm_animals_barn_pickup"))
    else
        local capacity = GlobalMarket.getAnimalBarnCapacity(farmId, snapshot, nil)
        if capacity >= numAnimals then
            table.insert(self.options2, false)
            table.insert(texts, string.format(g_i18n:getText("ui_gm_animals_barn_auto"), capacity))
        end
        local subTypeIndex = snapshot.cluster ~= nil and snapshot.cluster:getSubTypeIndex() or nil
        for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farmId, subTypeIndex)) do
            local free = GlobalMarketAnimalListings.getFreeSlots(barn, snapshot, farmId)
            if free >= numAnimals then
                table.insert(self.options2, barn)
                table.insert(texts, string.format(g_i18n:getText("ui_gm_animals_barn_option"), barn:getName(), free))
            end
        end
        if #self.options2 == 0 then
            table.insert(self.options2, false)
            table.insert(texts, g_i18n:getText("ui_gm_animals_barn_none"))
        end
    end
    setSelector(self.selector2, texts, 1)
    self.selector2:setVisible(true)
    self.selector2:setDisabled(#self.options2 <= 1)
end

-- =========================================================================
-- RECEIPT
-- =========================================================================

---Sets a receipt row (label + value with colors)
function GlobalMarketAnimalDialog:setReceiptRow(labelElem, valueElem, labelText, valueText, valueColor, labelColor)
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

---Returns the color of a price factor (bargain / markup / neutral)
local function getFactorColor(factor)
    if factor < 0.95 then
        return COLOR_GREEN
    elseif factor > 1.05 then
        return COLOR_AMBER
    end
    return COLOR_WHITE
end

---Formats a new price ("not available at the dealer" if nil)
local function formatNewPrice(newPrice)
    if newPrice == nil then
        return g_i18n:getText("ui_gm_animals_notAtDealerShop")
    end
    return g_i18n:formatMoney(newPrice, 0, true, true)
end

function GlobalMarketAnimalDialog:updateReceipt()
    local money = function(value) return g_i18n:formatMoney(value or 0, 0, true, true) end
    self.blockReason = nil

    if self.mode == GlobalMarketAnimalDialog.MODE_LIST then
        local factor = getSelected(self.selector2, self.options2, 1)
        local value = self:getListDealerValue()
        local asking = math.floor(value * factor + 0.5)
        local npcPayout = math.floor(asking * (1 - GlobalMarket.ANIMAL_MARKET.NPC_COMMISSION) + 0.5)
        self:setReceiptRow(self.receiptRow1Label, self.receiptRow1Value,
            g_i18n:getText("ui_gm_vehicles_receipt_dealer"), money(value), COLOR_MUTED)
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value,
            g_i18n:getText("ui_gm_animals_receipt_newPrice"), formatNewPrice(self:getListDealerNewPrice()), COLOR_MUTED)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value,
            string.format(g_i18n:getText("ui_gm_vehicles_receipt_npc"), math.floor(GlobalMarket.ANIMAL_MARKET.NPC_COMMISSION * 100 + 0.5)),
            money(npcPayout), COLOR_MUTED)
        self:setReceiptRow(self.receiptTotalLabel, self.receiptTotalValue,
            g_i18n:getText("ui_gm_vehicles_receipt_asking"), money(asking), getFactorColor(factor), COLOR_WHITE)
    elseif self.mode == GlobalMarketAnimalDialog.MODE_DEMAND then
        local gm = g_currentMission.globalMarket
        local cluster = self.args.cluster
        local count = getSelected(self.selector1, self.options1, 0)
        local value = (cluster ~= nil) and math.floor(cluster:getSellPrice() * count + 0.5) or 0
        local payout = (cluster ~= nil and gm.animalDemand ~= nil) and gm:getAnimalDemandPayout(cluster, count) or 0
        local isEligible, reason = false, "demandInactive"
        if cluster ~= nil and gm.animalDemand ~= nil then
            isEligible, reason = gm:getAnimalDemandEligibility(self.args.source, self.args.farmId, cluster.id, count)
        end
        if not isEligible then
            self.blockReason = reason or "invalid"
        end
        local bonusPct = (gm.animalDemand ~= nil) and math.floor((gm.animalDemand.bonus or 0) * 100 + 0.5) or 0
        self:setReceiptRow(self.receiptRow1Label, self.receiptRow1Value,
            g_i18n:getText("ui_gm_vehicles_receipt_dealer"), money(value), COLOR_MUTED)
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value,
            string.format(g_i18n:getText("ui_gm_animals_receipt_bonus"), bonusPct), money(payout - value), COLOR_GREEN)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value,
            g_i18n:getText("ui_gm_animals_receipt_quota"),
            string.format(g_i18n:getText("ui_gm_animals_animalsCount"), gm:getAnimalDemandRemaining()), COLOR_MUTED)
        self:setReceiptRow(self.receiptTotalLabel, self.receiptTotalValue,
            g_i18n:getText("ui_gm_animals_receipt_payout"), money(payout), self.blockReason ~= nil and COLOR_RED or COLOR_GREEN, COLOR_WHITE)
    else
        local listing = self.args.listing
        local snapshot = listing.snapshot
        local price = GlobalMarketAnimalListings.getListingPrice(listing) or 0
        local isBarn = (getSelected(self.selector1, self.options1, GlobalMarket.ANIMAL_DELIVERY.BARN) == GlobalMarket.ANIMAL_DELIVERY.BARN)
        local fee = isBarn and math.floor((GlobalMarketAnimalListings.getTransportFee(snapshot) or 0) + 0.5) or 0
        local total = price + fee

        if isBarn then
            local numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot)
            local subTypeIndex = snapshot.cluster ~= nil and snapshot.cluster:getSubTypeIndex() or nil
            if #GlobalMarketAnimalListings.getFarmBarns(self.args.farmId, subTypeIndex) == 0 then
                self.blockReason = "noBarn"
            elseif GlobalMarket.getAnimalBarnCapacity(self.args.farmId, snapshot, nil) < numAnimals then
                self.blockReason = "noSpace"
            end
        end
        if self.blockReason == nil and g_currentMission:getMoney(self.args.farmId) < total then
            self.blockReason = "notEnoughMoney"
        end

        self:setReceiptRow(self.receiptRow1Label, self.receiptRow1Value,
            string.format(g_i18n:getText("ui_gm_animals_receipt_price"), math.floor((listing.priceFactor or 1) * 100 + 0.5)),
            money(price), getFactorColor(listing.priceFactor or 1))
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value,
            g_i18n:getText("ui_gm_animals_receipt_transport"), money(fee), COLOR_MUTED)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value,
            g_i18n:getText("ui_gm_animals_receipt_newPrice"), formatNewPrice(GlobalMarketAnimalListings.getDealerNewPrice(snapshot)), COLOR_MUTED)
        self:setReceiptRow(self.receiptTotalLabel, self.receiptTotalValue,
            g_i18n:getText("ui_gm_animals_receipt_total"), money(total), self.blockReason ~= nil and COLOR_RED or COLOR_WHITE, COLOR_WHITE)
    end

    if self.dialogInfoTextElement ~= nil then
        if self.blockReason ~= nil then
            self.dialogInfoTextElement:setText(GlobalMarket.getAnimalMarketReasonText(self.blockReason))
            self.dialogInfoTextElement:setTextColor(COLOR_RED[1], COLOR_RED[2], COLOR_RED[3], COLOR_RED[4])
        else
            self.dialogInfoTextElement:setText(self.args.condition or "")
            self.dialogInfoTextElement:setTextColor(COLOR_WHITE[1], COLOR_WHITE[2], COLOR_WHITE[3], COLOR_WHITE[4])
        end
    end
    if self.yesButton ~= nil then
        self.yesButton:setDisabled(self.blockReason ~= nil)
    end
end

-- =========================================================================
-- CALLBACKS
-- =========================================================================

function GlobalMarketAnimalDialog:onClickSelector1(state)
    if self.mode == GlobalMarketAnimalDialog.MODE_LIST then
        self:updatePriceTexts(nil)
    elseif self.mode == GlobalMarketAnimalDialog.MODE_BUY then
        self:updateBarnOptions()
    end
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickSelector2(state)
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickSelector3(state)
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickOk()
    if self.blockReason ~= nil then
        return false
    end
    local args = self.args
    if self.mode == GlobalMarketAnimalDialog.MODE_LIST then
        if args.source ~= nil and args.cluster ~= nil then
            AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_CREATE, args.farmId, {
                object = args.source,
                clusterId = args.cluster.id,
                numAnimals = getSelected(self.selector1, self.options1, 1),
                priceFactor = getSelected(self.selector2, self.options2, 1),
                durationMonths = getSelected(self.selector3, self.options3, GlobalMarketAnimalDialog.DEFAULT_DURATION)
            })
        end
    elseif self.mode == GlobalMarketAnimalDialog.MODE_DEMAND then
        if args.source ~= nil and args.cluster ~= nil then
            AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_DEMAND_SELL, args.farmId, {
                object = args.source,
                clusterId = args.cluster.id,
                numAnimals = getSelected(self.selector1, self.options1, 0)
            })
        end
    elseif args.listing ~= nil then
        local barn = getSelected(self.selector2, self.options2, false)
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_BUY, args.farmId, {
            object = (barn ~= false) and barn or nil,
            targetId = args.listing.id,
            deliveryMode = getSelected(self.selector1, self.options1, GlobalMarket.ANIMAL_DELIVERY.BARN)
        })
    end
    GlobalMarketAnimalDialog:superClass().onClickOk(self)
    self:close()
    return false
end

function GlobalMarketAnimalDialog:onClickBack()
    GlobalMarketAnimalDialog:superClass().onClickBack(self)
    self:close()
    return false
end

function GlobalMarketAnimalDialog:onClose()
    GlobalMarketAnimalDialog:superClass().onClose(self)
    self.args = {}
end

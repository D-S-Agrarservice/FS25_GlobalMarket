-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalDialog.lua
-- Livestock market (#15): modal dialog with four modes.
--   LIST:   list animals of an own group, as fixed price (count, price 80-200 %, 1-3 months) or as
--           auction (count, start price 50-150 %, 6/12/24/48 hours, optional buy-now price)
--   BUY:    buy a fixed-price listing with barn delivery (automatic or chosen barn, plus transport fee) or pickup
--   DEMAND: sell animals of an own group to the active great demand (count, dealer value plus bonus)
--   BID:    bid on an auction or raise the own bid; the last option is the buy-now price while available
-- The dialog grows with the number of visible selectors. The server validates every request again;
-- the dialog only prevents obviously impossible requests.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketAnimalDialog = {}
local GlobalMarketAnimalDialog_mt = Class(GlobalMarketAnimalDialog, YesNoDialog)

GlobalMarketAnimalDialog.MODE_LIST = 1
GlobalMarketAnimalDialog.MODE_BUY = 2
GlobalMarketAnimalDialog.MODE_DEMAND = 3
GlobalMarketAnimalDialog.MODE_BID = 4
GlobalMarketAnimalDialog.PRICE_STEP = 0.05
GlobalMarketAnimalDialog.DEFAULT_DURATION = 1
GlobalMarketAnimalDialog.DEFAULT_AUCTION_HOURS = 12
GlobalMarketAnimalDialog.MAX_BID_OPTIONS = 40

-- Layout: selectors are 46 px apart, the receipt starts 54 px below the last visible selector
local SELECTOR_FIRST_Y = 90
local SELECTOR_SPACING = 46
local RECEIPT_GAP = 54
local LAYOUT_BASE_SELECTORS = 3 -- The XML dialog height fits three selectors

local COLOR_LABEL = { 0.78, 0.80, 0.82, 1 }
local COLOR_WHITE = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.85, 0.85, 0.85, 1 }
local COLOR_GREEN = { 0.46, 0.80, 0.15, 1 }
local COLOR_AMBER = { 0.95, 0.68, 0.20, 1 }
local COLOR_RED   = { 0.92, 0.28, 0.22, 1 }

local SALE_FIXED = "FIXED"
local SALE_AUCTION = "AUCTION"
local BUY_NOW_OPTION = "BUY_NOW"

function GlobalMarketAnimalDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketAnimalDialog_mt)
    self.mode = GlobalMarketAnimalDialog.MODE_LIST
    self.args = {}
    self.options = { {}, {}, {}, {}, {} }
    self.blockReason = nil
    self.defaultDialogHeight = nil
    return self
end

---Opens the dialog to list animals of an own group
---@param args table { source, cluster, title, condition, image, farmId }
function GlobalMarketAnimalDialog:showList(args)
    self.mode = GlobalMarketAnimalDialog.MODE_LIST
    self.args = args or {}
    g_gui:showDialog("GlobalMarketAnimalDialog")
end

---Opens the dialog to buy a fixed-price market listing
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

---Opens the dialog to bid on an auction
---@param args table { listing, title, condition, image, farmId }
function GlobalMarketAnimalDialog:showBid(args)
    self.mode = GlobalMarketAnimalDialog.MODE_BID
    self.args = args or {}
    g_gui:showDialog("GlobalMarketAnimalDialog")
end

-- =========================================================================
-- HELPERS
-- =========================================================================

local function money(value)
    return g_i18n:formatMoney(value or 0, 0, true, true)
end

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

---Returns factors from minFactor to maxFactor in PRICE_STEP steps
local function buildFactorOptions(minFactor, maxFactor)
    local factors = {}
    local steps = math.floor((maxFactor - minFactor) / GlobalMarketAnimalDialog.PRICE_STEP + 0.5)
    for i = 0, math.max(0, steps) do
        table.insert(factors, minFactor + i * GlobalMarketAnimalDialog.PRICE_STEP)
    end
    return factors
end

---Returns the index of the factor closest to a target
local function getClosestIndex(factors, target)
    local bestIndex, bestDiff = 1, math.huge
    for i, factor in ipairs(factors) do
        local diff = math.abs(factor - target)
        if diff < bestDiff then
            bestIndex, bestDiff = i, diff
        end
    end
    return bestIndex
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
    return money(newPrice)
end

---Returns selector i
function GlobalMarketAnimalDialog:getSelector(i)
    return self["selector" .. i]
end

---Fills selector i with options and texts, selects an index without firing its callback
function GlobalMarketAnimalDialog:setOptions(i, options, texts, index)
    self.options[i] = options
    local selector = self:getSelector(i)
    if selector == nil then
        return
    end
    selector:setTexts(texts)
    selector:setState(math.max(1, math.min(index or 1, #texts)), false)
    selector:setVisible(true)
    selector:setDisabled(#options <= 1)
end

---Returns the selected value of selector i
function GlobalMarketAnimalDialog:getValue(i, default)
    local selector = self:getSelector(i)
    local index = (selector ~= nil) and selector:getState() or 1
    local value = self.options[i][index]
    if value == nil then
        return default
    end
    return value
end

---Shows the first numVisible selectors, hides the rest and sizes the dialog to fit
---@param numVisible number
function GlobalMarketAnimalDialog:applyLayout(numVisible)
    for i = numVisible + 1, 5 do
        local selector = self:getSelector(i)
        if selector ~= nil then
            selector:setVisible(false)
        end
    end
    if self.dialogElement == nil or self.receiptBox == nil then
        return
    end
    if self.defaultDialogHeight == nil then
        self.defaultDialogHeight = self.dialogElement.size[2]
    end
    local extraPx = (numVisible - LAYOUT_BASE_SELECTORS) * SELECTOR_SPACING
    self.dialogElement:setSize(nil, self.defaultDialogHeight + GuiUtils.getNormalizedYValue(string.format("%dpx", extraPx)))
    local receiptY = SELECTOR_FIRST_Y + (numVisible - 1) * SELECTOR_SPACING + RECEIPT_GAP
    self.receiptBox:setPosition(nil, GuiUtils.getNormalizedYValue(string.format("%dpx", -receiptY)))
end

---Sets a receipt row (label + value with colors)
function GlobalMarketAnimalDialog:setReceiptRow(row, labelText, valueText, valueColor, labelColor)
    local labelElem, valueElem
    if row == "total" then
        labelElem, valueElem = self.receiptTotalLabel, self.receiptTotalValue
    else
        labelElem, valueElem = self["receiptRow" .. row .. "Label"], self["receiptRow" .. row .. "Value"]
    end
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

-- =========================================================================
-- OPEN
-- =========================================================================

function GlobalMarketAnimalDialog:onOpen()
    GlobalMarketAnimalDialog:superClass().onOpen(self)
    local args = self.args
    local M = GlobalMarketAnimalDialog
    local titleKey = "ui_gm_animals_dialog_titleBuy"
    if self.mode == M.MODE_LIST then
        titleKey = "ui_gm_animals_dialog_titleList"
    elseif self.mode == M.MODE_DEMAND then
        titleKey = "ui_gm_animals_dialog_titleDemand"
    elseif self.mode == M.MODE_BID then
        titleKey = "ui_gm_animals_dialog_titleBid"
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

    if self.mode == M.MODE_LIST then
        self:setupListMode()
    elseif self.mode == M.MODE_DEMAND then
        self:setupDemandMode()
    elseif self.mode == M.MODE_BID then
        self:setupBidMode()
    else
        self:setupBuyMode()
    end
    self:updateReceipt()
    if self.selector1 ~= nil then
        FocusManager:setFocus(self.selector1)
    end
end

-- =========================================================================
-- LIST (fixed price or auction)
-- =========================================================================

---LIST: count, sale mode, then the price/duration selectors of the chosen sale mode
function GlobalMarketAnimalDialog:setupListMode()
    local cluster = self.args.cluster
    local maxCount = (cluster ~= nil) and cluster:getNumAnimals() or 0
    if cluster ~= nil and not cluster:getSupportsMerging() then
        maxCount = math.min(maxCount, 1)
    end
    local counts = buildCountOptions(maxCount)
    local countTexts = {}
    for _, count in ipairs(counts) do
        table.insert(countTexts, string.format(g_i18n:getText("ui_gm_animals_countOption"), count, maxCount))
    end
    self:setOptions(1, counts, countTexts, #counts)
    self:setOptions(2, { SALE_FIXED, SALE_AUCTION },
        { g_i18n:getText("ui_gm_animals_saleMode_fixed"), g_i18n:getText("ui_gm_animals_saleMode_auction") }, 1)
    self:setupSaleModeOptions()
end

---LIST: dealer value of the selected count (what the dealer would pay)
---@return number
function GlobalMarketAnimalDialog:getListDealerValue()
    local cluster = self.args.cluster
    if cluster == nil then
        return 0
    end
    return cluster:getSellPrice() * self:getValue(1, 1)
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
    local count = self:getValue(1, 1)
    return (animalSystem:getAnimalBuyPrice(subTypeIndex, cluster.age) or 0) * count + cluster:getTranportationFee(count)
end

---LIST: builds price (3), duration (4) and, for auctions, buy-now (5) for the selected sale mode
function GlobalMarketAnimalDialog:setupSaleModeOptions()
    local isAuction = (self:getValue(2, SALE_FIXED) == SALE_AUCTION)
    if isAuction then
        local acfg = GlobalMarketAuction.CONFIG
        local factors = buildFactorOptions(acfg.START_FACTOR_MIN, acfg.START_FACTOR_MAX)
        self:setPriceOptions(factors, getClosestIndex(factors, 0.8))
        local hoursTexts = {}
        for _, hours in ipairs(acfg.DURATIONS) do
            table.insert(hoursTexts, string.format(g_i18n:getText("ui_gm_animals_durationHours"), hours))
        end
        self:setOptions(4, acfg.DURATIONS, hoursTexts, getClosestIndex(acfg.DURATIONS, GlobalMarketAnimalDialog.DEFAULT_AUCTION_HOURS))
        self:setupBuyNowOptions()
        self:applyLayout(5)
    else
        local cfg = GlobalMarket.ANIMAL_MARKET
        local factors = buildFactorOptions(cfg.PRICE_FACTOR_MIN, cfg.PRICE_FACTOR_MAX)
        self:setPriceOptions(factors, getClosestIndex(factors, 1))
        local months, monthTexts = {}, {}
        for m = cfg.DURATION_MIN, cfg.DURATION_MAX do
            table.insert(months, m)
            table.insert(monthTexts, string.format(g_i18n:getText("ui_gm_vehicles_durationOption"), m))
        end
        self:setOptions(4, months, monthTexts, getClosestIndex(months, GlobalMarketAnimalDialog.DEFAULT_DURATION))
        self:applyLayout(4)
    end
end

---LIST: price selector (3) with euro amounts for the selected count
---@param factors table
---@param index number
function GlobalMarketAnimalDialog:setPriceOptions(factors, index)
    local value = self:getListDealerValue()
    local isAuction = (self:getValue(2, SALE_FIXED) == SALE_AUCTION)
    local key = isAuction and "ui_gm_animals_startPriceOption" or "ui_gm_vehicles_priceOption"
    local texts = {}
    for _, factor in ipairs(factors) do
        table.insert(texts, string.format(g_i18n:getText(key), math.floor(factor * 100 + 0.5), money(value * factor)))
    end
    self:setOptions(3, factors, texts, index)
end

---LIST (auction): buy-now selector (5): off, or start price + one step up to the maximum
---@param keepFactor number|nil Factor to keep selected if still valid
function GlobalMarketAnimalDialog:setupBuyNowOptions(keepFactor)
    local acfg = GlobalMarketAuction.CONFIG
    local startFactor = self:getValue(3, acfg.START_FACTOR_MIN)
    local value = self:getListDealerValue()
    local options = { 0 }
    local texts = { g_i18n:getText("ui_gm_animals_buyNowOff") }
    for _, factor in ipairs(buildFactorOptions(startFactor + acfg.MIN_INCREMENT, acfg.BUY_NOW_FACTOR_MAX)) do
        table.insert(options, factor)
        table.insert(texts, string.format(g_i18n:getText("ui_gm_animals_buyNowOption"), math.floor(factor * 100 + 0.5), money(value * factor)))
    end
    local index = 1
    if keepFactor ~= nil and keepFactor > 0 then
        index = getClosestIndex(options, keepFactor)
    end
    self:setOptions(5, options, texts, index)
end

-- =========================================================================
-- DEMAND & BUY
-- =========================================================================

---DEMAND: count selector only (up to the group size and the remaining quota)
function GlobalMarketAnimalDialog:setupDemandMode()
    local gm = g_currentMission.globalMarket
    local cluster = self.args.cluster
    local maxCount = math.min(cluster ~= nil and cluster:getNumAnimals() or 0, gm:getAnimalDemandRemaining())
    local counts = buildCountOptions(maxCount)
    local countTexts = {}
    for _, count in ipairs(counts) do
        table.insert(countTexts, string.format(g_i18n:getText("ui_gm_animals_countOption"), count, maxCount))
    end
    if #countTexts == 0 then
        counts = { 0 }
        countTexts = { string.format(g_i18n:getText("ui_gm_animals_countOption"), 0, 0) }
    end
    self:setOptions(1, counts, countTexts, #counts)
    self:applyLayout(1)
end

---BUY: delivery and barn selectors
function GlobalMarketAnimalDialog:setupBuyMode()
    local D = GlobalMarket.ANIMAL_DELIVERY
    local fee = GlobalMarketAnimalListings.getTransportFee(self.args.listing.snapshot) or 0
    local options = { D.BARN }
    local texts = { string.format(g_i18n:getText("ui_gm_animals_delivery_barn"), money(fee)) }
    if GlobalMarket.getHasAnimalDealer() then
        table.insert(options, D.PICKUP)
        table.insert(texts, g_i18n:getText("ui_gm_animals_delivery_pickup"))
    end
    self:setOptions(1, options, texts, 1)
    self:updateBarnOptions()
    self:applyLayout(2)
end

---BUY: rebuilds the barn options (automatic plus every own barn with space for all animals)
function GlobalMarketAnimalDialog:updateBarnOptions()
    local farmId = self.args.farmId
    local snapshot = self.args.listing.snapshot
    local numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot)
    local isBarn = (self:getValue(1, GlobalMarket.ANIMAL_DELIVERY.BARN) == GlobalMarket.ANIMAL_DELIVERY.BARN)
    local options, texts = {}, {}
    if not isBarn then
        table.insert(options, false)
        table.insert(texts, g_i18n:getText("ui_gm_animals_barn_pickup"))
    else
        local capacity = GlobalMarket.getAnimalBarnCapacity(farmId, snapshot, nil)
        if capacity >= numAnimals then
            table.insert(options, false)
            table.insert(texts, string.format(g_i18n:getText("ui_gm_animals_barn_auto"), capacity))
        end
        local subTypeIndex = snapshot.cluster ~= nil and snapshot.cluster:getSubTypeIndex() or nil
        for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farmId, subTypeIndex)) do
            local free = GlobalMarketAnimalListings.getFreeSlots(barn, snapshot, farmId)
            if free >= numAnimals then
                table.insert(options, barn)
                table.insert(texts, string.format(g_i18n:getText("ui_gm_animals_barn_option"), barn:getName(), free))
            end
        end
        if #options == 0 then
            table.insert(options, false)
            table.insert(texts, g_i18n:getText("ui_gm_animals_barn_none"))
        end
    end
    self:setOptions(2, options, texts, 1)
end

-- =========================================================================
-- BID
-- =========================================================================

---BID: returns the base value (dealer value) and the amount the bidder already holds on this auction
---@return number baseValue
---@return number alreadyReserved
function GlobalMarketAnimalDialog:getBidBase()
    local listing = self.args.listing
    local auction = listing.auction
    local baseValue = GlobalMarketAnimalListings.getDealerValue(listing.snapshot) or 0
    local reserved = 0
    if auction.highFactor ~= nil and not auction.highIsNpc and auction.highFarmId == self.args.farmId then
        reserved = GlobalMarketAuction.getAmount(auction.highFactor, baseValue)
    end
    return baseValue, reserved
end

---BID: bid selector from the minimum bid upwards; the buy-now price is the last option while available
function GlobalMarketAnimalDialog:setupBidMode()
    local auction = self.args.listing.auction
    local acfg = GlobalMarketAuction.CONFIG
    local baseValue = self:getBidBase()
    local minFactor = GlobalMarketAuction.getMinBidFactor(auction)
    local maxFactor = acfg.BUY_NOW_FACTOR_MAX
    local hasBuyNow = GlobalMarketAuction.getIsBuyNowAvailable(auction)
    if hasBuyNow then
        maxFactor = auction.buyNowFactor - acfg.MIN_INCREMENT
    end
    local options, texts = {}, {}
    for _, factor in ipairs(buildFactorOptions(minFactor, maxFactor)) do
        if #options >= GlobalMarketAnimalDialog.MAX_BID_OPTIONS then
            break
        end
        table.insert(options, factor)
        table.insert(texts, string.format(g_i18n:getText("ui_gm_animals_bidOption"), math.floor(factor * 100 + 0.5),
            money(GlobalMarketAuction.getAmount(factor, baseValue))))
    end
    if hasBuyNow then
        table.insert(options, BUY_NOW_OPTION)
        table.insert(texts, string.format(g_i18n:getText("ui_gm_animals_bidBuyNow"),
            money(GlobalMarketAuction.getAmount(auction.buyNowFactor, baseValue))))
    end
    if #options == 0 then
        options = { minFactor }
        texts = { string.format(g_i18n:getText("ui_gm_animals_bidOption"), math.floor(minFactor * 100 + 0.5),
            money(GlobalMarketAuction.getAmount(minFactor, baseValue))) }
    end
    self:setOptions(1, options, texts, 1)
    self:applyLayout(1)
end

---BID: selected bid factor and whether it is the buy-now option
---@return number factor
---@return boolean isBuyNow
function GlobalMarketAnimalDialog:getSelectedBid()
    local value = self:getValue(1, 0)
    if value == BUY_NOW_OPTION then
        return self.args.listing.auction.buyNowFactor, true
    end
    return value, false
end

-- =========================================================================
-- RECEIPT
-- =========================================================================

function GlobalMarketAnimalDialog:updateReceipt()
    local M = GlobalMarketAnimalDialog
    self.blockReason = nil
    local okKey = "ui_gm_animals_action_buy"

    if self.mode == M.MODE_LIST then
        local value = self:getListDealerValue()
        local factor = self:getValue(3, 1)
        local amount = math.floor(value * factor + 0.5)
        self:setReceiptRow(1, g_i18n:getText("ui_gm_vehicles_receipt_dealer"), money(value), COLOR_MUTED)
        self:setReceiptRow(2, g_i18n:getText("ui_gm_animals_receipt_newPrice"), formatNewPrice(self:getListDealerNewPrice()), COLOR_MUTED)
        if self:getValue(2, SALE_FIXED) == SALE_AUCTION then
            local buyNow = self:getValue(5, 0)
            self:setReceiptRow(3, g_i18n:getText("ui_gm_animals_receipt_buyNow"),
                (buyNow > 0) and money(value * buyNow) or g_i18n:getText("ui_gm_animals_buyNowNone"), COLOR_MUTED)
            self:setReceiptRow("total", g_i18n:getText("ui_gm_animals_receipt_startPrice"), money(amount), getFactorColor(factor), COLOR_WHITE)
            okKey = "ui_gm_animals_action_auction"
        else
            local npcPayout = math.floor(amount * (1 - GlobalMarket.ANIMAL_MARKET.NPC_COMMISSION) + 0.5)
            self:setReceiptRow(3, string.format(g_i18n:getText("ui_gm_vehicles_receipt_npc"),
                math.floor(GlobalMarket.ANIMAL_MARKET.NPC_COMMISSION * 100 + 0.5)), money(npcPayout), COLOR_MUTED)
            self:setReceiptRow("total", g_i18n:getText("ui_gm_vehicles_receipt_asking"), money(amount), getFactorColor(factor), COLOR_WHITE)
            okKey = "ui_gm_vehicles_action_list"
        end
    elseif self.mode == M.MODE_DEMAND then
        local gm = g_currentMission.globalMarket
        local cluster = self.args.cluster
        local count = self:getValue(1, 0)
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
        self:setReceiptRow(1, g_i18n:getText("ui_gm_vehicles_receipt_dealer"), money(value), COLOR_MUTED)
        self:setReceiptRow(2, string.format(g_i18n:getText("ui_gm_animals_receipt_bonus"), bonusPct), money(payout - value), COLOR_GREEN)
        self:setReceiptRow(3, g_i18n:getText("ui_gm_animals_receipt_quota"),
            string.format(g_i18n:getText("ui_gm_animals_animalsCount"), gm:getAnimalDemandRemaining()), COLOR_MUTED)
        self:setReceiptRow("total", g_i18n:getText("ui_gm_animals_receipt_payout"), money(payout),
            self.blockReason ~= nil and COLOR_RED or COLOR_GREEN, COLOR_WHITE)
        okKey = "ui_gm_animals_action_demandSellShort"
    elseif self.mode == M.MODE_BID then
        local auction = self.args.listing.auction
        local baseValue, reserved = self:getBidBase()
        local factor, isBuyNow = self:getSelectedBid()
        local need = GlobalMarketAuction.getAmount(factor or 0, baseValue) - reserved
        if need > 0 and g_currentMission:getMoney(self.args.farmId) < need then
            self.blockReason = "notEnoughMoney"
        end
        local highText = g_i18n:getText("ui_gm_animals_noBidYet")
        if auction.highFactor ~= nil then
            highText = money(GlobalMarketAuction.getAmount(auction.highFactor, baseValue))
        end
        self:setReceiptRow(1, string.format(g_i18n:getText("ui_gm_animals_receipt_highBid"), GlobalMarketAuction.getBidCount(auction)),
            highText, (reserved > 0) and COLOR_GREEN or COLOR_MUTED)
        self:setReceiptRow(2, g_i18n:getText("ui_gm_animals_receipt_buyNow"),
            GlobalMarketAuction.getIsBuyNowAvailable(auction) and money(GlobalMarketAuction.getAmount(auction.buyNowFactor, baseValue))
                or g_i18n:getText("ui_gm_animals_buyNowNone"), COLOR_MUTED)
        self:setReceiptRow(3, g_i18n:getText("ui_gm_animals_receipt_reserved"), money(reserved), COLOR_MUTED)
        self:setReceiptRow("total", g_i18n:getText("ui_gm_animals_receipt_toReserve"), money(math.max(0, need)),
            self.blockReason ~= nil and COLOR_RED or COLOR_WHITE, COLOR_WHITE)
        okKey = isBuyNow and "ui_gm_animals_action_buyNow" or "ui_gm_animals_action_bid"
    else
        local listing = self.args.listing
        local snapshot = listing.snapshot
        local price = GlobalMarketAnimalListings.getListingPrice(listing) or 0
        local isBarn = (self:getValue(1, GlobalMarket.ANIMAL_DELIVERY.BARN) == GlobalMarket.ANIMAL_DELIVERY.BARN)
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
        self:setReceiptRow(1, string.format(g_i18n:getText("ui_gm_animals_receipt_price"), math.floor((listing.priceFactor or 1) * 100 + 0.5)),
            money(price), getFactorColor(listing.priceFactor or 1))
        self:setReceiptRow(2, g_i18n:getText("ui_gm_animals_receipt_transport"), money(fee), COLOR_MUTED)
        self:setReceiptRow(3, g_i18n:getText("ui_gm_animals_receipt_newPrice"), formatNewPrice(GlobalMarketAnimalListings.getDealerNewPrice(snapshot)), COLOR_MUTED)
        self:setReceiptRow("total", g_i18n:getText("ui_gm_animals_receipt_total"), money(total),
            self.blockReason ~= nil and COLOR_RED or COLOR_WHITE, COLOR_WHITE)
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
        self.yesButton:setText(g_i18n:getText(okKey))
        self.yesButton:setDisabled(self.blockReason ~= nil)
    end
end

-- =========================================================================
-- CALLBACKS
-- =========================================================================

function GlobalMarketAnimalDialog:onClickSelector1(state)
    if self.mode == GlobalMarketAnimalDialog.MODE_LIST then
        -- Euro amounts follow the count
        local isAuction = (self:getValue(2, SALE_FIXED) == SALE_AUCTION)
        self:setPriceOptions(self.options[3], self:getSelector(3):getState())
        if isAuction then
            self:setupBuyNowOptions(self:getValue(5, 0))
        end
    elseif self.mode == GlobalMarketAnimalDialog.MODE_BUY then
        self:updateBarnOptions()
    end
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickSelector2(state)
    if self.mode == GlobalMarketAnimalDialog.MODE_LIST then
        self:setupSaleModeOptions()
    end
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickSelector3(state)
    if self.mode == GlobalMarketAnimalDialog.MODE_LIST and self:getValue(2, SALE_FIXED) == SALE_AUCTION then
        -- The buy-now price must stay above the start price
        self:setupBuyNowOptions(self:getValue(5, 0))
    end
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickSelector4(state)
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickSelector5(state)
    self:updateReceipt()
end

function GlobalMarketAnimalDialog:onClickOk()
    if self.blockReason ~= nil then
        return false
    end
    local args = self.args
    local M = GlobalMarketAnimalDialog
    if self.mode == M.MODE_LIST then
        if args.source ~= nil and args.cluster ~= nil then
            if self:getValue(2, SALE_FIXED) == SALE_AUCTION then
                AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_AUCTION_CREATE, args.farmId, {
                    object = args.source,
                    clusterId = args.cluster.id,
                    numAnimals = self:getValue(1, 1),
                    priceFactor = self:getValue(3, 1),
                    durationMonths = self:getValue(4, M.DEFAULT_AUCTION_HOURS),
                    months = self:getValue(5, 0)
                })
            else
                AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_CREATE, args.farmId, {
                    object = args.source,
                    clusterId = args.cluster.id,
                    numAnimals = self:getValue(1, 1),
                    priceFactor = self:getValue(3, 1),
                    durationMonths = self:getValue(4, M.DEFAULT_DURATION)
                })
            end
        end
    elseif self.mode == M.MODE_DEMAND then
        if args.source ~= nil and args.cluster ~= nil then
            AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_DEMAND_SELL, args.farmId, {
                object = args.source,
                clusterId = args.cluster.id,
                numAnimals = self:getValue(1, 0)
            })
        end
    elseif self.mode == M.MODE_BID then
        if args.listing ~= nil then
            local factor, isBuyNow = self:getSelectedBid()
            if isBuyNow then
                AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_AUCTION_BUY_NOW, args.farmId, { targetId = args.listing.id })
            else
                AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_AUCTION_BID, args.farmId,
                    { targetId = args.listing.id, priceFactor = factor })
            end
        end
    elseif args.listing ~= nil then
        local barn = self:getValue(2, false)
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_BUY, args.farmId, {
            object = (barn ~= false) and barn or nil,
            targetId = args.listing.id,
            deliveryMode = self:getValue(1, GlobalMarket.ANIMAL_DELIVERY.BARN)
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

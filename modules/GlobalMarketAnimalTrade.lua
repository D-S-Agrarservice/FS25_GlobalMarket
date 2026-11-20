-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalTrade.lua
-- Livestock market (#15), Stage 1 trading: purchase with barn delivery or dealer pickup,
-- loading pickup box animals onto a livestock trailer at the animal dealer, HUD notices
-- and the related debug console commands.
-- Author: D-S-Agrarservice
-- =========================================================================================

-- =========================================================================
-- ANIMAL DEALER REGISTRY
-- =========================================================================

-- Animal dealer triggers of the running mission (map triggers and dealer placeables).
-- Weak keys: deleted triggers never keep the table alive.
local dealerTriggers = setmetatable({}, { __mode = "k" })

---Registers a loaded trigger if it is an animal dealer (not the loading trigger of a barn)
---@param trigger table
local function registerDealerTrigger(trigger)
    if trigger ~= nil and trigger.isDealer == true and trigger.husbandry == nil then
        dealerTriggers[trigger] = true
    end
end

if AnimalLoadingTrigger ~= nil then
    -- overwrittenFunction keeps the boolean result of both load functions
    AnimalLoadingTrigger.load = Utils.overwrittenFunction(AnimalLoadingTrigger.load, function(trigger, superFunc, ...)
        local success = superFunc(trigger, ...)
        if success then
            registerDealerTrigger(trigger)
        end
        return success
    end)
    AnimalLoadingTrigger.loadFromXML = Utils.overwrittenFunction(AnimalLoadingTrigger.loadFromXML, function(trigger, superFunc, ...)
        local success = superFunc(trigger, ...)
        if success then
            registerDealerTrigger(trigger)
        end
        return success
    end)
    AnimalLoadingTrigger.delete = Utils.prependedFunction(AnimalLoadingTrigger.delete, function(trigger)
        dealerTriggers[trigger] = nil
    end)
end

---Returns true if the mission has at least one animal dealer (dealer pickup is offered only then)
---@return boolean
function GlobalMarket.getHasAnimalDealer()
    return next(dealerTriggers) ~= nil
end

---Returns an own livestock trailer of a farm that stands in an animal dealer trigger
---@param farmId number
---@return table|nil trailer
function GlobalMarket.getAnimalMarketTrailerAtDealer(farmId)
    local husbandrySystem = (g_currentMission ~= nil) and g_currentMission.husbandrySystem or nil
    if husbandrySystem == nil or not GlobalMarketAnimalListings.getIsPlayerFarm(farmId) then
        return nil
    end
    for _, trailer in ipairs(husbandrySystem.livestockTrailers or {}) do
        if trailer:getOwnerFarmId() == farmId and GlobalMarketAnimalListings.getIsTrailerAtDealer(trailer) then
            return trailer
        end
    end
    return nil
end

-- =========================================================================
-- PICKUP BOX CHOICE AT THE ANIMAL DEALER (Client / host)
-- =========================================================================

-- Pickup box entries listed by name in the dealer choice dialog
local DEALER_CHOICE_MAX_NAMES = 3

---Returns the pickup box choice for an animal dealer activation, or nil if the basegame menu should open directly
---(not a dealer, no own livestock trailer in the trigger, or an empty pickup box)
---@param activatable table AnimalLoadingTriggerActivatable
---@return table|nil choice { farmId, trailer, text }
function GlobalMarket.getAnimalDealerPickupChoice(activatable)
    local gm = (g_currentMission ~= nil) and g_currentMission.globalMarket or nil
    local owner = (activatable ~= nil) and activatable.owner or nil
    if gm == nil or owner == nil or owner.isDealer ~= true or owner.husbandry ~= nil or OptionDialog == nil then
        return nil
    end
    if not GlobalMarketAnimalListings.getIsAvailable() then
        return nil
    end
    local farmId = g_currentMission:getFarmId()
    local trailer = owner.loadingVehicle
    if not GlobalMarketAnimalListings.getIsPlayerFarm(farmId) or not GlobalMarketAnimalListings.getIsTrailer(trailer)
        or trailer:getOwnerFarmId() ~= farmId or not g_currentMission:getHasPlayerPermission(Farm.PERMISSION.TRADE_ANIMALS) then
        return nil
    end
    local names = {}
    local numEntries = 0
    for _, entry in ipairs(gm.animalPickups or {}) do
        local numAnimals = GlobalMarketAnimalListings.getNumAnimals(entry.snapshot)
        if entry.farmId == farmId and numAnimals > 0 then
            numEntries = numEntries + 1
            if numEntries <= DEALER_CHOICE_MAX_NAMES then
                local info = GlobalMarketAnimalListings.getInfo(entry.snapshot)
                table.insert(names, string.format("%dx %s", numAnimals, info.title))
            end
        end
    end
    if numEntries == 0 then
        return nil
    end
    if numEntries > DEALER_CHOICE_MAX_NAMES then
        table.insert(names, "...")
    end
    return {
        farmId = farmId,
        trailer = trailer,
        text = string.format(g_i18n:getText("ui_gm_animals_dealer_text"), table.concat(names, ", "))
    }
end

if AnimalLoadingTriggerActivatable ~= nil and AnimalLoadingTriggerActivatable.run ~= nil then
    -- Same activate key as the basegame dealer: with a filled pickup box it first offers
    -- "Manage animals" (basegame menu) or "Load GM pickup box" onto the own trailer in the trigger
    AnimalLoadingTriggerActivatable.run = Utils.overwrittenFunction(AnimalLoadingTriggerActivatable.run, function(activatable, superFunc, ...)
        local choice = GlobalMarket.getAnimalDealerPickupChoice(activatable)
        if choice == nil then
            return superFunc(activatable, ...)
        end
        local options = {
            activatable.activateText or g_i18n:getText("animals_openAnimalScreen"),
            g_i18n:getText("ui_gm_animals_dealer_load")
        }
        -- target == nil: the dialog calls callback(selectedIndex, args); 0 = back
        OptionDialog.show(function(state)
            if state == 1 then
                superFunc(activatable)
            elseif state == 2 then
                AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_LOAD, choice.farmId,
                    { object = choice.trailer, targetId = 0 })
            end
        end, choice.text, g_i18n:getText("ui_gm_animals_dealer_title"), options, 2)
    end)
end

-- =========================================================================
-- STATE SYNC
-- =========================================================================

---Server: sends all listings and pickup box entries to all clients and refreshes the local UI
function GlobalMarket:broadcastAnimalMarketState()
    if g_server ~= nil and SyncAnimalMarketEvent ~= nil then
        g_server:broadcastEvent(SyncAnimalMarketEvent.new(self.animalListings or {}, self.animalPickups or {}, self.animalDemand))
    end
    self:onAnimalMarketChanged()
end

---Client: applies a received state
---@param listings table
---@param pickups table
---@param demand table|nil Active great demand
function GlobalMarket:applyAnimalMarketState(listings, pickups, demand)
    self.animalListings = listings or {}
    self.animalPickups = pickups or {}
    self.animalDemand = demand
    self:onAnimalMarketChanged()
end

---Refreshes the animal market UI if it is open (UI hook from step 5 on)
function GlobalMarket:onAnimalMarketChanged()
    local ui = self.ui or (g_currentMission ~= nil and g_currentMission.globalMarketUi) or nil
    if ui ~= nil and ui.onAnimalMarketChanged ~= nil then
        ui:onAnimalMarketChanged()
    end
end

-- =========================================================================
-- HUD NOTICES
-- =========================================================================

-- Reason codes that all mean "not possible here" without a dedicated text
local REASON_ALIASES = {
    notServer = "invalid"
}

---Returns the localized text of a reason code (HUD results and UI hints)
---@param code string
---@return string
function GlobalMarket.getAnimalMarketReasonText(code)
    local cfg = GlobalMarket.ANIMAL_MARKET
    code = REASON_ALIASES[code] or code
    local key = "ui_gm_animals_reason_" .. tostring(code)
    if not g_i18n:hasText(key) then
        key = "ui_gm_animals_reason_invalid"
    end
    local text = g_i18n:getText(key)
    if code == "priceOutOfRange" then
        return string.format(text, math.floor(cfg.PRICE_FACTOR_MIN * 100 + 0.5), math.floor(cfg.PRICE_FACTOR_MAX * 100 + 0.5))
    elseif code == "durationOutOfRange" then
        return string.format(text, cfg.DURATION_MIN, cfg.DURATION_MAX)
    elseif code == "farmLimitReached" then
        return string.format(text, cfg.MAX_PER_FARM)
    elseif code == "startOutOfRange" and GlobalMarketAuction ~= nil then
        local acfg = GlobalMarketAuction.CONFIG
        return string.format(text, math.floor(acfg.START_FACTOR_MIN * 100 + 0.5), math.floor(acfg.START_FACTOR_MAX * 100 + 0.5))
    elseif code == "buyNowOutOfRange" and GlobalMarketAuction ~= nil then
        local acfg = GlobalMarketAuction.CONFIG
        return string.format(text, math.floor(acfg.MIN_INCREMENT * 100 + 0.5), math.floor(acfg.BUY_NOW_FACTOR_MAX * 100 + 0.5))
    elseif code == "bidTooLow" and GlobalMarketAuction ~= nil then
        return string.format(text, math.floor(GlobalMarketAuction.CONFIG.MIN_INCREMENT * 100 + 0.5))
    elseif code == "demandUnhealthy" and GlobalMarket.ANIMAL_DEMAND ~= nil then
        return string.format(text, GlobalMarket.ANIMAL_DEMAND.MIN_HEALTH)
    elseif code == "demandQuotaExceeded" then
        local gm = (g_currentMission ~= nil) and g_currentMission.globalMarket or nil
        return string.format(text, (gm ~= nil and gm.getAnimalDemandRemaining ~= nil) and gm:getAnimalDemandRemaining() or 0)
    end
    return text
end

---Server: sends a result notice to the requesting connection only (local SP/host: shown directly)
---@param connection table|nil
---@param kind number GlobalMarket.ANIMAL_NOTICE
---@param code string Reason code
function GlobalMarket:notifyAnimalMarketRequester(connection, kind, code)
    if connection ~= nil and not connection:getIsLocal() and AnimalMarketActionEvent ~= nil then
        connection:sendEvent(AnimalMarketActionEvent.newNotice(kind, 0, 0, code, "", 0, 0, ""))
        return
    end
    self:showAnimalMarketNotice(kind, 0, 0, code, "", 0, 0, "")
end

-- Notice kind -> l10n key
local NOTICE_TEXT_KEYS = {
    [GlobalMarket.ANIMAL_NOTICE.LISTED] = "ui_gm_animals_notice_listed",
    [GlobalMarket.ANIMAL_NOTICE.NEW_LISTING] = "ui_gm_animals_notice_newListing",
    [GlobalMarket.ANIMAL_NOTICE.BOUGHT] = "ui_gm_animals_notice_bought",
    [GlobalMarket.ANIMAL_NOTICE.BOUGHT_PICKUP] = "ui_gm_animals_notice_boughtPickup",
    [GlobalMarket.ANIMAL_NOTICE.SOLD] = "ui_gm_animals_notice_sold",
    [GlobalMarket.ANIMAL_NOTICE.RETURNED] = "ui_gm_animals_notice_returned",
    [GlobalMarket.ANIMAL_NOTICE.RETURN_PENDING] = "ui_gm_animals_notice_returnPending",
    [GlobalMarket.ANIMAL_NOTICE.EXPIRED] = "ui_gm_animals_notice_expired",
    [GlobalMarket.ANIMAL_NOTICE.LOADED] = "ui_gm_animals_notice_loaded",
    [GlobalMarket.ANIMAL_NOTICE.DEMAND_START] = "ui_gm_animals_notice_demandStart",
    [GlobalMarket.ANIMAL_NOTICE.DEMAND_END] = "ui_gm_animals_notice_demandEnd",
    [GlobalMarket.ANIMAL_NOTICE.DEMAND_SOLD] = "ui_gm_animals_notice_demandSold",
    [GlobalMarket.ANIMAL_NOTICE.OUTBID] = "ui_gm_animals_notice_outbid",
    [GlobalMarket.ANIMAL_NOTICE.AUCTION_WON] = "ui_gm_animals_notice_auctionWon",
    [GlobalMarket.ANIMAL_NOTICE.AUCTION_NO_BID] = "ui_gm_animals_notice_auctionNoBid"
}

---Server: broadcasts a notice; clients filter by target farm (0 = all) and excluded farm
---@param kind number GlobalMarket.ANIMAL_NOTICE
---@param targetFarmId number
---@param excludeFarmId number
---@param subTypeName string
---@param numAnimals number
---@param amount number
---@param otherName string
---@param code string|nil "npc" = the other party is an NPC dealer (name localized on the client)
function GlobalMarket:notifyAnimalMarketFarms(kind, targetFarmId, excludeFarmId, subTypeName, numAnimals, amount, otherName, code)
    if g_server ~= nil and AnimalMarketActionEvent ~= nil and AnimalMarketActionEvent.newNotice ~= nil then
        g_server:broadcastEvent(AnimalMarketActionEvent.newNotice(kind, targetFarmId, excludeFarmId, code or "",
            subTypeName, numAnimals, amount, otherName))
    end
    self:showAnimalMarketNotice(kind, targetFarmId, excludeFarmId, code or "", subTypeName, numAnimals, amount, otherName)
end

---Client/host: shows an animal market notice if it concerns the local farm
---@param kind number
---@param targetFarmId number
---@param excludeFarmId number
---@param code string Reason code (RESULT notices)
---@param subTypeName string
---@param numAnimals number
---@param amount number
---@param otherName string
function GlobalMarket:showAnimalMarketNotice(kind, targetFarmId, excludeFarmId, code, subTypeName, numAnimals, amount, otherName)
    if g_dedicatedServer ~= nil or g_currentMission == nil or g_currentMission.hud == nil then
        return
    end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end
    if (targetFarmId or 0) > 0 and farmId ~= targetFarmId then
        return
    end
    if (excludeFarmId or 0) > 0 and farmId == excludeFarmId then
        return
    end
    if kind == GlobalMarket.ANIMAL_NOTICE.RESULT then
        if g_currentMission.hud.addSideNotification ~= nil then
            g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL or { 1, 1, 1, 1 },
                GlobalMarket.getAnimalMarketReasonText(code), 8000)
        end
        return
    end
    local key = NOTICE_TEXT_KEYS[kind]
    if key == nil or not g_i18n:hasText(key) then
        return
    end

    local N = GlobalMarket.ANIMAL_NOTICE
    local subTypeIndex = GlobalMarketAnimalListings.getSubTypeIndexByName(subTypeName)
    local animals = string.format("%dx %s", numAnimals or 0, GlobalMarketAnimalListings.getSubTypeTitle(subTypeIndex, tostring(subTypeName)))
    local money = g_i18n:formatMoney(amount or 0, 0, true, true)
    local color = FSBaseMission.INGAME_NOTIFICATION_OK or { 1, 1, 1, 1 }
    local text
    if kind == N.DEMAND_START then
        -- subTypeName = animal type, numAnimals = quota, amount = bonus percent, otherName = days
        text = string.format(g_i18n:getText(key), GlobalMarket.getAnimalDemandTypeTitle(subTypeName), amount or 0,
            tostring(otherName), numAnimals or 0)
        color = FSBaseMission.INGAME_NOTIFICATION_GREATDEMAND or FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.DEMAND_END then
        text = string.format(g_i18n:getText(key), GlobalMarket.getAnimalDemandTypeTitle(subTypeName), numAnimals or 0)
        color = FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.SOLD then
        local buyerName = (code == "npc") and g_i18n:getText("ui_gm_animals_npcName") or tostring(otherName)
        text = string.format(g_i18n:getText(key), animals, money, buyerName)
    elseif kind == N.RETURNED or kind == N.RETURN_PENDING or kind == N.EXPIRED or kind == N.LOADED or kind == N.AUCTION_NO_BID then
        text = string.format(g_i18n:getText(key), animals)
    else
        text = string.format(g_i18n:getText(key), animals, money)
    end
    if kind == N.OUTBID then
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or { 1, 1, 1, 1 }
    elseif kind == N.NEW_LISTING or kind == N.RETURNED or kind == N.EXPIRED or kind == N.AUCTION_NO_BID then
        color = FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.RETURN_PENDING then
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or { 1, 1, 1, 1 }
    end
    if g_currentMission.hud.addSideNotification ~= nil then
        g_currentMission.hud:addSideNotification(color, text, 8000)
    end
end

-- =========================================================================
-- PURCHASE (Server)
-- =========================================================================

---Returns how many animals of a snapshot a farm can take into its barns
---(one barn if given, otherwise all matching barns, capped by the global animal limit)
---@param farmId number
---@param snapshot table
---@param targetBarn table|nil
---@return number capacity
function GlobalMarket.getAnimalBarnCapacity(farmId, snapshot, targetBarn)
    if snapshot.cluster == nil then
        return 0
    end
    if targetBarn ~= nil then
        return (GlobalMarketAnimalListings.getFreeSlots(targetBarn, snapshot, farmId))
    end
    local subTypeIndex = snapshot.cluster:getSubTypeIndex()
    local total = 0
    for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farmId, subTypeIndex)) do
        total = total + (GlobalMarketAnimalListings.getFreeSlots(barn, snapshot, farmId))
    end
    local globalFree = g_currentMission.husbandrySystem:getNumOfFreeAnimalSlots(farmId, subTypeIndex)
    return math.max(0, math.min(total, math.floor(globalFree)))
end

---Moves as many animals of a snapshot as fit into one barn
---@param barn table
---@param snapshot table
---@param farmId number
---@return number moved
local function deliverAnimalsToBarn(barn, snapshot, farmId)
    local moved = 0
    -- Bounded loop: single-animal clusters move one animal per call
    for _ = 1, 65535 do
        if GlobalMarketAnimalListings.getNumAnimals(snapshot) <= 0 then
            break
        end
        local free = GlobalMarketAnimalListings.getFreeSlots(barn, snapshot, farmId)
        if free <= 0 then
            break
        end
        local step = GlobalMarketAnimalListings.placeIntoTarget(barn, snapshot, free)
        if step <= 0 then
            break
        end
        moved = moved + step
    end
    return moved
end

---Validates a purchase and returns its price parts
---@return table|nil purchase { listing, price, fee, numAnimals }
---@return string|nil reason
function GlobalMarket:getAnimalPurchase(listingId, buyerFarmId, deliveryMode, targetBarn)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return nil, "notServer"
    end
    if not GlobalMarketAnimalListings.getIsAvailable() then
        return nil, "unavailable"
    end
    if not GlobalMarketAnimalListings.getIsPlayerFarm(buyerFarmId) then
        return nil, "notOwned"
    end
    local listing = self:getAnimalListingById(listingId)
    if listing == nil then
        return nil, "listingNotFound"
    end
    if listing.status ~= GlobalMarket.ANIMAL_LISTING_STATUS.OPEN then
        return nil, "listingBusy"
    end
    if listing.saleMode == GlobalMarket.ANIMAL_SALE_MODE.AUCTION then
        return nil, "isAuction"
    end
    if not listing.isNpc and listing.sellerFarmId == buyerFarmId then
        return nil, "ownListing"
    end
    local snapshot = listing.snapshot
    local numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot)
    local price = GlobalMarketAnimalListings.getListingPrice(listing)
    if not GlobalMarketAnimalListings.getIsResolved(snapshot) or price == nil or numAnimals <= 0 then
        return nil, "notAvailable"
    end

    local fee = 0
    local D = GlobalMarket.ANIMAL_DELIVERY
    if deliveryMode == D.BARN then
        if targetBarn ~= nil and not GlobalMarketAnimalListings.getIsBarn(targetBarn) then
            return nil, "invalid"
        end
        if targetBarn == nil and #GlobalMarketAnimalListings.getFarmBarns(buyerFarmId, snapshot.cluster:getSubTypeIndex()) == 0 then
            return nil, "noBarn"
        end
        if GlobalMarket.getAnimalBarnCapacity(buyerFarmId, snapshot, targetBarn) < numAnimals then
            return nil, "noSpace"
        end
        fee = math.floor(GlobalMarketAnimalListings.getTransportFee(snapshot) + 0.5)
    elseif deliveryMode == D.PICKUP then
        if not GlobalMarket.getHasAnimalDealer() then
            return nil, "noDealer"
        end
    else
        return nil, "invalid"
    end
    if g_currentMission:getMoney(buyerFarmId) < price + fee then
        return nil, "notEnoughMoney"
    end
    return { listing = listing, price = price, fee = fee, numAnimals = numAnimals }, nil
end

---Buys an open listing for a farm (the animals come from the escrow snapshot, never from client data)
---@param listingId number
---@param buyerFarmId number
---@param deliveryMode number GlobalMarket.ANIMAL_DELIVERY
---@param targetBarn table|nil Barn delivery into this barn only (nil = best matching barns)
---@return boolean success
---@return string|nil reason
function GlobalMarket:buyAnimalListing(listingId, buyerFarmId, deliveryMode, targetBarn)
    local purchase, reason = self:getAnimalPurchase(listingId, buyerFarmId, deliveryMode, targetBarn)
    if purchase == nil then
        return false, reason
    end
    local listing = purchase.listing
    local snapshot = listing.snapshot
    local N = GlobalMarket.ANIMAL_NOTICE
    local total = purchase.price + purchase.fee

    self:removeAnimalListing(listing)
    -- The origin barn belongs to the seller and must not steer the buyer's delivery
    snapshot.originBarnId = nil

    g_currentMission:addMoney(-total, buyerFarmId, MoneyType.NEW_ANIMALS_COST, true, true)
    if not listing.isNpc then
        g_currentMission:addMoney(purchase.price, listing.sellerFarmId, MoneyType.SOLD_ANIMALS, true, true)
        self:notifyAnimalMarketFarms(N.SOLD, listing.sellerFarmId, 0, snapshot.subTypeName, purchase.numAnimals,
            purchase.price, GlobalMarket.getVehicleMarketFarmName(buyerFarmId))
    end

    if deliveryMode == GlobalMarket.ANIMAL_DELIVERY.BARN then
        if targetBarn ~= nil then
            deliverAnimalsToBarn(targetBarn, snapshot, buyerFarmId)
        end
        self:deliverAnimalsToFarmBarns(snapshot, buyerFarmId)
        -- Safety net: capacity was checked, but anything left is retried hourly like a return
        if GlobalMarketAnimalListings.getNumAnimals(snapshot) > 0 then
            self:addAnimalPickup(buyerFarmId, snapshot, GlobalMarket.ANIMAL_PICKUP_REASON.RETURN)
        end
        self:notifyAnimalMarketFarms(N.BOUGHT, buyerFarmId, 0, snapshot.subTypeName, purchase.numAnimals, total, "")
    else
        self:addAnimalPickup(buyerFarmId, snapshot, GlobalMarket.ANIMAL_PICKUP_REASON.BOUGHT)
        self:notifyAnimalMarketFarms(N.BOUGHT_PICKUP, buyerFarmId, 0, snapshot.subTypeName, purchase.numAnimals, total, "")
    end
    self:broadcastAnimalMarketState()
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Listing #%d sold to farm %d for %d (+%d transport fee, %s).",
            listing.id, buyerFarmId, purchase.price, purchase.fee,
            deliveryMode == GlobalMarket.ANIMAL_DELIVERY.BARN and "barn delivery" or "dealer pickup")
    end
    return true, nil
end

-- =========================================================================
-- TRAILER LOADING AT THE ANIMAL DEALER (Server)
-- =========================================================================

---Loads as many animals of a pickup box entry as fit onto an own livestock trailer at the animal dealer
---@param pickupId number
---@param trailer table
---@param farmId number
---@return number moved
---@return string|nil reason if nothing was loaded
function GlobalMarket:loadAnimalPickupOntoTrailer(pickupId, trailer, farmId)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return 0, "notServer"
    end
    local entry = self:getAnimalPickupById(pickupId)
    if entry == nil then
        return 0, "pickupNotFound"
    end
    if entry.farmId ~= farmId then
        return 0, "notOwner"
    end
    local snapshot = entry.snapshot
    if not GlobalMarketAnimalListings.getIsResolved(snapshot) then
        return 0, "notAvailable"
    end
    if not GlobalMarketAnimalListings.getIsTrailer(trailer) or trailer.isDeleted then
        return 0, "invalid"
    end
    if not GlobalMarketAnimalListings.getIsTrailerAtDealer(trailer) then
        return 0, "notAtDealer"
    end
    local free, reason = GlobalMarketAnimalListings.getFreeSlots(trailer, snapshot, farmId)
    if free <= 0 then
        return 0, reason or "noSpace"
    end

    local subTypeName = snapshot.subTypeName
    local moved = 0
    -- Bounded loop: single-animal clusters move one animal per call
    for _ = 1, 65535 do
        if free <= 0 or GlobalMarketAnimalListings.getNumAnimals(snapshot) <= 0 then
            break
        end
        local step = GlobalMarketAnimalListings.placeIntoTarget(trailer, snapshot, free)
        if step <= 0 then
            break
        end
        moved = moved + step
        free = GlobalMarketAnimalListings.getFreeSlots(trailer, snapshot, farmId)
    end
    if moved <= 0 then
        return 0, "noSpace"
    end
    self:cleanupAnimalPickups()
    self:notifyAnimalMarketFarms(GlobalMarket.ANIMAL_NOTICE.LOADED, farmId, 0, subTypeName, moved, 0, "")
    self:broadcastAnimalMarketState()
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Loaded %d animal(s) of pickup P%d onto a trailer of farm %d.", moved, pickupId, farmId)
    end
    return moved, nil
end

---Loads all pickup box entries of a farm that fit onto the trailer (in box order)
---@param trailer table
---@param farmId number
---@return number moved
---@return string|nil reason of the first entry that could not be loaded
function GlobalMarket:loadAllAnimalPickupsOntoTrailer(trailer, farmId)
    local ids = {}
    for _, entry in ipairs(self.animalPickups or {}) do
        if entry.farmId == farmId then
            table.insert(ids, entry.id)
        end
    end
    if #ids == 0 then
        return 0, "pickupNotFound"
    end
    local total, firstReason = 0, nil
    for _, pickupId in ipairs(ids) do
        local moved, reason = self:loadAnimalPickupOntoTrailer(pickupId, trailer, farmId)
        total = total + moved
        if moved == 0 and firstReason == nil then
            firstReason = reason
        end
    end
    return total, firstReason
end

-- =========================================================================
-- DEBUG CONSOLE
-- =========================================================================

---Console: buys a listing for the own farm: <listingId> [barn|pickup]
function GlobalMarket:consoleCommandAnimalMarketBuy(listingIdArg, modeArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(false)
    if guardError ~= nil then
        return guardError
    end
    local listingId = tonumber(listingIdArg)
    local mode = string.lower(tostring(modeArg or "barn"))
    local deliveryMode = (mode == "pickup") and GlobalMarket.ANIMAL_DELIVERY.PICKUP or GlobalMarket.ANIMAL_DELIVERY.BARN
    if listingId == nil or (mode ~= "barn" and mode ~= "pickup") then
        return "Usage: gmAnimalMarketBuy <listingId> [barn|pickup]"
    end
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_BUY, g_currentMission:getFarmId(),
            { targetId = listingId, deliveryMode = deliveryMode })
        return "Purchase request sent to the server (result as HUD notice)."
    end
    local success, reason = self:buyAnimalListing(listingId, g_currentMission:getFarmId(), deliveryMode, nil)
    return success and string.format("Listing #%d bought (%s).", listingId, mode) or ("Purchase rejected: " .. tostring(reason))
end

---Console: loads pickup box animals onto an own livestock trailer at the animal dealer: [pickupId|all]
function GlobalMarket:consoleCommandAnimalMarketLoad(pickupIdArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(false)
    if guardError ~= nil then
        return guardError
    end
    local pickupId = 0
    if pickupIdArg ~= nil and pickupIdArg ~= "all" then
        pickupId = tonumber(string.match(tostring(pickupIdArg), "%d+") or "")
        if pickupId == nil then
            return "Usage: gmAnimalMarketLoad [pickupId|all]"
        end
    end
    local farmId = g_currentMission:getFarmId()
    local trailer = GlobalMarket.getAnimalMarketTrailerAtDealer(farmId)
    if not g_currentMission:getIsServer() then
        -- The server looks for a trailer itself if the client does not see one at the dealer
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_LOAD, farmId, { object = trailer, targetId = pickupId })
        return "Load request sent to the server (result as HUD notice)."
    end
    if trailer == nil then
        return "No own livestock trailer stands in an animal dealer trigger."
    end
    local moved, reason
    if pickupId == 0 then
        moved, reason = self:loadAllAnimalPickupsOntoTrailer(trailer, farmId)
    else
        moved, reason = self:loadAnimalPickupOntoTrailer(pickupId, trailer, farmId)
    end
    if moved > 0 then
        return string.format("Loaded %d animal(s) onto the trailer.", moved)
    end
    return "Nothing loaded: " .. tostring(reason)
end

---Test helper (Server): turns a listing into an NPC dealer listing (buy back own listed animals)
---@param listingId number
---@return boolean success
---@return string|nil reason
function GlobalMarket:makeAnimalListingNpc(listingId)
    local listing = self:getAnimalListingById(listingId)
    if listing == nil then
        return false, "listingNotFound"
    end
    listing.isNpc = true
    listing.sellerFarmId = 0
    listing.sellerName = ""
    self:broadcastAnimalMarketState()
    return true, nil
end

---Console: turns a listing into an NPC dealer listing (test helper: host, dedicated server console or admin client)
function GlobalMarket:consoleCommandAnimalMarketMakeNpc(listingIdArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(true)
    if guardError ~= nil then
        return guardError
    end
    local listingId = tonumber(listingIdArg)
    if listingId == nil then
        return "Usage: gmAnimalMarketMakeNpc <id of an open listing>"
    end
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_ADMIN_MAKE_NPC, 0, { targetId = listingId })
        return "Admin request sent to the server."
    end
    local success, reason = self:makeAnimalListingNpc(listingId)
    if not success then
        return "Rejected: " .. tostring(reason)
    end
    return string.format("Listing #%d is now an NPC dealer listing (no seller payout, dropped on expiry).", listingId)
end

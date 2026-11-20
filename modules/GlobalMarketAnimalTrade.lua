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
-- HUD NOTICES
-- =========================================================================

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
    [GlobalMarket.ANIMAL_NOTICE.LOADED] = "ui_gm_animals_notice_loaded"
}

---Server: broadcasts a notice; clients filter by target farm (0 = all) and excluded farm
---@param kind number GlobalMarket.ANIMAL_NOTICE
---@param targetFarmId number
---@param excludeFarmId number
---@param subTypeName string
---@param numAnimals number
---@param amount number
---@param otherName string
function GlobalMarket:notifyAnimalMarketFarms(kind, targetFarmId, excludeFarmId, subTypeName, numAnimals, amount, otherName)
    if g_server ~= nil and AnimalMarketActionEvent ~= nil and AnimalMarketActionEvent.newNotice ~= nil then
        g_server:broadcastEvent(AnimalMarketActionEvent.newNotice(kind, targetFarmId, excludeFarmId, "",
            subTypeName, numAnimals, amount, otherName))
    end
    self:showAnimalMarketNotice(kind, targetFarmId, excludeFarmId, "", subTypeName, numAnimals, amount, otherName)
end

---Client/host: shows an animal market notice if it concerns the local farm
---@param kind number
---@param targetFarmId number
---@param excludeFarmId number
---@param code string Reason code (RESULT notices, step 4)
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
    if kind == N.SOLD then
        text = string.format(g_i18n:getText(key), animals, money, tostring(otherName))
    elseif kind == N.RETURNED or kind == N.RETURN_PENDING or kind == N.EXPIRED or kind == N.LOADED then
        text = string.format(g_i18n:getText(key), animals)
    else
        text = string.format(g_i18n:getText(key), animals, money)
    end
    if kind == N.NEW_LISTING or kind == N.RETURNED or kind == N.EXPIRED then
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
    if self.broadcastAnimalMarketState ~= nil then
        self:broadcastAnimalMarketState()
    end
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
    if self.broadcastAnimalMarketState ~= nil then
        self:broadcastAnimalMarketState()
    end
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
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local listingId = tonumber(listingIdArg)
    local mode = string.lower(tostring(modeArg or "barn"))
    local deliveryMode = (mode == "pickup") and GlobalMarket.ANIMAL_DELIVERY.PICKUP or GlobalMarket.ANIMAL_DELIVERY.BARN
    if listingId == nil or (mode ~= "barn" and mode ~= "pickup") then
        return "Usage: gmAnimalMarketBuy <listingId> [barn|pickup]"
    end
    local success, reason = self:buyAnimalListing(listingId, g_currentMission:getFarmId(), deliveryMode, nil)
    return success and string.format("Listing #%d bought (%s).", listingId, mode) or ("Purchase rejected: " .. tostring(reason))
end

---Console: loads pickup box animals onto an own livestock trailer at the animal dealer: [pickupId|all]
function GlobalMarket:consoleCommandAnimalMarketLoad(pickupIdArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local farmId = g_currentMission:getFarmId()
    local trailer = GlobalMarket.getAnimalMarketTrailerAtDealer(farmId)
    if trailer == nil then
        return "No own livestock trailer stands in an animal dealer trigger."
    end
    local moved, reason
    if pickupIdArg == nil or pickupIdArg == "all" then
        moved, reason = self:loadAllAnimalPickupsOntoTrailer(trailer, farmId)
    else
        local pickupId = tonumber(string.match(tostring(pickupIdArg), "%d+") or "")
        if pickupId == nil then
            return "Usage: gmAnimalMarketLoad [pickupId|all]"
        end
        moved, reason = self:loadAnimalPickupOntoTrailer(pickupId, trailer, farmId)
    end
    if moved > 0 then
        return string.format("Loaded %d animal(s) onto the trailer.", moved)
    end
    return "Nothing loaded: " .. tostring(reason)
end

---Console: turns a listing into an NPC dealer listing (SP test: buy back own listed animals)
function GlobalMarket:consoleCommandAnimalMarketMakeNpc(listingIdArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local listing = self:getAnimalListingById(tonumber(listingIdArg) or 0)
    if listing == nil then
        return "Usage: gmAnimalMarketMakeNpc <id of an open listing>"
    end
    listing.isNpc = true
    listing.sellerFarmId = 0
    listing.sellerName = ""
    if self.broadcastAnimalMarketState ~= nil then
        self:broadcastAnimalMarketState()
    end
    return string.format("Listing #%d is now an NPC dealer listing (no seller payout, dropped on expiry).", listing.id)
end

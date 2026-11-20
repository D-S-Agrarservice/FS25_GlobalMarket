-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalMarket.lua
-- Livestock market (#15), Stage 1 core: listing store, listing animals (escrow), returning
-- them to the seller, the farm pickup box (dealer pickup and undeliverable returns),
-- hourly expiry/retries, savegame persistence and debug console commands.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarket.ANIMAL_MARKET = {
    PRICE_FACTOR_MIN = 0.80,  -- Asking price band relative to the dealer value
    PRICE_FACTOR_MAX = 2.00,
    DURATION_MIN = 1,         -- Listing duration in in-game months
    DURATION_MAX = 3,
    MAX_PER_FARM = 10,
    MAX_TOTAL = 100,
    NPC_COMMISSION = 0.05     -- Dealer commission when an NPC buys
}

GlobalMarket.ANIMAL_LISTING_STATUS = {
    OPEN = "OPEN"
}

-- Why an entry sits in a farm's pickup box
GlobalMarket.ANIMAL_PICKUP_REASON = {
    BOUGHT = "BOUGHT",   -- Bought with dealer pickup (no transport fee, never delivered automatically)
    RETURN = "RETURN"    -- Returned listing that did not fit into the seller's barns (retried hourly)
}

-- How bought animals reach the buyer
GlobalMarket.ANIMAL_DELIVERY = {
    BARN = 1,    -- Into own barns, plus the basegame transport fee
    PICKUP = 2   -- Into the pickup box, loaded onto a livestock trailer at the animal dealer
}

-- HUD notice kinds (sent as numbers to clients)
GlobalMarket.ANIMAL_NOTICE = {
    RESULT = 1,
    LISTED = 2,
    NEW_LISTING = 3,
    BOUGHT = 4,
    BOUGHT_PICKUP = 5,
    SOLD = 6,
    RETURNED = 7,
    RETURN_PENDING = 8,
    EXPIRED = 9,
    LOADED = 10,
    DEMAND_START = 11,   -- Great demand for meat animals (Stage 1b)
    DEMAND_END = 12,
    DEMAND_SOLD = 13,
    OUTBID = 14,         -- Auctions (Stage 2)
    AUCTION_WON = 15,
    AUCTION_NO_BID = 16
}

-- =========================================================================
-- STATE
-- =========================================================================

---Initializes the animal market tables (called on map load)
function GlobalMarket:initAnimalMarket()
    self.animalListings = {}
    self.animalPickups = {}
    self.nextAnimalListingId = 1
    self.nextAnimalPickupId = 1
    self.animalDemand = nil
    if GlobalMarket.resetAnimalDemandCaches ~= nil then
        GlobalMarket.resetAnimalDemandCaches()
    end
    local incompatible = GlobalMarketAnimalListings.getIncompatibleMod()
    if incompatible ~= nil and not self.hasLoggedAnimalMarketDisabled then
        self.hasLoggedAnimalMarketDisabled = true
        Logging.info("[FS25_GlobalMarket] Animal market disabled: '%s' replaces the animal cluster system.", incompatible)
    end
end

---Returns a listing by its local ID
---@param listingId number
---@return table|nil listing
---@return number|nil index
function GlobalMarket:getAnimalListingById(listingId)
    for index, listing in ipairs(self.animalListings or {}) do
        if listing.id == listingId then
            return listing, index
        end
    end
    return nil, nil
end

---Returns a pickup box entry by its ID
---@param pickupId number
---@return table|nil entry
---@return number|nil index
function GlobalMarket:getAnimalPickupById(pickupId)
    for index, entry in ipairs(self.animalPickups or {}) do
        if entry.id == pickupId then
            return entry, index
        end
    end
    return nil, nil
end

---Counts the open listings of a farm
---@param farmId number
---@return number
function GlobalMarket:getAnimalListingCountForFarm(farmId)
    local count = 0
    for _, listing in ipairs(self.animalListings or {}) do
        if listing.sellerFarmId == farmId then
            count = count + 1
        end
    end
    return count
end

---Removes a listing from the store
---@param listing table
function GlobalMarket:removeAnimalListing(listing)
    local _, index = self:getAnimalListingById(listing.id)
    if index ~= nil then
        table.remove(self.animalListings, index)
    end
end

---Sends the state to all clients (GlobalMarketAnimalTrade.lua)
local function broadcastState(self)
    if self.broadcastAnimalMarketState ~= nil then
        self:broadcastAnimalMarketState()
    end
end

---Sends a HUD notice about the animals of a snapshot (GlobalMarketAnimalTrade.lua)
---@param numAnimals number|nil Animal count to show (default: current snapshot count)
local function notify(self, kind, targetFarmId, excludeFarmId, snapshot, price, numAnimals)
    if self.notifyAnimalMarketFarms ~= nil then
        self:notifyAnimalMarketFarms(kind, targetFarmId, excludeFarmId, snapshot.subTypeName,
            numAnimals or GlobalMarketAnimalListings.getNumAnimals(snapshot), price or 0, "")
    end
end

-- =========================================================================
-- LISTING ANIMALS (Server)
-- =========================================================================

---Lists animals of a barn or a livestock trailer at the dealer: validates and takes them into escrow
---@param source table Barn or livestock trailer
---@param clusterId number
---@param numAnimals number
---@param farmId number
---@param priceFactor number Asking price relative to the dealer value
---@param durationMonths number
---@param auctionOptions table|nil { startFactor, buyNowFactor, durationHours } lists as auction (Stage 2)
---@return table|nil listing
---@return string|nil reason Error code if the listing was rejected
function GlobalMarket:createAnimalListing(source, clusterId, numAnimals, farmId, priceFactor, durationMonths, auctionOptions)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return nil, "notServer"
    end
    local cfg = GlobalMarket.ANIMAL_MARKET
    numAnimals = math.floor(tonumber(numAnimals) or 0)
    local isEligible, reason = GlobalMarketAnimalListings.getEligibility(source, farmId, clusterId, numAnimals)
    if not isEligible then
        return nil, reason
    end
    local auction = nil
    if auctionOptions ~= nil then
        local isValid, auctionReason = GlobalMarketAuction.validateOptions(auctionOptions.startFactor,
            auctionOptions.buyNowFactor, auctionOptions.durationHours)
        if not isValid then
            return nil, auctionReason
        end
        auction = GlobalMarketAuction.create(tonumber(auctionOptions.startFactor), auctionOptions.buyNowFactor,
            tonumber(auctionOptions.durationHours))
        -- Auctions run on hours (auction.hoursRemaining); the price factor follows the current bid
        priceFactor = auction.startFactor
        durationMonths = 0
    else
        priceFactor = tonumber(priceFactor)
        if priceFactor == nil or priceFactor < cfg.PRICE_FACTOR_MIN - 0.0001 or priceFactor > cfg.PRICE_FACTOR_MAX + 0.0001 then
            return nil, "priceOutOfRange"
        end
        durationMonths = math.floor(tonumber(durationMonths) or 0)
        if durationMonths < cfg.DURATION_MIN or durationMonths > cfg.DURATION_MAX then
            return nil, "durationOutOfRange"
        end
    end
    self.animalListings = self.animalListings or {}
    if #self.animalListings >= cfg.MAX_TOTAL then
        return nil, "marketFull"
    end
    if self:getAnimalListingCountForFarm(farmId) >= cfg.MAX_PER_FARM then
        return nil, "farmLimitReached"
    end

    local snapshot = GlobalMarketAnimalListings.takeFromSource(source, clusterId, numAnimals)
    if snapshot == nil then
        return nil, "notEnoughAnimals"
    end

    local id = self.nextAnimalListingId or 1
    self.nextAnimalListingId = id + 1
    local serverId = (self.ensureServerInstanceId ~= nil) and self:ensureServerInstanceId() or (self.serverInstanceId or "")
    local listing = {
        id = id,
        uid = string.format("%s_a%d", serverId, id),
        status = GlobalMarket.ANIMAL_LISTING_STATUS.OPEN,
        sellerFarmId = farmId,
        sellerName = GlobalMarket.getVehicleMarketFarmName(farmId),
        isNpc = false,
        saleMode = (auction ~= nil) and GlobalMarket.ANIMAL_SALE_MODE.AUCTION or GlobalMarket.ANIMAL_SALE_MODE.FIXED,
        priceFactor = priceFactor,
        monthsRemaining = durationMonths,
        auction = auction,
        snapshot = snapshot
    }
    table.insert(self.animalListings, listing)

    local price = GlobalMarketAnimalListings.getListingPrice(listing) or 0
    notify(self, GlobalMarket.ANIMAL_NOTICE.LISTED, farmId, 0, snapshot, price)
    notify(self, GlobalMarket.ANIMAL_NOTICE.NEW_LISTING, 0, farmId, snapshot, price)
    broadcastState(self)
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Listing #%d created by farm %d (%s x%d, %.0f%% of dealer value, %d months).",
            id, farmId, snapshot.subTypeName, GlobalMarketAnimalListings.getNumAnimals(snapshot), priceFactor * 100, durationMonths)
    end
    return listing, nil
end

-- =========================================================================
-- DELIVERY & PICKUP BOX (Server)
-- =========================================================================

---Moves as many animals of a snapshot as fit into the barns of a farm
---@param snapshot table
---@param farmId number
---@return number moved
function GlobalMarket:deliverAnimalsToFarmBarns(snapshot, farmId)
    local moved = 0
    if not GlobalMarketAnimalListings.getIsResolved(snapshot) then
        return 0
    end
    -- Bounded loop: single-animal clusters move one animal per call
    for _ = 1, 65535 do
        if GlobalMarketAnimalListings.getNumAnimals(snapshot) <= 0 then
            break
        end
        local barn = GlobalMarketAnimalListings.findBarnWithSpace(farmId, snapshot)
        if barn == nil then
            break
        end
        local free = GlobalMarketAnimalListings.getFreeSlots(barn, snapshot, farmId)
        local step = GlobalMarketAnimalListings.placeIntoTarget(barn, snapshot, free)
        if step <= 0 then
            break
        end
        moved = moved + step
    end
    return moved
end

---Adds a snapshot to the pickup box of a farm
---@param farmId number
---@param snapshot table
---@param reason string GlobalMarket.ANIMAL_PICKUP_REASON
---@return table entry
function GlobalMarket:addAnimalPickup(farmId, snapshot, reason)
    self.animalPickups = self.animalPickups or {}
    local id = self.nextAnimalPickupId or 1
    self.nextAnimalPickupId = id + 1
    local entry = { id = id, farmId = farmId, reason = reason, snapshot = snapshot }
    table.insert(self.animalPickups, entry)
    return entry
end

---Removes empty pickup box entries
function GlobalMarket:cleanupAnimalPickups()
    local pickups = self.animalPickups or {}
    for i = #pickups, 1, -1 do
        if GlobalMarketAnimalListings.getNumAnimals(pickups[i].snapshot) <= 0 then
            table.remove(pickups, i)
        end
    end
end

---Returns the animals of a listing to the seller's barns; what does not fit goes into the seller's pickup box
---@param listing table
function GlobalMarket:returnAnimalListing(listing)
    if listing == nil then
        return
    end
    self:removeAnimalListing(listing)
    -- NPC listings have no physical animals to return
    if listing.isNpc then
        broadcastState(self)
        return
    end
    local snapshot = listing.snapshot
    local numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot)
    self:deliverAnimalsToFarmBarns(snapshot, listing.sellerFarmId)
    if GlobalMarketAnimalListings.getNumAnimals(snapshot) > 0 then
        self:addAnimalPickup(listing.sellerFarmId, snapshot, GlobalMarket.ANIMAL_PICKUP_REASON.RETURN)
        notify(self, GlobalMarket.ANIMAL_NOTICE.RETURN_PENDING, listing.sellerFarmId, 0, snapshot, 0)
        if self.debugManager ~= nil then
            self.debugManager:info("AnimalMarket: Listing #%d partly returned, %d animal(s) wait in the pickup box of farm %d.",
                listing.id, GlobalMarketAnimalListings.getNumAnimals(snapshot), listing.sellerFarmId)
        end
    else
        notify(self, GlobalMarket.ANIMAL_NOTICE.RETURNED, listing.sellerFarmId, 0, snapshot, 0, numAnimals)
        if self.debugManager ~= nil then
            self.debugManager:info("AnimalMarket: Listing #%d returned to farm %d.", listing.id, listing.sellerFarmId)
        end
    end
    broadcastState(self)
end

---Withdraws an open listing of a farm and returns the animals
---@param listingId number
---@param farmId number
---@return boolean success
---@return string|nil reason
function GlobalMarket:cancelAnimalListing(listingId, farmId)
    local listing = self:getAnimalListingById(listingId)
    if listing == nil then
        return false, "listingNotFound"
    end
    if listing.sellerFarmId ~= farmId then
        return false, "notOwner"
    end
    -- Auctions can only be withdrawn while nobody has bid
    local blockReason = GlobalMarket.getAnimalAuctionCancelBlock ~= nil and GlobalMarket.getAnimalAuctionCancelBlock(listing) or nil
    if blockReason ~= nil then
        return false, blockReason
    end
    self:returnAnimalListing(listing)
    return true, nil
end

---Retries the barn delivery of returned animals waiting in pickup boxes (bought animals stay for pickup)
---@return number moved
function GlobalMarket:retryAnimalPickupReturns()
    local moved = 0
    for _, entry in ipairs(self.animalPickups or {}) do
        if entry.reason == GlobalMarket.ANIMAL_PICKUP_REASON.RETURN then
            moved = moved + self:deliverAnimalsToFarmBarns(entry.snapshot, entry.farmId)
        end
    end
    if moved > 0 then
        self:cleanupAnimalPickups()
        broadcastState(self)
    end
    return moved
end

-- =========================================================================
-- HOURLY UPDATE (Server)
-- =========================================================================

---Advances listing timers, returns expired listings and retries pending returns
---@param customMonthDelta number|nil Months to advance (console tests), default one in-game hour
function GlobalMarket:updateAnimalMarketHourly(customMonthDelta)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    if not GlobalMarketAnimalListings.getIsAvailable() then
        return
    end
    local daysPerPeriod = (g_currentMission.environment ~= nil and g_currentMission.environment.daysPerPeriod) or 1
    local monthDelta = customMonthDelta or (1.0 / (24.0 * math.max(1, daysPerPeriod)))

    local expired = {}
    for _, listing in ipairs(self.animalListings or {}) do
        -- Auctions count down in hours (updateAnimalAuctionsHourly)
        if listing.saleMode ~= GlobalMarket.ANIMAL_SALE_MODE.AUCTION then
            listing.monthsRemaining = (listing.monthsRemaining or 0) - monthDelta
            if listing.monthsRemaining <= 0 then
                table.insert(expired, listing)
            end
        end
    end
    for _, listing in ipairs(expired) do
        if not listing.isNpc then
            notify(self, GlobalMarket.ANIMAL_NOTICE.EXPIRED, listing.sellerFarmId, 0, listing.snapshot, 0)
        end
        self:returnAnimalListing(listing)
    end
    local auctionsChanged = (self.updateAnimalAuctionsHourly ~= nil) and self:updateAnimalAuctionsHourly(monthDelta)
    self:retryAnimalPickupReturns()
    local npcChanged = (self.updateAnimalMarketNpcs ~= nil) and self:updateAnimalMarketNpcs(monthDelta)
    local demandChanged = (self.updateAnimalDemandHourly ~= nil) and self:updateAnimalDemandHourly(monthDelta)
    -- Clients show remaining times, so the state is sent every hour while listings or a great demand exist
    if #(self.animalListings or {}) > 0 or self.animalDemand ~= nil or npcChanged or demandChanged or auctionsChanged then
        broadcastState(self)
    end
end

---Removes the listings and pickup box entries of a deleted farm (the animals have no owner to return to)
---@param farmId number
---@return boolean changed
function GlobalMarket:cleanupAnimalMarketForDeletedFarm(farmId)
    -- Auctions first: refund bidders of the deleted seller, drop bids of a deleted bidder
    local changed = (self.cleanupAnimalAuctionsForDeletedFarm ~= nil) and self:cleanupAnimalAuctionsForDeletedFarm(farmId) or false
    local listings = self.animalListings or {}
    for i = #listings, 1, -1 do
        if not listings[i].isNpc and listings[i].sellerFarmId == farmId then
            table.remove(listings, i)
            changed = true
        end
    end
    local pickups = self.animalPickups or {}
    for i = #pickups, 1, -1 do
        if pickups[i].farmId == farmId then
            table.remove(pickups, i)
            changed = true
        end
    end
    if changed then
        broadcastState(self)
    end
    return changed
end

-- =========================================================================
-- SAVEGAME
-- =========================================================================

---Writes all listings and pickup box entries into globalMarket.xml
---@param xmlFile table
function GlobalMarket:saveAnimalMarketToXml(xmlFile)
    if xmlFile == nil then
        return
    end
    local rootKey = "globalMarket.animalMarket"
    xmlFile:setInt(rootKey .. "#nextListingId", self.nextAnimalListingId or 1)
    xmlFile:setInt(rootKey .. "#nextPickupId", self.nextAnimalPickupId or 1)
    for i, listing in ipairs(self.animalListings or {}) do
        local key = string.format("%s.listing(%d)", rootKey, i - 1)
        xmlFile:setInt(key .. "#id", listing.id)
        xmlFile:setString(key .. "#uid", listing.uid or "")
        xmlFile:setString(key .. "#status", listing.status or GlobalMarket.ANIMAL_LISTING_STATUS.OPEN)
        xmlFile:setInt(key .. "#sellerFarmId", listing.sellerFarmId or 0)
        xmlFile:setString(key .. "#sellerName", listing.sellerName or "")
        xmlFile:setBool(key .. "#isNpc", listing.isNpc == true)
        xmlFile:setString(key .. "#saleMode", listing.saleMode or "FIXED")
        xmlFile:setFloat(key .. "#priceFactor", listing.priceFactor or 1)
        xmlFile:setFloat(key .. "#monthsRemaining", listing.monthsRemaining or 0)
        if listing.auction ~= nil then
            GlobalMarketAuction.saveToXml(xmlFile, key .. ".auction", listing.auction)
        end
        GlobalMarketAnimalListings.writeSnapshotToXml(xmlFile, key .. ".animals", listing.snapshot)
    end
    for i, entry in ipairs(self.animalPickups or {}) do
        local key = string.format("%s.pickup(%d)", rootKey, i - 1)
        xmlFile:setInt(key .. "#id", entry.id)
        xmlFile:setInt(key .. "#farmId", entry.farmId or 0)
        xmlFile:setString(key .. "#reason", entry.reason or GlobalMarket.ANIMAL_PICKUP_REASON.RETURN)
        GlobalMarketAnimalListings.writeSnapshotToXml(xmlFile, key .. ".animals", entry.snapshot)
    end
    if self.saveAnimalDemandToXml ~= nil then
        self:saveAnimalDemandToXml(xmlFile, rootKey)
    end
end

---Loads all listings and pickup box entries from globalMarket.xml
---(entries whose subtype is unknown locally are kept, not deleted)
---@param xmlFile table
function GlobalMarket:loadAnimalMarketFromXml(xmlFile)
    self:initAnimalMarket()
    if xmlFile == nil then
        return
    end
    local rootKey = "globalMarket.animalMarket"
    local maxListingId, maxPickupId = 0, 0
    xmlFile:iterate(rootKey .. ".listing", function(_, key)
        local snapshot = GlobalMarketAnimalListings.readSnapshotFromXml(xmlFile, key .. ".animals")
        local id = xmlFile:getInt(key .. "#id")
        if snapshot ~= nil and id ~= nil then
            local saleMode = xmlFile:getString(key .. "#saleMode", "FIXED")
            local auction = nil
            if saleMode == "AUCTION" then
                auction = GlobalMarketAuction.loadFromXml(xmlFile, key .. ".auction")
                if auction == nil then
                    saleMode = "FIXED"
                end
            end
            table.insert(self.animalListings, {
                id = id,
                uid = xmlFile:getString(key .. "#uid", ""),
                status = xmlFile:getString(key .. "#status", GlobalMarket.ANIMAL_LISTING_STATUS.OPEN),
                sellerFarmId = xmlFile:getInt(key .. "#sellerFarmId", 0),
                sellerName = xmlFile:getString(key .. "#sellerName", ""),
                isNpc = xmlFile:getBool(key .. "#isNpc", false),
                saleMode = saleMode,
                priceFactor = xmlFile:getFloat(key .. "#priceFactor", 1),
                monthsRemaining = xmlFile:getFloat(key .. "#monthsRemaining", 0),
                auction = auction,
                snapshot = snapshot
            })
            maxListingId = math.max(maxListingId, id)
        end
    end)
    xmlFile:iterate(rootKey .. ".pickup", function(_, key)
        local snapshot = GlobalMarketAnimalListings.readSnapshotFromXml(xmlFile, key .. ".animals")
        local id = xmlFile:getInt(key .. "#id")
        if snapshot ~= nil and id ~= nil then
            table.insert(self.animalPickups, {
                id = id,
                farmId = xmlFile:getInt(key .. "#farmId", 0),
                reason = xmlFile:getString(key .. "#reason", GlobalMarket.ANIMAL_PICKUP_REASON.RETURN),
                snapshot = snapshot
            })
            maxPickupId = math.max(maxPickupId, id)
        end
    end)
    self.nextAnimalListingId = math.max(xmlFile:getInt(rootKey .. "#nextListingId", 1), maxListingId + 1)
    self.nextAnimalPickupId = math.max(xmlFile:getInt(rootKey .. "#nextPickupId", 1), maxPickupId + 1)
    if self.loadAnimalDemandFromXml ~= nil then
        self:loadAnimalDemandFromXml(xmlFile, rootKey)
    end
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Loaded %d listing(s) and %d pickup box entr(ies).",
            #self.animalListings, #self.animalPickups)
    end
end

-- =========================================================================
-- DEBUG CONSOLE
-- =========================================================================

---Shared guard for the animal market console commands that change state.
---Player actions run on MP clients as well (sent as AnimalMarketActionEvent). Test helpers run on the
---server or on the client of a logged-in admin (sent as admin request, checked again by the server).
---@param isTestHelper boolean
---@return string|nil errorText
local function getConsoleGuardError(isTestHelper)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_currentMission == nil then
        return "No mission running."
    end
    if isTestHelper and not g_currentMission:getIsServer() and not g_currentMission.isMasterUser then
        return "This test command needs the SP/MP host, the dedicated server console or an admin login."
    end
    -- Player actions need a farm; test helpers do not
    local farmId = g_currentMission:getFarmId()
    if not isTestHelper and (farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID) then
        return "Join a farm first."
    end
    if not GlobalMarketAnimalListings.getIsAvailable() then
        return "Animal market is not available in this mission."
    end
    return nil
end
GlobalMarket.getAnimalMarketConsoleGuardError = getConsoleGuardError

---Finds an own barn or livestock trailer holding a cluster
---@param farmId number
---@param clusterId number
---@return table|nil source
local function findSourceByClusterId(farmId, clusterId)
    for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farmId, nil)) do
        if barn:getClusterById(clusterId) ~= nil then
            return barn
        end
    end
    for _, trailer in ipairs(g_currentMission.husbandrySystem.livestockTrailers or {}) do
        if trailer:getOwnerFarmId() == farmId and trailer:getClusterById(clusterId) ~= nil then
            return trailer
        end
    end
    return nil
end
GlobalMarket.findAnimalSourceByClusterId = findSourceByClusterId

---Returns console lines for all listings and pickup box entries (appended to gmAnimalMarketList)
---@return table lines
function GlobalMarket:getAnimalMarketConsoleLines()
    local lines = { string.format("Listings (%d):", #(self.animalListings or {})) }
    for _, listing in ipairs(self.animalListings or {}) do
        local info = GlobalMarketAnimalListings.getInfo(listing.snapshot)
        local price = GlobalMarketAnimalListings.getListingPrice(listing)
        table.insert(lines, string.format("  #%d %s x%d | %d months | seller farm %d%s | %.0f%% = %s | %.2f months left",
            listing.id, info.title, info.numAnimals, info.age, listing.sellerFarmId, listing.isNpc and " (NPC)" or "",
            (listing.priceFactor or 1) * 100, price ~= nil and string.format("%d", price) or "n/a", listing.monthsRemaining or 0)
            .. (GlobalMarket.getAnimalAuctionConsoleSuffix ~= nil and GlobalMarket.getAnimalAuctionConsoleSuffix(listing) or ""))
    end
    table.insert(lines, string.format("Pickup box (%d):", #(self.animalPickups or {})))
    for _, entry in ipairs(self.animalPickups or {}) do
        local info = GlobalMarketAnimalListings.getInfo(entry.snapshot)
        table.insert(lines, string.format("  P%d farm %d | %s x%d | %s", entry.id, entry.farmId, info.title, info.numAnimals, entry.reason))
    end
    if self.getAnimalDemandConsoleLine ~= nil then
        table.insert(lines, self:getAnimalDemandConsoleLine())
    end
    return lines
end

---Console: lists animals of an own barn or trailer: <clusterId> <count> [pricePercent=100] [months=1]
function GlobalMarket:consoleCommandAnimalMarketSell(clusterIdArg, countArg, pricePctArg, monthsArg)
    local guardError = getConsoleGuardError(false)
    if guardError ~= nil then
        return guardError
    end
    local farmId = g_currentMission:getFarmId()
    local clusterId = tonumber(clusterIdArg)
    local source = (clusterId ~= nil) and findSourceByClusterId(farmId, clusterId) or nil
    if source == nil then
        return "Usage: gmAnimalMarketSell <clusterId from gmAnimalMarketList> <count> [pricePercent=100] [months=1]"
    end
    local numAnimals = tonumber(countArg) or 0
    local priceFactor = (tonumber(pricePctArg) or 100) / 100
    local durationMonths = tonumber(monthsArg) or 1
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_CREATE, farmId, { object = source,
            clusterId = clusterId, numAnimals = numAnimals, priceFactor = priceFactor, durationMonths = durationMonths })
        return "Listing request sent to the server (result as HUD notice)."
    end
    local listing, reason = self:createAnimalListing(source, clusterId, numAnimals, farmId, priceFactor, durationMonths)
    if listing == nil then
        return "Listing rejected: " .. tostring(reason)
    end
    return string.format("Listing #%d created (%s).", listing.id, tostring(GlobalMarketAnimalListings.getListingPrice(listing)))
end

---Console: withdraws an own listing, or retries the barn delivery of returned animals
---@param listingIdArg string|nil Listing ID, or "pending"
function GlobalMarket:consoleCommandAnimalMarketReturn(listingIdArg)
    local guardError = getConsoleGuardError(listingIdArg == "pending")
    if guardError ~= nil then
        return guardError
    end
    if listingIdArg == "pending" then
        if not g_currentMission:getIsServer() then
            AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_ADMIN_RETRY_RETURNS, 0, nil)
            return "Admin request sent to the server."
        end
        return string.format("Delivered %d returned animal(s) to barns.", self:retryAnimalPickupReturns())
    end
    local listingId = tonumber(listingIdArg)
    if listingId == nil then
        return "Usage: gmAnimalMarketReturn <listingId|pending>"
    end
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_CANCEL, g_currentMission:getFarmId(), { targetId = listingId })
        return "Withdraw request sent to the server (result as HUD notice)."
    end
    local success, reason = self:cancelAnimalListing(listingId, g_currentMission:getFarmId())
    return success and string.format("Listing #%d withdrawn.", listingId) or ("Withdraw rejected: " .. tostring(reason))
end

---Console: advances all listing timers (expiry test)
---@param monthsArg string|nil
function GlobalMarket:consoleCommandAdvanceAnimalMarket(monthsArg)
    local guardError = getConsoleGuardError(true)
    if guardError ~= nil then
        return guardError
    end
    local months = tonumber(monthsArg) or 1
    if months <= 0 then
        months = 1
    end
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_ADMIN_ADVANCE, 0, { months = months })
        return "Admin request sent to the server."
    end
    self:updateAnimalMarketHourly(months)
    return string.format("Animal market advanced by %.2f month(s).", months)
end

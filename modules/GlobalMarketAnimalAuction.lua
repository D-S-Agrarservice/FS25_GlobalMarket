-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalAuction.lua
-- Livestock market (#15), Stage 2: animal auctions on top of the generic auction engine
-- (GlobalMarketAuction.lua). Listings with saleMode "AUCTION" keep their animals in escrow
-- like fixed-price listings; bids reserve money, the highest bid wins at the end, the
-- animals go into the winner's barns (plus transport fee) or the pickup box.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarket.ANIMAL_SALE_MODE = {
    FIXED = "FIXED",
    AUCTION = "AUCTION"
}

-- Money operations for bids: reservations and refunds are booked as animal purchases
local AUCTION_MONEY = {
    canPay = function(farmId, amount)
        return g_currentMission:getMoney(farmId) >= amount
    end,
    take = function(farmId, amount)
        g_currentMission:addMoney(-amount, farmId, MoneyType.NEW_ANIMALS_COST, true, true)
    end,
    refund = function(farmId, amount)
        if GlobalMarketAnimalListings.getIsPlayerFarm(farmId) then
            g_currentMission:addMoney(amount, farmId, MoneyType.NEW_ANIMALS_COST, true, true)
        end
    end
}

---Returns true if a listing is an auction
---@param listing table|nil
---@return boolean
function GlobalMarket.getIsAnimalAuction(listing)
    return listing ~= nil and listing.saleMode == GlobalMarket.ANIMAL_SALE_MODE.AUCTION and listing.auction ~= nil
end

---Returns why an auction listing cannot be withdrawn (nil if it can)
---@param listing table
---@return string|nil reason
function GlobalMarket.getAnimalAuctionCancelBlock(listing)
    if GlobalMarket.getIsAnimalAuction(listing) and listing.auction.highFactor ~= nil then
        return "auctionHasBids"
    end
    return nil
end

-- =========================================================================
-- CREATE & BID (Server)
-- =========================================================================

---Lists animals of a barn or a livestock trailer at the dealer as an auction
---@param source table
---@param clusterId number
---@param numAnimals number
---@param farmId number
---@param startFactor number Start price relative to the dealer value
---@param buyNowFactor number|nil Buy-now price (0/nil = none)
---@param durationHours number 6 / 12 / 24 / 48
---@return table|nil listing
---@return string|nil reason
function GlobalMarket:createAnimalAuction(source, clusterId, numAnimals, farmId, startFactor, buyNowFactor, durationHours)
    return self:createAnimalListing(source, clusterId, numAnimals, farmId, startFactor, 1,
        { startFactor = startFactor, buyNowFactor = buyNowFactor, durationHours = durationHours })
end

---Returns the base value (dealer value of the escrowed animals) of an auction listing
---@param listing table
---@return number|nil
local function getBaseValue(listing)
    if not GlobalMarketAnimalListings.getIsResolved(listing.snapshot) then
        return nil
    end
    return GlobalMarketAnimalListings.getDealerValue(listing.snapshot)
end

---Validates the common bid preconditions
---@return table|nil listing
---@return number|nil baseValue
---@return string|nil reason
function GlobalMarket:getAnimalAuctionForBid(listingId, farmId)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return nil, nil, "notServer"
    end
    if not GlobalMarketAnimalListings.getIsAvailable() then
        return nil, nil, "unavailable"
    end
    if not GlobalMarketAnimalListings.getIsPlayerFarm(farmId) then
        return nil, nil, "notOwned"
    end
    local listing = self:getAnimalListingById(listingId)
    if listing == nil then
        return nil, nil, "listingNotFound"
    end
    if not GlobalMarket.getIsAnimalAuction(listing) then
        return nil, nil, "notAuction"
    end
    if listing.status ~= GlobalMarket.ANIMAL_LISTING_STATUS.OPEN then
        return nil, nil, "listingBusy"
    end
    if not listing.isNpc and listing.sellerFarmId == farmId then
        return nil, nil, "ownListing"
    end
    local baseValue = getBaseValue(listing)
    if baseValue == nil or baseValue <= 0 then
        return nil, nil, "notAvailable"
    end
    return listing, baseValue, nil
end

---Places or raises a bid of a farm (factor of the dealer value)
---@param listingId number
---@param farmId number
---@param factor number
---@return boolean success
---@return string|nil reason
function GlobalMarket:bidOnAnimalAuction(listingId, farmId, factor)
    local listing, baseValue, reason = self:getAnimalAuctionForBid(listingId, farmId)
    if listing == nil then
        return false, reason
    end
    return self:applyAnimalAuctionBid(listing, farmId, false, factor, baseValue)
end

---Buys an auction at its buy-now price
---@param listingId number
---@param farmId number
---@return boolean success
---@return string|nil reason
function GlobalMarket:buyNowAnimalAuction(listingId, farmId)
    local listing, baseValue, reason = self:getAnimalAuctionForBid(listingId, farmId)
    if listing == nil then
        return false, reason
    end
    if not GlobalMarketAuction.getIsBuyNowAvailable(listing.auction) then
        return false, "buyNowUnavailable"
    end
    return self:applyAnimalAuctionBid(listing, farmId, false, listing.auction.buyNowFactor, baseValue)
end

---Places an NPC bid (NPC bidders hold no money)
---@param listing table
---@param factor number
---@return boolean success
function GlobalMarket:npcBidOnAnimalAuction(listing, factor)
    local baseValue = getBaseValue(listing)
    if baseValue == nil or listing.status ~= GlobalMarket.ANIMAL_LISTING_STATUS.OPEN then
        return false
    end
    return (self:applyAnimalAuctionBid(listing, 0, true, factor, baseValue))
end

---Applies a bid through the auction engine, notifies an outbid farm and ends the auction on buy-now
---@return boolean success
---@return string|nil reason
function GlobalMarket:applyAnimalAuctionBid(listing, farmId, isNpc, factor, baseValue)
    local auction = listing.auction
    local ok, reason, result = GlobalMarketAuction.placeBid(auction, farmId, isNpc, factor, baseValue, AUCTION_MONEY)
    if not ok then
        return false, reason
    end
    listing.priceFactor = GlobalMarketAuction.getCurrentFactor(auction)
    local snapshot = listing.snapshot
    if result.outbidFarmId ~= nil and not result.outbidIsNpc and result.outbidFarmId ~= farmId then
        self:notifyAnimalMarketFarms(GlobalMarket.ANIMAL_NOTICE.OUTBID, result.outbidFarmId, 0, snapshot.subTypeName,
            GlobalMarketAnimalListings.getNumAnimals(snapshot), result.amount, "")
    end
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Auction #%d bid by %s: %.0f%% = %d%s.", listing.id,
            isNpc and "NPC" or ("farm " .. tostring(farmId)), auction.highFactor * 100, result.amount, result.isBuyNow and " (buy-now)" or "")
    end
    if result.isBuyNow then
        self:finishAnimalAuction(listing)
    else
        self:broadcastAnimalMarketState()
    end
    return true, nil
end

-- =========================================================================
-- END & SETTLEMENT (Server)
-- =========================================================================

---Ends an auction: highest bid wins, otherwise the animals return like on expiry
---@param listing table
function GlobalMarket:finishAnimalAuction(listing)
    local auction = listing.auction
    local snapshot = listing.snapshot
    local N = GlobalMarket.ANIMAL_NOTICE
    if auction.highFactor == nil then
        if not listing.isNpc then
            self:notifyAnimalMarketFarms(N.AUCTION_NO_BID, listing.sellerFarmId, 0, snapshot.subTypeName,
                GlobalMarketAnimalListings.getNumAnimals(snapshot), 0, "")
        end
        self:returnAnimalListing(listing)
        return
    end

    self:removeAnimalListing(listing)
    local numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot)
    local baseValue = getBaseValue(listing) or 0
    local price = auction.highIsNpc and GlobalMarketAuction.getAmount(auction.highFactor, baseValue) or (auction.highReserved or 0)
    local winnerName = auction.highIsNpc and "" or GlobalMarket.getVehicleMarketFarmName(auction.highFarmId)

    if not listing.isNpc then
        local payout = price
        if auction.highIsNpc then
            payout = math.floor(price * (1 - GlobalMarket.ANIMAL_MARKET.NPC_COMMISSION) + 0.5)
        end
        g_currentMission:addMoney(payout, listing.sellerFarmId, MoneyType.SOLD_ANIMALS, true, true)
        self:notifyAnimalMarketFarms(N.SOLD, listing.sellerFarmId, 0, snapshot.subTypeName, numAnimals, payout,
            winnerName, auction.highIsNpc and "npc" or nil)
    end

    if not auction.highIsNpc then
        -- The bid is already paid (reserved); delivery like a purchase: barns plus transport fee, rest into the pickup box
        local winnerFarmId = auction.highFarmId
        snapshot.originBarnId = nil
        local feeTotal = GlobalMarketAnimalListings.getTransportFee(snapshot) or 0
        local moved = self:deliverAnimalsToFarmBarns(snapshot, winnerFarmId)
        local fee = (numAnimals > 0) and math.floor(feeTotal * moved / numAnimals + 0.5) or 0
        if fee > 0 then
            g_currentMission:addMoney(-fee, winnerFarmId, MoneyType.NEW_ANIMALS_COST, true, true)
        end
        if GlobalMarketAnimalListings.getNumAnimals(snapshot) > 0 then
            self:addAnimalPickup(winnerFarmId, snapshot, GlobalMarket.ANIMAL_PICKUP_REASON.BOUGHT)
        end
        self:notifyAnimalMarketFarms(N.AUCTION_WON, winnerFarmId, 0, snapshot.subTypeName, numAnimals, price + fee, "")
    end
    self:broadcastAnimalMarketState()
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Auction #%d won by %s for %d (%d bids).", listing.id,
            auction.highIsNpc and "an NPC" or ("farm " .. tostring(auction.highFarmId)), price, auction.bidCount or 0)
    end
end

---Hourly tick: counts all open auctions down and settles ended ones
---@param monthDelta number
---@return boolean changed
function GlobalMarket:updateAnimalAuctionsHourly(monthDelta)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return false
    end
    local daysPerPeriod = (g_currentMission.environment ~= nil and g_currentMission.environment.daysPerPeriod) or 1
    local hours = monthDelta * 24 * math.max(1, daysPerPeriod)
    local ended = {}
    for _, listing in ipairs(self.animalListings or {}) do
        if GlobalMarket.getIsAnimalAuction(listing) and listing.status == GlobalMarket.ANIMAL_LISTING_STATUS.OPEN
            and GlobalMarketAuction.tick(listing.auction, hours) then
            table.insert(ended, listing)
        end
    end
    for _, listing in ipairs(ended) do
        self:finishAnimalAuction(listing)
    end
    return #ended > 0
end

---Farm deletion: refunds bidders on auctions of the deleted seller and drops bids of a deleted bidder
---(its money is gone with the farm). The listings of the seller are removed by the market cleanup.
---@param farmId number
---@return boolean changed
function GlobalMarket:cleanupAnimalAuctionsForDeletedFarm(farmId)
    local changed = false
    for _, listing in ipairs(self.animalListings or {}) do
        if GlobalMarket.getIsAnimalAuction(listing) then
            local auction = listing.auction
            if not listing.isNpc and listing.sellerFarmId == farmId then
                GlobalMarketAuction.refundHighBid(auction, AUCTION_MONEY)
                changed = true
            elseif not auction.highIsNpc and auction.highFarmId == farmId then
                GlobalMarketAuction.refundHighBid(auction, nil)
                listing.priceFactor = GlobalMarketAuction.getCurrentFactor(auction)
                changed = true
            end
            auction.bidders[farmId] = nil
        end
    end
    return changed
end

-- =========================================================================
-- DEBUG CONSOLE
-- =========================================================================

---Returns the console suffix of an auction listing ("" for fixed-price listings)
---@param listing table
---@return string
function GlobalMarket.getAnimalAuctionConsoleSuffix(listing)
    if not GlobalMarket.getIsAnimalAuction(listing) then
        return ""
    end
    local auction = listing.auction
    local high = "none"
    if auction.highFactor ~= nil then
        high = string.format("%.0f%% by %s", auction.highFactor * 100,
            auction.highIsNpc and "NPC" or ("farm " .. tostring(auction.highFarmId)))
    end
    return string.format(" | AUCTION start %.0f%%%s | high %s | %d bids | %.1f h left", auction.startFactor * 100,
        auction.buyNowFactor ~= nil and string.format(" buy-now %.0f%%", auction.buyNowFactor * 100) or "",
        high, auction.bidCount or 0, auction.hoursRemaining or 0)
end

---Shared guard: auction commands run on the SP/MP host until the network part (step 2-2) exists
local function getAuctionConsoleGuardError()
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(false)
    if guardError ~= nil then
        return guardError
    end
    if not g_currentMission:getIsServer() then
        return "Auction commands run on the SP/MP host for now."
    end
    return nil
end

---Console: lists own animals as an auction: <clusterId> <count> <startPercent> [buyNowPercent=0] [hours=12]
function GlobalMarket:consoleCommandAnimalAuctionCreate(clusterIdArg, countArg, startPctArg, buyNowPctArg, hoursArg)
    local guardError = getAuctionConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local farmId = g_currentMission:getFarmId()
    local clusterId = tonumber(clusterIdArg)
    local source = (clusterId ~= nil) and GlobalMarket.findAnimalSourceByClusterId(farmId, clusterId) or nil
    if source == nil or tonumber(startPctArg) == nil then
        return "Usage: gmAnimalAuctionCreate <clusterId> <count> <startPercent> [buyNowPercent=0] [hours=6|12|24|48]"
    end
    local listing, reason = self:createAnimalAuction(source, clusterId, tonumber(countArg) or 0, farmId,
        tonumber(startPctArg) / 100, (tonumber(buyNowPctArg) or 0) / 100, tonumber(hoursArg) or 12)
    if listing == nil then
        return "Auction rejected: " .. tostring(reason)
    end
    return string.format("Auction #%d created%s.", listing.id, GlobalMarket.getAnimalAuctionConsoleSuffix(listing))
end

---Console: bids on an auction: <listingId> <percent of the dealer value | min>
function GlobalMarket:consoleCommandAnimalAuctionBid(listingIdArg, pctArg)
    local guardError = getAuctionConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local listing = self:getAnimalListingById(tonumber(listingIdArg) or 0)
    if listing == nil or not GlobalMarket.getIsAnimalAuction(listing) then
        return "Usage: gmAnimalAuctionBid <auction listingId> <percent|min>"
    end
    local factor = (pctArg == "min") and GlobalMarketAuction.getMinBidFactor(listing.auction) or ((tonumber(pctArg) or 0) / 100)
    local success, reason = self:bidOnAnimalAuction(listing.id, g_currentMission:getFarmId(), factor)
    if not success then
        return "Bid rejected: " .. tostring(reason)
    end
    local current = self:getAnimalListingById(listing.id)
    return "Bid placed" .. ((current ~= nil) and GlobalMarket.getAnimalAuctionConsoleSuffix(current) or " (auction ended).")
end

---Console: buys an auction at its buy-now price: <listingId>
function GlobalMarket:consoleCommandAnimalAuctionBuyNow(listingIdArg)
    local guardError = getAuctionConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local listingId = tonumber(listingIdArg)
    if listingId == nil then
        return "Usage: gmAnimalAuctionBuyNow <auction listingId>"
    end
    local success, reason = self:buyNowAnimalAuction(listingId, g_currentMission:getFarmId())
    return success and string.format("Auction #%d bought at the buy-now price.", listingId) or ("Buy-now rejected: " .. tostring(reason))
end

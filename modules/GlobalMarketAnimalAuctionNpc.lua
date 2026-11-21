-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalAuctionNpc.lua
-- Livestock market (#15), Stage 2 NPC bidders: every auction gets 0-3 hidden NPC bidders
-- with a secret limit (higher for pregnant and very healthy animals). They bid spread over
-- the duration and more often near the end, answer an outbid after 1-3 hours, mostly with
-- the minimum bid, and may take a buy-now price inside their limit. Server only; the
-- bidders are saved with the auction but never sent to clients.
-- Controlled by the admin setting "NPC animal trading" (Off / Low / Normal).
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketAnimalAuctionNpc = {}

GlobalMarketAnimalAuctionNpc.CONFIG = {
    -- Chance of 0, 1, 2, 3 NPC bidders per auction for each NPC level (1 = Low, 2 = Normal)
    BIDDER_WEIGHTS = {
        [1] = { 0.35, 0.45, 0.20, 0.00 },
        [2] = { 0.15, 0.35, 0.30, 0.20 }
    },
    LIMIT_MIN = 0.90,
    LIMIT_MAX = 1.30,
    PREGNANT_BONUS = 0.15,
    HEALTH_BONUS = 0.05,       -- For animals with at least HEALTH_BONUS_MIN health
    HEALTH_BONUS_MIN = 90,
    LIMIT_CAP = 1.50,
    FIRST_BIDS_EXPECTED = 1.0, -- Expected first-bid attempts per bidder before the final phase
    FINAL_PHASE_SHARE = 0.25,  -- Final phase: last quarter of the duration ...
    FINAL_PHASE_MIN_HOURS = 2, -- ... but at least this many hours
    FINAL_CHANCE = 0.35,       -- Hourly bid chance in the final phase
    RESPONSE_DELAY_MIN = 1,    -- Hours an outbid NPC waits before answering
    RESPONSE_DELAY_MAX = 3,
    RESPONSE_CHANCE = 0.80,    -- Hourly chance to answer once the delay is over
    BUY_NOW_CHANCE = 0.15,     -- Hourly chance to take a buy-now price inside the limit
    JUMP_CHANCE = 0.20,        -- Chance of a bid 1-2 steps above the minimum bid
    JUMP_STEPS_MAX = 2
}

local EPSILON = 0.0001

---Rounds a factor to whole percent
---@param factor number
---@return number
local function roundFactor(factor)
    return math.floor(factor * 100 + 0.5) / 100
end

---Returns the hidden limit of a new NPC bidder for a listing
---@param listing table
---@return number limit
local function rollLimit(listing)
    local cfg = GlobalMarketAnimalAuctionNpc.CONFIG
    local limit = cfg.LIMIT_MIN + math.random() * (cfg.LIMIT_MAX - cfg.LIMIT_MIN)
    local info = GlobalMarketAnimalListings.getInfo(listing.snapshot)
    if info.isPregnant then
        limit = limit + cfg.PREGNANT_BONUS
    end
    if (info.health or 0) >= cfg.HEALTH_BONUS_MIN then
        limit = limit + cfg.HEALTH_BONUS
    end
    return roundFactor(math.min(limit, cfg.LIMIT_CAP))
end

---Returns the number of NPC bidders for a new auction
---@param level number
---@return number
local function rollBidderCount(level)
    local weights = GlobalMarketAnimalAuctionNpc.CONFIG.BIDDER_WEIGHTS[level]
    if weights == nil then
        return 0
    end
    local roll = math.random()
    for i, weight in ipairs(weights) do
        roll = roll - weight
        if roll < 0 then
            return i - 1
        end
    end
    return 0
end

---Returns a printable list of the hidden limits
---@param auction table
---@return string
function GlobalMarketAnimalAuctionNpc.getBiddersText(auction)
    if auction.npcBidders == nil then
        return "not generated"
    end
    local parts = {}
    for i, bidder in ipairs(auction.npcBidders) do
        table.insert(parts, string.format("#%d %.0f%%%s", i, bidder.limit * 100,
            (auction.npcHighIndex == i) and " (high)" or ""))
    end
    return (#parts > 0) and table.concat(parts, ", ") or "none"
end

---Creates the NPC bidders of an auction (on the first tick, also for auctions from older savegames)
---@param gm table GlobalMarket instance
---@param listing table
---@param level number
local function generateBidders(gm, listing, level)
    local auction = listing.auction
    auction.npcBidders = {}
    auction.npcTotalHours = math.max(1, auction.npcTotalHours or auction.hoursRemaining or 1)
    for _ = 1, rollBidderCount(level) do
        table.insert(auction.npcBidders, { limit = rollLimit(listing), hasBid = false, waitHours = 0 })
    end
    if gm.debugManager ~= nil then
        gm.debugManager:info("AnimalMarket: Auction #%d NPC bidders: %s.", listing.id, GlobalMarketAnimalAuctionNpc.getBiddersText(auction))
    end
end

---Returns the bid factor of an NPC bidder (nil if the minimum bid is above its limit)
---@param auction table
---@param limit number
---@return number|nil factor
local function getNpcBidFactor(auction, limit)
    local cfg = GlobalMarketAnimalAuctionNpc.CONFIG
    local minBid = roundFactor(GlobalMarketAuction.getMinBidFactor(auction))
    if minBid > limit + EPSILON then
        return nil
    end
    local factor = minBid
    if math.random() < cfg.JUMP_CHANCE then
        local step = GlobalMarketAuction.CONFIG.MIN_INCREMENT
        for extra = math.random(1, cfg.JUMP_STEPS_MAX), 1, -1 do
            local candidate = roundFactor(minBid + extra * step)
            if candidate <= limit + EPSILON then
                factor = candidate
                break
            end
        end
    end
    -- Plain bids stay below the buy-now price; taking it is a separate decision
    if GlobalMarketAuction.getIsBuyNowAvailable(auction) and factor >= auction.buyNowFactor - EPSILON then
        factor = minBid
    end
    return factor
end

---Returns true if the bidder acts this tick
---@param auction table
---@param bidder table
---@param hours number
---@return boolean
local function getWantsToBid(auction, bidder, hours)
    local cfg = GlobalMarketAnimalAuctionNpc.CONFIG
    if bidder.hasBid then
        return math.random() < cfg.RESPONSE_CHANCE * hours
    end
    local total = auction.npcTotalHours or 1
    local finalHours = math.max(cfg.FINAL_PHASE_MIN_HOURS, total * cfg.FINAL_PHASE_SHARE)
    if (auction.hoursRemaining or 0) <= finalHours then
        return math.random() < cfg.FINAL_CHANCE * hours
    end
    return math.random() < cfg.FIRST_BIDS_EXPECTED / math.max(1, total - finalHours) * hours
end

---Lets the NPC bidders of one auction act (at most one bid per auction and tick)
---@param gm table GlobalMarket instance
---@param listing table
---@param hours number
---@return boolean changed
local function updateAuctionBidders(gm, listing, hours)
    local cfg = GlobalMarketAnimalAuctionNpc.CONFIG
    local auction = listing.auction
    local bidders = auction.npcBidders or {}
    local order = {}
    for i = 1, #bidders do
        table.insert(order, math.random(1, #order + 1), i)
    end
    for _, i in ipairs(order) do
        local bidder = bidders[i]
        if auction.npcHighIndex ~= i then
            if (bidder.waitHours or 0) > 0 then
                bidder.waitHours = math.max(0, bidder.waitHours - hours)
            else
                local factor = nil
                if GlobalMarketAuction.getIsBuyNowAvailable(auction) and auction.buyNowFactor <= bidder.limit + EPSILON
                    and math.random() < cfg.BUY_NOW_CHANCE * hours then
                    factor = auction.buyNowFactor
                elseif getWantsToBid(auction, bidder, hours) then
                    factor = getNpcBidFactor(auction, bidder.limit)
                end
                if factor ~= nil then
                    auction.npcBiddingIndex = i
                    local ok = gm:npcBidOnAnimalAuction(listing, factor)
                    auction.npcBiddingIndex = nil
                    if ok then
                        bidder.hasBid = true
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- =========================================================================
-- GLOBALMARKET HOOKS (Server)
-- =========================================================================

---Hourly tick: generates missing bidders and lets them bid on all open auctions
---@param hours number In-game hours of this tick
---@return boolean changed
function GlobalMarket:updateAnimalAuctionNpcs(hours)
    local level = GlobalMarket.ANIMAL_NPC_LEVEL or 0
    if level <= 0 or g_currentMission == nil or not g_currentMission:getIsServer() then
        return false
    end
    local open = {}
    for _, listing in ipairs(self.animalListings or {}) do
        if GlobalMarket.getIsAnimalAuction(listing) and listing.status == GlobalMarket.ANIMAL_LISTING_STATUS.OPEN
            and GlobalMarketAnimalListings.getIsResolved(listing.snapshot) then
            if listing.auction.npcBidders == nil then
                generateBidders(self, listing, level)
            end
            table.insert(open, listing)
        end
    end
    local changed = false
    for _, listing in ipairs(open) do
        -- A buy-now in an earlier iteration may have ended the listing
        if listing.status == GlobalMarket.ANIMAL_LISTING_STATUS.OPEN and self:getAnimalListingById(listing.id) == listing
            and updateAuctionBidders(self, listing, hours) then
            changed = true
        end
    end
    return changed
end

---Called by applyAnimalAuctionBid after every accepted bid: tracks which NPC holds the highest
---bid and lets an outbid NPC wait before it answers
---@param auction table
---@param isNpc boolean
---@param result table See GlobalMarketAuction.placeBid
function GlobalMarket.onAnimalAuctionBidPlaced(auction, isNpc, result)
    local cfg = GlobalMarketAnimalAuctionNpc.CONFIG
    local previous = auction.npcHighIndex
    if result ~= nil and result.outbidIsNpc and previous ~= nil and auction.npcBidders ~= nil then
        local bidder = auction.npcBidders[previous]
        if bidder ~= nil then
            bidder.hasBid = true
            bidder.waitHours = math.random(cfg.RESPONSE_DELAY_MIN, cfg.RESPONSE_DELAY_MAX)
        end
    end
    auction.npcHighIndex = isNpc and auction.npcBiddingIndex or nil
end

---NPC trading switched off: NPC auctions with a player's highest bid end now (the player wins),
---all NPC bidders leave. NPC bids already placed stay. Remaining NPC listings are removed by the caller.
function GlobalMarket:endAnimalAuctionNpcs()
    local finish = {}
    for _, listing in ipairs(self.animalListings or {}) do
        if GlobalMarket.getIsAnimalAuction(listing) then
            listing.auction.npcBidders = {}
            listing.auction.npcHighIndex = nil
            local auction = listing.auction
            if listing.isNpc and listing.status == GlobalMarket.ANIMAL_LISTING_STATUS.OPEN
                and auction.highFactor ~= nil and not auction.highIsNpc then
                table.insert(finish, listing)
            end
        end
    end
    for _, listing in ipairs(finish) do
        self:finishAnimalAuction(listing)
    end
end

-- =========================================================================
-- SAVEGAME
-- =========================================================================

---Writes the NPC bidders of an auction (nothing if they were not generated yet)
---@param xmlFile table
---@param key string Auction key
---@param auction table
function GlobalMarketAnimalAuctionNpc.saveToXml(xmlFile, key, auction)
    if auction.npcBidders == nil then
        return
    end
    xmlFile:setInt(key .. ".npcBidders#count", #auction.npcBidders)
    xmlFile:setFloat(key .. ".npcBidders#totalHours", auction.npcTotalHours or 1)
    xmlFile:setInt(key .. ".npcBidders#highIndex", auction.npcHighIndex or 0)
    for i, bidder in ipairs(auction.npcBidders) do
        local bidderKey = string.format("%s.npcBidders.bidder(%d)", key, i - 1)
        xmlFile:setFloat(bidderKey .. "#limit", bidder.limit)
        xmlFile:setBool(bidderKey .. "#hasBid", bidder.hasBid == true)
        xmlFile:setFloat(bidderKey .. "#waitHours", bidder.waitHours or 0)
    end
end

---Reads the NPC bidders written by saveToXml into an auction
---@param xmlFile table
---@param key string Auction key
---@param auction table
function GlobalMarketAnimalAuctionNpc.loadFromXml(xmlFile, key, auction)
    if xmlFile:getInt(key .. ".npcBidders#count") == nil then
        return
    end
    auction.npcBidders = {}
    auction.npcTotalHours = xmlFile:getFloat(key .. ".npcBidders#totalHours", auction.hoursRemaining or 1)
    xmlFile:iterate(key .. ".npcBidders.bidder", function(_, bidderKey)
        local limit = xmlFile:getFloat(bidderKey .. "#limit")
        if limit ~= nil then
            table.insert(auction.npcBidders, {
                limit = limit,
                hasBid = xmlFile:getBool(bidderKey .. "#hasBid", false),
                waitHours = xmlFile:getFloat(bidderKey .. "#waitHours", 0)
            })
        end
    end)
    local highIndex = xmlFile:getInt(key .. ".npcBidders#highIndex", 0)
    if highIndex > 0 and highIndex <= #auction.npcBidders and auction.highIsNpc then
        auction.npcHighIndex = highIndex
    end
end

-- =========================================================================
-- CONSOLE (test helper)
-- =========================================================================

---Test helper (Server): places the minimum bid of an anonymous NPC, ignoring the hidden limits
---@param listingId number
---@return boolean success
---@return string|nil reason
function GlobalMarket:forceNpcAuctionBid(listingId)
    local listing = self:getAnimalListingById(tonumber(listingId) or 0)
    if listing == nil or not GlobalMarket.getIsAnimalAuction(listing) or listing.status ~= GlobalMarket.ANIMAL_LISTING_STATUS.OPEN then
        return false, "listingNotFound"
    end
    local factor = roundFactor(GlobalMarketAuction.getMinBidFactor(listing.auction))
    if GlobalMarketAuction.getIsBuyNowAvailable(listing.auction) and factor >= listing.auction.buyNowFactor - EPSILON then
        factor = listing.auction.buyNowFactor
    end
    if not self:npcBidOnAnimalAuction(listing, factor) then
        return false, "invalid"
    end
    return true, nil
end

---Console: an NPC places the minimum bid on an auction now (host, dedicated server console or admin client): <listingId>
function GlobalMarket:consoleCommandAnimalAuctionNpcBid(listingIdArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(true)
    if guardError ~= nil then
        return guardError
    end
    local listingId = tonumber(listingIdArg)
    if listingId == nil then
        return "Usage: gmAnimalAuctionNpcBid <auction listingId>"
    end
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_ADMIN_AUCTION_NPC_BID, 0, { targetId = listingId })
        return "Admin request sent to the server."
    end
    local listing = self:getAnimalListingById(listingId)
    local biddersText = (listing ~= nil and listing.auction ~= nil) and GlobalMarketAnimalAuctionNpc.getBiddersText(listing.auction) or ""
    local success, reason = self:forceNpcAuctionBid(listingId)
    if not success then
        return "NPC bid rejected: " .. tostring(reason)
    end
    local current = self:getAnimalListingById(listingId)
    return "NPC bid placed" .. ((current ~= nil) and GlobalMarket.getAnimalAuctionConsoleSuffix(current) or " (auction ended)")
        .. " | NPC bidders: " .. biddersText
end

-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAuction.lua
-- Generic auction engine (#15 Stage 2), independent of the listing type: start and buy-now
-- price, bids with escrow (only the highest bid holds money, a bidder raising their own bid
-- reserves the difference), minimum increment, anti-sniping extension, countdown and
-- savegame persistence. Prices are factors relative to a base value the caller provides
-- (e.g. the dealer value of the animals), money moves through caller-supplied functions.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketAuction = {}

GlobalMarketAuction.CONFIG = {
    START_FACTOR_MIN = 0.50,
    START_FACTOR_MAX = 1.50,
    BUY_NOW_FACTOR_MAX = 2.50,
    MIN_INCREMENT = 0.05,      -- Minimum raise relative to the base value
    DURATIONS = { 6, 12, 24, 48 }, -- Allowed durations in in-game hours
    SNIPE_WINDOW_HOURS = 1,    -- A bid inside this window extends the auction ...
    EXTENSION_HOURS = 1        -- ... by this many hours
}

local EPSILON = 0.0001

---Returns true if a duration is one of the allowed values
---@param hours number
---@return boolean
local function getIsAllowedDuration(hours)
    for _, allowed in ipairs(GlobalMarketAuction.CONFIG.DURATIONS) do
        if math.abs(allowed - hours) < EPSILON then
            return true
        end
    end
    return false
end

---Validates auction options
---@param startFactor number
---@param buyNowFactor number|nil 0/nil = no buy-now price
---@param durationHours number
---@return boolean isValid
---@return string|nil reason
function GlobalMarketAuction.validateOptions(startFactor, buyNowFactor, durationHours)
    local cfg = GlobalMarketAuction.CONFIG
    startFactor = tonumber(startFactor)
    if startFactor == nil or startFactor < cfg.START_FACTOR_MIN - EPSILON or startFactor > cfg.START_FACTOR_MAX + EPSILON then
        return false, "startOutOfRange"
    end
    buyNowFactor = tonumber(buyNowFactor) or 0
    if buyNowFactor > 0 and (buyNowFactor < startFactor + cfg.MIN_INCREMENT - EPSILON or buyNowFactor > cfg.BUY_NOW_FACTOR_MAX + EPSILON) then
        return false, "buyNowOutOfRange"
    end
    if not getIsAllowedDuration(tonumber(durationHours) or 0) then
        return false, "auctionDurationInvalid"
    end
    return true, nil
end

---Creates a new auction state (call validateOptions first)
---@param startFactor number
---@param buyNowFactor number|nil
---@param durationHours number
---@return table auction
function GlobalMarketAuction.create(startFactor, buyNowFactor, durationHours)
    local buyNow = tonumber(buyNowFactor) or 0
    return {
        startFactor = startFactor,
        buyNowFactor = (buyNow > 0) and buyNow or nil,
        hoursRemaining = durationHours,
        highFarmId = nil,       -- Highest bidder (0 for NPC bidders)
        highIsNpc = false,
        highFactor = nil,
        highReserved = 0,       -- Money held for the highest bid
        bidCount = 0,
        bidders = {}            -- farmId -> true (players who took part, for the UI)
    }
end

---Returns the number of bids
---@param auction table|nil
---@return number
function GlobalMarketAuction.getBidCount(auction)
    return (auction ~= nil) and (auction.bidCount or 0) or 0
end

---Returns the current price factor (highest bid or start price)
---@param auction table
---@return number
function GlobalMarketAuction.getCurrentFactor(auction)
    return auction.highFactor or auction.startFactor
end

---Returns the lowest factor a new bid must reach
---@param auction table
---@return number
function GlobalMarketAuction.getMinBidFactor(auction)
    if auction.highFactor == nil then
        return auction.startFactor
    end
    return auction.highFactor + GlobalMarketAuction.CONFIG.MIN_INCREMENT
end

---Returns true while the buy-now price is still available (no bid has reached it)
---@param auction table
---@return boolean
function GlobalMarketAuction.getIsBuyNowAvailable(auction)
    return auction.buyNowFactor ~= nil and (auction.highFactor == nil or auction.highFactor < auction.buyNowFactor - EPSILON)
end

---Converts a factor into money for a base value
---@param factor number
---@param baseValue number
---@return number
function GlobalMarketAuction.getAmount(factor, baseValue)
    return math.floor(factor * baseValue + 0.5)
end

---Places or raises a bid. Money operations go through money.canPay / money.take / money.refund
---(farmId, amount); NPC bidders (isNpc) hold no money.
---@param auction table
---@param farmId number Bidder farm (0 for NPC bidders)
---@param isNpc boolean
---@param factor number Bid as factor of the base value
---@param baseValue number
---@param money table { canPay = function(farmId, amount), take = function(farmId, amount), refund = function(farmId, amount) }
---@return boolean success
---@return string|nil reason
---@return table|nil result { outbidFarmId, outbidIsNpc, isBuyNow, amount }
function GlobalMarketAuction.placeBid(auction, farmId, isNpc, factor, baseValue, money)
    factor = tonumber(factor)
    if factor == nil or baseValue == nil or baseValue <= 0 then
        return false, "invalid", nil
    end
    local isBuyNow = false
    if GlobalMarketAuction.getIsBuyNowAvailable(auction) and factor >= auction.buyNowFactor - EPSILON then
        factor = auction.buyNowFactor
        isBuyNow = true
    elseif factor < GlobalMarketAuction.getMinBidFactor(auction) - EPSILON then
        return false, "bidTooLow", nil
    end

    local isRaise = (not isNpc and not auction.highIsNpc and auction.highFarmId == farmId)
    local amount = GlobalMarketAuction.getAmount(factor, baseValue)
    local alreadyReserved = isRaise and (auction.highReserved or 0) or 0
    local need = amount - alreadyReserved
    if not isNpc then
        if need > 0 and not money.canPay(farmId, need) then
            return false, "notEnoughMoney", nil
        end
        if need > 0 then
            money.take(farmId, need)
        end
    end

    local result = { isBuyNow = isBuyNow, amount = amount }
    if not isRaise and auction.highFactor ~= nil then
        -- Refund the previous highest bidder at once
        result.outbidFarmId = auction.highFarmId
        result.outbidIsNpc = auction.highIsNpc
        if not auction.highIsNpc and (auction.highReserved or 0) > 0 then
            money.refund(auction.highFarmId, auction.highReserved)
        end
    end
    auction.highFarmId = isNpc and 0 or farmId
    auction.highIsNpc = isNpc == true
    auction.highFactor = factor
    auction.highReserved = isNpc and 0 or amount
    auction.bidCount = (auction.bidCount or 0) + 1
    if not isNpc then
        auction.bidders[farmId] = true
    end
    -- Anti-sniping: a late bid gives the others time to react
    local cfg = GlobalMarketAuction.CONFIG
    if not isBuyNow and (auction.hoursRemaining or 0) < cfg.SNIPE_WINDOW_HOURS then
        auction.hoursRemaining = (auction.hoursRemaining or 0) + cfg.EXTENSION_HOURS
    end
    return true, nil, result
end

---Refunds the highest bid (cancel, deleted seller) and clears it
---@param auction table
---@param money table See placeBid
function GlobalMarketAuction.refundHighBid(auction, money)
    if auction.highFactor ~= nil and not auction.highIsNpc and (auction.highReserved or 0) > 0 and money ~= nil then
        money.refund(auction.highFarmId, auction.highReserved)
    end
    auction.highFarmId = nil
    auction.highIsNpc = false
    auction.highFactor = nil
    auction.highReserved = 0
end

---Counts the auction down
---@param auction table
---@param hours number
---@return boolean ended
function GlobalMarketAuction.tick(auction, hours)
    auction.hoursRemaining = (auction.hoursRemaining or 0) - hours
    return auction.hoursRemaining <= 0
end

-- =========================================================================
-- SAVEGAME
-- =========================================================================

---Writes an auction state below an XML key
---@param xmlFile table
---@param key string
---@param auction table
function GlobalMarketAuction.saveToXml(xmlFile, key, auction)
    xmlFile:setFloat(key .. "#startFactor", auction.startFactor or 1)
    xmlFile:setFloat(key .. "#buyNowFactor", auction.buyNowFactor or 0)
    xmlFile:setFloat(key .. "#hoursRemaining", auction.hoursRemaining or 0)
    xmlFile:setInt(key .. "#bidCount", auction.bidCount or 0)
    if auction.highFactor ~= nil then
        xmlFile:setInt(key .. ".highBid#farmId", auction.highFarmId or 0)
        xmlFile:setBool(key .. ".highBid#isNpc", auction.highIsNpc == true)
        xmlFile:setFloat(key .. ".highBid#factor", auction.highFactor)
        xmlFile:setInt(key .. ".highBid#reserved", auction.highReserved or 0)
    end
    local bidders = {}
    for farmId in pairs(auction.bidders or {}) do
        table.insert(bidders, tostring(farmId))
    end
    table.sort(bidders)
    xmlFile:setString(key .. "#bidders", table.concat(bidders, " "))
end

---Reads an auction state written by saveToXml
---@param xmlFile table
---@param key string
---@return table|nil auction
function GlobalMarketAuction.loadFromXml(xmlFile, key)
    local startFactor = xmlFile:getFloat(key .. "#startFactor")
    if startFactor == nil then
        return nil
    end
    local auction = GlobalMarketAuction.create(startFactor, xmlFile:getFloat(key .. "#buyNowFactor", 0),
        xmlFile:getFloat(key .. "#hoursRemaining", 0))
    auction.bidCount = xmlFile:getInt(key .. "#bidCount", 0)
    local highFactor = xmlFile:getFloat(key .. ".highBid#factor")
    if highFactor ~= nil then
        auction.highFarmId = xmlFile:getInt(key .. ".highBid#farmId", 0)
        auction.highIsNpc = xmlFile:getBool(key .. ".highBid#isNpc", false)
        auction.highFactor = highFactor
        auction.highReserved = xmlFile:getInt(key .. ".highBid#reserved", 0)
    end
    for farmIdText in string.gmatch(xmlFile:getString(key .. "#bidders", ""), "%d+") do
        auction.bidders[tonumber(farmIdText)] = true
    end
    return auction
end

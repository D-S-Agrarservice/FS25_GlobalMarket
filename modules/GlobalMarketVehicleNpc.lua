-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleNpc.lua
-- Used vehicle market (#16), Stage 1 NPC trading: NPC dealers buy player listings
-- (price-dependent, minus commission) and list generated used vehicles of their own.
-- Controlled by the admin setting "NPC vehicle trading" (Off / Low / Normal).
-- Author: D-S-Agrarservice
-- =========================================================================================

-- 0 = Off, 1 = Low, 2 = Normal (set by GlobalMarketSettings)
GlobalMarket.VEHICLE_NPC_LEVEL = 2

GlobalMarket.VEHICLE_NPC = {
    -- Expected NPC purchases per month for a listing at the best price (scaled by attractiveness^2)
    BUY_RATE_PER_MONTH = { [1] = 1.0, [2] = 3.0 },
    -- No NPC buys above this price factor; attractiveness 1.0 at PRICE_FACTOR_MIN
    BUY_MAX_FACTOR = 1.25,
    -- Target number of open NPC listings and expected new NPC listings per month
    TARGET_LISTINGS = { [1] = 4, [2] = 10 },
    NEW_PER_MONTH = { [1] = 2, [2] = 6 },
    -- Generated condition and terms
    AGE_MIN = 6,
    AGE_MAX = 60,
    PRICE_FACTOR_MIN = 0.90,
    PRICE_FACTOR_MAX = 1.15,
    DURATION_MIN = 1,
    DURATION_MAX = 4,
    CONFIG_CHANGE_CHANCE = 0.25
}

-- =========================================================================
-- NPC BUYERS
-- =========================================================================

---Returns the hourly purchase chance of a player listing
---@param listing table
---@param monthDelta number Months per tick
---@return number chance
local function getNpcBuyChance(listing, monthDelta)
    local npc = GlobalMarket.VEHICLE_NPC
    local rate = npc.BUY_RATE_PER_MONTH[GlobalMarket.VEHICLE_NPC_LEVEL or 0]
    if rate == nil then
        return 0
    end
    local minFactor = GlobalMarket.VEHICLE_MARKET.PRICE_FACTOR_MIN
    local attractiveness = math.clamp((npc.BUY_MAX_FACTOR - (listing.priceFactor or 1)) / (npc.BUY_MAX_FACTOR - minFactor), 0, 1)
    return rate * attractiveness * attractiveness * monthDelta
end

---NPC dealer buys a player listing: the seller gets the price minus commission, the vehicle is gone
---@param listing table
function GlobalMarket:sellVehicleListingToNpc(listing)
    local price = GlobalMarketVehicleListings.getListingPrice(listing)
    if price == nil then
        return
    end
    local payout = math.floor(price * (1 - GlobalMarket.VEHICLE_MARKET.NPC_COMMISSION) + 0.5)
    g_currentMission:addMoney(payout, listing.sellerFarmId, MoneyType.SHOP_VEHICLE_SELL, true, true)
    self:removeVehicleListing(listing)
    self:notifyVehicleMarketFarms(GlobalMarket.VEHICLE_NOTICE.SOLD, listing.sellerFarmId, 0, "npc",
        listing.snapshot.xmlFilename, payout, "")
    if self.debugManager ~= nil then
        self.debugManager:info("VehicleMarket: NPC dealer bought listing #%d for %d (payout %d).", listing.id, price, payout)
    end
end

-- =========================================================================
-- NPC SELLERS (generated used vehicles)
-- =========================================================================

---Returns true if a store item may be generated as NPC listing
local function isGeneratableStoreItem(storeItem)
    return storeItem ~= nil and storeItem.showInStore and storeItem.extraContentId == nil
        and storeItem.bundleInfo == nil and (storeItem.price or 0) > 0
        and GlobalMarketVehicleListings.getGroupForStoreItem(storeItem) ~= nil
end

---Returns true if a config name is controlled by a configuration set (left at default, like the basegame)
local function isInConfigSet(storeItem, configName)
    for _, configSet in ipairs(storeItem.configurationSets or {}) do
        if configSet.configurations ~= nil and configSet.configurations[configName] ~= nil then
            return true
        end
    end
    return false
end

---Builds a random but valid configuration snapshot for a store item
---@param storeItem table
---@return table|nil snapshot
function GlobalMarket.buildNpcVehicleSnapshot(storeItem)
    local npc = GlobalMarket.VEHICLE_NPC
    local configs = {}
    for configName, items in pairs(storeItem.configurations or {}) do
        local configId = ConfigurationUtil.getDefaultConfigIdFromItems(items)
        if #items > 1 and not isInConfigSet(storeItem, configName) and math.random() < npc.CONFIG_CHANGE_CHANCE then
            local candidate = math.random(1, #items)
            if items[candidate] ~= nil and items[candidate].isSelectable ~= false then
                configId = candidate
            end
        end
        local item = items[configId]
        if item ~= nil and item.saveId ~= nil then
            table.insert(configs, { name = configName, saveId = tostring(item.saveId), isActive = true, isBought = true })
        end
    end
    table.sort(configs, function(a, b) return a.name < b.name end)

    local age = math.random(npc.AGE_MIN, npc.AGE_MAX)
    local modName, modFileHash = GlobalMarketVehicleListings.getModInfo(storeItem)
    return {
        xmlFilename = NetworkUtil.convertToNetworkFilename(storeItem.xmlFilename),
        modName = modName,
        modFileHash = modFileHash,
        group = GlobalMarketVehicleListings.getGroupForStoreItem(storeItem),
        configs = configs,
        age = age,
        -- Same operating time formula as the basegame used vehicle generator
        operatingTime = age * (math.random() * 0.8 + 0.5) * 60 * 60 * 1000,
        damage = math.random() * 0.4 + 0.1,
        wear = math.random() * 0.7 + 0.1
    }
end

---Creates one NPC dealer listing from a random store vehicle
---@return table|nil listing
function GlobalMarket:createNpcVehicleListing()
    local npc = GlobalMarket.VEHICLE_NPC
    local items = g_storeManager:getItems()
    local storeItem = nil
    for _ = 1, 20 do
        local candidate = items[math.random(1, #items)]
        if isGeneratableStoreItem(candidate) then
            storeItem = candidate
            break
        end
    end
    if storeItem == nil then
        return nil
    end
    local snapshot = GlobalMarket.buildNpcVehicleSnapshot(storeItem)
    if GlobalMarketVehicleListings.resolveSnapshot(snapshot) == nil then
        return nil
    end

    local id = self.nextVehicleListingId or 1
    self.nextVehicleListingId = id + 1
    local serverId = (self.ensureServerInstanceId ~= nil) and self:ensureServerInstanceId() or (self.serverInstanceId or "")
    local steps = math.floor((npc.PRICE_FACTOR_MAX - npc.PRICE_FACTOR_MIN) / 0.05 + 0.5)
    local listing = {
        id = id,
        uid = string.format("%s_v%d", serverId, id),
        status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN,
        sellerFarmId = 0,
        sellerName = "",
        isNpc = true,
        saleMode = "FIXED",
        priceFactor = npc.PRICE_FACTOR_MIN + math.random(0, steps) * 0.05,
        monthsRemaining = math.random(npc.DURATION_MIN, npc.DURATION_MAX),
        snapshot = snapshot
    }
    table.insert(self.vehicleListings, listing)
    if self.debugManager ~= nil then
        self.debugManager:info("VehicleMarket: NPC listing #%d created (%s, %.0f%%).", id, snapshot.xmlFilename, listing.priceFactor * 100)
    end
    return listing
end

-- =========================================================================
-- HOURLY TICK & MODE CHANGES (Server)
-- =========================================================================

---Runs NPC purchases and NPC listing generation for one tick
---@param monthDelta number
---@return boolean changed
function GlobalMarket:updateVehicleMarketNpcs(monthDelta)
    local level = GlobalMarket.VEHICLE_NPC_LEVEL or 0
    if level <= 0 or g_currentMission == nil or not g_currentMission:getIsServer() then
        return false
    end
    local npc = GlobalMarket.VEHICLE_NPC
    local changed = false

    local buyers = {}
    local npcCount = 0
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isNpc then
            npcCount = npcCount + 1
        elseif listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.OPEN and math.random() < getNpcBuyChance(listing, monthDelta) then
            table.insert(buyers, listing)
        end
    end
    for _, listing in ipairs(buyers) do
        self:sellVehicleListingToNpc(listing)
        changed = true
    end

    local target = npc.TARGET_LISTINGS[level] or 0
    local chance = (npc.NEW_PER_MONTH[level] or 0) * monthDelta
    if npcCount < target and #self.vehicleListings < GlobalMarket.VEHICLE_MARKET.MAX_TOTAL and math.random() < chance then
        if self:createNpcVehicleListing() ~= nil then
            changed = true
        end
    end
    return changed
end

---Reacts to a changed NPC level; "Off" removes all open NPC listings (server)
---@param level number
function GlobalMarket:onVehicleNpcModeChanged(level)
    if (level or 0) > 0 or g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    local kept, removed = {}, 0
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isNpc and listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.OPEN then
            removed = removed + 1
        else
            table.insert(kept, listing)
        end
    end
    if removed > 0 then
        self.vehicleListings = kept
        self:broadcastVehicleMarketState()
    end
end

---Console: creates NPC listings immediately (test)
---@param countArg string|nil
function GlobalMarket:consoleCommandVehicleMarketSpawnNpc(countArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "Execute gmVehicleMarketSpawnNpc on the server/SP host."
    end
    local created = 0
    for _ = 1, math.clamp(tonumber(countArg) or 1, 1, 20) do
        if #self.vehicleListings < GlobalMarket.VEHICLE_MARKET.MAX_TOTAL and self:createNpcVehicleListing() ~= nil then
            created = created + 1
        end
    end
    self:broadcastVehicleMarketState()
    return string.format("Created %d NPC listing(s).", created)
end

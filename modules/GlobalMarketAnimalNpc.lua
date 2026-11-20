-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalNpc.lua
-- Livestock market (#15), Stage 1 NPC trading: NPC animal dealers buy player listings
-- (price-dependent, minus commission) and list generated animals of their own, incl. age
-- stages and pregnant animals the basegame dealer does not sell.
-- Controlled by the admin setting "NPC animal trading" (Off / Low / Normal).
-- Author: D-S-Agrarservice
-- =========================================================================================

-- 0 = Off, 1 = Low, 2 = Normal (set by GlobalMarketSettings)
GlobalMarket.ANIMAL_NPC_LEVEL = 2

GlobalMarket.ANIMAL_NPC = {
    -- Expected NPC purchases per month for a listing at the best price (scaled by attractiveness^2)
    BUY_RATE_PER_MONTH = { [1] = 1.0, [2] = 3.0 },
    -- No NPC buys above this price factor; attractiveness 1.0 at PRICE_FACTOR_MIN of the market
    BUY_MAX_FACTOR = 1.25,
    -- Target number of open NPC listings and expected new NPC listings per month
    TARGET_LISTINGS = { [1] = 4, [2] = 8 },
    NEW_PER_MONTH = { [1] = 2, [2] = 6 },
    -- Asking price of NPC listings (5 % steps); pregnant animals start higher
    PRICE_FACTOR_MIN = 0.95,
    PRICE_FACTOR_MAX = 1.30,
    PREGNANT_PRICE_FACTOR_MIN = 1.10,
    DURATION_MIN = 1,
    DURATION_MAX = 3,
    -- Generated condition
    YOUNG_CHANCE = 0.25,      -- Share of animals below breeding age
    ADULT_AGE_SPAN = 30,      -- Adults: breeding age up to breeding age + span (months)
    MAX_AGE = 60,
    HEALTH_MIN = 70,
    HEALTH_MAX = 100,
    PREGNANT_CHANCE = 0.30,   -- Share of breeding-ready animals that are pregnant
    PREGNANCY_MIN = 10,
    PREGNANCY_MAX = 90,
    GROUP_MIN = 1,
    GROUP_MAX = 10,
    -- Animal types kept in large flocks
    LARGE_GROUP_TYPES = { CHICKEN = true },
    LARGE_GROUP_MIN = 10,
    LARGE_GROUP_MAX = 50
}

-- =========================================================================
-- NPC BUYERS
-- =========================================================================

---Returns the hourly purchase chance of a player listing
---@param listing table
---@param monthDelta number Months per tick
---@return number chance
local function getNpcBuyChance(listing, monthDelta)
    local npc = GlobalMarket.ANIMAL_NPC
    local rate = npc.BUY_RATE_PER_MONTH[GlobalMarket.ANIMAL_NPC_LEVEL or 0]
    if rate == nil then
        return 0
    end
    local minFactor = GlobalMarket.ANIMAL_MARKET.PRICE_FACTOR_MIN
    local attractiveness = math.clamp((npc.BUY_MAX_FACTOR - (listing.priceFactor or 1)) / (npc.BUY_MAX_FACTOR - minFactor), 0, 1)
    return rate * attractiveness * attractiveness * monthDelta
end

---NPC dealer buys a player listing: the seller gets the price minus commission, the animals are gone
---@param listing table
function GlobalMarket:sellAnimalListingToNpc(listing)
    local price = GlobalMarketAnimalListings.getListingPrice(listing)
    if price == nil then
        return
    end
    local snapshot = listing.snapshot
    local numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot)
    local payout = math.floor(price * (1 - GlobalMarket.ANIMAL_MARKET.NPC_COMMISSION) + 0.5)
    g_currentMission:addMoney(payout, listing.sellerFarmId, MoneyType.SOLD_ANIMALS, true, true)
    self:removeAnimalListing(listing)
    self:notifyAnimalMarketFarms(GlobalMarket.ANIMAL_NOTICE.SOLD, listing.sellerFarmId, 0, snapshot.subTypeName,
        numAnimals, payout, "", "npc")
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: NPC dealer bought listing #%d for %d (payout %d).", listing.id, price, payout)
    end
end

-- =========================================================================
-- NPC SELLERS (generated animals)
-- =========================================================================

---Returns the subtypes that at least one player farm can keep in one of its barns
---@return table subTypeIndices
local function getNpcSubTypeCandidates()
    local animalSystem = g_currentMission.animalSystem
    local supported = {}
    local candidates = {}
    for _, farm in pairs(g_farmManager:getFarms()) do
        if GlobalMarketAnimalListings.getIsPlayerFarm(farm.farmId) then
            for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farm.farmId, nil)) do
                for index, _ in ipairs(animalSystem.subTypes or {}) do
                    if not supported[index] and barn:getSupportsAnimalSubType(index) then
                        supported[index] = true
                        table.insert(candidates, index)
                    end
                end
            end
        end
    end
    return candidates
end

---Builds a generated cluster of a subtype with a mixed age, health and pregnancy state
---@param subTypeIndex number
---@return table|nil cluster Detached cluster
function GlobalMarket.buildNpcAnimalCluster(subTypeIndex)
    local npc = GlobalMarket.ANIMAL_NPC
    local animalSystem = g_currentMission.animalSystem
    local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
    local cluster = (subType ~= nil) and animalSystem:createClusterFromSubTypeIndex(subTypeIndex) or nil
    if cluster == nil then
        return nil
    end
    local breedingAge = math.max(1, subType.reproductionMinAgeMonth or 12)
    local age
    if math.random() < npc.YOUNG_CHANCE then
        age = math.random(0, breedingAge - 1)
    else
        age = math.random(breedingAge, math.min(npc.MAX_AGE, breedingAge + npc.ADULT_AGE_SPAN))
    end
    cluster.age = math.min(age, npc.MAX_AGE)
    cluster.health = math.random(npc.HEALTH_MIN, npc.HEALTH_MAX)
    cluster.reproduction = 0

    local typeName = GlobalMarketAnimalListings.getTypeName(subTypeIndex)
    local count
    if not cluster:getSupportsMerging() then
        count = 1
    elseif npc.LARGE_GROUP_TYPES[typeName or ""] then
        count = math.random(npc.LARGE_GROUP_MIN, npc.LARGE_GROUP_MAX)
    else
        count = math.random(npc.GROUP_MIN, npc.GROUP_MAX)
    end
    cluster.numAnimals = math.max(1, math.min(count, cluster:getMaxNumAnimals()))

    if cluster:getSupportsReproduction() and cluster.age >= breedingAge
        and cluster:getHealthFactor() >= (subType.reproductionMinHealth or 0) and math.random() < npc.PREGNANT_CHANCE then
        cluster.reproduction = math.random(npc.PREGNANCY_MIN, npc.PREGNANCY_MAX)
    end
    return cluster
end

---Creates one NPC dealer listing with generated animals
---@return table|nil listing
function GlobalMarket:createNpcAnimalListing()
    local npc = GlobalMarket.ANIMAL_NPC
    local candidates = getNpcSubTypeCandidates()
    if #candidates == 0 then
        return nil
    end
    local cluster = GlobalMarket.buildNpcAnimalCluster(candidates[math.random(1, #candidates)])
    if cluster == nil then
        return nil
    end
    local snapshot = GlobalMarketAnimalListings.createSnapshot(cluster)
    local minFactor = (cluster.reproduction > 0) and npc.PREGNANT_PRICE_FACTOR_MIN or npc.PRICE_FACTOR_MIN
    local steps = math.max(0, math.floor((npc.PRICE_FACTOR_MAX - minFactor) / 0.05 + 0.5))

    local id = self.nextAnimalListingId or 1
    self.nextAnimalListingId = id + 1
    local serverId = (self.ensureServerInstanceId ~= nil) and self:ensureServerInstanceId() or (self.serverInstanceId or "")
    local listing = {
        id = id,
        uid = string.format("%s_a%d", serverId, id),
        status = GlobalMarket.ANIMAL_LISTING_STATUS.OPEN,
        sellerFarmId = 0,
        sellerName = "",
        isNpc = true,
        saleMode = "FIXED",
        priceFactor = minFactor + math.random(0, steps) * 0.05,
        monthsRemaining = math.random(npc.DURATION_MIN, npc.DURATION_MAX),
        snapshot = snapshot
    }
    table.insert(self.animalListings, listing)
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: NPC listing #%d created (%s x%d, %d months, health %d, pregnant %d%%, %.0f%%).",
            id, snapshot.subTypeName, cluster.numAnimals, cluster.age, cluster.health, cluster.reproduction, listing.priceFactor * 100)
    end
    return listing
end

-- =========================================================================
-- HOURLY TICK & MODE CHANGES (Server)
-- =========================================================================

---Runs NPC purchases and NPC listing generation for one tick
---@param monthDelta number
---@return boolean changed
function GlobalMarket:updateAnimalMarketNpcs(monthDelta)
    local level = GlobalMarket.ANIMAL_NPC_LEVEL or 0
    if level <= 0 or g_currentMission == nil or not g_currentMission:getIsServer() then
        return false
    end
    local npc = GlobalMarket.ANIMAL_NPC
    local changed = false

    local buyers = {}
    local npcCount = 0
    for _, listing in ipairs(self.animalListings or {}) do
        if listing.isNpc then
            npcCount = npcCount + 1
        elseif listing.saleMode ~= GlobalMarket.ANIMAL_SALE_MODE.AUCTION and GlobalMarketAnimalListings.getIsResolved(listing.snapshot)
            and math.random() < getNpcBuyChance(listing, monthDelta) then
            table.insert(buyers, listing)
        end
    end
    for _, listing in ipairs(buyers) do
        self:sellAnimalListingToNpc(listing)
        changed = true
    end

    local target = npc.TARGET_LISTINGS[level] or 0
    local chance = (npc.NEW_PER_MONTH[level] or 0) * monthDelta
    if npcCount < target and #self.animalListings < GlobalMarket.ANIMAL_MARKET.MAX_TOTAL and math.random() < chance then
        if self:createNpcAnimalListing() ~= nil then
            changed = true
        end
    end
    return changed
end

---Reacts to a changed NPC level; "Off" removes all open NPC listings and ends a great demand (server)
---@param level number
function GlobalMarket:onAnimalNpcModeChanged(level)
    if (level or 0) > 0 or g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    -- Great demands come from NPC dealers as well (Stage 1b)
    if self.animalDemand ~= nil and self.endAnimalDemand ~= nil then
        self:endAnimalDemand()
    end
    local listings = self.animalListings or {}
    local removed = 0
    for i = #listings, 1, -1 do
        if listings[i].isNpc then
            table.remove(listings, i)
            removed = removed + 1
        end
    end
    if removed > 0 then
        self:broadcastAnimalMarketState()
    end
end

---Test helper (Server): creates NPC listings immediately
---@param count number
---@return number created
function GlobalMarket:spawnNpcAnimalListings(count)
    local created = 0
    for _ = 1, math.clamp(math.floor(count or 1), 1, 20) do
        if #self.animalListings < GlobalMarket.ANIMAL_MARKET.MAX_TOTAL and self:createNpcAnimalListing() ~= nil then
            created = created + 1
        end
    end
    if created > 0 then
        self:broadcastAnimalMarketState()
    end
    return created
end

---Console: creates NPC listings now (host, dedicated server console or admin client): [count=1]
function GlobalMarket:consoleCommandAnimalMarketSpawnNpc(countArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(true)
    if guardError ~= nil then
        return guardError
    end
    local count = math.clamp(tonumber(countArg) or 1, 1, 20)
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_ADMIN_SPAWN_NPC, 0, { targetId = count })
        return "Admin request sent to the server."
    end
    return string.format("Created %d NPC animal listing(s).", self:spawnNpcAnimalListings(count))
end

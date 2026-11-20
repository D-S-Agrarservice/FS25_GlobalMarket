-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalDemand.lua
-- Livestock market (#15), Stage 1b: great demand for meat animals. NPC animal dealers
-- occasionally ask for slaughter-ready meat animals of one animal type and pay the dealer
-- value plus a bonus for a limited time and quota (direct sale from the GM menu).
-- Coupled to the admin setting "NPC animal trading" (Off / Low / Normal).
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarket.ANIMAL_DEMAND = {
    -- Expected great demands per in-game month by NPC level (max. one at a time)
    RATE_PER_MONTH = { [1] = 0.5, [2] = 1.0 },
    BONUS_MIN = 0.20,           -- Bonus on top of the dealer value (5 % steps)
    BONUS_MAX = 0.40,
    HOURS_MIN = 24,             -- Duration in in-game hours (1-3 days)
    HOURS_MAX = 72,
    QUOTA_MIN = 20,             -- Animals all farms can sell together
    QUOTA_MAX = 60,
    LARGE_GROUP_QUOTA_FACTOR = 10,
    MIN_HEALTH = 50,            -- Minimum health in percent
    SLAUGHTER_VALUE_SHARE = 0.95, -- Slaughter age: dealer value reaches this share of its maximum
    MAX_AGE = 60
}

-- Cache: subtype index -> slaughter age in months (subtype indices are per mission)
local slaughterAgeCache = {}

---Clears per-mission caches (called when the animal market is initialized)
function GlobalMarket.resetAnimalDemandCaches()
    slaughterAgeCache = {}
end

---Returns the slaughter age of a subtype: the youngest age at which the dealer value reaches
---SLAUGHTER_VALUE_SHARE of its maximum on the subtype's sell price curve
---@param subTypeIndex number
---@return number|nil ageMonths
function GlobalMarket.getAnimalSlaughterAge(subTypeIndex)
    if subTypeIndex == nil then
        return nil
    end
    if slaughterAgeCache[subTypeIndex] ~= nil then
        return slaughterAgeCache[subTypeIndex]
    end
    local cfg = GlobalMarket.ANIMAL_DEMAND
    local subType = g_currentMission.animalSystem:getSubTypeByIndex(subTypeIndex)
    if subType == nil or subType.sellPrice == nil then
        return nil
    end
    local maxValue = 0
    for age = 0, cfg.MAX_AGE do
        maxValue = math.max(maxValue, subType.sellPrice:get(age) or 0)
    end
    local slaughterAge = cfg.MAX_AGE
    for age = 0, cfg.MAX_AGE do
        if (subType.sellPrice:get(age) or 0) >= maxValue * cfg.SLAUGHTER_VALUE_SHARE then
            slaughterAge = age
            break
        end
    end
    slaughterAgeCache[subTypeIndex] = slaughterAge
    return slaughterAge
end

---Returns the title of an animal type for notices and the banner ("Cows", "Pigs", ...)
---@param typeName string|nil
---@return string
function GlobalMarket.getAnimalDemandTypeTitle(typeName)
    local animalType = (g_currentMission ~= nil and typeName ~= nil) and g_currentMission.animalSystem:getTypeByName(typeName) or nil
    if animalType ~= nil and animalType.groupTitle ~= nil and animalType.groupTitle ~= "" then
        return animalType.groupTitle
    end
    return tostring(typeName)
end

---Returns the active great demand (server and clients) or nil
---@return table|nil demand { typeName, bonus, hoursRemaining, quota, sold }
function GlobalMarket:getAnimalDemand()
    return self.animalDemand
end

---Returns the remaining quota of the active great demand
---@return number
function GlobalMarket:getAnimalDemandRemaining()
    local demand = self.animalDemand
    if demand == nil then
        return 0
    end
    return math.max(0, (demand.quota or 0) - (demand.sold or 0))
end

-- =========================================================================
-- ELIGIBILITY (Server and clients)
-- =========================================================================

---Checks whether animals of a group may be sold to the active great demand
---@param source table Barn or livestock trailer at the animal dealer
---@param farmId number
---@param clusterId number
---@param numAnimals number
---@return boolean isEligible
---@return string|nil reason
function GlobalMarket:getAnimalDemandEligibility(source, farmId, clusterId, numAnimals)
    local demand = self.animalDemand
    if demand == nil then
        return false, "demandInactive"
    end
    local isEligible, reason = GlobalMarketAnimalListings.getEligibility(source, farmId, clusterId, numAnimals)
    if not isEligible then
        return false, reason
    end
    local cluster = source:getClusterById(clusterId)
    local subTypeIndex = cluster:getSubTypeIndex()
    if not GlobalMarketAnimalListings.getIsMeatAnimal(subTypeIndex)
        or GlobalMarketAnimalListings.getTypeName(subTypeIndex) ~= demand.typeName then
        return false, "demandWrongType"
    end
    if cluster.age < (GlobalMarket.getAnimalSlaughterAge(subTypeIndex) or GlobalMarket.ANIMAL_DEMAND.MAX_AGE) then
        return false, "demandTooYoung"
    end
    if cluster.health < GlobalMarket.ANIMAL_DEMAND.MIN_HEALTH then
        return false, "demandUnhealthy"
    end
    if numAnimals > self:getAnimalDemandRemaining() then
        return false, "demandQuotaExceeded"
    end
    return true, nil
end

---Returns the payout for selling animals of a group to the active great demand
---@param cluster table
---@param numAnimals number
---@return number payout
function GlobalMarket:getAnimalDemandPayout(cluster, numAnimals)
    local bonus = (self.animalDemand ~= nil) and self.animalDemand.bonus or 0
    return math.floor(cluster:getSellPrice() * numAnimals * (1 + bonus) + 0.5)
end

-- =========================================================================
-- START, END & SALE (Server)
-- =========================================================================

---Returns the animal types with meat breeds that at least one player farm can keep
---@return table typeIndices
local function getDemandTypeCandidates()
    local animalSystem = g_currentMission.animalSystem
    local found, candidates = {}, {}
    for _, farm in pairs(g_farmManager:getFarms()) do
        if GlobalMarketAnimalListings.getIsPlayerFarm(farm.farmId) then
            for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farm.farmId, nil)) do
                for index, _ in ipairs(animalSystem.subTypes or {}) do
                    local typeIndex = animalSystem:getTypeIndexBySubTypeIndex(index)
                    if typeIndex ~= nil and not found[typeIndex] and GlobalMarketAnimalListings.getIsMeatAnimal(index)
                        and barn:getSupportsAnimalSubType(index) then
                        found[typeIndex] = true
                        table.insert(candidates, typeIndex)
                    end
                end
            end
        end
    end
    return candidates
end

---Starts a great demand (random type and terms if typeIndex is nil)
---@param typeIndex number|nil
---@return table|nil demand
function GlobalMarket:startAnimalDemand(typeIndex)
    if g_currentMission == nil or not g_currentMission:getIsServer() or self.animalDemand ~= nil then
        return nil
    end
    local candidates = getDemandTypeCandidates()
    if typeIndex == nil or typeIndex <= 0 then
        if #candidates == 0 then
            return nil
        end
        typeIndex = candidates[math.random(1, #candidates)]
    end
    local animalType = g_currentMission.animalSystem:getTypeByIndex(typeIndex)
    if animalType == nil then
        return nil
    end
    local cfg = GlobalMarket.ANIMAL_DEMAND
    local bonusSteps = math.floor((cfg.BONUS_MAX - cfg.BONUS_MIN) / 0.05 + 0.5)
    local quota = math.random(cfg.QUOTA_MIN, cfg.QUOTA_MAX)
    local largeGroups = GlobalMarket.ANIMAL_NPC ~= nil and GlobalMarket.ANIMAL_NPC.LARGE_GROUP_TYPES or {}
    if largeGroups[animalType.name] then
        quota = quota * cfg.LARGE_GROUP_QUOTA_FACTOR
    end
    self.animalDemand = {
        typeName = animalType.name,
        bonus = cfg.BONUS_MIN + math.random(0, bonusSteps) * 0.05,
        hoursRemaining = math.random(cfg.HOURS_MIN, cfg.HOURS_MAX),
        quota = quota,
        sold = 0
    }
    local demand = self.animalDemand
    self:notifyAnimalMarketFarms(GlobalMarket.ANIMAL_NOTICE.DEMAND_START, 0, 0, demand.typeName, demand.quota,
        math.floor(demand.bonus * 100 + 0.5), tostring(math.max(1, math.floor(demand.hoursRemaining / 24 + 0.5))))
    self:broadcastAnimalMarketState()
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Great demand started (%s, +%.0f%%, %d hours, %d animals).",
            demand.typeName, demand.bonus * 100, demand.hoursRemaining, demand.quota)
    end
    return demand
end

---Ends the active great demand
function GlobalMarket:endAnimalDemand()
    local demand = self.animalDemand
    if demand == nil then
        return
    end
    self.animalDemand = nil
    self:notifyAnimalMarketFarms(GlobalMarket.ANIMAL_NOTICE.DEMAND_END, 0, 0, demand.typeName, demand.sold or 0, 0, "")
    self:broadcastAnimalMarketState()
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Great demand for %s ended (%d of %d animals sold).",
            demand.typeName, demand.sold or 0, demand.quota or 0)
    end
end

---Sells animals of a group directly to the active great demand (dealer value plus bonus, paid immediately)
---@param source table Barn or livestock trailer at the animal dealer
---@param clusterId number
---@param numAnimals number
---@param farmId number
---@return boolean success
---@return string|nil reason
function GlobalMarket:sellAnimalsToDemand(source, clusterId, numAnimals, farmId)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return false, "notServer"
    end
    numAnimals = math.floor(tonumber(numAnimals) or 0)
    local isEligible, reason = self:getAnimalDemandEligibility(source, farmId, clusterId, numAnimals)
    if not isEligible then
        return false, reason
    end
    local cluster = source:getClusterById(clusterId)
    local subTypeName = g_currentMission.animalSystem:getSubTypeByIndex(cluster:getSubTypeIndex()).name
    local payout = self:getAnimalDemandPayout(cluster, numAnimals)
    cluster:changeNumAnimals(-numAnimals)
    source:getClusterSystem():updateNow()
    g_currentMission:addMoney(payout, farmId, MoneyType.SOLD_ANIMALS, true, true)

    local demand = self.animalDemand
    demand.sold = (demand.sold or 0) + numAnimals
    self:notifyAnimalMarketFarms(GlobalMarket.ANIMAL_NOTICE.DEMAND_SOLD, farmId, 0, subTypeName, numAnimals, payout, "")
    if self.debugManager ~= nil then
        self.debugManager:info("AnimalMarket: Farm %d sold %dx %s to the great demand for %d (%d of %d).",
            farmId, numAnimals, subTypeName, payout, demand.sold, demand.quota)
    end
    if self:getAnimalDemandRemaining() <= 0 then
        self:endAnimalDemand()
    else
        self:broadcastAnimalMarketState()
    end
    return true, nil
end

---Hourly tick: counts down the active demand or starts a new one (coupled to the NPC animal trading level)
---@param monthDelta number
---@return boolean changed
function GlobalMarket:updateAnimalDemandHourly(monthDelta)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return false
    end
    local level = GlobalMarket.ANIMAL_NPC_LEVEL or 0
    if self.animalDemand ~= nil then
        if level <= 0 then
            self:endAnimalDemand()
            return true
        end
        local daysPerPeriod = (g_currentMission.environment ~= nil and g_currentMission.environment.daysPerPeriod) or 1
        self.animalDemand.hoursRemaining = (self.animalDemand.hoursRemaining or 0) - monthDelta * 24 * math.max(1, daysPerPeriod)
        if self.animalDemand.hoursRemaining <= 0 then
            self:endAnimalDemand()
            return true
        end
        return false
    end
    local rate = GlobalMarket.ANIMAL_DEMAND.RATE_PER_MONTH[level]
    if rate ~= nil and math.random() < rate * monthDelta then
        return self:startAnimalDemand(nil) ~= nil
    end
    return false
end

-- =========================================================================
-- SAVEGAME
-- =========================================================================

---Writes the active great demand below the animal market key
---@param xmlFile table
---@param rootKey string
function GlobalMarket:saveAnimalDemandToXml(xmlFile, rootKey)
    local demand = self.animalDemand
    if demand == nil then
        return
    end
    local key = rootKey .. ".demand"
    xmlFile:setString(key .. "#typeName", demand.typeName)
    xmlFile:setFloat(key .. "#bonus", demand.bonus or 0)
    xmlFile:setFloat(key .. "#hoursRemaining", demand.hoursRemaining or 0)
    xmlFile:setInt(key .. "#quota", demand.quota or 0)
    xmlFile:setInt(key .. "#sold", demand.sold or 0)
end

---Loads the active great demand (dropped if the animal type does not exist here)
---@param xmlFile table
---@param rootKey string
function GlobalMarket:loadAnimalDemandFromXml(xmlFile, rootKey)
    self.animalDemand = nil
    local key = rootKey .. ".demand"
    local typeName = xmlFile:getString(key .. "#typeName")
    if typeName == nil or g_currentMission.animalSystem:getTypeByName(typeName) == nil then
        return
    end
    self.animalDemand = {
        typeName = typeName,
        bonus = xmlFile:getFloat(key .. "#bonus", GlobalMarket.ANIMAL_DEMAND.BONUS_MIN),
        hoursRemaining = xmlFile:getFloat(key .. "#hoursRemaining", 0),
        quota = xmlFile:getInt(key .. "#quota", 0),
        sold = xmlFile:getInt(key .. "#sold", 0)
    }
end

-- =========================================================================
-- DEBUG CONSOLE
-- =========================================================================

---Returns the console line of the active great demand
---@return string
function GlobalMarket:getAnimalDemandConsoleLine()
    local demand = self.animalDemand
    if demand == nil then
        return "Great demand: none"
    end
    return string.format("Great demand: %s +%.0f%% | %.1f hours left | %d of %d animals sold",
        demand.typeName, (demand.bonus or 0) * 100, demand.hoursRemaining or 0, demand.sold or 0, demand.quota or 0)
end

---Console: starts a great demand now (test helper): [typeName, e.g. COW or PIG]
function GlobalMarket:consoleCommandAnimalDemandStart(typeNameArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(true)
    if guardError ~= nil then
        return guardError
    end
    local typeIndex = 0
    if typeNameArg ~= nil then
        typeIndex = g_currentMission.animalSystem:getTypeIndexByName(string.upper(typeNameArg)) or -1
        if typeIndex < 0 then
            return "Usage: gmAnimalDemandStart [animal type, e.g. COW or PIG]"
        end
    end
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_START, 0, { targetId = typeIndex })
        return "Admin request sent to the server."
    end
    if self.animalDemand ~= nil then
        return "A great demand is already active: " .. self:getAnimalDemandConsoleLine()
    end
    local demand = self:startAnimalDemand(typeIndex)
    return (demand ~= nil) and self:getAnimalDemandConsoleLine() or "No great demand started (no farm can keep meat animals of that type)."
end

---Console: ends the active great demand (test helper)
function GlobalMarket:consoleCommandAnimalDemandEnd()
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(true)
    if guardError ~= nil then
        return guardError
    end
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_END, 0, nil)
        return "Admin request sent to the server."
    end
    if self.animalDemand == nil then
        return "No great demand active."
    end
    self:endAnimalDemand()
    return "Great demand ended."
end

---Console: sells animals of an own group to the great demand: <clusterId> <count>
function GlobalMarket:consoleCommandAnimalDemandSell(clusterIdArg, countArg)
    local guardError = GlobalMarket.getAnimalMarketConsoleGuardError(false)
    if guardError ~= nil then
        return guardError
    end
    local farmId = g_currentMission:getFarmId()
    local clusterId = tonumber(clusterIdArg)
    local source = (clusterId ~= nil) and GlobalMarket.findAnimalSourceByClusterId(farmId, clusterId) or nil
    if source == nil then
        return "Usage: gmAnimalDemandSell <clusterId from gmAnimalMarketList> <count>"
    end
    local numAnimals = tonumber(countArg) or 0
    if not g_currentMission:getIsServer() then
        AnimalMarketActionEvent.dispatch(AnimalMarketActionEvent.ACTION_DEMAND_SELL, farmId,
            { object = source, clusterId = clusterId, numAnimals = numAnimals })
        return "Sale request sent to the server (result as HUD notice)."
    end
    local success, reason = self:sellAnimalsToDemand(source, clusterId, numAnimals, farmId)
    return success and "Sold to the great demand." or ("Sale rejected: " .. tostring(reason))
end

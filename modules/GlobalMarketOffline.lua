--
-- FS25 - GlobalMarket (Offline Market Module)
--

GlobalMarketOffline = {}
GlobalMarketOffline.PRICE_MIN_FACTOR = 0.7 -- Minimum 70% of base price
GlobalMarketOffline.PRICE_MAX_FACTOR = 1.3 -- Maximum 130% of base price
GlobalMarketOffline.SATURATION_LIMIT = 5000000 -- 5M Liters = Market is "full" (lowest price)

function GlobalMarket:initOfflineMarket()
    self.offlineMarketFillTypes = {}
    local addedCount = 0

    if g_fillTypeManager ~= nil and g_fillTypeManager.fillTypes ~= nil then
        for _, fillType in pairs(g_fillTypeManager.fillTypes) do
            -- Only add tradeable goods that appear in the price table
            if fillType.showOnPriceTable then
                -- Starting stock: Random between 50k and 250k Liters
                local startLevel = math.random(5, 25) * 10000
                
                table.insert(self.offlineMarketFillTypes, {
                    fillType = fillType.name,
                    fillTypeIndex = fillType.index,
                    basePrice = fillType.pricePerLiter or 0.5,
                    fillLevel = startLevel,
                    price = 0 -- Calculated on demand/update
                })
                addedCount = addedCount + 1
            end
        end
    end

    self:updateOfflinePrices()
    GlobalMarket.debugLog("OfflineMarket: Initialized with %d dynamic fillTypes.", addedCount)
end

-- Calculates the price considering Season Factors and Market Saturation
function GlobalMarket:updateOfflinePrices()
    local currentPeriod = 1
    if g_currentMission.environment ~= nil then
        currentPeriod = g_currentMission.environment.period
    end

    for _, data in pairs(self.offlineMarketFillTypes) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(data.fillTypeIndex)
        local seasonFactor = 1.0

        -- Fetch the engine's season factor for the current month
        if fillType ~= nil and fillType.economy ~= nil and fillType.economy.factors ~= nil then
            seasonFactor = fillType.economy.factors[currentPeriod] or 1.0
        end

        -- Calculate Saturation Factor (Supply & Demand)
        -- More stock = lower price
        local saturation = math.min(data.fillLevel / GlobalMarketOffline.SATURATION_LIMIT, 1.0)
        local priceRange = GlobalMarketOffline.PRICE_MAX_FACTOR - GlobalMarketOffline.PRICE_MIN_FACTOR
        local demandFactor = GlobalMarketOffline.PRICE_MAX_FACTOR - (priceRange * saturation)

        -- Final Price: Base * Season * Demand * 1000 (for display per unit)
        data.price = data.basePrice * seasonFactor * demandFactor * 1000
    end
end

-- Simulation of NPC trading (Hourly)
function GlobalMarket:runOfflineSimulation()
    if not g_currentMission:getIsServer() or self:getIsMarketOnline() then
        return
    end

    for _, data in pairs(self.offlineMarketFillTypes) do
        -- Random fluctuation: -5000 to +4500 Liters
        local fluctuation = math.random(-50, 45) * 100
        data.fillLevel = math.max(data.fillLevel + fluctuation, 0)
    end

    self:updateOfflinePrices()
    
    -- Sync new offline state to clients
    if g_server ~= nil then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
    end
end

-- Retrieves the offline price by fillType name. 
-- Prevents UI crash during table population.
function GlobalMarket:getOfflinePriceByFillType(fillTypeName)
    if self.offlineMarketFillTypes == nil then return 0 end

    for _, data in pairs(self.offlineMarketFillTypes) do
        if data.fillType == fillTypeName then
            return data.price or 0
        end
    end

    return 0
end
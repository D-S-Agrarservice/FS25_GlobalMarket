--
-- FS25 - GlobalMarket (Offline Market Module)
--

GlobalMarketOffline = {}
GlobalMarketOffline.PRICE_MIN_FACTOR = 0.7 -- Minimum 70% of base price
GlobalMarketOffline.PRICE_MAX_FACTOR = 1.3 -- Maximum 130% of base price
GlobalMarketOffline.SATURATION_LIMIT = 5000000 -- 5M Liters = Market is "full" (lowest price)

-- Initialize the simulated market. Fetches valid fillTypes and sets random starting stocks.
function GlobalMarket:initOfflineMarket()
    self.offlineMarketFillTypes = {}
    local addedCount = 0

    if g_fillTypeManager ~= nil and g_fillTypeManager.fillTypes ~= nil then
        for _, fillType in pairs(g_fillTypeManager.fillTypes) do

            -- Ask the API if this fillType is allowed on the market (handles Whitelist/Blacklist/Engine-Flags)
            if GlobalMarketAPI.getIsFillTypeAllowed(fillType) then

                -- Starting stock: Random between 0 and 750k Liters
                local startLevel = math.random(0, 75) * 10000

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
    else
        if self.debugManager ~= nil then
            self.debugManager:warning("g_fillTypeManager.fillTypes is nil! Cannot initialize offline market.")
        end
    end

    self:updateOfflinePrices()

    if self.debugManager ~= nil then
        self.debugManager:info("OfflineMarket: Initialized with %d dynamic fillTypes.", addedCount)
        -- Deep trace to verify the starting stock of all generated items
        self.debugManager:traceTable("OfflineMarket: Initial state dumped.", self.offlineMarketFillTypes)
    end
end

-- Calculates the price considering Season Factors and Market Saturation.
function GlobalMarket:updateOfflinePrices()
    local currentPeriod = 1
    if g_currentMission ~= nil and g_currentMission.environment ~= nil then
        currentPeriod = g_currentMission.environment.period
    end

    for _, data in pairs(self.offlineMarketFillTypes) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(data.fillTypeIndex)
        local seasonFactor = 1.0

        -- Fetch the engine's season factor for the current month
        if fillType ~= nil and fillType.economy ~= nil and fillType.economy.factors ~= nil then
            seasonFactor = fillType.economy.factors[currentPeriod] or 1.0
        end

        -- Calculate Saturation Factor (Supply & Demand). More stock = lower price.
        local saturation = math.min(data.fillLevel / GlobalMarketOffline.SATURATION_LIMIT, 1.0)
        local priceRange = GlobalMarketOffline.PRICE_MAX_FACTOR - GlobalMarketOffline.PRICE_MIN_FACTOR
        local demandFactor = GlobalMarketOffline.PRICE_MAX_FACTOR - (priceRange * saturation)

        -- Final Price: Base * Season * Demand * 1000 (for display per unit)
        data.price = data.basePrice * seasonFactor * demandFactor * 1000

        if self.debugManager ~= nil then
            self.debugManager:trace("OfflineMarket Price Update - %s: Base=%.2f, Season=%.2f, Demand=%.2f, Final=%.2f", data.fillType, data.basePrice, seasonFactor, demandFactor, data.price)
        end
    end
end

-- Simulation of NPC trading (Hourly). Adjusts stock levels and recalculates prices.
function GlobalMarket:runOfflineSimulation()
    if not g_currentMission:getIsServer() or self:getIsMarketOnline() then
        return
    end

    if self.debugManager ~= nil then
        self.debugManager:debug("Running hourly offline simulation...")
    end

    for _, data in pairs(self.offlineMarketFillTypes) do
        -- Random fluctuation: -50000 to +45000 Liters
        local fluctuation = math.random(-500, 450) * 100
        data.fillLevel = math.max(data.fillLevel + fluctuation, 0)

        if self.debugManager ~= nil then
            self.debugManager:trace("OfflineMarket Fluctuation - %s: %+d L. New Level: %d L", data.fillType, fluctuation, data.fillLevel)
        end
    end

    self:updateOfflinePrices()

    -- Sync new offline state to clients
    if g_server ~= nil then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        if self.debugManager ~= nil then
            self.debugManager:debug("Offline market simulation finished and synced to clients.")
        end
    end
end

-- Retrieves the offline price by fillType name.
-- Prevents UI crash during table population.
function GlobalMarket:getOfflinePriceByFillType(fillTypeName)
    if self.offlineMarketFillTypes == nil then
        if self.debugManager ~= nil then
            self.debugManager:error("offlineMarketFillTypes table is nil while requesting price for %s", tostring(fillTypeName))
        end
        return 0
    end

    for _, data in pairs(self.offlineMarketFillTypes) do
        if data.fillType == fillTypeName then
            return data.price or 0
        end
    end

    -- Logged as TRACE because modded UI elements frequently poll invalid fillTypes,
    -- which would heavily spam the WARNING/INFO logs.
    if self.debugManager ~= nil then
        self.debugManager:trace("Requested price for unknown fillType in offline market: %s", tostring(fillTypeName))
    end

    return 0
end
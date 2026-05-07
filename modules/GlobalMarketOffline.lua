--
-- FS25 - GlobalMarket (Offline Market Module)
--

GlobalMarketOffline = {}
GlobalMarketOffline.PRICE_MIN_FACTOR = 0.7 -- Minimum 70% of base price
GlobalMarketOffline.PRICE_MAX_FACTOR = 1.3 -- Maximum 130% of base price

-- Initialize the simulated market. Fetches valid fillTypes and sets random starting stocks.
function GlobalMarket:initOfflineMarket()
    self.offlineMarketFillTypes = {}
    local addedCount = 0

    if g_fillTypeManager ~= nil and g_fillTypeManager.fillTypes ~= nil then
        for _, fillType in pairs(g_fillTypeManager.fillTypes) do

            -- Ask the API if this fillType is allowed on the market
            if GlobalMarketAPI.getIsFillTypeAllowed(fillType) then

                -- Dynamic starting stock based on the server's configured capacity limit
                local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
                -- Start between 10% and 50% of the maximum capacity
                local minStart = currentLimit * 0.10
                local maxStart = currentLimit * 0.50

                -- math.random needs integers, so we round the values
                local startLevel = math.random(math.floor(minStart), math.floor(maxStart))

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

    self:refreshMarketPrices()

    if self.debugManager ~= nil then
        self.debugManager:info("OfflineMarket: Initialized with %d dynamic fillTypes.", addedCount)
        -- Deep trace to verify the starting stock of all generated items
        self.debugManager:traceTable("OfflineMarket: Initial state dumped.", self.offlineMarketFillTypes)
    end
end

-- Calculates the price considering Season Factors and Market Saturation.
function GlobalMarket:updateOfflinePrices()
    local currentPeriod = 1
    local periodAlpha = 0.5 -- Fallback for the middle of the month

    if g_currentMission ~= nil and g_currentMission.environment ~= nil and g_currentMission.environment.getPeriodAndAlphaIntoPeriod ~= nil then
        -- FS25 Native: Fetch the exact period and the time progression (alpha) within that period
        currentPeriod, periodAlpha = g_currentMission.environment:getPeriodAndAlphaIntoPeriod()
    end

    for _, data in pairs(self.offlineMarketFillTypes) do
        local fillTypeIndex = data.fillTypeIndex
        local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

        -- ===============================================================
        -- 1. MAP SPY: Get the actual average price from local selling stations
        -- ===============================================================
        local totalMapPrice = 0
        local numStations = 0

        if g_currentMission.economyManager ~= nil and g_currentMission.economyManager.sellingStations ~= nil then
            for _, stationData in ipairs(g_currentMission.economyManager.sellingStations) do
                local station = stationData.station

                -- Check if this station accepts the current fillType
                if station.acceptedFillTypes ~= nil and station.acceptedFillTypes[fillTypeIndex] then
                    -- Fetch the exact current price this station is paying per liter.
                    -- CRITICAL: This already includes Difficulty, Season, and Map XML priceScales!
                    local stationPrice = station:getEffectiveFillTypePrice(fillTypeIndex, ToolType.UNDEFINED)

                    if stationPrice > 0 then
                        totalMapPrice = totalMapPrice + stationPrice
                        numStations = numStations + 1
                    end
                end
            end
        end

        local currentBasePricePerLiter = data.basePrice

        if numStations > 0 then
            -- Use the average map price as the GM baseline
            currentBasePricePerLiter = totalMapPrice / numStations
        else
            -- FALLBACK: If no station on the map accepts this fillType (e.g. custom productions),
            -- fallback to the native EconomyManager calculation.
            if g_currentMission.economyManager ~= nil and g_currentMission.economyManager.getPricePerLiter ~= nil then
                currentBasePricePerLiter = g_currentMission.economyManager:getPricePerLiter(fillTypeIndex)
            elseif fillTypeDesc ~= nil then
                -- Hard fallback if EconomyManager is unavailable
                currentBasePricePerLiter = fillTypeDesc.pricePerLiter
            end
        end

        -- ===============================================================
        -- 2. GM DEMAND FACTOR: Apply our own saturation logic
        -- ===============================================================
        -- OFFLINE MODE: Apply local saturation logic
        -- Fallback to 2M if settings haven't loaded yet
        local currentSaturationLimit = GlobalMarket.MARKET_CAPACITY or 2000000

        local saturation = math.min(data.fillLevel / currentSaturationLimit, 1.0)
        local priceRange = GlobalMarketOffline.PRICE_MAX_FACTOR - GlobalMarketOffline.PRICE_MIN_FACTOR
        local demandFactor = GlobalMarketOffline.PRICE_MAX_FACTOR - (priceRange * saturation)

        -- Final Price: BaseMapPrice * Demand * 1000 (for display per unit)
        -- Note: Difficulty and Season are ALREADY included in currentBasePricePerLiter!
        data.price = currentBasePricePerLiter * demandFactor * 1000

        if self.debugManager ~= nil then
            self.debugManager:trace("OfflineMarket Price Update - %s: MapAvgBase=%.2f, Demand=%.2f, Final=%.2f", data.fillType, currentBasePricePerLiter, demandFactor, data.price)
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

    -- Fetch current capacity to scale the NPC trade volume
    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000

    for _, data in pairs(self.offlineMarketFillTypes) do
        -- Scale fluctuation between -2.5% and +2.25% of the total market capacity.
        -- This ensures the market remains dynamic regardless of the chosen size.
        -- Higher minus to "bleed out" the market over time.
        local minFluct = currentLimit * -0.025
        local maxFluct = currentLimit * 0.0225

        local fluctuation = math.random(math.floor(minFluct), math.floor(maxFluct))
        data.fillLevel = math.max(data.fillLevel + fluctuation, 0)

        if self.debugManager ~= nil then
            self.debugManager:trace("OfflineMarket Fluctuation - %s: %+d L. New Level: %d L", data.fillType, fluctuation, data.fillLevel)
        end
    end

    self:refreshMarketPrices()

    -- Sync new offline state to clients
    if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
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
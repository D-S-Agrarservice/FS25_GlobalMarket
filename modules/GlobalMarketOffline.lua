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
                local initialNormalPrice = (fillType.pricePerLiter or 0.5) * 1000

                table.insert(self.offlineMarketFillTypes, {
                    fillType = fillType.name,
                    fillTypeIndex = fillType.index,
                    basePrice = fillType.pricePerLiter or 0.5,
                    normalPrice = initialNormalPrice,
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

-- Resolves the current local map baseline price per liter for a given fillTypeIndex.
-- Queries active map SellingStations first (including difficulty, season, and station priceScales),
-- and falls back to EconomyManager:getPricePerLiter when no station accepts the fillType.
function GlobalMarket:getMapBasePricePerLiter(fillTypeIndex, fallbackBasePrice)
    local fillTypeDesc = fillTypeIndex ~= nil and g_fillTypeManager:getFillTypeByIndex(fillTypeIndex) or nil
    local totalMapPrice = 0
    local numStations = 0

    if fillTypeIndex ~= nil and g_currentMission ~= nil and g_currentMission.economyManager ~= nil and g_currentMission.economyManager.sellingStations ~= nil then
        for _, stationData in ipairs(g_currentMission.economyManager.sellingStations) do
            local station = stationData.station

            -- Only include visible map selling stations that accept this fillType
            if station ~= nil and not station.hideFromPricesMenu and station.acceptedFillTypes ~= nil and station.acceptedFillTypes[fillTypeIndex] then
                local isAllowed = true
                if station.getIsFillTypeAllowed ~= nil then
                    isAllowed = station:getIsFillTypeAllowed(fillTypeIndex)
                end

                if isAllowed then
                    -- Fetch the exact current price this station is paying per liter.
                    -- CRITICAL: This already includes Difficulty, Season, and Map XML priceScales!
                    local stationPrice = station:getEffectiveFillTypePrice(fillTypeIndex, ToolType.UNDEFINED)

                    if stationPrice ~= nil and stationPrice > 0 then
                        totalMapPrice = totalMapPrice + stationPrice
                        numStations = numStations + 1
                    end
                end
            end
        end
    end

    if numStations > 0 then
        return totalMapPrice / numStations
    end

    -- FALLBACK: If no station on the map accepts this fillType (e.g. custom productions or early map load),
    -- fallback to the native EconomyManager calculation (includes Difficulty & Season).
    if fillTypeIndex ~= nil and g_currentMission ~= nil and g_currentMission.economyManager ~= nil and g_currentMission.economyManager.getPricePerLiter ~= nil and g_currentMission.environment ~= nil then
        local econPrice = g_currentMission.economyManager:getPricePerLiter(fillTypeIndex)
        if econPrice ~= nil and econPrice > 0 then
            return econPrice
        end
    end

    local rawBase = (fillTypeDesc ~= nil and fillTypeDesc.pricePerLiter) or fallbackBasePrice or 0.5
    local diffMult = (EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil and g_currentMission ~= nil and g_currentMission.missionInfo ~= nil) and (EconomyManager.getPriceMultiplier() or 1) or 1
    return rawBase * diffMult
end

-- Calculates the price considering Season Factors, Map SellingStations, and Market Saturation.
function GlobalMarket:updateOfflinePrices()
    if self.offlineMarketFillTypes == nil then
        return
    end

    local currentSaturationLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    local priceRange = GlobalMarketOffline.PRICE_MAX_FACTOR - GlobalMarketOffline.PRICE_MIN_FACTOR

    for _, data in pairs(self.offlineMarketFillTypes) do
        local fillTypeIndex = data.fillTypeIndex
        if fillTypeIndex == nil and data.fillType ~= nil and g_fillTypeManager ~= nil then
            fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(data.fillType)
            data.fillTypeIndex = fillTypeIndex
        end

        -- 1. MAP SPY: Get the actual average price per liter from local selling stations / EconomyManager
        local currentBasePricePerLiter = self:getMapBasePricePerLiter(fillTypeIndex, data.basePrice)

        -- Store the neutral 1000L map reference price (demandFactor = 1.0) for accurate UI trend arrows & MP sync
        data.normalPrice = currentBasePricePerLiter * 1000

        -- 2. GM DEMAND FACTOR: Apply local saturation logic
        local saturation = math.min((data.fillLevel or 0) / currentSaturationLimit, 1.0)
        local demandFactor = GlobalMarketOffline.PRICE_MAX_FACTOR - (priceRange * saturation)

        -- Final Price: NormalMapPrice * Demand
        data.price = data.normalPrice * demandFactor

        if self.debugManager ~= nil then
            self.debugManager:trace("OfflineMarket Price Update - %s: MapNormal=%.2f, Demand=%.2f, Final=%.2f", tostring(data.fillType), data.normalPrice, demandFactor, data.price)
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

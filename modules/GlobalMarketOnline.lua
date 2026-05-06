--
-- FS25 - GlobalMarket (Online Market Module)
-- Description: Handles price calculations based on external EXE trend factors.
-- Uses the "Map Spy" logic to align global trends with local map economy.
--

GlobalMarketOnline = {}

-- Updates the prices for all fillTypes using the server-provided trend factor.
-- @param fillTypeTable table: The shared market data table (usually self.offlineMarketFillTypes)
function GlobalMarketOnline:updateOnlinePrices(fillTypeTable)
    if fillTypeTable == nil then return end

    for _, data in pairs(fillTypeTable) do
        local fillTypeIndex = data.fillTypeIndex
        local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)

        -- ===============================================================
        -- 1. MAP SPY: Determine the local baseline from selling stations
        -- ===============================================================
        local totalMapPrice = 0
        local numStations = 0

        if g_currentMission.economyManager ~= nil and g_currentMission.economyManager.sellingStations ~= nil then
            for _, stationData in ipairs(g_currentMission.economyManager.sellingStations) do
                local station = stationData.station
                
                if station.acceptedFillTypes ~= nil and station.acceptedFillTypes[fillTypeIndex] then
                    -- Effective price includes Difficulty, Season and Map-XML scales
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
            -- Average map price is our 1.0 trend baseline
            currentBasePricePerLiter = totalMapPrice / numStations
        else
            -- Fallback to native economy calculation if no station accepts this fillType
            if g_currentMission.economyManager ~= nil and g_currentMission.economyManager.getPricePerLiter ~= nil then
                currentBasePricePerLiter = g_currentMission.economyManager:getPricePerLiter(fillTypeIndex)
            elseif fillTypeDesc ~= nil then
                currentBasePricePerLiter = fillTypeDesc.pricePerLiter
            end
        end

        -- ===============================================================
        -- 2. TREND INJECTION: Apply the trend factor from the .exe
        -- ===============================================================
        -- The trend is provided by the Sync module via XML from the EXE.
        -- If no trend is provided yet (e.g. freshly connected), default to 1.0.
        local serverTrend = data.trend or 1.0

        -- Final Price: MapBase * ServerTrend * 1000 (standard display unit)
        data.price = currentBasePricePerLiter * serverTrend * 1000

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:trace("OnlineMarket Price Update - %s: MapAvg=%.2f, Trend=%.2f, Final=%.2f", data.fillType, currentBasePricePerLiter, serverTrend, data.price)
        end
    end
end
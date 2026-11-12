--
-- FS25 - GlobalMarket (Online Market Module)
-- Description: Handles price calculations based on external EXE trend factors / stock levels.
-- Uses the "Map Spy" logic to align global trends with local map economy (#5 & #14).
--

GlobalMarketOnline = {}

-- Updates the prices for all fillTypes using the server-provided trend factor or online stock level.
-- @param fillTypeTable table: The shared market data table (usually self.offlineMarketFillTypes)
function GlobalMarketOnline:updateOnlinePrices(fillTypeTable)
    if fillTypeTable == nil then return end

    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local currentSaturationLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    local minFactor = (GlobalMarketOffline ~= nil and GlobalMarketOffline.PRICE_MIN_FACTOR) or 0.7
    local maxFactor = (GlobalMarketOffline ~= nil and GlobalMarketOffline.PRICE_MAX_FACTOR) or 1.3
    local gdThreshold = (GlobalMarketOffline ~= nil and GlobalMarketOffline.GREAT_DEMAND_THRESHOLD) or 1.25
    local priceRange = maxFactor - minFactor

    for _, data in pairs(fillTypeTable) do
        local fillTypeIndex = data.fillTypeIndex
        if fillTypeIndex == nil and data.fillType ~= nil and g_fillTypeManager ~= nil then
            fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(data.fillType)
            data.fillTypeIndex = fillTypeIndex
        end

        -- ===============================================================
        -- 1. MAP SPY: Determine the local baseline from selling stations
        -- ===============================================================
        local currentBasePricePerLiter = data.basePrice or 0.5
        if gm ~= nil and gm.getMapBasePricePerLiter ~= nil then
            currentBasePricePerLiter = gm:getMapBasePricePerLiter(fillTypeIndex, data.basePrice)
        end

        -- Store the neutral 1000L map reference price (trend = 1.0) for accurate UI trend arrows & MP sync
        data.normalPrice = currentBasePricePerLiter * 1000

        -- ===============================================================
        -- 2. HYBRID ROUTING: Online APPROVED vs. Local PENDING / REJECTED
        -- ===============================================================
        if data.onlineStatus == "APPROVED" then
            -- Online APPROVED: Apply EXE trend (or online stock saturation) + authoritative Backend Great Demand
            local serverTrend = data.trend
            if serverTrend == nil or serverTrend <= 0 then
                local saturation = math.min((data.fillLevel or 0) / currentSaturationLimit, 1.0)
                serverTrend = maxFactor - (priceRange * saturation)
            end

            data.isGreatDemand = (data.greatDemandFromServer == true)
            if data.isGreatDemand then
                -- Apply optional server Great Demand bonus (or +25% fallback if backend only sent fillLevel without pre-boosted trend)
                local serverBonus = (data.onlineGreatDemandBonus ~= nil and data.onlineGreatDemandBonus > 0)
                    and data.onlineGreatDemandBonus
                    or ((data.trend == nil or data.trend <= 0) and 0.25 or 0)
                serverTrend = serverTrend + serverBonus
            end

            data.price = data.normalPrice * serverTrend

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("OnlineMarket Price Update (APPROVED) - %s: MapNormal=%.2f, Trend=%.2f, GD=%s, Final=%.2f",
                    tostring(data.fillType), data.normalPrice, serverTrend, tostring(data.isGreatDemand), data.price)
            end
        elseif GlobalMarketOffline ~= nil and GlobalMarketOffline.applyLocalDemandFactor ~= nil then
            -- Hybrid Mode (PENDING / REJECTED): Calculate local saturation & local Great Demand price
            local localDemand = GlobalMarketOffline.applyLocalDemandFactor(data, currentSaturationLimit)
            data.price = data.normalPrice * localDemand

            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:trace("OnlineMarket Price Update (HYBRID %s) - %s: MapNormal=%.2f, LocalDemand=%.2f, GD=%s, Final=%.2f",
                    tostring(data.onlineStatus or "PENDING"), tostring(data.fillType), data.normalPrice, localDemand, tostring(data.isGreatDemand), data.price)
            end
        else
            local saturation = math.min((data.fillLevel or 0) / currentSaturationLimit, 1.0)
            local fallbackDemand = maxFactor - (priceRange * saturation)
            data.isGreatDemand = false
            data.price = data.normalPrice * fallbackDemand
        end
    end
end

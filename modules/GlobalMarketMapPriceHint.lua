-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketMapPriceHint.lua
-- Spot market footer hint for a selected market row: average map price (the same baseline
-- the trend arrow uses), the best selling point on the map and how far the market price is
-- above or below the average. Display only; station prices are known on every client
-- (same source as the basegame price menu).
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketMapPriceHint = {}

-- Market price within this share of the average counts as "at average level"
GlobalMarketMapPriceHint.SAME_LEVEL_PERCENT = 1

GlobalMarketMapPriceHint.COLOR_DEFAULT = { 0.88, 0.90, 0.92, 1 }
GlobalMarketMapPriceHint.COLOR_MARKET_BETTER = { 0.30, 0.80, 0.00, 1 }

---Returns the display name of a selling station
---@param station table SellingStation
---@return string
local function getStationName(station)
    local name = nil
    if station.getName ~= nil then
        name = station:getName()
    end
    if (name == nil or name == "") and station.owningPlaceable ~= nil and station.owningPlaceable.getName ~= nil then
        name = station.owningPlaceable:getName()
    end
    return name or "?"
end

---Returns the selling station on the map that currently pays the most for a fill type
---@param fillTypeIndex number
---@return number|nil pricePerLiter
---@return string|nil stationName
function GlobalMarket.getBestMapSellingStation(fillTypeIndex)
    if fillTypeIndex == nil or g_currentMission == nil or g_currentMission.storageSystem == nil then
        return nil, nil
    end
    local bestPrice, bestStation = nil, nil
    for _, station in pairs(g_currentMission.storageSystem:getUnloadingStations()) do
        if station.isa ~= nil and station:isa(SellingStation) and not station.hideFromPricesMenu
            and station.getIsFillTypeAllowed ~= nil and station:getIsFillTypeAllowed(fillTypeIndex) then
            local price = station:getEffectiveFillTypePrice(fillTypeIndex)
            if price ~= nil and price > 0 and (bestPrice == nil or price > bestPrice) then
                bestPrice, bestStation = price, station
            end
        end
    end
    if bestStation == nil then
        return nil, nil
    end
    return bestPrice, getStationName(bestStation)
end

---Returns the comparison text of the market price against the average map price
---@param price number Market price per 1000 l
---@param average number Average map price per 1000 l
---@return string
local function getDifferenceText(price, average)
    local percent = (price / average - 1) * 100
    local rounded = math.floor(math.abs(percent) + 0.5)
    if rounded <= GlobalMarketMapPriceHint.SAME_LEVEL_PERCENT then
        return g_i18n:getText("ui_gm_mapPrice_same")
    end
    local key = (percent > 0) and "ui_gm_mapPrice_above" or "ui_gm_mapPrice_below"
    return string.format(g_i18n:getText(key), rounded)
end

---Updates the spot market footer hint for the selected market row
---@param frame table GlobalMarketUI
---@param data table|nil Selected market row data (nil clears the hint)
function GlobalMarketMapPriceHint.updateSelectionHint(frame, data)
    local hint = frame.storageAgeHint
    if hint == nil then
        return
    end
    local color = GlobalMarketMapPriceHint.COLOR_DEFAULT
    hint:setTextColor(color[1], color[2], color[3], color[4])

    local fillTypeDesc = (data ~= nil) and g_fillTypeManager:getFillTypeByName(data.fillType) or nil
    if fillTypeDesc == nil then
        hint:setText("")
        return
    end
    local title = fillTypeDesc.title or tostring(data.fillType)

    local bestPrice, stationName = GlobalMarket.getBestMapSellingStation(fillTypeDesc.index)
    if bestPrice == nil then
        hint:setText(string.format(g_i18n:getText("ui_gm_mapPrice_hintNoStation"), title))
        return
    end
    bestPrice = bestPrice * 1000

    -- Same baseline as the trend arrow (server value in MP/online), local average as fallback
    local average = data.normalPrice
    if average == nil or average <= 0 then
        average = (GlobalMarket.getMapBasePricePerLiter ~= nil and g_currentMission.globalMarket ~= nil)
            and g_currentMission.globalMarket:getMapBasePricePerLiter(fillTypeDesc.index) * 1000 or bestPrice
    end

    local price = data.price or 0
    hint:setText(string.format(g_i18n:getText("ui_gm_mapPrice_hint"), title,
        g_i18n:formatMoney(average, 0, true, true), g_i18n:formatMoney(bestPrice, 0, true, true), stationName,
        getDifferenceText(price, average)))

    if price > bestPrice then
        color = GlobalMarketMapPriceHint.COLOR_MARKET_BETTER
        hint:setTextColor(color[1], color[2], color[3], color[4])
    end
end

--
-- FS25 - GlobalMarket (Economy Module)
--

-- Constants for offline economy calculation
GlobalMarket.PRICE_MIN = 0.8
GlobalMarket.PRICE_MAX = 1.2
GlobalMarket.PRICE_LEVEL_MAX = 10000000
GlobalMarket.DELIVER_COST = 200
GlobalMarket.DELIVER_COST_PERLITER = 0.01

-- Initialization called by the main GlobalMarket:loadMap()
function GlobalMarket:initEconomy()
    self.offlineMarketFillTypes = {}
    self:loadOfflineMarket()

    -- Subscribe to the hourly event to trigger market fluctuations
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
end

-- Loads the offline market prices and base levels from the XML
function GlobalMarket:loadOfflineMarket()
    local path = GlobalMarket.dir .. "offlineMarket.xml"

    if not fileExists(path) then
        return
    end

    local xmlFile = XMLFile.load("globalMarket_offline", path)
    if xmlFile == nil then
        return
    end

    xmlFile:iterate("globalMarket_offline.fillTypes.fillType", function (_, baseKey)
        local name = xmlFile:getString(baseKey .. "#name")
        local price = xmlFile:getFloat(baseKey .. "#price")

        local level = math.random (0, 50) * 10000
        if name ~= nil and price ~= nil then
            table.insert(self.offlineMarketFillTypes, {
                fillType = name,
                fillLevel = level,
                normalPrice = price,
                price = GlobalMarket.calcOfflinePrice(price, level)
            })
        end
    end)

    -- Clean up memory
    xmlFile:delete()
end

-- Calculates the dynamic offline price based on current fill level
function GlobalMarket.calcOfflinePrice(price, currentLevel)
    local fillTypeMinPrice = price * GlobalMarket.PRICE_MIN
    local fillTypeMaxPrice = price * GlobalMarket.PRICE_MAX
    local diffPrice = fillTypeMaxPrice - fillTypeMinPrice
    return fillTypeMaxPrice - (diffPrice / GlobalMarket.PRICE_LEVEL_MAX * math.min(currentLevel, GlobalMarket.PRICE_LEVEL_MAX))
end

-- Returns the current price for a specific fillType (handles both online and offline)
function GlobalMarket:getPriceByFillType(fillType)
    if self:getIsMarketOnline() then
        for _,e in pairs(self.fillTypes) do
            if e.fillType == fillType then return e.price end
        end
    else
        for _,e in pairs(self.offlineMarketFillTypes) do
            if e.fillType == fillType then return e.price end
        end
    end
    return 0
end

-- Returns the current silo level for a specific fillType (handles both online and offline)
function GlobalMarket:getMarketSiloLevelByFillType(fillType)
    if self:getIsMarketOnline() then
        if self.siloLevels[fillType] == nil then return 0 end
        return self.siloLevels[fillType]
    else
        for _,e in pairs(self.offlineMarketFillTypes) do
            if e.fillType == fillType then return e.fillLevel end
        end
    end
    return 0
end

-- Event triggered every in-game hour to simulate market fluctuations
function GlobalMarket:onHourChanged(currentHour)
    if g_server ~= nil then
        for _,ft in pairs(self.offlineMarketFillTypes) do
            -- Fluctuate levels randomly
            ft.fillLevel = math.max(ft.fillLevel + math.random(-4000, 5000), 0)

            -- Recalculate price based on the new level
            ft.price = GlobalMarket.calcOfflinePrice(ft.normalPrice, ft.fillLevel)
        end

        -- Broadcast event to clients to sync the offline market
        if g_client ~= nil then
            g_client:getServerConnection():sendEvent(SynchOfflineMarketEvent.new())
        end
    end
end
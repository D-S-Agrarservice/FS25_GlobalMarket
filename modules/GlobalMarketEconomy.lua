--
-- FS25 - GlobalMarket (Economy Module)
--

GlobalMarket.PRICE_MIN = 0.8
GlobalMarket.PRICE_MAX = 1.2
GlobalMarket.PRICE_LEVEL_MAX = 10000000
GlobalMarket.DELIVER_COST = 200
GlobalMarket.DELIVER_COST_PERLITER = 0.01

function GlobalMarket:initEconomy()
    -- FIXED: Changed self:debugLog to GlobalMarket.debugLog
    GlobalMarket.debugLog("Initializing Economy Module...")
    self.offlineMarketFillTypes = {}
    self:loadOfflineMarket()

    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
end

function GlobalMarket:loadOfflineMarket()
    local path = GlobalMarket.dir .. "offlineMarket.xml"
    GlobalMarket.debugLog("Loading offline market from: %s", path)

    if not fileExists(path) then
        GlobalMarket.debugLog("Error: offlineMarket.xml not found at %s", path)
        return
    end

    local xmlFile = XMLFile.load("globalMarket_offline", path)
    if xmlFile == nil then
        GlobalMarket.debugLog("Error: Could not parse globalMarket_offline XML!")
        return
    end

    xmlFile:iterate("globalMarket_offline.fillTypes.fillType", function (_, baseKey)
        local name = xmlFile:getString(baseKey .. "#name")
        local price = xmlFile:getFloat(baseKey .. "#price")

        if name ~= nil and price ~= nil then
            local level = math.random(0, 50) * 10000

            table.insert(self.offlineMarketFillTypes, {
                fillType = name,
                fillLevel = level,
                normalPrice = price,
                price = GlobalMarket.calcOfflinePrice(price, level)
            })
            GlobalMarket.debugLog("  -> Registered FillType: %s (Base: %f, Start Level: %d)", name, price, level)
        end
    end)

    xmlFile:delete()
end

function GlobalMarket.calcOfflinePrice(price, currentLevel)
    local fillTypeMinPrice = price * GlobalMarket.PRICE_MIN
    local fillTypeMaxPrice = price * GlobalMarket.PRICE_MAX
    local diffPrice = fillTypeMaxPrice - fillTypeMinPrice
    return fillTypeMaxPrice - (diffPrice / GlobalMarket.PRICE_LEVEL_MAX * math.min(currentLevel, GlobalMarket.PRICE_LEVEL_MAX))
end

function GlobalMarket:getPriceByFillType(fillType)
    for _, e in pairs(self.offlineMarketFillTypes) do
        if e.fillType == fillType then return e.price end
    end
    return 0
end

function GlobalMarket:getMarketSiloLevelByFillType(fillType)
    for _, e in pairs(self.offlineMarketFillTypes) do
        if e.fillType == fillType then return e.fillLevel end
    end
    return 0
end

function GlobalMarket:onHourChanged(currentHour)
    if g_server ~= nil then
        GlobalMarket.debugLog("Economy: Hour changed (%d), updating prices.", currentHour)

        for _, ft in pairs(self.offlineMarketFillTypes) do
            ft.fillLevel = math.max(ft.fillLevel + math.random(-4000, 5000), 0)
            ft.price = GlobalMarket.calcOfflinePrice(ft.normalPrice, ft.fillLevel)
        end

        if g_client ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    end
end
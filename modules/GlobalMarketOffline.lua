--
-- FS25 - GlobalMarket (Offline Market Module)
-- Description: Handles local market simulation, Map Spy baseline price resolution,
-- saturation pricing, and Great Demand announcements (#5 & #14).
--

GlobalMarketOffline = {}
GlobalMarketOffline.PRICE_MIN_FACTOR = 0.7 -- Minimum 70% of base price
GlobalMarketOffline.PRICE_MAX_FACTOR = 1.3 -- Maximum 130% of base price

-- Great Demand (#14) Configuration
GlobalMarketOffline.GREAT_DEMAND_THRESHOLD = 1.25      -- >= +25% above local normalPrice (~8.3% stock saturation or lower)
GlobalMarketOffline.MAX_CONCURRENT_GREAT_DEMANDS = 2   -- Maximum simultaneous NPC bulk-buyout events
GlobalMarketOffline.GREAT_DEMAND_HOURLY_CHANCE = 0.08  -- 8% chance per daytime hour (07:00 - 19:00)
GlobalMarketOffline.MAX_GREAT_DEMAND_HOURS = 18        -- Auto-replenish after 18h if players do not supply the good
GlobalMarketOffline.NOTIFY_COOLDOWN_MS = 600000        -- 10 min real-time cooldown per product to prevent notification spam

-- Initialize the simulated market. Fetches valid fillTypes and sets random starting stocks.
function GlobalMarket:initOfflineMarket()
    self.offlineMarketFillTypes = {}
    self.knownGreatDemands = {}
    self.lastGreatDemandNotifyTime = {}
    self.hasInitializedGreatDemands = false

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
                    price = 0, -- Calculated on demand/update
                    isGreatDemand = false,
                    greatDemandBonus = 0,
                    greatDemandHours = 0
                })
                addedCount = addedCount + 1
            end
        end
    else
        if self.debugManager ~= nil then
            self.debugManager:warning("g_fillTypeManager.fillTypes is nil! Cannot initialize offline market.")
        end
    end

    self:refreshMarketPrices(true)

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

-- Calculates the price considering Season Factors, Map SellingStations, Market Saturation, and Great Demand (#14).
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

        -- 3. GREAT DEMAND BONUS (#14): Scales down smoothly as players supply the market up to 12% capacity
        if data.greatDemandBonus ~= nil and data.greatDemandBonus > 0 then
            if saturation >= 0.12 then
                data.greatDemandBonus = 0
                data.greatDemandHours = 0
            else
                local activeBonus = data.greatDemandBonus * (1.0 - (saturation / 0.12))
                demandFactor = demandFactor + activeBonus
            end
        end

        data.isGreatDemand = (demandFactor >= GlobalMarketOffline.GREAT_DEMAND_THRESHOLD) or ((data.greatDemandBonus or 0) > 0)
        if not data.isGreatDemand then
            data.greatDemandHours = 0
        end

        -- Final Price: NormalMapPrice * Demand
        data.price = data.normalPrice * demandFactor

        if self.debugManager ~= nil then
            self.debugManager:trace("OfflineMarket Price Update - %s: MapNormal=%.2f, Demand=%.2f, GD=%s, Final=%.2f", tostring(data.fillType), data.normalPrice, demandFactor, tostring(data.isGreatDemand), data.price)
        end
    end
end

-- Checks for newly started Great Demands (both Offline & Online) and triggers the native FS25 HUD notification (#14).
function GlobalMarket:checkAndAnnounceGreatDemands(suppressNotifications)
    if self.offlineMarketFillTypes == nil then
        return
    end

    self.knownGreatDemands = self.knownGreatDemands or {}
    self.lastGreatDemandNotifyTime = self.lastGreatDemandNotifyTime or {}

    -- On initial map load or initial client join sync, record baseline state silently without notification spam
    if not self.hasInitializedGreatDemands or suppressNotifications == true then
        for _, data in pairs(self.offlineMarketFillTypes) do
            if data.fillType ~= nil then
                self.knownGreatDemands[data.fillType] = (data.isGreatDemand == true)
            end
        end
        if not suppressNotifications or g_currentMission:getIsServer() then
            self.hasInitializedGreatDemands = true
        end
        return
    end

    local now = g_time or 0
    local cooldown = GlobalMarketOffline.NOTIFY_COOLDOWN_MS or 600000

    for _, data in pairs(self.offlineMarketFillTypes) do
        local ftName = data.fillType
        if ftName ~= nil then
            local isGD = (data.isGreatDemand == true)
            local wasGD = (self.knownGreatDemands[ftName] == true)

            if isGD and not wasGD then
                local lastNotify = self.lastGreatDemandNotifyTime[ftName] or -9999999
                if (now - lastNotify) >= cooldown then
                    self.lastGreatDemandNotifyTime[ftName] = now

                    if g_currentMission ~= nil and g_currentMission.hud ~= nil and g_currentMission.hud.addSideNotification ~= nil then
                        local ftDesc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(ftName) or nil
                        local ftTitle = (ftDesc ~= nil and ftDesc.title ~= nil and ftDesc.title ~= "") and ftDesc.title or ftName
                        local fmt = (g_i18n ~= nil and g_i18n:hasText("ui_gm_notification_greatDemand"))
                            and g_i18n:getText("ui_gm_notification_greatDemand")
                            or "Great demand for %s on the Global Market!"
                        local message = string.format(fmt, ftTitle)
                        local soundSample = (GuiSoundPlayer ~= nil and GuiSoundPlayer.SOUND_SAMPLES ~= nil) and GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION or nil
                        local notifType = (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_GREATDEMAND) or nil

                        g_currentMission.hud:addSideNotification(notifType, message, 35000, soundSample)

                        if self.debugManager ~= nil then
                            self.debugManager:info("GreatDemand: Announced high demand for '%s' (%s).", ftTitle, ftName)
                        end
                    end
                end
            end

            self.knownGreatDemands[ftName] = isGD
        end
    end
end

-- Simulation of NPC trading (Hourly). Adjusts stock levels, manages NPC bulk buyouts (#14), and recalculates prices.
function GlobalMarket:runOfflineSimulation()
    if not g_currentMission:getIsServer() or self:getIsMarketOnline() then
        return
    end

    if self.debugManager ~= nil then
        self.debugManager:debug("Running hourly offline simulation...")
    end

    -- Fetch current capacity to scale the NPC trade volume
    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    local activeGreatDemands = 0
    local candidates = {}

    for _, data in pairs(self.offlineMarketFillTypes) do
        -- Scale fluctuation between -2.5% and +2.25% of the total market capacity.
        -- This ensures the market remains dynamic regardless of the chosen size.
        -- Higher minus to "bleed out" the market over time.
        local minFluct = currentLimit * -0.025
        local maxFluct = currentLimit * 0.0225

        local fluctuation = math.random(math.floor(minFluct), math.floor(maxFluct))
        data.fillLevel = math.max(data.fillLevel + fluctuation, 0)

        -- Track active Great Demands and auto-replenish after MAX_GREAT_DEMAND_HOURS so unproduced items never block slots forever
        if data.isGreatDemand then
            data.greatDemandHours = (data.greatDemandHours or 0) + 1
            if data.greatDemandHours >= GlobalMarketOffline.MAX_GREAT_DEMAND_HOURS then
                data.fillLevel = math.random(math.floor(currentLimit * 0.18), math.floor(currentLimit * 0.30))
                data.greatDemandBonus = 0
                data.greatDemandHours = 0
                data.isGreatDemand = false
                if self.debugManager ~= nil then
                    self.debugManager:info("OfflineMarket: Great Demand for %s expired after %dh (replenished by NPCs).", tostring(data.fillType), GlobalMarketOffline.MAX_GREAT_DEMAND_HOURS)
                end
            else
                activeGreatDemands = activeGreatDemands + 1
            end
        else
            table.insert(candidates, data)
        end

        if self.debugManager ~= nil then
            self.debugManager:trace("OfflineMarket Fluctuation - %s: %+d L. New Level: %d L", data.fillType, fluctuation, data.fillLevel)
        end
    end

    -- Daytime NPC Bulk Buyout Event (07:00 - 19:00): Triggers a Great Demand if slots are available
    local currentHour = (g_currentMission.environment ~= nil and g_currentMission.environment.currentHour) or 12
    if currentHour >= 7 and currentHour <= 19
        and activeGreatDemands < GlobalMarketOffline.MAX_CONCURRENT_GREAT_DEMANDS
        and #candidates > 0
        and math.random() < GlobalMarketOffline.GREAT_DEMAND_HOURLY_CHANCE then

        local chosen = candidates[math.random(1, #candidates)]
        if chosen ~= nil then
            chosen.fillLevel = math.random(0, math.floor(currentLimit * 0.02))
            chosen.greatDemandBonus = math.random(5, 12) / 100
            chosen.greatDemandHours = 0
            chosen.isGreatDemand = true

            if self.debugManager ~= nil then
                self.debugManager:info("OfflineMarket: NPC bulk buyout triggered Great Demand for %s (Stock=%d L, Bonus=+%.0f%%).", tostring(chosen.fillType), chosen.fillLevel, chosen.greatDemandBonus * 100)
            end
        end
    end

    -- Ensure baseline is marked initialized before hourly evaluation so new demands announce properly
    self.hasInitializedGreatDemands = true
    self:refreshMarketPrices()

    -- Sync new offline state to clients
    if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        if self.debugManager ~= nil then
            self.debugManager:debug("Offline market simulation finished and synced to clients.")
        end
    end
end

-- Developer / Admin console command to test Great Demand announcements immediately (`gmTriggerGreatDemand [fillType]`)
function GlobalMarket:consoleCommandTriggerGreatDemand(fillTypeArg)
    if not g_currentMission:getIsServer() and not g_currentMission.isMasterUser then
        return "Permission denied: Only Server or MasterUser can trigger a Great Demand."
    end

    -- Dedicated Server Client (MasterUser): Relay trigger request to the authoritative Server
    if not g_currentMission:getIsServer() and g_client ~= nil and InitOfflineMarketEvent ~= nil then
        local arg = (fillTypeArg ~= nil and fillTypeArg ~= "") and string.upper(fillTypeArg) or "*"
        if arg ~= "*" and self.knownGreatDemands ~= nil then
            self.knownGreatDemands[arg] = false
        end
        if arg ~= "*" and self.lastGreatDemandNotifyTime ~= nil then
            self.lastGreatDemandNotifyTime[arg] = nil
        end
        self.hasInitializedGreatDemands = true
        g_client:getServerConnection():sendEvent(InitOfflineMarketEvent.new(arg))
        return string.format("Sent Great Demand trigger request ('%s') to Dedicated Server.", arg)
    end
    if self.offlineMarketFillTypes == nil or #self.offlineMarketFillTypes == 0 then
        return "Error: Offline market fillTypes table is empty."
    end

    local targetData = nil
    if fillTypeArg ~= nil and fillTypeArg ~= "" then
        local upperArg = string.upper(fillTypeArg)
        for _, data in ipairs(self.offlineMarketFillTypes) do
            if string.upper(data.fillType) == upperArg then
                targetData = data
                break
            end
        end
        if targetData == nil then
            return string.format("FillType '%s' not found in GlobalMarket.", tostring(fillTypeArg))
        end
    else
        targetData = self.offlineMarketFillTypes[math.random(1, #self.offlineMarketFillTypes)]
    end

    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    targetData.fillLevel = math.random(0, math.floor(currentLimit * 0.01))
    targetData.greatDemandBonus = 0.10
    targetData.greatDemandHours = 0
    targetData.isGreatDemand = false

    self.hasInitializedGreatDemands = true
    if self.knownGreatDemands ~= nil then
        self.knownGreatDemands[targetData.fillType] = false
    end
    if self.lastGreatDemandNotifyTime ~= nil then
        self.lastGreatDemandNotifyTime[targetData.fillType] = nil
    end

    self:refreshMarketPrices()

    if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
    end

    return string.format("Triggered Great Demand for %s (Stock=%d L, Price=%.0f).", tostring(targetData.fillType), targetData.fillLevel, targetData.price or 0)
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

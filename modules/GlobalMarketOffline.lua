-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketOffline.lua
-- Simulated offline market engine, local baseline pricing, and Great Demand scheduling.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketOffline = {}
GlobalMarketOffline.PRICE_MIN_FACTOR = 0.7 -- Minimum 70% of base price
GlobalMarketOffline.PRICE_MAX_FACTOR = 1.3 -- Maximum 130% of base price

-- Great Demand Configuration
GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY = 1     -- Stock/Scarcity-driven (Default)
GlobalMarketOffline.GREAT_DEMAND_MODE_RANDOM = 2       -- Random event-driven (Stock unchanged, 2h / 200k L limit)
GlobalMarketOffline.GREAT_DEMAND_MODE_OFF = 3          -- Disabled

GlobalMarketOffline.GREAT_DEMAND_THRESHOLD = 1.25      -- >= +25% above local normalPrice (~8.3% stock saturation or lower)
GlobalMarketOffline.MAX_CONCURRENT_GREAT_DEMANDS = 2   -- Maximum simultaneous Great Demand events
GlobalMarketOffline.GREAT_DEMAND_CHECK_CHANCE = 0.12   -- 12% chance per decoupled check interval (23-67 ingame min)
GlobalMarketOffline.MAX_GREAT_DEMAND_HOURS = 18        -- Auto-replenish after 18h in Scarcity mode if players do not supply
GlobalMarketOffline.RANDOM_GREAT_DEMAND_MINUTES = 120  -- 2 ingame hours duration for Random mode Great Demand
GlobalMarketOffline.DEFAULT_GREAT_DEMAND_VOLUME = 200000 -- 200,000 L target delivery quota before demand ends early
GlobalMarketOffline.MIN_CAPACITY_BUFFER = 200000       -- Items within 200k of MARKET_CAPACITY cannot get Random Great Demand
-- Computes the local saturation & Great Demand multiplier for an offline or Hybrid (PENDING/REJECTED) market entry.
function GlobalMarketOffline.applyLocalDemandFactor(data, currentSaturationLimit)
    local limit = currentSaturationLimit or GlobalMarket.MARKET_CAPACITY or 2000000
    local priceRange = GlobalMarketOffline.PRICE_MAX_FACTOR - GlobalMarketOffline.PRICE_MIN_FACTOR
    local saturation = math.min((data.fillLevel or 0) / limit, 1.0)
    local demandFactor = GlobalMarketOffline.PRICE_MAX_FACTOR - (priceRange * saturation)

    local gdMode = GlobalMarket.GREAT_DEMAND_MODE or GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY
    if gdMode == GlobalMarketOffline.GREAT_DEMAND_MODE_OFF then
        data.isGreatDemand = false
        data.greatDemandBonus = 0
        data.greatDemandHours = 0
        data.greatDemandRemainingMinutes = 0
        data.greatDemandRemainingLiters = 0
        data.greatDemandOriginMode = 0
    elseif data.greatDemandBonus ~= nil and data.greatDemandBonus > 0 then
        local originMode = data.greatDemandOriginMode or gdMode
        if originMode == GlobalMarketOffline.GREAT_DEMAND_MODE_RANDOM then
            if saturation >= 0.95 or (data.greatDemandRemainingLiters ~= nil and data.greatDemandRemainingLiters <= 0) then
                data.isGreatDemand = false
                data.greatDemandBonus = 0
                data.greatDemandHours = 0
                data.greatDemandRemainingMinutes = 0
                data.greatDemandRemainingLiters = 0
                data.greatDemandOriginMode = 0
            else
                demandFactor = demandFactor + data.greatDemandBonus
                data.isGreatDemand = true
            end
        else
            if saturation >= 0.12 or (data.greatDemandRemainingLiters ~= nil and data.greatDemandRemainingLiters <= 0) then
                data.isGreatDemand = false
                data.greatDemandBonus = 0
                data.greatDemandHours = 0
                data.greatDemandRemainingMinutes = 0
                data.greatDemandRemainingLiters = 0
                data.greatDemandOriginMode = 0
            else
                local activeBonus = data.greatDemandBonus * math.max(0.25, 1.0 - (saturation / 0.12))
                demandFactor = demandFactor + activeBonus
                data.isGreatDemand = true
            end
        end
    else
        data.isGreatDemand = false
        data.greatDemandHours = 0
        data.greatDemandRemainingMinutes = 0
        data.greatDemandRemainingLiters = 0
        data.greatDemandOriginMode = 0
    end

    return demandFactor
end

GlobalMarketOffline.NOTIFY_COOLDOWN_MS = 600000        -- 10 min real-time cooldown per product to prevent notification spam

-- Initialize the simulated market. Fetches valid fillTypes and sets random starting stocks.
function GlobalMarket:initOfflineMarket()
    self.offlineMarketFillTypes = {}
    self.knownGreatDemands = {}
    self.lastGreatDemandNotifyTime = {}
    self.hasInitializedGreatDemands = false
    self.gdIngameMinuteTimerMs = 0
    self.nextGdCheckMinutes = math.random(23, 67)

    local addedCount = 0

    if g_fillTypeManager ~= nil and g_fillTypeManager.fillTypes ~= nil then
        for _, fillType in pairs(g_fillTypeManager.fillTypes) do

            -- Ask the API if this fillType is allowed on the market
            if GlobalMarketAPI.getIsFillTypeAllowed(fillType) then

                -- Dynamic starting stock based on the server's configured capacity limit
                local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
                -- Start between 20% and 60% of the maximum capacity so a fresh market does not start at scarcity
                local minStart = currentLimit * 0.20
                local maxStart = currentLimit * 0.60

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
                    greatDemandHours = 0,
                    greatDemandRemainingMinutes = 0,
                    greatDemandRemainingLiters = 0,
                    greatDemandOriginMode = 0
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
    if fillTypeIndex ~= nil and g_currentMission ~= nil and g_currentMission.economyManager ~= nil
        and g_currentMission.economyManager.getPricePerLiter ~= nil and g_currentMission.environment ~= nil then
        local econPrice = g_currentMission.economyManager:getPricePerLiter(fillTypeIndex)
        if econPrice ~= nil and econPrice > 0 then
            return econPrice
        end
    end

    local rawBase = (fillTypeDesc ~= nil and fillTypeDesc.pricePerLiter) or fallbackBasePrice or 0.5
    local hasEconMult = (EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil
        and g_currentMission ~= nil and g_currentMission.missionInfo ~= nil)
    local diffMult = hasEconMult and (EconomyManager.getPriceMultiplier() or 1) or 1
    return rawBase * diffMult
end

-- Calculates the price considering Season Factors, Map SellingStations, Market Saturation, and Great Demand.
function GlobalMarket:updateOfflinePrices()
    if self.offlineMarketFillTypes == nil then
        return
    end

    local currentSaturationLimit = GlobalMarket.MARKET_CAPACITY or 2000000

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

        -- 2. GM DEMAND FACTOR & GREAT DEMAND BONUS
        local demandFactor = GlobalMarketOffline.applyLocalDemandFactor(data, currentSaturationLimit)

        -- Final Price: NormalMapPrice * Demand
        data.price = data.normalPrice * demandFactor

        if self.debugManager ~= nil then
            self.debugManager:trace(
                "OfflineMarket Price Update - %s: MapNormal=%.2f, Demand=%.2f, GD=%s, Final=%.2f",
                tostring(data.fillType), data.normalPrice, demandFactor, tostring(data.isGreatDemand), data.price
            )
        end
    end
end

-- Checks for newly started Great Demands (both Offline & Online) and triggers the native FS25 HUD notification.
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

-- Triggers a Great Demand for a candidate fillType according to the selected mode.
function GlobalMarket:triggerDecoupledOfflineGreatDemand(mode, forcedTargetData)
    if self.offlineMarketFillTypes == nil or #self.offlineMarketFillTypes == 0 then
        return nil
    end

    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    local minBuffer = math.min(GlobalMarketOffline.MIN_CAPACITY_BUFFER or 200000, math.floor(currentLimit * 0.25))
    local maxAllowedStock = currentLimit - minBuffer
    local chosen = forcedTargetData

    if chosen ~= nil and self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(chosen.fillType) then
        return nil
    end

    if chosen == nil then
        local candidates = {}

        if mode == GlobalMarketOffline.GREAT_DEMAND_MODE_RANDOM then
            -- Random mode: Any non-GreatDemand local/Hybrid product that is at least 200k L (or 15-25%) below MARKET_CAPACITY
            for _, data in ipairs(self.offlineMarketFillTypes) do
                local isOnlineApproved = (self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(data.fillType))
                if not isOnlineApproved and not data.isGreatDemand and (data.fillLevel or 0) <= maxAllowedStock and (data.fillLevel or 0) <= (currentLimit * 0.85) then
                    table.insert(candidates, data)
                end
            end
        else
            -- Scarcity mode: Prefer local/Hybrid items already in low stock (<= 15%), otherwise moderate/low stock (<= 45%)
            local scarceCandidates = {}
            local moderateCandidates = {}
            for _, data in ipairs(self.offlineMarketFillTypes) do
                local isOnlineApproved = (self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(data.fillType))
                if not isOnlineApproved and not data.isGreatDemand then
                    local lvl = data.fillLevel or 0
                    if lvl <= (currentLimit * 0.15) then
                        table.insert(scarceCandidates, data)
                    elseif lvl <= (currentLimit * 0.45) then
                        table.insert(moderateCandidates, data)
                    end
                end
            end
            candidates = (#scarceCandidates > 0) and scarceCandidates or moderateCandidates
        end

        if #candidates > 0 then
            chosen = candidates[math.random(1, #candidates)]
        end
    end

    if chosen == nil then
        return nil
    end

    local defaultQuota = GlobalMarketOffline.DEFAULT_GREAT_DEMAND_VOLUME or 200000

    if mode == GlobalMarketOffline.GREAT_DEMAND_MODE_RANDOM then
        -- Keep current stock level unchanged; apply strong price bonus for 2 ingame hours (120 min) or 200,000 L delivered
        chosen.greatDemandOriginMode = GlobalMarketOffline.GREAT_DEMAND_MODE_RANDOM
        chosen.greatDemandBonus = math.random(20, 32) / 100
        chosen.greatDemandRemainingMinutes = GlobalMarketOffline.RANDOM_GREAT_DEMAND_MINUTES or 120
        chosen.greatDemandHours = 0
        chosen.greatDemandRemainingLiters = math.min(defaultQuota, math.max(50000, math.floor(currentLimit - (chosen.fillLevel or 0))))
        chosen.isGreatDemand = true

        if self.debugManager ~= nil then
            self.debugManager:info("OfflineMarket (Random GD): Triggered Great Demand for %s (Stock=%d L unchanged, Bonus=+%.0f%%, Quota=%d L, Duration=%d min).",
                tostring(chosen.fillType), math.floor(chosen.fillLevel or 0), chosen.greatDemandBonus * 100, chosen.greatDemandRemainingLiters, chosen.greatDemandRemainingMinutes)
        end
    else
        -- Scarcity / NPC Bulk Buyout mode: Stock drops to 0-2%, demand lasts until 12% saturation, 200k L delivered, or max hours
        chosen.fillLevel = math.random(0, math.floor(currentLimit * 0.02))
        chosen.greatDemandOriginMode = GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY
        chosen.greatDemandBonus = math.random(10, 18) / 100
        chosen.greatDemandRemainingMinutes = (GlobalMarketOffline.MAX_GREAT_DEMAND_HOURS or 18) * 60
        chosen.greatDemandHours = 0
        chosen.greatDemandRemainingLiters = math.min(defaultQuota, math.max(50000, math.floor(currentLimit * 0.15)))
        chosen.isGreatDemand = true

        if self.debugManager ~= nil then
            self.debugManager:info("OfflineMarket (Scarcity GD): Triggered Great Demand for %s (Stock=%d L, Bonus=+%.0f%%, Quota=%d L).",
                tostring(chosen.fillType), math.floor(chosen.fillLevel or 0), chosen.greatDemandBonus * 100, chosen.greatDemandRemainingLiters)
        end
    end

    return chosen
end

-- Decoupled ingame-minute timer for Great Demands.
-- Evaluates expirations and triggers new Great Demands at random non-hourly timestamps (e.g. 09:23 -> 11:23).
-- In Online Hybrid Mode, APPROVED items are controlled by the backend while PENDING/REJECTED items continue locally.
function GlobalMarket:updateOfflineGreatDemands(dt)
    if not g_currentMission:getIsServer() then
        return
    end
    if self.offlineMarketFillTypes == nil or g_currentMission.paused then
        return
    end

    local timeScale = (g_currentMission.getEffectiveTimeScale ~= nil and g_currentMission:getEffectiveTimeScale())
        or (g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.timeScale)
        or 1
    if timeScale <= 0 then
        return
    end

    self.gdIngameMinuteTimerMs = (self.gdIngameMinuteTimerMs or 0) + (dt * timeScale)
    if self.gdIngameMinuteTimerMs < 60000 then
        return
    end

    local elapsedMinutes = math.floor(self.gdIngameMinuteTimerMs / 60000)
    self.gdIngameMinuteTimerMs = self.gdIngameMinuteTimerMs - (elapsedMinutes * 60000)

    local gdMode = GlobalMarket.GREAT_DEMAND_MODE or GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY
    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    local activeGreatDemands = 0
    local hasLocalCandidates = false
    local stateChanged = false

    -- 1. Evaluate active Great Demands minute-by-minute (skipping APPROVED online items)
    for _, data in ipairs(self.offlineMarketFillTypes) do
        local isOnlineApproved = (self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(data.fillType))
        if isOnlineApproved then
            if data.isGreatDemand then
                activeGreatDemands = activeGreatDemands + 1
            end
        else
            hasLocalCandidates = true
            if data.isGreatDemand or (data.greatDemandBonus or 0) > 0 then
                if gdMode == GlobalMarketOffline.GREAT_DEMAND_MODE_OFF then
                    data.isGreatDemand = false
                    data.greatDemandBonus = 0
                    data.greatDemandHours = 0
                    data.greatDemandRemainingMinutes = 0
                    data.greatDemandRemainingLiters = 0
                    data.greatDemandOriginMode = 0
                    stateChanged = true
                else
                    if (data.greatDemandRemainingMinutes or 0) <= 0 then
                        local defaultTotalMin = ((data.greatDemandOriginMode or gdMode) == GlobalMarketOffline.GREAT_DEMAND_MODE_RANDOM)
                            and (GlobalMarketOffline.RANDOM_GREAT_DEMAND_MINUTES or 120)
                            or ((GlobalMarketOffline.MAX_GREAT_DEMAND_HOURS or 18) * 60)
                        local elapsedMin = math.floor((data.greatDemandHours or 0) * 60)
                        data.greatDemandRemainingMinutes = math.max(15, defaultTotalMin - elapsedMin)
                    end

                    data.greatDemandRemainingMinutes = data.greatDemandRemainingMinutes - elapsedMinutes
                    data.greatDemandHours = (data.greatDemandHours or 0) + (elapsedMinutes / 60.0)

                    if data.greatDemandRemainingMinutes <= 0 or (data.greatDemandRemainingLiters ~= nil and data.greatDemandRemainingLiters <= 0) then
                        -- Replenish stock only if this was a Scarcity buyout that remained empty
                        if (data.greatDemandOriginMode or gdMode) == GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY and (data.fillLevel or 0) < (currentLimit * 0.12) then
                            data.fillLevel = math.random(math.floor(currentLimit * 0.18), math.floor(currentLimit * 0.30))
                        end
                        data.isGreatDemand = false
                        data.greatDemandBonus = 0
                        data.greatDemandHours = 0
                        data.greatDemandRemainingMinutes = 0
                        data.greatDemandRemainingLiters = 0
                        data.greatDemandOriginMode = 0
                        stateChanged = true

                        if self.debugManager ~= nil then
                            self.debugManager:info("OfflineMarket: Great Demand for %s expired (decoupled timer).", tostring(data.fillType))
                        end
                    else
                        activeGreatDemands = activeGreatDemands + 1
                    end
                end
            end
        end
    end

    -- 2. Check decoupled random spawn timer (every 23 to 67 ingame minutes, never locked to full hours)
    self.nextGdCheckMinutes = (self.nextGdCheckMinutes or math.random(23, 67)) - elapsedMinutes
    if self.nextGdCheckMinutes <= 0 then
        self.nextGdCheckMinutes = math.random(23, 67)

        if hasLocalCandidates and gdMode ~= GlobalMarketOffline.GREAT_DEMAND_MODE_OFF and activeGreatDemands < GlobalMarketOffline.MAX_CONCURRENT_GREAT_DEMANDS then
            local currentHour = (g_currentMission.environment ~= nil and g_currentMission.environment.currentHour) or 12
            if currentHour >= 7 and currentHour <= 19 and math.random() < (GlobalMarketOffline.GREAT_DEMAND_CHECK_CHANCE or 0.12) then
                local triggeredItem = self:triggerDecoupledOfflineGreatDemand(gdMode)
                if triggeredItem ~= nil then
                    stateChanged = true
                end
            end
        end
    end

    if stateChanged then
        self.hasInitializedGreatDemands = true
        self:refreshMarketPrices()
        if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    end
end

-- Tracks player sales against active local/Hybrid Great Demand volume quotas (e.g. 200,000 L limit).
function GlobalMarket:onMarketGoodsSold(fillTypeName, soldLiters)
    if not g_currentMission:getIsServer() then
        return
    end
    if self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(fillTypeName) then
        return
    end
    if self.offlineMarketFillTypes == nil or fillTypeName == nil or (soldLiters or 0) <= 0 then
        return
    end

    for _, data in ipairs(self.offlineMarketFillTypes) do
        if data.fillType == fillTypeName and data.isGreatDemand then
            local remaining = (data.greatDemandRemainingLiters or GlobalMarketOffline.DEFAULT_GREAT_DEMAND_VOLUME or 200000) - soldLiters
            data.greatDemandRemainingLiters = math.max(0, math.floor(remaining))

            if data.greatDemandRemainingLiters <= 0 then
                data.isGreatDemand = false
                data.greatDemandBonus = 0
                data.greatDemandHours = 0
                data.greatDemandRemainingMinutes = 0
                data.greatDemandRemainingLiters = 0
                data.greatDemandOriginMode = 0

                if self.debugManager ~= nil then
                    self.debugManager:info("OfflineMarket: Great Demand for %s fulfilled and ended early (target delivery quota reached).", tostring(fillTypeName))
                end
            end
            break
        end
    end
end

-- Invoked when the Admin changes the Great Demand Mode in GlobalMarketSettings.
function GlobalMarket:onGreatDemandModeChanged(newMode)
    if not g_currentMission:getIsServer() or self.offlineMarketFillTypes == nil then
        return
    end

    local changed = false
    if newMode == GlobalMarketOffline.GREAT_DEMAND_MODE_OFF then
        for _, data in ipairs(self.offlineMarketFillTypes) do
            local isOnlineApproved = (self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(data.fillType))
            if not isOnlineApproved and (data.isGreatDemand or (data.greatDemandBonus or 0) > 0) then
                data.isGreatDemand = false
                data.greatDemandBonus = 0
                data.greatDemandHours = 0
                data.greatDemandRemainingMinutes = 0
                data.greatDemandRemainingLiters = 0
                data.greatDemandOriginMode = 0
                changed = true
            end
        end
    end

    if changed then
        self:refreshMarketPrices()
        if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    end
end

-- Simulation of NPC trading (Hourly). Adjusts stock levels and recalculates prices.
-- In Online Hybrid Mode, APPROVED items keep their backend stock while PENDING/REJECTED items continue simulating locally.
function GlobalMarket:runOfflineSimulation()
    if not g_currentMission:getIsServer() then
        return
    end

    -- Evaluate GM Logistics Center storage fees, natural bulk decay, warnings, and expiration
    -- Runs hourly in both Offline and Online modes!
    if self.updateGmStorageFeesAndDecay ~= nil then
        self:updateGmStorageFeesAndDecay()
    end

    -- Evaluate Supply Contracts, +/-10% Direct Offers, Pickup Inbox grace/liquidation & NPC cycles
    if self.updateContractsAndOffersHourly ~= nil then
        self:updateContractsAndOffersHourly()
    end

    -- Used vehicle market (#16): listing expiry and pending return retries
    if self.updateVehicleMarketHourly ~= nil then
        self:updateVehicleMarketHourly()
    end

    if self.offlineMarketFillTypes == nil then
        return
    end

    -- Fetch current capacity to scale the NPC trade volume
    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    local isOnline = self:getIsMarketOnline()
    local updatedAnyLocalItem = false

    for _, data in pairs(self.offlineMarketFillTypes) do
        local isOnlineApproved = isOnline and (self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(data.fillType))
        if not isOnlineApproved then
            -- Scale fluctuation between -2.5% and +2.25% of the total market capacity.
            -- This ensures the market remains dynamic regardless of the chosen size.
            local minFluct = currentLimit * -0.025
            local maxFluct = currentLimit * 0.0225

            local fluctuation = math.random(math.floor(minFluct), math.floor(maxFluct))

            -- While a Great Demand is active, prevent NPC upward stock fluctuation from ending the demand prematurely
            if data.isGreatDemand then
                if (data.greatDemandOriginMode or 1) == GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY then
                    fluctuation = math.min(fluctuation, 0)
                else
                    fluctuation = 0
                end
            end

            data.fillLevel = math.clamp(data.fillLevel + fluctuation, 0, currentLimit)
            updatedAnyLocalItem = true

            if self.debugManager ~= nil then
                self.debugManager:trace("OfflineMarket Fluctuation - %s: %+d L. New Level: %d L", data.fillType, fluctuation, data.fillLevel)
            end
        end
    end

    if isOnline and not updatedAnyLocalItem then
        return
    end

    -- Ensure baseline is marked initialized before hourly evaluation
    self.hasInitializedGreatDemands = true
    self:refreshMarketPrices()

    -- Sync new offline/hybrid state to clients
    if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        if self.debugManager ~= nil then
            self.debugManager:debug("Offline/Hybrid market simulation finished and synced to clients.")
        end
    end
end

-- Developer / Admin console command to test Great Demand announcements immediately (`gmTriggerGreatDemand [fillType]`)
function GlobalMarket:consoleCommandTriggerGreatDemand(fillTypeArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
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
    end

    local activeMode = GlobalMarket.GREAT_DEMAND_MODE or GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY
    if activeMode == GlobalMarketOffline.GREAT_DEMAND_MODE_OFF then
        activeMode = GlobalMarketOffline.GREAT_DEMAND_MODE_SCARCITY
    end

    self.hasInitializedGreatDemands = true
    local chosen = self:triggerDecoupledOfflineGreatDemand(activeMode, targetData)
    if chosen == nil then
        return "Error: No eligible FillType found for Great Demand."
    end

    if self.knownGreatDemands ~= nil then
        self.knownGreatDemands[chosen.fillType] = false
    end
    if self.lastGreatDemandNotifyTime ~= nil then
        self.lastGreatDemandNotifyTime[chosen.fillType] = nil
    end

    self:refreshMarketPrices()

    if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
    end

    return string.format("Triggered Great Demand (Mode %d) for %s (Stock=%d L, Quota=%d L, Duration=%d min, Price=%.0f).",
        activeMode, tostring(chosen.fillType), math.floor(chosen.fillLevel or 0), chosen.greatDemandRemainingLiters or 0, chosen.greatDemandRemainingMinutes or 0, chosen.price or 0)
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

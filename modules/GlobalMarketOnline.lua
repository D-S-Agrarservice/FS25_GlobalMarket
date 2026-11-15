-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketOnline.lua
-- Online market pricing engine combining global trend/stock data with local map baselines.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketOnline = {}
GlobalMarket.DEFAULT_MIN_EXE_VERSION = "0.9.10"
GlobalMarket.EXE_SWITCH_GRACE_MS = 4500

-- Validates and normalizes a numeric SemVer / 4-part version string (e.g. "0.9.10", "1.0.0", or "1.0.0.0")
function GlobalMarket.sanitizeExeVersion(rawVersion)
    if type(rawVersion) ~= "string" then
        return nil
    end
    local trimmed = string.match(rawVersion, "^%s*(%d+%.%d+[%.%d]*)%s*$")
    if trimmed == nil or string.len(trimmed) > 32 then
        return nil
    end
    return trimmed
end

-- Compares two numeric version strings up to 4 segments (missing segments pad with 0)
function GlobalMarket.isExeVersionSufficient(currentVersion, minVersion)
    local cleanCurrent = GlobalMarket.sanitizeExeVersion(currentVersion)
    local cleanMin = GlobalMarket.sanitizeExeVersion(minVersion)
    if cleanCurrent == nil then return false end
    if cleanMin == nil then return true end

    local currentParts = {}
    for p in string.gmatch(cleanCurrent, "%d+") do table.insert(currentParts, tonumber(p)) end
    local minParts = {}
    for p in string.gmatch(cleanMin, "%d+") do table.insert(minParts, tonumber(p)) end
    for i = 1, 4 do
        local cVal = currentParts[i] or 0
        local mVal = minParts[i] or 0
        if cVal > mVal then return true end
        if cVal < mVal then return false end
    end
    return true
end

-- Loads any previously raised minimum client version floor from modSettings/FS25_GlobalMarket/clientVersionState.xml (Client/Host only)
function GlobalMarket:loadPersistedMinExeVersion()
    if g_dedicatedServer ~= nil or self.clientVersionStateFile == nil or not fileExists(self.clientVersionStateFile) then
        return
    end

    local xmlFile = XMLFile.load("gmClientVersionState", self.clientVersionStateFile)
    if xmlFile ~= nil then
        local rawSaved = xmlFile:getString("gmClientVersionState#minExeVersion") or xmlFile:getString("gmClientVersionState.minExeVersion")
        xmlFile:delete()

        local savedMin = GlobalMarket.sanitizeExeVersion(rawSaved)
        if savedMin ~= nil and not GlobalMarket.isExeVersionSufficient(self.minExeVersion, savedMin) then
            self.minExeVersion = savedMin
            if self.debugManager ~= nil then
                self.debugManager:info("Sync: Loaded persisted minimum client version floor '%s' from clientVersionState.xml.", savedMin)
            end
        end
    end
end

-- Persists a newly raised minimum client version floor to modSettings/FS25_GlobalMarket/clientVersionState.xml (Client/Host only)
function GlobalMarket:savePersistedMinExeVersion(newMinVersion)
    if g_dedicatedServer ~= nil or self.clientVersionStateFile == nil then
        return
    end

    local cleanMin = GlobalMarket.sanitizeExeVersion(newMinVersion)
    if cleanMin == nil then
        return
    end

    local xmlFile = XMLFile.create("gmClientVersionState", self.clientVersionStateFile, "gmClientVersionState")
    if xmlFile ~= nil then
        xmlFile:setString("gmClientVersionState#minExeVersion", cleanMin)
        xmlFile:setString("gmClientVersionState#updatedAt", getDate("%Y-%m-%d %H:%M:%S"))
        xmlFile:save()
        xmlFile:delete()

        if self.debugManager ~= nil then
            self.debugManager:info("Sync: Persisted raised minimum client version floor '%s' to clientVersionState.xml.", cleanMin)
        end
    end
end

-- Reconciles self.minExeVersion against globalMarketOnline.minVersion from an active client heartbeat:
-- 1. Any higher backendMinVersion immediately raises and persists the floor (even when isConnected="false" due to version lock).
-- 2. When an active server handshake (isConnected="true") reports a lower minVersion (admin rollback), lowers the floor back to max(DEFAULT_MIN_EXE_VERSION, backendMinVersion).
function GlobalMarket:reconcileMinExeVersion(backendMinVersion, isTimestampActive, backendConnectedNow)
    if not isTimestampActive then
        return
    end

    local cleanBackendMin = GlobalMarket.sanitizeExeVersion(backendMinVersion)
    if cleanBackendMin == nil then
        return
    end

    if not GlobalMarket.isExeVersionSufficient(self.minExeVersion, cleanBackendMin) then
        self.minExeVersion = cleanBackendMin
        self:savePersistedMinExeVersion(cleanBackendMin)
    elseif backendConnectedNow == true then
        local baseFloor = GlobalMarket.DEFAULT_MIN_EXE_VERSION or "0.9.10"
        local effectiveFloor = GlobalMarket.isExeVersionSufficient(cleanBackendMin, baseFloor) and cleanBackendMin or baseFloor
        if not GlobalMarket.isExeVersionSufficient(effectiveFloor, self.minExeVersion) then
            self.minExeVersion = effectiveFloor
            self:savePersistedMinExeVersion(effectiveFloor)
            if self.debugManager ~= nil then
                self.debugManager:info("Sync: Server rolled back mandatory client version floor to '%s'.", effectiveFloor)
            end
        end
    end
end

-- Displays a non-blocking, once-per-session HUD info notification when an optional GlobalMarketClient update is available
function GlobalMarket:notifyOptionalExeUpdate(exeVersion, latestVersion)
    if g_dedicatedServer ~= nil or g_currentMission == nil then
        return
    end

    local cleanLatest = GlobalMarket.sanitizeExeVersion(latestVersion)
    if cleanLatest == nil or GlobalMarket.isExeVersionSufficient(exeVersion, cleanLatest) then
        return
    end

    self.shownOptionalUpdateVersions = self.shownOptionalUpdateVersions or {}
    if self.shownOptionalUpdateVersions[cleanLatest] == true then
        return
    end

    self.shownOptionalUpdateVersions[cleanLatest] = true
    self.hasShownOptionalUpdateHint = true

    local fmt = (g_i18n ~= nil and g_i18n:hasText("ui_gm_info_exe_update_optional"))
        and g_i18n:getText("ui_gm_info_exe_update_optional")
        or "GlobalMarket: A new client version (v%s) is available - update recommended."
    local hintMsg = string.format(fmt, cleanLatest)

    if g_currentMission.hud ~= nil and g_currentMission.hud.addSideNotification ~= nil then
        local notifType = (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_INFO) or { 1, 1, 1, 1 }
        local sound = (GuiSoundPlayer ~= nil and GuiSoundPlayer.SOUND_SAMPLES ~= nil) and GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION or nil
        g_currentMission.hud:addSideNotification(notifType, hintMsg, 12000, sound)
    else
        g_currentMission:showBlinkingWarning(hintMsg, 6000)
    end

    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Optional GlobalMarketClient update v%s available (running v%s).", cleanLatest, tostring(exeVersion))
    end
end

-- Updates the prices for all fillTypes using the server-provided trend factor or online stock level.
-- @param fillTypeTable table: The shared market data table (usually self.offlineMarketFillTypes)
function GlobalMarketOnline:updateOnlinePrices(fillTypeTable)
    if fillTypeTable == nil then return end

    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local currentSaturationLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    local minFactor = (GlobalMarketOffline ~= nil and GlobalMarketOffline.PRICE_MIN_FACTOR) or 0.7
    local maxFactor = (GlobalMarketOffline ~= nil and GlobalMarketOffline.PRICE_MAX_FACTOR) or 1.3
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

-- Applies authoritative Server-computed online/hybrid stock levels, Map-Spy prices, and Great Demand states on MP clients.
-- Prevents MP clients from recalculating prices locally or wiping server-side Hybrid Great Demands.
function GlobalMarketOnline.applyAuthoritativeClientSync(gm, incomingByFillType)
    if gm == nil then return end

    if gm.offlineMarketFillTypes ~= nil and incomingByFillType ~= nil then
        for _, localItem in pairs(gm.offlineMarketFillTypes) do
            local incomingItem = incomingByFillType[localItem.fillType]
            if incomingItem ~= nil then
                localItem.onlineStatus = incomingItem.status or "PENDING"
                localItem.fillLevel = incomingItem.fillLevel or 0
                localItem.trend = incomingItem.trend
                localItem.isGreatDemand = (incomingItem.isGreatDemand == true)
                localItem.onlineGreatDemandBonus = incomingItem.greatDemandBonus
                localItem.greatDemandRemainingLiters = incomingItem.greatDemandRemainingLiters or 0
                if incomingItem.normalPrice ~= nil then
                    localItem.normalPrice = incomingItem.normalPrice
                end
                if incomingItem.price ~= nil then
                    localItem.price = incomingItem.price
                end
            end
        end
    end

    if gm.checkAndAnnounceGreatDemands ~= nil then
        local isInitialSync = not gm.hasInitializedGreatDemands
        gm:checkAndAnnounceGreatDemands(isInitialSync)
        gm.hasInitializedGreatDemands = true
    end

    local ui = gm.ui or (g_currentMission ~= nil and g_currentMission.globalMarketUi or nil)
    if ui ~= nil and ui:getIsVisible() then
        ui:updateContent()
    end
end

-- Restores a single market entry back to its snapshotted pre-online Offline stock & Great Demand state
function GlobalMarket:restoreItemOfflineState(item, currentLimit)
    if item == nil then return end
    local limit = currentLimit or GlobalMarket.MARKET_CAPACITY or 2000000

    if item.savedOfflineFillLevel ~= nil then
        item.fillLevel = math.clamp(item.savedOfflineFillLevel, 0, limit)
        item.greatDemandBonus = item.savedOfflineGdBonus or 0
        item.greatDemandHours = item.savedOfflineGdHours or 0
        item.greatDemandRemainingMinutes = item.savedOfflineGdRemainingMinutes or 0
        item.greatDemandRemainingLiters = item.savedOfflineGdRemainingLiters or 0
        item.greatDemandOriginMode = item.savedOfflineGdOriginMode or 0
        item.isGreatDemand = (item.greatDemandBonus > 0)

        item.savedOfflineFillLevel = nil
        item.savedOfflineGdBonus = nil
        item.savedOfflineGdHours = nil
        item.savedOfflineGdRemainingMinutes = nil
        item.savedOfflineGdRemainingLiters = nil
        item.savedOfflineGdOriginMode = nil
    else
        item.fillLevel = math.clamp(item.fillLevel or 0, 0, limit)
        if item.greatDemandFromServer then
            item.isGreatDemand = false
            item.greatDemandRemainingLiters = 0
        end
    end

    item.onlineStatus = nil
    item.trend = nil
    item.greatDemandFromServer = nil
    item.onlineGreatDemandBonus = nil
end

-- Restores all market entries from Online stock back to their local Offline simulation state
function GlobalMarket:restoreOfflineMarketState()
    if self.clearOnlineMarketBranding ~= nil then self:clearOnlineMarketBranding() end
    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    if self.offlineMarketFillTypes ~= nil then
        for _, item in pairs(self.offlineMarketFillTypes) do
            self:restoreItemOfflineState(item, currentLimit)
        end
    end
end

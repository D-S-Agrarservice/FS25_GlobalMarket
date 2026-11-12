-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketFinance.lua
-- Custom MoneyType registration, finance UI routing, and GM storage fee/decay evaluation.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketFinance = {}
GlobalMarketFinance.isDetailedCached = false

-- =========================================================================
-- GLOBAL I18N TEXT HOOK
-- =========================================================================
-- The basegame UI calls g_i18n:getText() without specifying our mod name.
-- We intercept this call and forcefully append our customEnv so the engine finds our texts.
if not GlobalMarketFinance.i18nHooked then
    local function customGetText(self, superFunc, name, customEnv)
        if customEnv == nil and type(name) == "string" and string.sub(name, 1, 10) == "finance_gm" then
            -- Force the engine to look in the GlobalMarket mod localization
            return superFunc(self, name, GlobalMarket.modName)
        end
        return superFunc(self, name, customEnv)
    end
    I18N.getText = Utils.overwrittenFunction(I18N.getText, customGetText)
    GlobalMarketFinance.i18nHooked = true
end

-- =========================================================================
-- ROOT LEVEL INITIALIZATION
-- =========================================================================
local function setupFinanceSystemEarly()
    -- 1. Read settings directly from disk to ensure we know the mode
    local isDetailed = false
    local settingsDirectory = g_currentModSettingsDirectory
    if settingsDirectory == nil or settingsDirectory == "" then
        settingsDirectory = string.format("%smodSettings/%s/", getUserProfileAppPath(), GlobalMarket.modName)
    end

    local savePath = settingsDirectory .. "settings.xml"
    if fileExists(savePath) then
        local xmlFile = XMLFile.load("GMSettingsEarly", savePath)
        if xmlFile ~= nil then

            -- Helper to determine the current environment profile early in the boot sequence
            local prefix = "globalMarketSettings.profiles.sp"
            local isDedi = (g_dedicatedServer ~= nil)
            if not isDedi and StartParams ~= nil and type(StartParams.getIsSet) == "function" then
                isDedi = StartParams.getIsSet("server") or StartParams.getIsSet("serverWithGui")
            end
            if isDedi then
                prefix = "globalMarketSettings.profiles.dedi"
            elseif g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer then
                prefix = "globalMarketSettings.profiles.mp"
            end

            -- Load the specific detailed finance setting from the correct profile
            isDetailed = xmlFile:getBool(prefix .. "#isDetailedFinance", false)
            xmlFile:delete()
        end
    end

    GlobalMarketFinance.isDetailedCached = isDetailed

    -- 2. BACKEND: Register ALL Money Types unconditionally
    -- This guarantees that the network IDs never shift between Server and Client.
    MoneyType.GM_FEE = MoneyType.register("gmFee", "finance_gmFee", GlobalMarket.modName)

    MoneyType.GM_BUY_BULK   = MoneyType.register("gmBuyBulk", "finance_gmBuyBulk", GlobalMarket.modName)
    MoneyType.GM_BUY_BALE   = MoneyType.register("gmBuyBale", "finance_gmBuyBale", GlobalMarket.modName)
    MoneyType.GM_BUY_LIQUID = MoneyType.register("gmBuyLiquid", "finance_gmBuyLiquid", GlobalMarket.modName)
    MoneyType.GM_BUY_PIECE  = MoneyType.register("gmBuyPiece", "finance_gmBuyPiece", GlobalMarket.modName)

    MoneyType.GM_SELL_BULK   = MoneyType.register("gmSellBulk", "finance_gmSellBulk", GlobalMarket.modName)
    MoneyType.GM_SELL_BALE   = MoneyType.register("gmSellBale", "finance_gmSellBale", GlobalMarket.modName)
    MoneyType.GM_SELL_LIQUID = MoneyType.register("gmSellLiquid", "finance_gmSellLiquid", GlobalMarket.modName)
    MoneyType.GM_SELL_PIECE  = MoneyType.register("gmSellPiece", "finance_gmSellPiece", GlobalMarket.modName)

    MoneyType.GM_BUY  = MoneyType.register("gmBuy", "finance_gmBuy", GlobalMarket.modName)
    MoneyType.GM_SELL = MoneyType.register("gmSell", "finance_gmSell", GlobalMarket.modName)

    -- Update LAST_ID so FSBaseMission:initialize() -> MoneyType.reset() does not reset
    -- the internal ID counter below our registered MoneyTypes.
    MoneyType.LAST_ID = MoneyType.GM_SELL.id

    -- 3. UNCONDITIONAL FinanceStats Injection
    -- We inject ALL stats here to ensure perfect network synchronization.
    -- Visibility logic is strictly handled in the UI hooks below.
    if FinanceStats ~= nil and FinanceStats.statNames ~= nil then
        local function injectStat(statKey)
            if not table.hasElement(FinanceStats.statNames, statKey) then
                table.insert(FinanceStats.statNames, statKey)
                FinanceStats.statNameToIndex[statKey] = #FinanceStats.statNames
            end
        end

        injectStat("gmBuyBulk")
        injectStat("gmBuyBale")
        injectStat("gmBuyLiquid")
        injectStat("gmBuyPiece")
        injectStat("gmSellBulk")
        injectStat("gmSellBale")
        injectStat("gmSellLiquid")
        injectStat("gmSellPiece")
        injectStat("gmBuy")
        injectStat("gmSell")
        injectStat("gmFee")
    end
end

-- Execute the setup instantly upon parsing the file
setupFinanceSystemEarly()


-- =========================================================================
-- FRONTEND UI HOOKS (Separating data structure from visibility)
-- =========================================================================

--- Helper: Returns a list of statNames that should currently be visible.
function GlobalMarketFinance.getVisibleFinanceStats()
    local visibleStats = {}
    local isDetailed = GlobalMarketFinance.isDetailedCached

    for _, statName in ipairs(FinanceStats.statNames) do
        local keep = true

        if isDetailed then
            -- In detailed mode, hide the aggregated simple categories
            if statName == "gmBuy" or statName == "gmSell" then
                keep = false
            end
        else
            -- In simple mode, hide all specific details
            if statName == "gmBuyBulk" or statName == "gmBuyBale" or statName == "gmBuyLiquid" or statName == "gmBuyPiece" or
               statName == "gmSellBulk" or statName == "gmSellBale" or statName == "gmSellLiquid" or statName == "gmSellPiece" then
                keep = false
            end
        end

        if keep then
            table.insert(visibleStats, statName)
        end
    end

    return visibleStats
end

if InGameMenuStatisticsFrame ~= nil and not GlobalMarketFinance.uiHooked then

    -- 1. Hook the row count for the finances list
    InGameMenuStatisticsFrame.getNumberOfItemsInSection = Utils.overwrittenFunction(InGameMenuStatisticsFrame.getNumberOfItemsInSection, function(self, superFunc, list, section)
        if list == self.financesList then
            -- Return the dynamically filtered amount of rows
            return #GlobalMarketFinance.getVisibleFinanceStats()
        end
        return superFunc(self, list, section)
    end)

    -- 2. Hook the row population to handle filtering and dynamic aggregation
    InGameMenuStatisticsFrame.populateCellForItemInSection = Utils.overwrittenFunction(
        InGameMenuStatisticsFrame.populateCellForItemInSection,
        function(self, superFunc, list, section, index, cell)
        if list == self.financesList then
            local visibleStats = GlobalMarketFinance.getVisibleFinanceStats()
            local actualStatName = visibleStats[index]

            if actualStatName ~= nil then
                local stats = self.playerFarm.stats
                local currentFinances = stats.finances
                local pastFinances = stats.financesHistory
                local statsNameText = FinanceStats.statNamesI18n[actualStatName]

                cell:getAttribute("name"):setText(statsNameText)

                -- Internal helper to aggregate values dynamically if the user changed settings mid-game
                local function getAggregatedValue(financesTable, statName)
                    if financesTable == nil then return 0 end
                    local val = financesTable[statName] or 0

                    if statName == "gmBuy" then
                        val = val + (financesTable["gmBuyBulk"] or 0)
                                  + (financesTable["gmBuyBale"] or 0)
                                  + (financesTable["gmBuyLiquid"] or 0)
                                  + (financesTable["gmBuyPiece"] or 0)
                    elseif statName == "gmSell" then
                        val = val + (financesTable["gmSellBulk"] or 0)
                                  + (financesTable["gmSellBale"] or 0)
                                  + (financesTable["gmSellLiquid"] or 0)
                                  + (financesTable["gmSellPiece"] or 0)
                    end
                    return val
                end

                -- Internal helper to assign the correct profile and string, mimicking Vanilla behavior
                local function applyFinanceValue(element, financesTable, dayIndex)
                    if InGameMenuStatisticsFrame.FINANCES.PAST_PERIOD_COUNT < dayIndex then return end

                    local valueStr = "-"
                    local profile = InGameMenuStatisticsFrame.PROFILE.VALUE_CELL_NEUTRAL

                    local targetFinances = financesTable
                    if dayIndex > 0 and financesTable ~= nil then
                        local pastIndex = #financesTable - (dayIndex - 1)
                        targetFinances = financesTable[pastIndex]
                    end

                    if targetFinances ~= nil then
                        local moneyValue = getAggregatedValue(targetFinances, actualStatName)
                        local moneyText = g_i18n:formatMoney(moneyValue, 0, false)
                        valueStr = moneyText .. " " .. self.currentMoneyUnitText

                        if math.floor(moneyValue) <= -1 then
                            profile = InGameMenuStatisticsFrame.PROFILE.VALUE_CELL_NEGATIVE
                        end
                    end

                    element:applyProfile(profile, true)
                    element:setText(valueStr)
                end

                -- Populate the cells for the current and past days
                applyFinanceValue(cell:getAttribute("todayMinusFour"), pastFinances, 4)
                applyFinanceValue(cell:getAttribute("todayMinusThree"), pastFinances, 3)
                applyFinanceValue(cell:getAttribute("todayMinusTwo"), pastFinances, 2)
                applyFinanceValue(cell:getAttribute("todayMinusOne"), pastFinances, 1)
                applyFinanceValue(cell:getAttribute("today"), currentFinances, 0)
            end

            -- Prevent superFunc from running for the financesList to avoid indexing errors
            return
        end

        return superFunc(self, list, section, index, cell)
    end)

    -- 3. Hook HUD notifications so simple finance mode displays aggregated labels
    if HUD ~= nil then
        HUD.showMoneyChange = Utils.overwrittenFunction(HUD.showMoneyChange, function(self, superFunc, moneyType, text)
            if not GlobalMarketFinance.isDetailedCached and text == nil and moneyType ~= nil and type(moneyType.title) == "string" then
                if string.sub(moneyType.title, 1, 13) == "finance_gmBuy" then
                    text = g_i18n:getText("finance_gmBuy", GlobalMarket.modName)
                elseif string.sub(moneyType.title, 1, 14) == "finance_gmSell" then
                    text = g_i18n:getText("finance_gmSell", GlobalMarket.modName)
                end
            end
            return superFunc(self, moneyType, text)
        end)
    end

    GlobalMarketFinance.uiHooked = true
end

-- Synchronizes cached UI preference after GlobalMarketSettings finishes loading
function GlobalMarketFinance.init()
    -- Sync cached UI preference with the loaded environment profile from GlobalMarketSettings.
    if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil then
        GlobalMarketFinance.isDetailedCached = (GlobalMarketSettings.current.isDetailedFinance == true)
    end
end

-- =========================================================================
-- ROUTING LOGIC
-- =========================================================================
function GlobalMarketFinance.getMoneyType(fillTypeIndex, isBuying, isBale, isPallet)
    local isDetailed = GlobalMarketFinance.isDetailedCached

    -- Always book into the 8 detailed categories on the server so every client can
    -- freely toggle between simple (aggregated) and detailed finance views at runtime.
            -- (no-op branch)
        if false then
        return isBuying and MoneyType.GM_BUY or MoneyType.GM_SELL
    end

    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil then
        -- Failsafe fallback: default to Bulk
        if true then return isBuying and MoneyType.GM_BUY_BULK or MoneyType.GM_SELL_BULK end
    end -- close fillType == nil
        -- (no-op branch)
        if false then
    end

    -- 1. Check for Liquids (Absolute Content Priority)
    local isLiquid = false
    local liquidCats = GlobalMarketAPI.getLiquidCategories()

    for _, category in ipairs(liquidCats) do
        if g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, category) then
            isLiquid = true
            break
        end
    end

    if isLiquid then
        return isBuying and MoneyType.GM_BUY_LIQUID or MoneyType.GM_SELL_LIQUID
    end

    -- 2. User Explicit Choice: Bale
    if isBale then
        return isBuying and MoneyType.GM_BUY_BALE or MoneyType.GM_SELL_BALE
    end

    -- 3. User Explicit Choice: Pallet/Piece
    if isPallet then
        return isBuying and MoneyType.GM_BUY_PIECE or MoneyType.GM_SELL_PIECE
    end

    -- 4. Fallback for Silo Transactions (Native Engine Flags)
    local hasPalletXML = (fillType.palletFilename ~= nil and fillType.palletFilename ~= "")
    local isPieceCategory = g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, "PIECE")

    -- Prevent items flagged as both Bulk and Pallet (such as Potatoes/Carrots in FS25)
    -- from being wrongly categorized as Pieces when handled in a bulk terminal.
    local isStrictlyPiece = (fillType.isPalletType or hasPalletXML) and not fillType.isBulkType

    if isPieceCategory or isStrictlyPiece then
        return isBuying and MoneyType.GM_BUY_PIECE or MoneyType.GM_SELL_PIECE
    end

    -- Prevent items flagged as both Bulk and Bale (such as Straw/Hay/Silage) from being booked as Bales in bulk silos
    if fillType.isBaleType and not fillType.isBulkType then
        return isBuying and MoneyType.GM_BUY_BALE or MoneyType.GM_SELL_BALE
    end

    -- 5. Final Absolute Fallback (Standard Bulk)
    local fallbackType = isBuying and MoneyType.GM_BUY_BULK or MoneyType.GM_SELL_BULK
    return fallbackType
end

-- =========================================================================
-- GM STORAGE FEES, DECAY & CLEARANCE LIFECYCLE
-- =========================================================================
-- Notification types for GM Storage events
GlobalMarketFinance.NOTIFY_HALFWAY_INFO      = 1 -- Halfway reached (e.g., 3 months): Fees + bulk decay info
GlobalMarketFinance.NOTIFY_EXPENSIVE_WARNING = 2 -- Final 2 months (e.g., month 5 & 6): High fees + clearance warning
GlobalMarketFinance.NOTIFY_FINAL_WARNING     = 3 -- Quarter month before expiration: Urgent final warning
GlobalMarketFinance.NOTIFY_CLEARED           = 4 -- Expiration reached (e.g., 6 months): Goods removed from GM storage

-- Displays a localized HUD notification + audio cue on the local client/host for GM Storage events
function GlobalMarketFinance.showStorageNotificationLocal(fillTypeIndex, notifyType, paramA, paramB)
    if g_currentMission == nil or g_currentMission.hud == nil or g_currentMission.hud.addSideNotification == nil then
        return
    end

    local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local title = (fillTypeDesc ~= nil and fillTypeDesc.title) or "Goods"
    local message = nil
    local color = FSBaseMission.INGAME_NOTIFICATION_GREATDEMAND or {0.95, 0.65, 0.1, 1}

    if notifyType == GlobalMarketFinance.NOTIFY_HALFWAY_INFO then
        local feeStr = g_i18n:formatMoney(math.floor((paramA or 0) + 0.5), 0, true, true)
        local monthsLeft = math.max(1, math.floor((paramB or 1) + 0.5))
        local pattern = g_i18n:getText("ui_gm_notification_storage_halfway")
        if pattern == nil or pattern == "ui_gm_notification_storage_halfway" then
            pattern = "GM Storage (%s): Storage fee (%s) charged. Clearance in %d month(s)."
        end
        message = string.format(pattern, title, feeStr, monthsLeft)

    elseif notifyType == GlobalMarketFinance.NOTIFY_EXPENSIVE_WARNING then
        local feeStr = g_i18n:formatMoney(math.floor((paramA or 0) + 0.5), 0, true, true)
        local monthsLeft = math.max(1, math.floor((paramB or 1) + 0.5))
        local pattern = g_i18n:getText("ui_gm_notification_storage_warning")
        if pattern == nil or pattern == "ui_gm_notification_storage_warning" then
            pattern = "GM Storage Warning (%s): High storage fee (%s)! Clearance in %d month(s)!"
        end
        message = string.format(pattern, title, feeStr, monthsLeft)
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or color

    elseif notifyType == GlobalMarketFinance.NOTIFY_FINAL_WARNING then
        local volStr = g_i18n:formatVolume(math.floor((paramA or 0) + 0.5), 0)
        local pattern = g_i18n:getText("ui_gm_notification_storage_final")
        if pattern == nil or pattern == "ui_gm_notification_storage_final" then
            pattern = "FINAL WARNING: %s (%s) in GM Storage expires soon! Pick up or sell immediately!"
        end
        message = string.format(pattern, title, volStr)
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or color

    elseif notifyType == GlobalMarketFinance.NOTIFY_CLEARED then
        local volStr = g_i18n:formatVolume(math.floor((paramA or 0) + 0.5), 0)
        local maxM = math.max(1, math.floor((paramB or 6) + 0.5))
        local pattern = g_i18n:getText("ui_gm_notification_storage_cleared")
        if pattern == nil or pattern == "ui_gm_notification_storage_cleared" then
            pattern = "GM Storage Cleared: %s (%s) was removed after %d months storage limit!"
        end
        message = string.format(pattern, title, volStr, maxM)
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or color
    end

    if message ~= nil then
        local sound = (GuiSoundPlayer ~= nil and GuiSoundPlayer.SOUND_SAMPLES ~= nil) and GuiSoundPlayer.SOUND_SAMPLES.NOTIFICATION or nil
        g_currentMission.hud:addSideNotification(color, message, 35000, sound)
    end
end

-- Dispatches a GM storage notification (and optional silo level sync) to the owning farm across SP/Host/Dedi
function GlobalMarketFinance.notifyFarm(farmId, fillTypeIndex, notifyType, paramA, paramB, syncedStorage, newFillLevel)
    if g_dedicatedServer == nil and g_currentMission ~= nil and g_currentMission:getFarmId() == farmId then
        if notifyType ~= nil and notifyType > 0 then
            GlobalMarketFinance.showStorageNotificationLocal(fillTypeIndex, notifyType, paramA, paramB)
        end
    end

    if g_server ~= nil and SyncGmSiloEvent ~= nil then
        if syncedStorage ~= nil or (notifyType ~= nil and notifyType > 0) then
            g_server:broadcastEvent(SyncGmSiloEvent.new(syncedStorage, farmId, fillTypeIndex, newFillLevel or 0, notifyType, paramA, paramB))
        end
    end
end

-- Removes all stored objects belonging to a specific farmId and fillTypeIndex from a GM PlaceableObjectStorage
function GlobalMarketFinance.removeExpiredObjectsFromStorage(placeable, farmId, fillTypeIndex)
    if placeable == nil or placeable.spec_objectStorage == nil then
        return 0
    end

    local spec = placeable.spec_objectStorage
    if spec.objectInfos == nil or spec.storedObjects == nil then
        return 0
    end

    local removedLiters = 0
    local removedBales = 0
    local removedPallets = 0

    for infoIndex = #spec.objectInfos, 1, -1 do
        local objectInfo = spec.objectInfos[infoIndex]
        if objectInfo ~= nil and objectInfo.objects ~= nil and #objectInfo.objects > 0 then
            local sampleObj = objectInfo.objects[1]
            local objFillType = nil
            local objLevel = 0
            local objFarmId = FarmManager.SPECTATOR_FARM_ID
            local isBaleType = false

            if sampleObj.REFERENCE_CLASS_NAME == "Bale" or sampleObj.REFERENCE_CLASS_NAME == "PackedBale" then
                isBaleType = true
                objFillType = (sampleObj.baleObject ~= nil and sampleObj.baleObject:getFillType()) or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.fillType)
                objLevel = (sampleObj.baleObject ~= nil and sampleObj.baleObject:getFillLevel()) or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.fillLevel) or 0
                objFarmId = (sampleObj.baleObject ~= nil and sampleObj.baleObject.ownerFarmId)
                    or (sampleObj.baleAttributes ~= nil and sampleObj.baleAttributes.farmId)
                    or FarmManager.SPECTATOR_FARM_ID
            elseif sampleObj.REFERENCE_CLASS_NAME == "Vehicle" then
                objFillType = sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.fillType
                objLevel = (sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.fillLevel) or 0
                objFarmId = (sampleObj.palletAttributes ~= nil and sampleObj.palletAttributes.ownerFarmId) or FarmManager.SPECTATOR_FARM_ID
            end

            if objFillType == fillTypeIndex and objFarmId == farmId then
                local countInGroup = #objectInfo.objects
                for _ = 1, countInGroup do
                    local objToRemove = objectInfo.objects[1]
                    for k = 1, #spec.storedObjects do
                        if spec.storedObjects[k] == objToRemove then
                            table.remove(spec.storedObjects, k)
                            break
                        end
                    end
                    table.remove(objectInfo.objects, 1)
                end

                removedLiters = removedLiters + (countInGroup * objLevel)
                if isBaleType then
                    removedBales = removedBales + countInGroup
                else
                    removedPallets = removedPallets + countInGroup
                end

                table.remove(spec.objectInfos, infoIndex)
            end
        end
    end

    if removedBales > 0 then
        g_farmManager:updateFarmStats(farmId, "storedBales", -removedBales)
    end
    if removedPallets > 0 then
        g_farmManager:updateFarmStats(farmId, "storedPallets", -removedPallets)
    end

    if removedBales > 0 or removedPallets > 0 then
        spec.numStoredObjects = #spec.storedObjects
        placeable:setObjectStorageObjectInfosDirty()
    end

    return removedLiters
end

-- Core hourly evaluation of GM Storage Fees, Bulk Decay, Warnings, and Expiration Clearance
function GlobalMarket:updateGmStorageFeesAndDecay(customMonthDelta)
    if not g_currentMission:getIsServer() then
        return 0
    end

    local maxMonths = GlobalMarket.STORAGE_DECAY_MONTHS
    if maxMonths == nil then
        maxMonths = 6
    end
    if maxMonths <= 0 then
        return 0
    end

    if g_currentMission.placeableSystem == nil or g_currentMission.placeableSystem.placeables == nil then
        return 0
    end

    local daysPerPeriod = (g_currentMission.environment ~= nil and g_currentMission.environment.daysPerPeriod) or 1
    daysPerPeriod = math.max(1, daysPerPeriod)
    local monthDelta = customMonthDelta or (1.0 / (24.0 * daysPerPeriod))
    local halfMonths = math.max(1, math.floor(maxMonths * 0.5))
    local processedEntries = 0
    local anyUiChange = false

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.isGmMarket then
            -- =================================================================
            -- 1. BULK GM SILOS (Loose Goods: Fees + Single-Digit Decay + Clear)
            -- =================================================================
            if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                for _, storage in ipairs(placeable.spec_silo.storages) do
                    storage.gmStorageTracker = storage.gmStorageTracker or {}

                    if storage.gmFarmFillLevels ~= nil then
                        for farmId, fillLevels in pairs(storage.gmFarmFillLevels) do
                            if farmId ~= nil and farmId ~= FarmManager.SPECTATOR_FARM_ID and farmId > 0 then
                                storage.gmStorageTracker[farmId] = storage.gmStorageTracker[farmId] or {}

                                local ftList = {}
                                for ftIdx, _ in pairs(fillLevels) do
                                    table.insert(ftList, ftIdx)
                                end

                                for _, fillTypeIndex in ipairs(ftList) do
                                    local currentLevel = fillLevels[fillTypeIndex] or 0
                                    if currentLevel <= 0.1 then
                                        storage.gmStorageTracker[farmId][fillTypeIndex] = nil
                                    else
                                        processedEntries = processedEntries + 1
                                        local tracker = storage.gmStorageTracker[farmId][fillTypeIndex]
                                        if tracker == nil then
                                            tracker = {
                                                months = 0,
                                                lastBilledMonth = 0,
                                                warnedFinal = false,
                                                lastTrackedLevel = currentLevel
                                            }
                                            storage.gmStorageTracker[farmId][fillTypeIndex] = tracker
                                        end

                                        local prevLevel = tracker.lastTrackedLevel or currentLevel
                                        if currentLevel > (prevLevel + 0.1) and prevLevel > 0.1 and (tracker.months or 0) > 0 then
                                            tracker.months = (tracker.months * prevLevel) / currentLevel
                                            tracker.lastBilledMonth = math.floor(tracker.months)
                                            if tracker.months < (maxMonths - 0.25) then
                                                tracker.warnedFinal = false
                                            end
                                        end

                                        tracker.lastTrackedLevel = currentLevel
                                        tracker.months = (tracker.months or 0) + monthDelta

                                        if tracker.months >= maxMonths then
                                            local removedLiters = currentLevel
                                            fillLevels[fillTypeIndex] = 0
                                            storage.gmStorageTracker[farmId][fillTypeIndex] = nil

                                            local physLevel = storage:getFillLevel(fillTypeIndex)
                                            storage.gmTempFarmId = nil
                                            storage:setFillLevel(math.max(0, physLevel - removedLiters), fillTypeIndex, nil)
                                            anyUiChange = true

                                            if self.debugManager ~= nil then
                                                self.debugManager:info(
                                                    "GM Storage Clearance: Removed %.0f L (FillType %d) for Farm %d after %d months.",
                                                    removedLiters, fillTypeIndex, farmId, maxMonths
                                                )
                                            end

                                            GlobalMarketFinance.notifyFarm(farmId, fillTypeIndex, GlobalMarketFinance.NOTIFY_CLEARED, removedLiters, maxMonths, storage, 0)
                                        else
                                            local completedMonths = math.floor(tracker.months)
                                            local lastBilled = tracker.lastBilledMonth or 0
                                            local levelChanged = false
                                            local pendingNotifyType = nil
                                            local pendingParamA = 0
                                            local pendingParamB = 0

                                            if completedMonths > lastBilled then
                                                local maxStep = math.min(completedMonths, maxMonths - 1)
                                                for m = lastBilled + 1, maxStep do
                                                    tracker.lastBilledMonth = m
                                                    local monthsRemaining = math.max(1, maxMonths - m)

                                                    local feeMultiplier = 1.0
                                                    if monthsRemaining == 1 then
                                                        feeMultiplier = 6.0
                                                    elseif monthsRemaining == 2 then
                                                        feeMultiplier = 4.0
                                                    elseif m == 1 then
                                                        feeMultiplier = 1.0
                                                    elseif m == 2 then
                                                        feeMultiplier = 1.5
                                                    else
                                                        feeMultiplier = 2.0
                                                    end

                                                    local basePrice = (self.getMapBasePricePerLiter ~= nil and self:getMapBasePricePerLiter(fillTypeIndex)) or 0.50
                                                    if basePrice <= 0 then basePrice = 0.50 end
                                                    local goodsValue = currentLevel * basePrice
                                                    local baseFee = math.max((currentLevel / 1000) * 2.0, goodsValue * 0.015) * EconomyManager.getCostMultiplier()
                                                    local feeAmount = math.ceil(baseFee * feeMultiplier)

                                                    if feeAmount > 0 then
                                                        g_currentMission:addMoney(-feeAmount, farmId, MoneyType.GM_FEE, true, true)
                                                    end

                                                    if m >= halfMonths then
                                                        local stepAfterHalf = m - halfMonths
                                                        local decayRate = math.min(0.09, 0.03 + (stepAfterHalf * 0.02))
                                                        local lostLiters = math.floor(currentLevel * decayRate)
                                                        if lostLiters > 0 then
                                                            currentLevel = math.max(0, currentLevel - lostLiters)
                                                            fillLevels[fillTypeIndex] = currentLevel
                                                            tracker.lastTrackedLevel = currentLevel

                                                            local physLevel = storage:getFillLevel(fillTypeIndex)
                                                            storage.gmTempFarmId = nil
                                                            storage:setFillLevel(math.max(0, physLevel - lostLiters), fillTypeIndex, nil)
                                                            levelChanged = true
                                                            anyUiChange = true
                                                        end
                                                    end

                                                    if monthsRemaining <= 2 then
                                                        pendingNotifyType = GlobalMarketFinance.NOTIFY_EXPENSIVE_WARNING
                                                        pendingParamA = feeAmount
                                                        pendingParamB = monthsRemaining
                                                    elseif m == halfMonths then
                                                        pendingNotifyType = GlobalMarketFinance.NOTIFY_HALFWAY_INFO
                                                        pendingParamA = feeAmount
                                                        pendingParamB = monthsRemaining
                                                    end
                                                end
                                            end

                                            if not tracker.warnedFinal and tracker.months >= (maxMonths - 0.25) then
                                                tracker.warnedFinal = true
                                                pendingNotifyType = GlobalMarketFinance.NOTIFY_FINAL_WARNING
                                                pendingParamA = currentLevel
                                                pendingParamB = 0
                                            end

                                            if pendingNotifyType ~= nil or levelChanged then
                                                GlobalMarketFinance.notifyFarm(
                                                    farmId, fillTypeIndex, pendingNotifyType, pendingParamA,
                                                    pendingParamB, levelChanged and storage or nil, currentLevel
                                                )
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- =================================================================
            -- 2. OBJECT GM STORAGES (Pallets/Bales: Fees + 0% Decay + Clear)
            -- =================================================================
            if placeable.spec_objectStorage ~= nil then
                if placeable.updateDirtyObjectStorageObjectInfos ~= nil then
                    placeable:updateDirtyObjectStorageObjectInfos()
                end

                local spec = placeable.spec_objectStorage
                local objectVolumeByFarm = {}

                if spec.storedObjects ~= nil then
                    for _, obj in ipairs(spec.storedObjects) do
                        local objFillType = nil
                        local objLevel = 0
                        local objFarmId = FarmManager.SPECTATOR_FARM_ID
                        local isFermenting = false

                        if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                            objFillType = (obj.baleObject ~= nil and obj.baleObject:getFillType()) or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                            objLevel = (obj.baleObject ~= nil and obj.baleObject:getFillLevel()) or (obj.baleAttributes ~= nil and obj.baleAttributes.fillLevel) or 0
                            objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID
                            if (obj.baleObject ~= nil and obj.baleObject.isFermenting) or (obj.baleAttributes ~= nil and obj.baleAttributes.isFermenting) then
                                isFermenting = true
                            end
                        elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                            objFillType = obj.palletAttributes ~= nil and obj.palletAttributes.fillType
                            objLevel = (obj.palletAttributes ~= nil and obj.palletAttributes.fillLevel) or 0
                            objFarmId = (obj.palletAttributes ~= nil and obj.palletAttributes.ownerFarmId) or FarmManager.SPECTATOR_FARM_ID
                        end

                        if objFillType ~= nil and not isFermenting and objFarmId ~= FarmManager.SPECTATOR_FARM_ID and objFarmId > 0 and objLevel > 0.1 then
                            objectVolumeByFarm[objFarmId] = objectVolumeByFarm[objFarmId] or {}
                            objectVolumeByFarm[objFarmId][objFillType] = (objectVolumeByFarm[objFarmId][objFillType] or 0) + objLevel
                        end
                    end
                end

                placeable.gmObjectTracker = placeable.gmObjectTracker or {}

                for fId, ftTrackers in pairs(placeable.gmObjectTracker) do
                    for ftIdx, _ in pairs(ftTrackers) do
                        if objectVolumeByFarm[fId] == nil or (objectVolumeByFarm[fId][ftIdx] or 0) <= 0.1 then
                            ftTrackers[ftIdx] = nil
                        end
                    end
                end

                for farmId, ftVolumes in pairs(objectVolumeByFarm) do
                    placeable.gmObjectTracker[farmId] = placeable.gmObjectTracker[farmId] or {}

                    for fillTypeIndex, currentLevel in pairs(ftVolumes) do
                        if currentLevel > 0.1 then
                            processedEntries = processedEntries + 1
                            local tracker = placeable.gmObjectTracker[farmId][fillTypeIndex]
                            if tracker == nil then
                                tracker = {
                                    months = 0,
                                    lastBilledMonth = 0,
                                    warnedFinal = false,
                                    lastTrackedLevel = currentLevel
                                }
                                placeable.gmObjectTracker[farmId][fillTypeIndex] = tracker
                            end

                            local prevLevel = tracker.lastTrackedLevel or currentLevel
                            if currentLevel > (prevLevel + 0.1) and prevLevel > 0.1 and (tracker.months or 0) > 0 then
                                tracker.months = (tracker.months * prevLevel) / currentLevel
                                tracker.lastBilledMonth = math.floor(tracker.months)
                                if tracker.months < (maxMonths - 0.25) then
                                    tracker.warnedFinal = false
                                end
                            end

                            tracker.lastTrackedLevel = currentLevel
                            tracker.months = (tracker.months or 0) + monthDelta

                            if tracker.months >= maxMonths then
                                local removedLiters = GlobalMarketFinance.removeExpiredObjectsFromStorage(placeable, farmId, fillTypeIndex)
                                placeable.gmObjectTracker[farmId][fillTypeIndex] = nil
                                anyUiChange = true

                                if self.debugManager ~= nil then
                                    self.debugManager:info(
                                        "GM ObjectStorage Clearance: Removed %.0f L (FillType %d) for Farm %d after %d months.",
                                        removedLiters, fillTypeIndex, farmId, maxMonths
                                    )
                                end

                                GlobalMarketFinance.notifyFarm(farmId, fillTypeIndex, GlobalMarketFinance.NOTIFY_CLEARED, removedLiters > 0 and removedLiters or currentLevel, maxMonths, nil, 0)
                            else
                                local completedMonths = math.floor(tracker.months)
                                local lastBilled = tracker.lastBilledMonth or 0
                                local pendingNotifyType = nil
                                local pendingParamA = 0
                                local pendingParamB = 0

                                if completedMonths > lastBilled then
                                    local maxStep = math.min(completedMonths, maxMonths - 1)
                                    for m = lastBilled + 1, maxStep do
                                        tracker.lastBilledMonth = m
                                        local monthsRemaining = math.max(1, maxMonths - m)

                                        local feeMultiplier = 1.0
                                        if monthsRemaining == 1 then
                                            feeMultiplier = 6.0
                                        elseif monthsRemaining == 2 then
                                            feeMultiplier = 4.0
                                        elseif m == 1 then
                                            feeMultiplier = 1.0
                                        elseif m == 2 then
                                            feeMultiplier = 1.5
                                        else
                                            feeMultiplier = 2.0
                                        end

                                        local basePrice = (self.getMapBasePricePerLiter ~= nil and self:getMapBasePricePerLiter(fillTypeIndex)) or 0.50
                                        if basePrice <= 0 then basePrice = 0.50 end
                                        local goodsValue = currentLevel * basePrice
                                        local baseFee = math.max((currentLevel / 1000) * 2.0, goodsValue * 0.015) * EconomyManager.getCostMultiplier()
                                        local feeAmount = math.ceil(baseFee * feeMultiplier)

                                        if feeAmount > 0 then
                                            g_currentMission:addMoney(-feeAmount, farmId, MoneyType.GM_FEE, true, true)
                                        end

                                        if monthsRemaining <= 2 then
                                            pendingNotifyType = GlobalMarketFinance.NOTIFY_EXPENSIVE_WARNING
                                            pendingParamA = feeAmount
                                            pendingParamB = monthsRemaining
                                        elseif m == halfMonths then
                                            pendingNotifyType = GlobalMarketFinance.NOTIFY_HALFWAY_INFO
                                            pendingParamA = feeAmount
                                            pendingParamB = monthsRemaining
                                        end
                                    end
                                end

                                if not tracker.warnedFinal and tracker.months >= (maxMonths - 0.25) then
                                    tracker.warnedFinal = true
                                    pendingNotifyType = GlobalMarketFinance.NOTIFY_FINAL_WARNING
                                    pendingParamA = currentLevel
                                    pendingParamB = 0
                                end

                                if pendingNotifyType ~= nil then
                                    GlobalMarketFinance.notifyFarm(farmId, fillTypeIndex, pendingNotifyType, pendingParamA, pendingParamB, nil, 0)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if anyUiChange then
        local ui = self.ui or g_currentMission.globalMarketUi
        if ui ~= nil and ui:getIsVisible() then
            ui:updateContent()
        end
    end

    return processedEntries
end

-- Developer / Admin console command to test GM storage fees, decay, warnings, and clearance (`gmAdvanceStorageAge [months]`)
function GlobalMarket:consoleCommandAdvanceStorageAge(monthsArg)
    if not g_currentMission:getIsServer() and not g_currentMission.isMasterUser then
        return "Permission denied: Only Server or MasterUser can advance GM storage age."
    end

    local monthsToAdd = tonumber(monthsArg) or 1.0
    if monthsToAdd <= 0 then
        monthsToAdd = 1.0
    end

    if not g_currentMission:getIsServer() and g_client ~= nil and SyncGmSiloEvent ~= nil then
        g_client:getServerConnection():sendEvent(SyncGmSiloEvent.new(nil, g_currentMission:getFarmId(), 1, 0, 99, monthsToAdd, 0))
        return string.format("Sent request to Dedicated Server to advance GM storage age by +%.2f month(s).", monthsToAdd)
    end

    local count = self:updateGmStorageFeesAndDecay(monthsToAdd)
    return string.format("Advanced GM storage age by +%.2f month(s) across %d stored item stack(s) (Limit: %d months).", monthsToAdd, count, GlobalMarket.STORAGE_DECAY_MONTHS or 6)
end -- End of consoleCommandAdvanceStorageAge

-- End of file
-- (Fallback handled above)
        -- (no-op branch)
        if false then
end

--
-- FS25 - GlobalMarket (Finance Module)
-- Description: Handles custom money types, UI injections, and dynamic transaction routing.
-- Executed at root level. Uses an I18N hook to reliably bypass load-order race conditions.
-- Now relies on GlobalMarketAPI for external data.
--

GlobalMarketFinance = {}
GlobalMarketFinance.isDetailedCached = false

-- =========================================================================
-- THE ULTIMATE FIX: I18N Text Hook
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
            if g_dedicatedServerInfo ~= nil then
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
    InGameMenuStatisticsFrame.populateCellForItemInSection = Utils.overwrittenFunction(InGameMenuStatisticsFrame.populateCellForItemInSection, function(self, superFunc, list, section, index, cell)
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

    GlobalMarketFinance.uiHooked = true
end

-- Dummy init function so we don't crash GlobalMarket:loadMap when it calls this
function GlobalMarketFinance.init()
    -- Kept empty to prevent missing function calls from the main loader.
    -- External data is now handled entirely by GlobalMarketAPI.
end

-- =========================================================================
-- ROUTING LOGIC
-- =========================================================================
function GlobalMarketFinance.getMoneyType(fillTypeIndex, isBuying, isBale, isPallet)
    local isDetailed = GlobalMarketFinance.isDetailedCached

    if not isDetailed then
        return isBuying and MoneyType.GM_BUY or MoneyType.GM_SELL
    end

    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil then
        -- Failsafe fallback
        return isBuying and MoneyType.GM_BUY_BULK or MoneyType.GM_SELL_BULK
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

    -- FIX: Prevent items that are BOTH Bulk and Pallet (like Potatoes/Carrots in FS25)
    -- from being wrongly categorized as Pieces when handled in a bulk terminal.
    local isStrictlyPiece = (fillType.isPalletType or hasPalletXML) and not fillType.isBulkType

    if isPieceCategory or isStrictlyPiece then
        return isBuying and MoneyType.GM_BUY_PIECE or MoneyType.GM_SELL_PIECE
    end

    if fillType.isBaleType then
        return isBuying and MoneyType.GM_BUY_BALE or MoneyType.GM_SELL_BALE
    end

    -- Final Absolute Fallback (Standard Bulk)
    return isBuying and MoneyType.GM_BUY_BULK or MoneyType.GM_SELL_BULK
end
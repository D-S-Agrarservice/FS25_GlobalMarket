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
            isDetailed = xmlFile:getBool("globalMarketSettings#isDetailedFinance", false)
            xmlFile:delete()
        end
    end

    GlobalMarketFinance.isDetailedCached = isDetailed

    -- 2. Register Money Types
    MoneyType.GM_FEE = MoneyType.register("gmFee", "finance_gmFee", GlobalMarket.modName)

    if isDetailed then
        MoneyType.GM_BUY_BULK   = MoneyType.register("gmBuyBulk", "finance_gmBuyBulk", GlobalMarket.modName)
        MoneyType.GM_BUY_BALE   = MoneyType.register("gmBuyBale", "finance_gmBuyBale", GlobalMarket.modName)
        MoneyType.GM_BUY_LIQUID = MoneyType.register("gmBuyLiquid", "finance_gmBuyLiquid", GlobalMarket.modName)
        MoneyType.GM_BUY_PIECE  = MoneyType.register("gmBuyPiece", "finance_gmBuyPiece", GlobalMarket.modName)

        MoneyType.GM_SELL_BULK   = MoneyType.register("gmSellBulk", "finance_gmSellBulk", GlobalMarket.modName)
        MoneyType.GM_SELL_BALE   = MoneyType.register("gmSellBale", "finance_gmSellBale", GlobalMarket.modName)
        MoneyType.GM_SELL_LIQUID = MoneyType.register("gmSellLiquid", "finance_gmSellLiquid", GlobalMarket.modName)
        MoneyType.GM_SELL_PIECE  = MoneyType.register("gmSellPiece", "finance_gmSellPiece", GlobalMarket.modName)
    else
        MoneyType.GM_BUY  = MoneyType.register("gmBuy", "finance_gmBuy", GlobalMarket.modName)
        MoneyType.GM_SELL = MoneyType.register("gmSell", "finance_gmSell", GlobalMarket.modName)
    end

    -- 3. Inject into FinanceStats UI (No text injection here anymore, just the slots)
    if FinanceStats ~= nil and FinanceStats.statNames ~= nil then
        local function injectStat(statKey)
            if not table.hasElement(FinanceStats.statNames, statKey) then
                table.insert(FinanceStats.statNames, statKey)
                FinanceStats.statNameToIndex[statKey] = #FinanceStats.statNames
            end
        end

        if isDetailed then
            injectStat("gmBuyBulk")
            injectStat("gmBuyBale")
            injectStat("gmBuyLiquid")
            injectStat("gmBuyPiece")
            injectStat("gmSellBulk")
            injectStat("gmSellBale")
            injectStat("gmSellLiquid")
            injectStat("gmSellPiece")
        else
            injectStat("gmBuy")
            injectStat("gmSell")
        end
        injectStat("gmFee")
    end
end

-- Execute the setup instantly upon parsing the file
setupFinanceSystemEarly()

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
    -- Liquids are always booked as liquids, regardless of being in a tank or an IBC pallet.
    -- NOW USING THE CENTRAL API
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
    -- If the UI explicitly passed isBale=true (user selected a bale storage/format),
    -- it overrides any native bulk flags (e.g., for Hay or Straw).
    if isBale then
        return isBuying and MoneyType.GM_BUY_BALE or MoneyType.GM_SELL_BALE
    end

    -- 3. User Explicit Choice: Pallet/Piece
    -- If the UI explicitly passed isPallet=true, the user consciously bought/sold
    -- a pallet (e.g., Wheat in a wooden box). It counts as a piece good.
    if isPallet then
        return isBuying and MoneyType.GM_BUY_PIECE or MoneyType.GM_SELL_PIECE
    end

    -- 4. Fallback for Silo Transactions (Native Engine Flags)
    -- If neither bale nor pallet was selected, it's a standard bulk/silo transaction.
    -- We check if the item is natively a piece good (like Wool or Saplings) just in case,
    -- otherwise it defaults to Bulk.
    local hasPalletXML = (fillType.palletFilename ~= nil and fillType.palletFilename ~= "")
    local isPieceCategory = g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, "PIECE")

    if fillType.isPalletType or isPieceCategory or (hasPalletXML and not fillType.isBulkType) then
        return isBuying and MoneyType.GM_BUY_PIECE or MoneyType.GM_SELL_PIECE
    end

    if fillType.isBaleType then
        return isBuying and MoneyType.GM_BUY_BALE or MoneyType.GM_SELL_BALE
    end

    -- Final Absolute Fallback (Standard Bulk)
    return isBuying and MoneyType.GM_BUY_BULK or MoneyType.GM_SELL_BULK
end
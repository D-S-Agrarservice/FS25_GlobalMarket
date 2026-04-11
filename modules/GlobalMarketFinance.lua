--
-- FS25 - GlobalMarket (Finance Module)
-- Description: Handles custom money types, UI injections, and dynamic transaction routing.
-- Executed at root level. Uses an I18N hook to reliably bypass load-order race conditions.
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
function GlobalMarketFinance.init() end

-- =========================================================================
-- ROUTING LOGIC
-- =========================================================================
function GlobalMarketFinance.getMoneyType(fillTypeIndex, isBuying)
    local isDetailed = GlobalMarketFinance.isDetailedCached

    if not isDetailed then
        return isBuying and MoneyType.GM_BUY or MoneyType.GM_SELL
    end

    if g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, "BALE") then
        return isBuying and MoneyType.GM_BUY_BALE or MoneyType.GM_SELL_BALE
    elseif g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, "LIQUID") then
        return isBuying and MoneyType.GM_BUY_LIQUID or MoneyType.GM_SELL_LIQUID
    elseif g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, "PIECE") then
        return isBuying and MoneyType.GM_BUY_PIECE or MoneyType.GM_SELL_PIECE
    else
        return isBuying and MoneyType.GM_BUY_BULK or MoneyType.GM_SELL_BULK
    end
end
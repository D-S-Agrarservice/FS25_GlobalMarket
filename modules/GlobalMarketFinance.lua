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
function GlobalMarketFinance.init()
    -- Start scanning for external mod extensions once the map loads
    GlobalMarketFinance.loadExternalModExtensions()
end

-- =========================================================================
-- EXTERNAL MOD EXTENSION LOGIC
-- =========================================================================
GlobalMarketFinance.liquidCategories = {"LIQUID", "SLURRYTANK", "SPRAYER"}

function GlobalMarketFinance.registerLiquidCategory(categoryName)
    local upperName = string.upper(categoryName)
    if not table.hasElement(GlobalMarketFinance.liquidCategories, upperName) then
        table.insert(GlobalMarketFinance.liquidCategories, upperName)
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("GM Finance: Registered custom liquid category '%s' from external mod.", upperName)
        end
    end
end

function GlobalMarketFinance.loadExternalModExtensions()
    -- Create a temporary schema for the external XMLs to satisfy the Engine's strict validator
    local schema = XMLSchema.new("GMFinanceExtension")
    schema:register(XMLValueType.STRING, "globalMarket.liquidCategories.category(?)#name", "Name of the custom liquid category")

    -- Scan all active mods for the ghost XML
    for _, mod in ipairs(g_modManager:getActiveMods()) do
        local xmlPath = mod.modDir .. "gm_finance.xml"

        if fileExists(xmlPath) then
            -- Pass the schema into the load function as the third argument
            local xmlFile = XMLFile.load("GMExtension", xmlPath, schema)

            if xmlFile ~= nil then
                -- Parse the custom liquid categories
                xmlFile:iterate("globalMarket.liquidCategories.category", function(_, key)
                    local catName = xmlFile:getValue(key .. "#name")
                    if catName ~= nil then
                        GlobalMarketFinance.registerLiquidCategory(catName)
                    end
                end)
                xmlFile:delete()
            end
        end
    end
end

-- =========================================================================
-- ROUTING LOGIC
-- =========================================================================
function GlobalMarketFinance.getMoneyType(fillTypeIndex, isBuying, isBale, isPallet)
    local isDetailed = GlobalMarketFinance.isDetailedCached

    if not isDetailed then
        return isBuying and MoneyType.GM_BUY or MoneyType.GM_SELL
    end

    -- 1. Explicit Overrides from the Storage Module
    if isBale then
        return isBuying and MoneyType.GM_BUY_BALE or MoneyType.GM_SELL_BALE
    end
    if isPallet then
        return isBuying and MoneyType.GM_BUY_PIECE or MoneyType.GM_SELL_PIECE
    end

    -- 2. Clean Array-Check for Liquid Categories (Using the global table)
    local isLiquid = false
    for _, category in ipairs(GlobalMarketFinance.liquidCategories) do
        if g_fillTypeManager:getIsFillTypeInCategory(fillTypeIndex, category) then
            isLiquid = true
            break -- Found a match, stop looping to save performance
        end
    end

    -- 3. Final Routing
    if isLiquid then
        return isBuying and MoneyType.GM_BUY_LIQUID or MoneyType.GM_SELL_LIQUID
    else
        return isBuying and MoneyType.GM_BUY_BULK or MoneyType.GM_SELL_BULK
    end
end
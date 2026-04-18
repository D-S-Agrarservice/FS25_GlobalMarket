--
-- FS25 - GlobalMarketAPI
-- Description: Central API module acting as the single source of truth for external data.
-- Handles custom liquid categories, market whitelists, and blacklists.
-- Priority: 1. Basegame (Hardcode) -> 2. Mods (gm_customs.xml) -> 3. Player Fallback (gm_fallback.xml)
--

GlobalMarketAPI = {}
GlobalMarketAPI.liquidCategories = {}
GlobalMarketAPI.marketWhitelist = {}
GlobalMarketAPI.marketBlacklist = {}

-- Main initialization function
function GlobalMarketAPI.init()
    GlobalMarketAPI.loadBasegameDefaults()
    GlobalMarketAPI.loadExternalModExtensions()
    GlobalMarketAPI.loadPlayerFallback()
end

-- =========================================================================
-- DATA COLLECTION
-- =========================================================================

-- PRIORITY 1: Hardcoded definitions for basegame items
function GlobalMarketAPI.loadBasegameDefaults()
    -- Basegame liquid categories
    table.insert(GlobalMarketAPI.liquidCategories, "LIQUID")
    table.insert(GlobalMarketAPI.liquidCategories, "SLURRYTANK")
    table.insert(GlobalMarketAPI.liquidCategories, "SPRAYER")

    -- Basegame Whitelist: Force market registration despite showOnPriceTable="false"
    local basegameWhitelist = {
        "SILAGE_ADDITIVE", "PIGFOOD", "MINERAL_FEED", "TREESAPLINGS",
        "DEF", "BALE_NET", "BALE_TWINE", "BALE_WRAP", "METHANE"
    }
    for _, fillType in ipairs(basegameWhitelist) do
        GlobalMarketAPI.registerToWhitelist(fillType, true)
    end

    -- Basegame Blacklist: Strictly forbidden from the market
    local basegameBlacklist = {
        "AIR", "WEED", "SNOW", "ELECTRICCHARGE", "TARP", "MEADOW", "FORAGE_MIXING",
        "WHEAT_CUT", "BARLEY_CUT", "OAT_CUT", "CANOLA_CUT", "SOYBEAN_CUT ROADSALT"
    }
    for _, fillType in ipairs(basegameBlacklist) do
        GlobalMarketAPI.registerToBlacklist(fillType, true)
    end
end

-- PRIORITY 2: Scans all active mods for a 'gm_customs.xml'
function GlobalMarketAPI.loadExternalModExtensions()
    local schema = XMLSchema.new("GMCustomsExtension")
    GlobalMarketAPI.registerSchemaElements(schema)

    for _, mod in ipairs(g_modManager:getActiveMods()) do
        local xmlPath = mod.modDir .. "gm_customs.xml"

        if fileExists(xmlPath) then
            local xmlFile = XMLFile.load("GMExtension", xmlPath, schema)
            if xmlFile ~= nil then
                GlobalMarketAPI.parseXMLToAPI(xmlFile, true)
                xmlFile:delete()
            end
        end
    end
end

-- PRIORITY 3: Player Fallback (Lowest Priority)
function GlobalMarketAPI.loadPlayerFallback()
    -- Use g_currentModName to dynamically get the mod folder name (fallback if nil)
    local modName = g_currentModName or "FS25_GlobalMarket"
    local settingsPath = getUserProfileAppPath() .. "modSettings/" .. modName .. "/"
    local xmlPath = settingsPath .. "gm_fallback.xml"

    -- Create folder if it doesn't exist, so the player knows where to put the file
    if not fileExists(settingsPath) then
        createFolder(settingsPath)
    end

    if fileExists(xmlPath) then
        local schema = XMLSchema.new("GMFallbackExtension")
        GlobalMarketAPI.registerSchemaElements(schema)

        local xmlFile = XMLFile.load("GMFallback", xmlPath, schema)
        if xmlFile ~= nil then
            -- false = This is a fallback, must not overwrite existing entries
            GlobalMarketAPI.parseXMLToAPI(xmlFile, false)
            xmlFile:delete()
        end
    end
end

-- =========================================================================
-- HELPER & REGISTRATION LOGIC
-- =========================================================================

function GlobalMarketAPI.registerSchemaElements(schema)
    schema:register(XMLValueType.STRING, "globalMarket.finance.liquidCategories.category(?)#name", "Name of the custom liquid category")
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.whitelist.fillType(?)#name", "Name of the fillType to whitelist")
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.blacklist.fillType(?)#name", "Name of the fillType to blacklist")
end

function GlobalMarketAPI.parseXMLToAPI(xmlFile, isPriority)
    xmlFile:iterate("globalMarket.finance.liquidCategories.category", function(_, key)
        local catName = xmlFile:getValue(key .. "#name")
        if catName ~= nil then
            GlobalMarketAPI.registerLiquidCategory(catName)
        end
    end)

    xmlFile:iterate("globalMarket.marketRegistration.whitelist.fillType", function(_, key)
        local fillTypeName = xmlFile:getValue(key .. "#name")
        if fillTypeName ~= nil then
            GlobalMarketAPI.registerToWhitelist(fillTypeName, isPriority)
        end
    end)

    xmlFile:iterate("globalMarket.marketRegistration.blacklist.fillType", function(_, key)
        local fillTypeName = xmlFile:getValue(key .. "#name")
        if fillTypeName ~= nil then
            GlobalMarketAPI.registerToBlacklist(fillTypeName, isPriority)
        end
    end)
end

function GlobalMarketAPI.isFillTypeLocked(upperName)
    return table.hasElement(GlobalMarketAPI.marketBlacklist, upperName) or table.hasElement(GlobalMarketAPI.marketWhitelist, upperName)
end

function GlobalMarketAPI.registerLiquidCategory(categoryName)
    local upperName = string.upper(categoryName)
    if not table.hasElement(GlobalMarketAPI.liquidCategories, upperName) then
        table.insert(GlobalMarketAPI.liquidCategories, upperName)
    end
end

function GlobalMarketAPI.registerToWhitelist(fillTypeName, isPriority)
    local upperName = string.upper(fillTypeName)

    -- If it has no priority (Fallback) and the type is already defined -> Block!
    if not isPriority and GlobalMarketAPI.isFillTypeLocked(upperName) then
        return
    end

    if not table.hasElement(GlobalMarketAPI.marketWhitelist, upperName) then
        table.insert(GlobalMarketAPI.marketWhitelist, upperName)
    end
end

function GlobalMarketAPI.registerToBlacklist(fillTypeName, isPriority)
    local upperName = string.upper(fillTypeName)

    -- If it has no priority (Fallback) and the type is already defined -> Block!
    if not isPriority and GlobalMarketAPI.isFillTypeLocked(upperName) then
        return
    end

    if not table.hasElement(GlobalMarketAPI.marketBlacklist, upperName) then
        table.insert(GlobalMarketAPI.marketBlacklist, upperName)
    end
end

-- =========================================================================
-- PUBLIC GETTER API FOR CORE MODULES
-- =========================================================================

function GlobalMarketAPI.getLiquidCategories()
    return GlobalMarketAPI.liquidCategories
end

function GlobalMarketAPI.getIsFillTypeAllowed(fillType)
    if fillType == nil or fillType.name == nil then
        return false
    end

    local upperName = string.upper(fillType.name)

    -- 1. Blacklist is absolute
    if table.hasElement(GlobalMarketAPI.marketBlacklist, upperName) then
        return false
    end

    -- 2. Whitelist forces allowance
    if table.hasElement(GlobalMarketAPI.marketWhitelist, upperName) then
        return true
    end

    -- 3. Fallback to native Engine visibility flag
    return fillType.showOnPriceTable == true
end

-- Self-execution fallback (call this from your main init logic)
GlobalMarketAPI.init()
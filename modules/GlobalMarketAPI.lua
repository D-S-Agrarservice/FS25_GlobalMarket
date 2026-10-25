--
-- FS25 - GlobalMarketAPI
-- Description: Central API module acting as the single source of truth for external data.
-- Handles custom liquid categories, market whitelists, blacklists, container restrictions,
-- and optional UI category overrides (#19).
-- Priority: 1. Basegame (Hardcode) -> 2. Mods (gm_customs.xml) -> 3. Player Fallback (gm_fallback.xml)
--

GlobalMarketAPI = {}
GlobalMarketAPI.liquidCategories = {}
GlobalMarketAPI.marketWhitelist = {}
GlobalMarketAPI.marketBlacklist = {}
GlobalMarketAPI.containerRestrictions = {}
GlobalMarketAPI.uiCategoryOverrides = {}

-- Main initialization function
function GlobalMarketAPI.init()
    -- FIX: Clear memory tables to prevent "Ghost-Data" from previous savegames
    -- when a player leaves a server or switches maps without restarting the game.
    GlobalMarketAPI.liquidCategories = {}
    GlobalMarketAPI.marketWhitelist = {}
    GlobalMarketAPI.marketBlacklist = {}
    GlobalMarketAPI.containerRestrictions = {}
    GlobalMarketAPI.uiCategoryOverrides = {}

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
        "WHEAT_CUT", "BARLEY_CUT", "OAT_CUT", "CANOLA_CUT", "SOYBEAN_CUT", "ROADSALT",
        "WATER"
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
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.whitelist.fillType(?)#category", "Optional UI Detailed Category ID (GRAINS, ROOTS, FORAGE, SUPPLIES, ANIMAL, PALLETS, OTHER)")
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.whitelist.fillType(?)#compactCategory", "Optional UI Compact Category ID (CROPS_BULK, BALES_FORAGE, LIQUIDS, PALLETS_PRODUCTS)")
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.blacklist.fillType(?)#name", "Name of the fillType to blacklist")

    -- Optional standalone UI category overrides for fillTypes that already have showOnPriceTable="true"
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.uiCategories.fillType(?)#name", "Name of the fillType")
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.uiCategories.fillType(?)#category", "UI Detailed Category ID (GRAINS, ROOTS, FORAGE, SUPPLIES, ANIMAL, PALLETS, OTHER)")
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.uiCategories.fillType(?)#compactCategory", "UI Compact Category ID (CROPS_BULK, BALES_FORAGE, LIQUIDS, PALLETS_PRODUCTS)")

    -- Schema elements for container restrictions
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.containerRestrictions.restriction(?)#fillType", "Name of the fillType to restrict")
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.containerRestrictions.restriction(?).allow(?)#unitKey", "Allowed UI unit key (e.g., ui_gm_unit_ibc)")
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
            local cat = xmlFile:getValue(key .. "#category")
            local compactCat = xmlFile:getValue(key .. "#compactCategory")
            if cat ~= nil or compactCat ~= nil then
                GlobalMarketAPI.registerUiCategoryOverride(fillTypeName, cat, compactCat, isPriority)
            end
        end
    end)

    xmlFile:iterate("globalMarket.marketRegistration.uiCategories.fillType", function(_, key)
        local fillTypeName = xmlFile:getValue(key .. "#name")
        if fillTypeName ~= nil then
            local cat = xmlFile:getValue(key .. "#category")
            local compactCat = xmlFile:getValue(key .. "#compactCategory")
            if cat ~= nil or compactCat ~= nil then
                GlobalMarketAPI.registerUiCategoryOverride(fillTypeName, cat, compactCat, isPriority)
            end
        end
    end)

    xmlFile:iterate("globalMarket.marketRegistration.blacklist.fillType", function(_, key)
        local fillTypeName = xmlFile:getValue(key .. "#name")
        if fillTypeName ~= nil then
            GlobalMarketAPI.registerToBlacklist(fillTypeName, isPriority)
        end
    end)

    -- Parse container restrictions
    xmlFile:iterate("globalMarket.marketRegistration.containerRestrictions.restriction", function(_, key)
        local fillTypeName = xmlFile:getValue(key .. "#fillType")
        if fillTypeName ~= nil then
            xmlFile:iterate(key .. ".allow", function(_, allowKey)
                local unitKey = xmlFile:getValue(allowKey .. "#unitKey")
                if unitKey ~= nil then
                    GlobalMarketAPI.registerContainerRestriction(fillTypeName, unitKey, isPriority)
                end
            end)
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

function GlobalMarketAPI.registerContainerRestriction(fillTypeName, unitKey, isPriority)
    local upperName = string.upper(fillTypeName)
    local upperUnitKey = string.upper(unitKey)

    -- Priority Check: If Fallback tries to write, but Mod/Basegame already locked it -> Block!
    if not isPriority and GlobalMarketAPI.containerRestrictions[upperName] ~= nil then
        return
    end

    -- Initialize table for this fillType if it doesn't exist
    if GlobalMarketAPI.containerRestrictions[upperName] == nil then
        GlobalMarketAPI.containerRestrictions[upperName] = {}
    end

    if not table.hasElement(GlobalMarketAPI.containerRestrictions[upperName], upperUnitKey) then
        table.insert(GlobalMarketAPI.containerRestrictions[upperName], upperUnitKey)
    end
end

function GlobalMarketAPI.registerUiCategoryOverride(fillTypeName, categoryName, compactCategoryName, isPriority)
    if fillTypeName == nil then
        return
    end
    local upperName = string.upper(fillTypeName)

    -- Priority Check: Do not let fallback overwrite an existing Mod/Basegame UI category override
    if not isPriority and GlobalMarketAPI.uiCategoryOverrides[upperName] ~= nil then
        return
    end

    local entry = GlobalMarketAPI.uiCategoryOverrides[upperName] or {}
    if categoryName ~= nil and categoryName ~= "" then
        entry.category = string.upper(categoryName)
    end
    if compactCategoryName ~= nil and compactCategoryName ~= "" then
        entry.compactCategory = string.upper(compactCategoryName)
    end
    GlobalMarketAPI.uiCategoryOverrides[upperName] = entry
end

-- =========================================================================
-- PUBLIC GETTER API FOR CORE MODULES
-- =========================================================================

function GlobalMarketAPI.getLiquidCategories()
    return GlobalMarketAPI.liquidCategories
end

function GlobalMarketAPI.getUiCategoryOverride(fillTypeName)
    if fillTypeName == nil then
        return nil
    end
    return GlobalMarketAPI.uiCategoryOverrides[string.upper(fillTypeName)]
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

function GlobalMarketAPI.getIsContainerAllowedForFillType(fillType, unitKey)
    if fillType == nil or fillType.name == nil or unitKey == nil then
        return false
    end

    local upperName = string.upper(fillType.name)
    local upperUnitKey = string.upper(unitKey)

    local allowedContainers = GlobalMarketAPI.containerRestrictions[upperName]

    -- If no restriction is defined, default to allowing all containers (Basegame behavior)
    if allowedContainers == nil or #allowedContainers == 0 then
        return true
    end

    -- If restrictions exist, strictly check if the unitKey is permitted
    return table.hasElement(allowedContainers, upperUnitKey)
end

-- Self-execution fallback (call this from your main init logic)
GlobalMarketAPI.init()

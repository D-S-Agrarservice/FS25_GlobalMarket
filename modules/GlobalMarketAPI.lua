-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAPI.lua
-- Central 3-tier registry for fillType allowances, container rules, and metadata exports.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketAPI = {}
GlobalMarketAPI.liquidCategories = {}
GlobalMarketAPI.marketWhitelist = {}
GlobalMarketAPI.marketBlacklist = {}
GlobalMarketAPI.containerRestrictions = {}
GlobalMarketAPI.uiCategoryOverrides = {}

-- Main initialization function
function GlobalMarketAPI.init()
    -- Clear memory tables to prevent residual data from previous savegames
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
    schema:register(
        XMLValueType.STRING,
        "globalMarket.marketRegistration.whitelist.fillType(?)#category",
        "Optional UI Detailed Category ID (GRAINS, ROOTS, FORAGE, SUPPLIES, ANIMAL, PALLETS, OTHER)"
    )
    schema:register(
        XMLValueType.STRING,
        "globalMarket.marketRegistration.whitelist.fillType(?)#compactCategory",
        "Optional UI Compact Category ID (CROPS_BULK, BALES_FORAGE, LIQUIDS, PALLETS_PRODUCTS)"
    )
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.blacklist.fillType(?)#name", "Name of the fillType to blacklist")

    -- Optional standalone UI category overrides for fillTypes that already have showOnPriceTable="true"
    schema:register(XMLValueType.STRING, "globalMarket.marketRegistration.uiCategories.fillType(?)#name", "Name of the fillType")
    schema:register(
        XMLValueType.STRING,
        "globalMarket.marketRegistration.uiCategories.fillType(?)#category",
        "UI Detailed Category ID (GRAINS, ROOTS, FORAGE, SUPPLIES, ANIMAL, PALLETS, OTHER)"
    )
    schema:register(
        XMLValueType.STRING,
        "globalMarket.marketRegistration.uiCategories.fillType(?)#compactCategory",
        "UI Compact Category ID (CROPS_BULK, BALES_FORAGE, LIQUIDS, PALLETS_PRODUCTS)"
    )

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

-- =========================================================================
-- BACKEND WHITELIST METADATA RESOLUTION
-- =========================================================================

GlobalMarketAPI.WHITELIST_ROOT_VEG = {
    POTATO = true, SUGARBEET = true, SUGARBEET_CUT = true, BEETROOT = true,
    CARROT = true, PARSNIP = true, ONION = true, GARLIC = true,
    CABBAGE = true, REDCABBAGE = true
}

GlobalMarketAPI.WHITELIST_GREENS_SPECIAL = {
    SPINACH = true, GREENBEAN = true, PEA = true, OLIVE = true, GRAPE = true,
    SUGARCANE = true, HOPS = true, LAVENDER = true, POPLAR = true,
    WOODCHIPS = true, WOOD = true, TREE = true, STONE = true
}

GlobalMarketAPI.WHITELIST_BALES_SILAGE = {
    GRASS = true, GRASS_WINDROW = true, DRYGRASS = true, DRYGRASS_WINDROW = true,
    STRAW = true, SILAGE = true, CHAFF = true, FORAGE = true, FORAGE_MIXING = true,
    COTTON = true, ALFALFA = true, ALFALFA_WINDROW = true, DRYALFALFA = true, DRYALFALFA_WINDROW = true,
    CLOVER = true, CLOVER_WINDROW = true, DRYCLOVER = true, DRYCLOVER_WINDROW = true,
    MAIZESILAGE = true, WETGRASS_WINDROW = true,
    ROUNDBALE = true, ROUNDBALE_GRASS = true, ROUNDBALE_DRYGRASS = true, ROUNDBALE_COTTON = true, ROUNDBALE_WOOD = true,
    SQUAREBALE = true, SQUAREBALE_GRASS = true, SQUAREBALE_DRYGRASS = true, SQUAREBALE_COTTON = true, SQUAREBALE_WOOD = true
}

GlobalMarketAPI.WHITELIST_INPUTS_FERT = {
    SEEDS = true, FERTILIZER = true, LIME = true, MANURE = true, COMPOST = true,
    PIGFOOD = true, MINERAL_FEED = true, CHICKENFOOD = true, HORSEFOOD = true,
    BALE_NET = true, BALE_TWINE = true, BALE_WRAP = true,
    RICESAPLINGS = true, TREESAPLINGS = true, ROADSALT = true
}

-- Builds a deterministic origin map ("BASEGAME" or exact mod folder name) for all registered fillTypes.
function GlobalMarketAPI.buildFillTypeSourceMap()
    local sourceMap = {}

    -- 1. Basegame ground truth from data/maps/maps_fillTypes.xml
    local baseXml = XMLFile.load("gmBaseFillTypes", "data/maps/maps_fillTypes.xml")
    if baseXml ~= nil then
        local rootName = baseXml:getRootName() or "map"
        baseXml:iterate(rootName .. ".fillTypes.fillType", function(_, ftKey)
            local ftName = baseXml:getString(ftKey .. "#name")
            if ftName ~= nil and ftName ~= "" then
                sourceMap[string.upper(ftName)] = "BASEGAME"
            end
        end)
        baseXml:delete()
    end

    -- 2. Mod fillTypes registered via g_fillTypeManager.modsToLoad ({ xmlFilename, baseDirectory, customEnvironment })
    if g_fillTypeManager ~= nil and g_fillTypeManager.modsToLoad ~= nil then
        for _, modData in ipairs(g_fillTypeManager.modsToLoad) do
            local xmlFilename = modData[1]
            local customEnv = modData[3]
            if xmlFilename ~= nil and customEnv ~= nil and customEnv ~= "" then
                local modXml = XMLFile.loadIfExists("gmModFillTypes", xmlFilename)
                if modXml ~= nil then
                    local rootName = modXml:getRootName() or "map"
                    modXml:iterate(rootName .. ".fillTypes.fillType", function(_, ftKey)
                        local ftName = modXml:getString(ftKey .. "#name")
                        if ftName ~= nil and ftName ~= "" then
                            local upperName = string.upper(ftName)
                            if sourceMap[upperName] == nil then
                                sourceMap[upperName] = customEnv
                            end
                        end
                    end)
                    modXml:delete()
                end
            end
        end
    end

    -- 3. Active mod directory prefixes for asset/store path matching on remaining fillTypes
    local activeModPrefixes = {}
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        for _, mod in ipairs(g_modManager:getActiveMods()) do
            if mod.modDir ~= nil and mod.modName ~= nil then
                table.insert(activeModPrefixes, {
                    modDirLower = string.lower(mod.modDir),
                    modName = mod.modName
                })
            end
        end
    end

    return sourceMap, activeModPrefixes
end

-- Resolves backend whitelist metadata attributes (category, type, source) for a given FillTypeDesc.
function GlobalMarketAPI.resolveWhitelistMetadata(fillTypeDesc, sourceMap, activeModPrefixes)
    if fillTypeDesc == nil or fillTypeDesc.name == nil then
        return "PRODUCTS_PALLETS", "BULK", "BASEGAME"
    end

    local nameUpper = string.upper(fillTypeDesc.name)
    local ftIndex = fillTypeDesc.index

    -- 1. Resolve #type ("BULK" | "BALE" | "PALLET")
    local itemType = "BULK"
    local isPalletSupply = (GlobalMarketUI ~= nil and GlobalMarketUI.LOOKUP_PALLET_SUPPLIES ~= nil and GlobalMarketUI.LOOKUP_PALLET_SUPPLIES[nameUpper] == true)

    if fillTypeDesc.isBulkType == true then
        itemType = "BULK"
    elseif not isPalletSupply and (
        fillTypeDesc.isBaleType == true
        or nameUpper == "COTTON"
        or string.find(nameUpper, "BALE", 1, true) ~= nil
        or (ftIndex ~= nil and g_baleManager ~= nil and g_baleManager.getIsFillTypeSupported ~= nil and g_baleManager:getIsFillTypeSupported(ftIndex))
    ) then
        itemType = "BALE"
    elseif fillTypeDesc.isPalletType == true
        or isPalletSupply
        or (fillTypeDesc.palletFilename ~= nil and fillTypeDesc.palletFilename ~= "")
        or (GlobalMarketStoreCache ~= nil and GlobalMarketStoreCache.cache ~= nil and GlobalMarketStoreCache.cache[nameUpper] ~= nil) then
        itemType = "PALLET"
    end

    -- 2. Resolve #category ("GRAINS" | "ROOT_VEG" | "GREENS_SPECIAL" | "BALES_SILAGE" | "LIQUIDS" | "INPUTS_FERT" | "PRODUCTS_PALLETS")
    local category = "PRODUCTS_PALLETS"
    local isLiquid = (GlobalMarketUI ~= nil and GlobalMarketUI.LOOKUP_LIQUIDS ~= nil and GlobalMarketUI.LOOKUP_LIQUIDS[nameUpper] == true)

    if not isLiquid and ftIndex ~= nil and g_fillTypeManager ~= nil then
        if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "LIQUID")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SPRAYER")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SLURRYTANK") then
            isLiquid = true
        else
            for _, catName in ipairs(GlobalMarketAPI.getLiquidCategories()) do
                if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, catName) then
                    isLiquid = true
                    break
                end
            end
            if not isLiquid and GlobalMarketAPI.containerRestrictions ~= nil and GlobalMarketAPI.containerRestrictions[nameUpper] ~= nil then
                if table.hasElement(GlobalMarketAPI.containerRestrictions[nameUpper], "UI_GM_UNIT_IBC") then
                    isLiquid = true
                end
            end
        end
    end

    if isLiquid then
        category = "LIQUIDS"
    elseif GlobalMarketAPI.WHITELIST_ROOT_VEG[nameUpper] then
        category = "ROOT_VEG"
    elseif GlobalMarketAPI.WHITELIST_GREENS_SPECIAL[nameUpper] then
        category = "GREENS_SPECIAL"
    elseif GlobalMarketAPI.WHITELIST_BALES_SILAGE[nameUpper] then
        category = "BALES_SILAGE"
    elseif GlobalMarketAPI.WHITELIST_INPUTS_FERT[nameUpper] then
        category = "INPUTS_FERT"
    elseif GlobalMarketUI ~= nil and GlobalMarketUI.LOOKUP_GRAINS ~= nil and GlobalMarketUI.LOOKUP_GRAINS[nameUpper] then
        category = "GRAINS"
    elseif GlobalMarketUI ~= nil and GlobalMarketUI.LOOKUP_ANIMAL ~= nil and GlobalMarketUI.LOOKUP_ANIMAL[nameUpper] then
        category = "PRODUCTS_PALLETS"
    elseif ftIndex ~= nil and g_fillTypeManager ~= nil then
        if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "COMBINE")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "FARMSILO") then
            category = "GRAINS"
        elseif g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "ROOT_CROPS")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "VEGETABLES")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "TOPLIFTINGHARVESTER") then
            category = "ROOT_VEG"
        elseif g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "PLANTER_SMALL") then
            category = "GREENS_SPECIAL"
        elseif g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "FORAGEWAGON")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "MIXERWAGON")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "WINDROW")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "HAYLOFT")
            or itemType == "BALE" then
            category = "BALES_SILAGE"
        elseif g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SPREADER")
            or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "MANURESPREADER") then
            category = "INPUTS_FERT"
        elseif itemType == "BULK" then
            category = "GREENS_SPECIAL"
        else
            category = "PRODUCTS_PALLETS"
        end
    end

    -- 3. Resolve #source ("BASEGAME" or exact mod folder name)
    local source = (sourceMap ~= nil and sourceMap[nameUpper]) or nil
    if source == nil then
        local candidatePaths = {
            fillTypeDesc.hudOverlayFilename,
            fillTypeDesc.palletFilename,
            fillTypeDesc.layerTextures ~= nil and fillTypeDesc.layerTextures.diffuseMapFilename or nil
        }

        if GlobalMarketStoreCache ~= nil and GlobalMarketStoreCache.cache ~= nil and GlobalMarketStoreCache.cache[nameUpper] ~= nil then
            local firstCached = GlobalMarketStoreCache.cache[nameUpper][1]
            if firstCached ~= nil and firstCached.xmlFilename ~= nil then
                table.insert(candidatePaths, firstCached.xmlFilename)
            end
        end

        if activeModPrefixes ~= nil then
            for _, rawPath in ipairs(candidatePaths) do
                if rawPath ~= nil and rawPath ~= "" then
                    local lowerPath = string.lower(rawPath)
                    for _, modEntry in ipairs(activeModPrefixes) do
                        if string.startsWith(lowerPath, modEntry.modDirLower) then
                            source = modEntry.modName
                            break
                        end
                    end
                    if source ~= nil then
                        break
                    end
                end
            end
        end

        if source == nil then
            local mapEnv = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.customEnvironment or nil
            if mapEnv ~= nil and mapEnv ~= "" then
                source = mapEnv
            else
                source = "BASEGAME"
            end
        end
    end

    return category, itemType, source
end

-- Initialize basegame defaults on script load (re-initialized with map/mod scan during loadMap)
GlobalMarketAPI.init()

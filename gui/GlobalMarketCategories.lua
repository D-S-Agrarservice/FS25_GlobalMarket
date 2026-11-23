-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketCategories.lua
-- Category view modes, fillType lookup tables and classification helpers of the spot market
-- (Detailed / Compact / A-Z). Also used by the API, storage and dialogs for sorting and search.
-- Author: D-S-Agrarservice
-- =========================================================================================

-- Switchable Category View Modes
GlobalMarketUI.CATEGORY_MODE_DETAILED = 1
GlobalMarketUI.CATEGORY_MODE_COMPACT  = 2
GlobalMarketUI.CATEGORY_MODE_FLAT     = 3

GlobalMarketUI.DETAILED_CATEGORIES = {
    { id = "GRAINS",   l10n = "ui_gm_cat_detail_grains",   fallback = "Grains & Combinables" },
    { id = "ROOTS",    l10n = "ui_gm_cat_detail_roots",    fallback = "Root Crops, Vegetables & Specialty" },
    { id = "FORAGE",   l10n = "ui_gm_cat_detail_forage",   fallback = "Forage, Grass & Bales" },
    { id = "SUPPLIES", l10n = "ui_gm_cat_detail_supplies", fallback = "Seeds, Fertilizer & Supplies" },
    { id = "ANIMAL",   l10n = "ui_gm_cat_detail_animal",   fallback = "Animal Products" },
    { id = "PALLETS",  l10n = "ui_gm_cat_detail_pallets",  fallback = "Pallets & Productions" },
    { id = "OTHER",    l10n = "ui_gm_cat_detail_other",    fallback = "Forestry, Bulk & Other" }
}

GlobalMarketUI.COMPACT_CATEGORIES = {
    { id = "CROPS_BULK",       l10n = "ui_gm_cat_compact_crops",   fallback = "Field Crops & Bulk" },
    { id = "BALES_FORAGE",     l10n = "ui_gm_cat_compact_bales",   fallback = "Bales & Forage" },
    { id = "LIQUIDS",          l10n = "ui_gm_cat_compact_liquids", fallback = "Liquids" },
    { id = "PALLETS_PRODUCTS", l10n = "ui_gm_cat_compact_pallets", fallback = "Pallets & Productions" }
}

-- Explicit FillType lookup tables for fast, reliable classification across vanilla and mod maps
GlobalMarketUI.LOOKUP_GRAINS = {
    WHEAT = true, BARLEY = true, OAT = true, CANOLA = true, SORGHUM = true,
    SUNFLOWER = true, SOYBEAN = true, MAIZE = true, RICE = true, RICELONGGRAIN = true,
    RYE = true, SPELT = true, TRITICALE = true, MILLET = true, POPPY = true,
    MUSTARD = true, LINSEED = true, LENTILS = true, CHICKPEAS = true, BUCKWHEAT = true,
    HEMP = true, FLAX = true, GRAINMAIZE = true, CORN = true
}

GlobalMarketUI.LOOKUP_ROOTS = {
    POTATO = true, SUGARBEET = true, SUGARBEET_CUT = true, BEETROOT = true,
    CARROT = true, PARSNIP = true, GREENBEAN = true, PEA = true, SPINACH = true,
    OLIVE = true, GRAPE = true, SUGARCANE = true, ONION = true, HOPS = true, LAVENDER = true
}

GlobalMarketUI.LOOKUP_FORAGE = {
    GRASS = true, GRASS_WINDROW = true, DRYGRASS = true, DRYGRASS_WINDROW = true,
    STRAW = true, SILAGE = true, CHAFF = true, FORAGE = true, FORAGE_MIXING = true,
    PIGFOOD = true, MINERAL_FEED = true, COTTON = true, CHICKENFOOD = true, HORSEFOOD = true,
    ALFALFA = true, ALFALFA_WINDROW = true, DRYALFALFA = true, DRYALFALFA_WINDROW = true,
    CLOVER = true, CLOVER_WINDROW = true, DRYCLOVER = true, DRYCLOVER_WINDROW = true,
    MAIZESILAGE = true, WETGRASS_WINDROW = true,
    ROUNDBALE = true, ROUNDBALE_GRASS = true, ROUNDBALE_DRYGRASS = true, ROUNDBALE_COTTON = true,
    SQUAREBALE = true, SQUAREBALE_GRASS = true, SQUAREBALE_DRYGRASS = true, SQUAREBALE_COTTON = true
}

GlobalMarketUI.LOOKUP_SUPPLIES = {
    SEEDS = true, FERTILIZER = true, LIQUIDFERTILIZER = true, LIME = true,
    HERBICIDE = true, MANURE = true, LIQUIDMANURE = true, DIGESTATE = true,
    SILAGE_ADDITIVE = true, DIESEL = true, DEF = true, WATER = true,
    ROADSALT = true, METHANE = true, ELECTRICCHARGE = true,
    BALE_NET = true, BALE_TWINE = true, BALE_WRAP = true,
    LIQUIDSEEDTREATMENT = true, COMPOST = true, RICESAPLINGS = true, TREESAPLINGS = true
}

-- Non-bulk operating supplies traded exclusively as pallets/rolls (classified as Supplies in Detailed, Pallets in Compact)
GlobalMarketUI.LOOKUP_PALLET_SUPPLIES = {
    BALE_NET = true, BALE_TWINE = true, BALE_WRAP = true,
    RICESAPLINGS = true, TREESAPLINGS = true
}

GlobalMarketUI.LOOKUP_ANIMAL = {
    MILK = true, BUFFALOMILK = true, GOATMILK = true,
    MILK_BOTTLED = true, BUFFALOMILK_BOTTLED = true, GOATMILK_BOTTLED = true,
    EGG = true, WOOL = true, HONEY = true, BUTTER = true,
    CHEESE = true, BUFFALOMOZZARELLA = true, GOATCHEESE = true,
    MEAT = true, SAUSAGE = true, LEATHER = true
}

GlobalMarketUI.LOOKUP_LIQUIDS = {
    MILK = true, BUFFALOMILK = true, GOATMILK = true, WATER = true,
    DIESEL = true, DEF = true, LIQUIDFERTILIZER = true, HERBICIDE = true,
    LIQUIDMANURE = true, DIGESTATE = true, SILAGE_ADDITIVE = true,
    LIQUIDSEEDTREATMENT = true, METHANE = true
}

GlobalMarketUI.LOOKUP_FORESTRY_OTHER = {
    WOOD = true, WOODCHIPS = true, POPLAR = true, TREE = true,
    ROUNDBALE_WOOD = true, SQUAREBALE_WOOD = true, STONE = true, SNOW = true, TARP = true
}

-- Normalizes localized fillType titles for alphabetical sorting and search matching across languages (DE/EN/FR/ES/etc.)
function GlobalMarketUI.normalizeSortTitle(title)
    if title == nil or title == "" then
        return ""
    end
    local s = title
    s = string.gsub(s, "Ä", "A"):gsub("ä", "a")
    s = string.gsub(s, "Ö", "O"):gsub("ö", "o")
    s = string.gsub(s, "Ü", "U"):gsub("ü", "u")
    s = string.gsub(s, "ß", "ss")
    s = string.gsub(s, "Á", "A"):gsub("á", "a"):gsub("À", "A"):gsub("à", "a"):gsub("Â", "A"):gsub("â", "a")
    s = string.gsub(s, "É", "E"):gsub("é", "e"):gsub("È", "E"):gsub("è", "e"):gsub("Ê", "E"):gsub("ê", "e")
    s = string.gsub(s, "Í", "I"):gsub("í", "i"):gsub("Ì", "I"):gsub("ì", "i"):gsub("Î", "I"):gsub("î", "i")
    s = string.gsub(s, "Ó", "O"):gsub("ó", "o"):gsub("Ò", "O"):gsub("ò", "o"):gsub("Ô", "O"):gsub("ô", "o")
    s = string.gsub(s, "Ú", "U"):gsub("ú", "u"):gsub("Ù", "U"):gsub("ù", "u"):gsub("Û", "U"):gsub("û", "u")
    s = string.gsub(s, "Ñ", "N"):gsub("ñ", "n"):gsub("Ç", "C"):gsub("ç", "c")
    return string.lower(s)
end

-- Lookup maps for optional XML UI category overrides (gm_customs.xml / gm_fallback.xml)
GlobalMarketUI.DETAILED_CATEGORY_BY_ID = {
    GRAINS = 1, ROOTS = 2, FORAGE = 3, SUPPLIES = 4, ANIMAL = 5, PALLETS = 6, OTHER = 7,
    CROPS_BULK = 1, BALES_FORAGE = 3, LIQUIDS = 4, PALLETS_PRODUCTS = 6
}

GlobalMarketUI.COMPACT_CATEGORY_BY_ID = {
    CROPS_BULK = 1, BALES_FORAGE = 2, LIQUIDS = 3, PALLETS_PRODUCTS = 4,
    GRAINS = 1, ROOTS = 1, FORAGE = 2, ANIMAL = 4, PALLETS = 4
}

-- Resolves the 1..7 Detailed Category index for a given fillType name
function GlobalMarketUI.getDetailedCategoryIndex(fillTypeName)
    if fillTypeName == nil then
        return 7
    end
    local nameUpper = string.upper(fillTypeName)

    -- 1. Check optional explicit XML override from GlobalMarketAPI (gm_customs.xml / gm_fallback.xml)
    if GlobalMarketAPI ~= nil and GlobalMarketAPI.getUiCategoryOverride ~= nil then
        local override = GlobalMarketAPI.getUiCategoryOverride(nameUpper)
        if override ~= nil and override.category ~= nil then
            local mapped = GlobalMarketUI.DETAILED_CATEGORY_BY_ID[override.category]
            if mapped ~= nil then
                return mapped
            end
        end
    end

    -- 2. Check explicit basegame & common mod lookup tables
    if GlobalMarketUI.LOOKUP_FORESTRY_OTHER[nameUpper] then
        return 7
    end
    if GlobalMarketUI.LOOKUP_GRAINS[nameUpper] then
        return 1
    end
    if GlobalMarketUI.LOOKUP_ROOTS[nameUpper] then
        return 2
    end
    if GlobalMarketUI.LOOKUP_FORAGE[nameUpper] then
        return 3
    end
    if GlobalMarketUI.LOOKUP_SUPPLIES[nameUpper] then
        return 4
    end
    if GlobalMarketUI.LOOKUP_ANIMAL[nameUpper] then
        return 5
    end

    -- 3. Check GIANTS fillTypeCategories, GlobalMarketAPI liquid/IBC rules, and GlobalMarketStoreCache
    if g_fillTypeManager ~= nil then
        local ftDesc = g_fillTypeManager:getFillTypeByName(nameUpper)
        if ftDesc ~= nil then
            local ftIndex = ftDesc.index
            if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "COMBINE")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "FARMSILO") then
                return 1
            end
            if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "ROOT_CROPS")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "VEGETABLES")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "TOPLIFTINGHARVESTER")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "PLANTER_SMALL") then
                return 2
            end
            if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "FORAGEWAGON")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "MIXERWAGON")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "WINDROW")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "HAYLOFT")
                or ftDesc.isBaleType == true then
                return 3
            end
            if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SPRAYER")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SPREADER")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SLURRYTANK")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "MANURESPREADER")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "PRODUCT_BGA") then
                return 4
            end

            -- Check custom mod liquid categories (e.g. CCM_ADDITIVE / GRIST_ADDITIVE for LUPROSIL) and IBC restrictions
            if GlobalMarketAPI ~= nil then
                if GlobalMarketAPI.getLiquidCategories ~= nil then
                    for _, catName in ipairs(GlobalMarketAPI.getLiquidCategories()) do
                        if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, catName) then
                            return 4
                        end
                    end
                end
                if GlobalMarketAPI.containerRestrictions ~= nil and GlobalMarketAPI.containerRestrictions[nameUpper] ~= nil then
                    if table.hasElement(GlobalMarketAPI.containerRestrictions[nameUpper], "UI_GM_UNIT_IBC") then
                        return 4
                    end
                end
            end

            if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "PRODUCT")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SELLINGSTATION_PRODUCTS")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SELLINGSTATION_PRODUCTSFOOD")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "PIECE")
                or ftDesc.isPalletType == true
                or (not ftDesc.isBulkType and not ftDesc.isBaleType and (
                    (ftDesc.palletFilename ~= nil and ftDesc.palletFilename ~= "")
                    or (GlobalMarketStoreCache ~= nil and GlobalMarketStoreCache.cache ~= nil and GlobalMarketStoreCache.cache[nameUpper] ~= nil)
                )) then
                return 6
            end
        end
    end

    return 7
end

-- Resolves the 1..4 Compact Category index for a given fillType name
function GlobalMarketUI.getCompactCategoryIndex(fillTypeName)
    if fillTypeName == nil then
        return 1
    end
    local nameUpper = string.upper(fillTypeName)

    -- 0. Check optional explicit XML override from GlobalMarketAPI (gm_customs.xml / gm_fallback.xml)
    if GlobalMarketAPI ~= nil and GlobalMarketAPI.getUiCategoryOverride ~= nil then
        local override = GlobalMarketAPI.getUiCategoryOverride(nameUpper)
        if override ~= nil then
            if override.compactCategory ~= nil and GlobalMarketUI.COMPACT_CATEGORY_BY_ID[override.compactCategory] ~= nil then
                return GlobalMarketUI.COMPACT_CATEGORY_BY_ID[override.compactCategory]
            elseif override.category ~= nil and GlobalMarketUI.COMPACT_CATEGORY_BY_ID[override.category] ~= nil then
                return GlobalMarketUI.COMPACT_CATEGORY_BY_ID[override.category]
            end
        end
    end

    -- 1. Check Liquids first (includes liquid manure, liquid fertilizer, milk, water, diesel, and custom API liquid/IBC categories)
    if GlobalMarketUI.LOOKUP_LIQUIDS[nameUpper] then
        return 3
    end

    if g_fillTypeManager ~= nil then
        local ftDesc = g_fillTypeManager:getFillTypeByName(nameUpper)
        if ftDesc ~= nil then
            local ftIndex = ftDesc.index
            if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "LIQUID")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SPRAYER")
                or g_fillTypeManager:getIsFillTypeInCategory(ftIndex, "SLURRYTANK") then
                return 3
            end
            if GlobalMarketAPI ~= nil then
                if GlobalMarketAPI.getLiquidCategories ~= nil then
                    for _, catName in ipairs(GlobalMarketAPI.getLiquidCategories()) do
                        if g_fillTypeManager:getIsFillTypeInCategory(ftIndex, catName) then
                            return 3
                        end
                    end
                end
                if GlobalMarketAPI.containerRestrictions ~= nil and GlobalMarketAPI.containerRestrictions[nameUpper] ~= nil then
                    if table.hasElement(GlobalMarketAPI.containerRestrictions[nameUpper], "UI_GM_UNIT_IBC") then
                        return 3
                    end
                end
            end
        end
    end

    -- 2. Check non-bulk pallet operating supplies (Bale Twine, Bale Net, Bale Wrap, Rice/Tree Saplings)
    if GlobalMarketUI.LOOKUP_PALLET_SUPPLIES[nameUpper] then
        return 4
    end

    -- 3. Map from Detailed Category for remaining types
    local detailedIdx = GlobalMarketUI.getDetailedCategoryIndex(nameUpper)
    if detailedIdx == 3 then
        -- Forage, Grass & Bales
        return 2
    elseif detailedIdx == 5 or detailedIdx == 6 then
        -- Animal Products (non-liquid) & Pallets/Productions
        return 4
    end

    -- 4. Fallback for custom mod pallet/piece items where isPalletType was omitted on <fillType>
    if g_fillTypeManager ~= nil then
        local ftDesc = g_fillTypeManager:getFillTypeByName(nameUpper)
        if ftDesc ~= nil and not ftDesc.isBulkType and not ftDesc.isBaleType then
            if ftDesc.isPalletType == true
                or (ftDesc.palletFilename ~= nil and ftDesc.palletFilename ~= "")
                or g_fillTypeManager:getIsFillTypeInCategory(ftDesc.index, "PIECE")
                or g_fillTypeManager:getIsFillTypeInCategory(ftDesc.index, "PRODUCT")
                or (GlobalMarketStoreCache ~= nil and GlobalMarketStoreCache.cache ~= nil and GlobalMarketStoreCache.cache[nameUpper] ~= nil) then
                return 4
            end
        end
    end

    -- Default: Field Crops & Bulk (Grains, Root Crops, Seeds, Solid Fertilizer, Lime, Woodchips, Stones, etc.)
    return 1
end

--
-- FS25 - GlobalMarketStoreCache
-- Description: Pre-caches available shop items (BigBags, Pallets, IBCs) at mission start.
-- PHASE 1: Store Item Scan (Strict XML parsing, deduplication, upgrade logic).
-- PHASE 2: Engine FillType Bridge (Injects engine-defined fallback pallets if allowed by API).
--

GlobalMarketStoreCache = {}
GlobalMarketStoreCache.cache = {}
GlobalMarketStoreCache.isInitialized = false

-- ALIAS INTERCEPTOR: Maps filename keywords to custom Global Market identities.
local INTERCEPTOR_ALIASES = {
    ["chickenfood"] = "CHICKENFOOD",
    ["horsefood"]   = "HORSEFOOD",
    ["pigfood"]     = "PIGFOOD",
    ["roadsalt"]    = "ROADSALT"
}

local function getInterceptorAlias(xmlPathLower)
    for keyword, alias in pairs(INTERCEPTOR_ALIASES) do
        if string.find(xmlPathLower, keyword) then
            return alias
        end
    end
    return nil
end

-- Enhanced path normalizer to fix engine slash mixing
local function normalizePath(path)
    if path == nil then return "" end
    local p = string.lower(path)
    p = string.gsub(p, "\\", "/")
    p = string.gsub(p, "^%$data/", "data/")
    return p
end

-- Safely fetches localized text to prevent "Missing '...'" UI bugs
local function getLocalizedText(key, fallback)
    if g_i18n ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return fallback
end

-- Checks if the native store item name is too generic for a standalone UI dropdown entry
local function isGenericItemName(name)
    if name == nil or name == "" then return true end
    local n = string.lower(name)
    n = string.gsub(n, "[ %-]", "")
    return n == "pallet" or n == "palette" or n == "bigbag" or n == "ibc" or n == "liquidtank"
end

-- Runs exactly ONCE during mission start
function GlobalMarketStoreCache.init()
    if GlobalMarketStoreCache.isInitialized then return end
    if g_storeManager == nil or g_storeManager.items == nil then return end

    GlobalMarketStoreCache.cache = {}
    local itemCount = 0

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("StoreCache: Initializing Global Market format dictionary...")
    end

    -- =========================================================================
    -- PHASE 1: STORE ITEM SCAN (Specific packaged goods, MultiPurchases, etc.)
    -- =========================================================================
    for _, item in ipairs(g_storeManager:getItems()) do
        local xmlPath = item.xmlFilename or ""
        local normPath = normalizePath(xmlPath)
        local catLower = item.categoryName and string.lower(item.categoryName) or ""

        local isRelevant = false
        local unitKey = "ui_gm_unit_pallet"
        local formatSuffix = " (Pallet)"

        if string.find(catLower, "bigbags") then
            isRelevant = true
            unitKey = "ui_gm_unit_bigbag"
            formatSuffix = " (Bigbag)"
        elseif string.find(catLower, "bigbagpallets") then
            isRelevant = true
            unitKey = "ui_gm_unit_bigbagpallet"
            formatSuffix = " (Bigbag Pallet)"
        elseif string.find(catLower, "ibc") or string.find(catLower, "fertilizerherbicide") then
            isRelevant = true
            unitKey = "ui_gm_unit_ibc"
            formatSuffix = " (IBC)"
        elseif string.find(catLower, "pallets") or string.find(catLower, "animals") then
            isRelevant = true
            unitKey = "ui_gm_unit_pallet"
            formatSuffix = " (Pallet)"
        end

        if isRelevant then
            local xmlFile = XMLFile.load("GMCacheItem", xmlPath)
            if xmlFile ~= nil then
                local capacity = 0
                local engineFillTypeStr = ""
                local targetFormatXml = normPath

                local fillUnitRoot = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)"
                capacity = xmlFile:getFloat(fillUnitRoot .. "#capacity") or 0
                engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#fillTypes")

                if engineFillTypeStr == nil or engineFillTypeStr == "" then
                    engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#startFillType") or ""
                end

                local multiPurchaseXml = xmlFile:getString("vehicle.multipleItemPurchase#filename")
                if multiPurchaseXml ~= nil and multiPurchaseXml ~= "" then
                    local absolutePath = Utils.getFilename(multiPurchaseXml, item.baseDir)
                    targetFormatXml = normalizePath(absolutePath)
                end

                xmlFile:delete()

                if capacity <= 0 then capacity = 1000 end

                if engineFillTypeStr ~= "" then
                    local primaryFillType = string.match(engineFillTypeStr, "%S+")
                    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(primaryFillType)

                    if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then

                        local isContainerAllowed = true
                        if GlobalMarketAPI.getIsContainerAllowedForFillType ~= nil then
                            isContainerAllowed = GlobalMarketAPI.getIsContainerAllowedForFillType(fillTypeDesc, unitKey)
                        end

                        if isContainerAllowed then
                            local gmMarketKey = string.upper(fillTypeDesc.name)
                            local customAlias = getInterceptorAlias(targetFormatXml)
                            local baseName = item.name or ""

                            -- Override logic for intercepted aliases to bypass misleading engine L10n
                            if customAlias ~= nil then
                                gmMarketKey = customAlias
                                if customAlias == "CHICKENFOOD" then
                                    baseName = getLocalizedText("fillType_chickenFood", "Chicken Food")
                                elseif customAlias == "HORSEFOOD" then
                                    baseName = getLocalizedText("fillType_horseFood", "Horse Food")
                                elseif customAlias == "PIGFOOD" then
                                    baseName = getLocalizedText("fillType_pigFood", "Pig Food")
                                elseif customAlias == "ROADSALT" then
                                    baseName = getLocalizedText("fillType_roadSalt", "Road Salt")
                                end
                            elseif isGenericItemName(baseName) then
                                -- Rely on Engine FillType title for generic names
                                baseName = fillTypeDesc.title
                            end

                            if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                                GlobalMarketStoreCache.cache[gmMarketKey] = {}
                            end

                            local brandSuffix = ""
                            if item.brandIndex ~= nil and item.brandIndex ~= 0 then
                                local brand = g_brandManager:getBrandByIndex(item.brandIndex)
                                if brand ~= nil and brand.name ~= "NONE" then
                                    brandSuffix = " (" .. brand.title .. ")"
                                end
                            end

                            local displayTitle = baseName .. formatSuffix .. brandSuffix

                            -- Deduplication & Title Upgrade
                            local existingEntry = nil
                            for _, existing in ipairs(GlobalMarketStoreCache.cache[gmMarketKey]) do
                                if existing.xml == targetFormatXml then
                                    existingEntry = existing
                                    break
                                end
                            end

                            if existingEntry ~= nil then
                                if item.showInStore and not existingEntry.showInStore then
                                    existingEntry.title = displayTitle
                                    existingEntry.showInStore = true
                                end
                            else
                                table.insert(GlobalMarketStoreCache.cache[gmMarketKey], {
                                    title = displayTitle,
                                    xml = targetFormatXml,
                                    capacity = capacity,
                                    unitKey = unitKey,
                                    showInStore = item.showInStore
                                })
                                itemCount = itemCount + 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- =========================================================================
    -- PHASE 2: ENGINE FILLTYPE BRIDGE (Fallback for generic bulk-to-pallet)
    -- =========================================================================
    if g_fillTypeManager ~= nil and g_fillTypeManager.fillTypes ~= nil then
        for _, fillTypeDesc in pairs(g_fillTypeManager.fillTypes) do

            if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then
                if fillTypeDesc.palletFilename ~= nil and fillTypeDesc.palletFilename ~= "" then

                    local isContainerAllowed = true
                    if GlobalMarketAPI.getIsContainerAllowedForFillType ~= nil then
                        isContainerAllowed = GlobalMarketAPI.getIsContainerAllowedForFillType(fillTypeDesc, "ui_gm_unit_pallet")
                    end

                    if isContainerAllowed then
                        local gmMarketKey = string.upper(fillTypeDesc.name)
                        local targetFormatXml = normalizePath(fillTypeDesc.palletFilename)

                        if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                            GlobalMarketStoreCache.cache[gmMarketKey] = {}
                        end

                        local alreadyExists = false
                        for _, existing in ipairs(GlobalMarketStoreCache.cache[gmMarketKey]) do
                            if existing.xml == targetFormatXml then
                                alreadyExists = true
                                break
                            end
                        end

                        if not alreadyExists then
                            local storeItem = g_storeManager:getItemByXMLFilename(fillTypeDesc.palletFilename)
                            local palletTitle = storeItem ~= nil and storeItem.name or ""

                            -- Prefix generic generated pallets with their FillType
                            if isGenericItemName(palletTitle) then
                                palletTitle = fillTypeDesc.title .. " (Pallet)"
                            else
                                palletTitle = palletTitle .. " (Pallet)"
                            end

                            table.insert(GlobalMarketStoreCache.cache[gmMarketKey], {
                                title = palletTitle,
                                xml = targetFormatXml,
                                capacity = 1000,
                                unitKey = "ui_gm_unit_pallet",
                                showInStore = storeItem ~= nil and storeItem.showInStore or false
                            })
                            itemCount = itemCount + 1
                        end
                    end
                end
            end
        end
    end

    GlobalMarketStoreCache.isInitialized = true
end

-- Retrieves all available buying/selling formats (BigBags, Pallets, IBCs) for a specific Engine FillType
function GlobalMarketStoreCache.getFormatsForFillType(fillTypeName)
    if fillTypeName == nil then return {} end
    local upperName = string.upper(fillTypeName)
    return GlobalMarketStoreCache.cache[upperName] or {}
end
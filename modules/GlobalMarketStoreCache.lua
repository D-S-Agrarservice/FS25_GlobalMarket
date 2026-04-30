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
-- Prevents packaged goods (like Chickenfood) from vanishing under generic engine FillTypes (like Wheat).
local INTERCEPTOR_ALIASES = {
    ["chickenfood"] = "CHICKENFOOD",
    ["horsefood"]   = "HORSEFOOD",
    ["pigfood"]     = "PIGFOOD",
    ["roadsalt"]    = "ROADSALT"
}

-- Checks if the xml filename contains a known alias keyword
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
    p = string.gsub(p, "\\", "/") -- Standardize slashes for absolute paths
    p = string.gsub(p, "^%$data/", "data/")
    return p
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
        local formatSuffix = " (Palette)"

        -- Filter by relevant packaging categories (Fuzzy matching)
        if string.find(catLower, "bigbags") then
            isRelevant = true
            unitKey = "ui_gm_unit_bigbag"
            formatSuffix = " (Bigbag)"
        elseif string.find(catLower, "bigbagpallets") then
            isRelevant = true
            unitKey = "ui_gm_unit_bigbagpallet"
            formatSuffix = " (Bigbag-Palette)"
        elseif string.find(catLower, "ibc") or string.find(catLower, "fertilizerherbicide") then
            isRelevant = true
            unitKey = "ui_gm_unit_ibc"
            formatSuffix = " (IBC)"
        elseif string.find(catLower, "pallets") or string.find(catLower, "animals") then
            isRelevant = true
            unitKey = "ui_gm_unit_pallet"
            formatSuffix = " (Palette)"
        end

        if isRelevant then
            local xmlFile = XMLFile.load("GMCacheItem", xmlPath)
            if xmlFile ~= nil then
                local capacity = 0
                local engineFillTypeStr = ""
                local targetFormatXml = normPath

                -- Extract capacity and fillTypes safely
                local fillUnitRoot = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)"
                capacity = xmlFile:getFloat(fillUnitRoot .. "#capacity") or 0
                engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#fillTypes")

                if engineFillTypeStr == nil or engineFillTypeStr == "" then
                    engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#startFillType") or ""
                end

                -- MultipleItemPurchase Check: Redirect UI to the single physical item XML using absolute path
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

                    -- THE GATEKEEPER 1: Is the base Engine FillType allowed on the market?
                    if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then

                        -- THE GATEKEEPER 2: Is THIS specific container format allowed for this FillType?
                        local isContainerAllowed = true
                        if GlobalMarketAPI.getIsContainerAllowedForFillType ~= nil then
                            isContainerAllowed = GlobalMarketAPI.getIsContainerAllowedForFillType(fillTypeDesc, unitKey)
                        end

                        if isContainerAllowed then
                            -- Default GM Market Key is the Engine FillType (e.g., WHEAT)
                            local gmMarketKey = string.upper(fillTypeDesc.name)

                            -- ALIAS INTERCEPTOR: Reroute specific formats to custom GM categories
                            local customAlias = getInterceptorAlias(targetFormatXml)
                            if customAlias ~= nil then
                                gmMarketKey = customAlias
                            end

                            if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                                GlobalMarketStoreCache.cache[gmMarketKey] = {}
                            end

                            -- Base UI name generation: Use native engine localization as default
                            local baseName = fillTypeDesc.title

                            -- Override native name ONLY for intercepted aliases (otherwise engine calls Chickenfood "Wheat")
                            if gmMarketKey == "CHICKENFOOD" then
                                baseName = g_i18n:getText("fillType_chickenFood") or "Hühnerfutter"
                            elseif gmMarketKey == "HORSEFOOD" then
                                baseName = g_i18n:getText("fillType_horseFood") or "Pferdefutter"
                            elseif gmMarketKey == "PIGFOOD" then
                                baseName = g_i18n:getText("fillType_pigFood") or "Schweinefutter"
                            elseif gmMarketKey == "ROADSALT" then
                                baseName = g_i18n:getText("fillType_roadSalt") or "Streusalz"
                            end

                            local brandSuffix = ""
                            if item.brandIndex ~= nil and item.brandIndex ~= 0 then
                                local brand = g_brandManager:getBrandByIndex(item.brandIndex)
                                if brand ~= nil and brand.name ~= "NONE" then
                                    brandSuffix = " (" .. brand.title .. ")"
                                end
                            end

                            local displayTitle = baseName .. formatSuffix .. brandSuffix

                            -- Deduplication & Title Upgrade Strategy
                            local existingEntry = nil
                            for _, existing in ipairs(GlobalMarketStoreCache.cache[gmMarketKey]) do
                                if existing.xml == targetFormatXml then
                                    existingEntry = existing
                                    break
                                end
                            end

                            if existingEntry ~= nil then
                                -- UPGRADE CHECK: If the new item is visible in the shop (Parent/MultiPurchase)
                                -- and the cached one is hidden (Child), we upgrade the cache entry to the better name!
                                if item.showInStore and not existingEntry.showInStore then
                                    existingEntry.title = displayTitle
                                    existingEntry.showInStore = true

                                    if GlobalMarket.debugManager ~= nil then
                                        GlobalMarket.debugManager:trace("StoreCache: Upgraded hidden entry to visible Parent '%s'", displayTitle)
                                    end
                                end
                            else
                                -- Store new into Cache
                                table.insert(GlobalMarketStoreCache.cache[gmMarketKey], {
                                    title = displayTitle,
                                    xml = targetFormatXml,
                                    capacity = capacity,
                                    unitKey = unitKey,
                                    showInStore = item.showInStore
                                })
                                itemCount = itemCount + 1

                                if GlobalMarket.debugManager ~= nil then
                                    GlobalMarket.debugManager:trace("StoreCache: Added '%s' (%.0f L) to Market Key %s [EngineType: %s]", displayTitle, capacity, gmMarketKey, fillTypeDesc.name)
                                end
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

            -- Only process if the fillType is allowed on the market
            if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then

                -- Check if the engine defines a fallback pallet XML for this bulk/fillType
                if fillTypeDesc.palletFilename ~= nil and fillTypeDesc.palletFilename ~= "" then

                    -- API Gatekeeper: Is a generic pallet allowed for this specific fillType?
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

                        -- Ensure we don't duplicate if Phase 1 already caught it
                        local alreadyExists = false
                        for _, existing in ipairs(GlobalMarketStoreCache.cache[gmMarketKey]) do
                            if existing.xml == targetFormatXml then
                                alreadyExists = true
                                break
                            end
                        end

                        if not alreadyExists then
                            local storeItem = g_storeManager:getItemByXMLFilename(fillTypeDesc.palletFilename)
                            local palletTitle = storeItem ~= nil and storeItem.name or (g_i18n:getText("ui_gm_format_pallet") or "Palette")

                            table.insert(GlobalMarketStoreCache.cache[gmMarketKey], {
                                title = palletTitle,
                                xml = targetFormatXml,
                                capacity = 1000, -- Default fallback for generated pallets
                                unitKey = "ui_gm_unit_pallet",
                                showInStore = storeItem ~= nil and storeItem.showInStore or false
                            })
                            itemCount = itemCount + 1

                            if GlobalMarket.debugManager ~= nil then
                                GlobalMarket.debugManager:trace("StoreCache: Bridged engine pallet for %s to Market Key %s", palletTitle, gmMarketKey)
                            end
                        end
                    end
                end
            end
        end
    end

    GlobalMarketStoreCache.isInitialized = true
    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("StoreCache: Initialization complete. Cached %d format variations.", itemCount)
    end
end

-- =========================================================================
-- API EXPORTS FOR UI
-- =========================================================================

-- Retrieves all available buying/selling formats (BigBags, Pallets, IBCs) for a specific Engine FillType
-- @param fillTypeName string: The GM Market Key (e.g., "WHEAT" or "CHICKENFOOD")
-- @return table: Array of formatData objects ready for the Dialog UI
function GlobalMarketStoreCache.getFormatsForFillType(fillTypeName)
    if fillTypeName == nil then return {} end
    local upperName = string.upper(fillTypeName)
    return GlobalMarketStoreCache.cache[upperName] or {}
end
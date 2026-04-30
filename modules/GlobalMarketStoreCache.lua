--
-- FS25 - GlobalMarketStoreCache
-- Description: Pre-caches available shop items (BigBags, Pallets, IBCs) at mission start.
-- 1. Evaluates relevant store categories with fuzzy matching.
-- 2. Uses strict XML reading (getString/getFloat) to bypass schema requirements.
-- 3. Identifies MultipleItemPurchases and normalizes paths to prevent duplicates.
-- 4. Generates contextual Display Titles for Aliases.
-- 5. Queries the GlobalMarketAPI strictly for FillType economic validation AND container restrictions.
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

    -- Iterate over all store items
    for _, item in ipairs(g_storeManager:getItems()) do
        local xmlPath = item.xmlFilename or ""
        local normPath = normalizePath(xmlPath)
        local catLower = item.categoryName and string.lower(item.categoryName) or ""

        local isRelevant = false
        local unitKey = "ui_gm_unit_pallet"
        local formatSuffix = " (Palette)"

        -- STEP 1: Filter by relevant packaging categories (Fuzzy matching)
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

        -- STEP 2: Process the relevant items
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

                -- Default fallback for capacities
                if capacity <= 0 then capacity = 1000 end

                -- STEP 3: Validate and Map to Global Market
                if engineFillTypeStr ~= "" then
                    local primaryFillType = string.match(engineFillTypeStr, "%S+")
                    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(primaryFillType)

                    -- THE GATEKEEPER 1: Is the FillType allowed at all?
                    if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then

                        -- THE GATEKEEPER 2: Is THIS specific container format allowed for this FillType?
                        local isContainerAllowed = true
                        if GlobalMarketAPI.getIsContainerAllowedForFillType ~= nil then
                            isContainerAllowed = GlobalMarketAPI.getIsContainerAllowedForFillType(fillTypeDesc, unitKey)
                        end

                        if isContainerAllowed then
                            local gmMarketKey = string.upper(fillTypeDesc.name)

                            if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                                GlobalMarketStoreCache.cache[gmMarketKey] = {}
                            end

                            -- Generate contextual display title based on alias keywords
                            local baseName = item.name

                            if string.find(targetFormatXml, "chickenfood") then
                                baseName = g_i18n:getText("fillType_chickenFood") or "Hühnerfutter"
                            elseif string.find(targetFormatXml, "horsefood") then
                                baseName = g_i18n:getText("fillType_horseFood") or "Pferdefutter"
                            elseif string.find(targetFormatXml, "pigfood") then
                                baseName = g_i18n:getText("fillType_pigFood") or "Schweinefutter"
                            elseif string.find(targetFormatXml, "roadsalt") then
                                baseName = g_i18n:getText("fillType_roadSalt") or "Streusalz"
                            elseif string.find(targetFormatXml, "seeds") then
                                baseName = g_i18n:getText("fillType_seeds") or "Saatgut"
                            elseif string.find(targetFormatXml, "lime") then
                                baseName = g_i18n:getText("fillType_lime") or "Kalk"
                            elseif string.find(targetFormatXml, "liquidfertilizer") then
                                baseName = g_i18n:getText("fillType_liquidFertilizer") or "Flüssigdünger"
                            elseif string.find(targetFormatXml, "fertilizer") then
                                baseName = g_i18n:getText("fillType_fertilizer") or "Mineraldünger"
                            elseif string.find(targetFormatXml, "herbicide") then
                                baseName = g_i18n:getText("fillType_herbicide") or "Herbizid"
                            end

                            local brandSuffix = ""
                            if item.brandIndex ~= nil and item.brandIndex ~= 0 then
                                local brand = g_brandManager:getBrandByIndex(item.brandIndex)
                                if brand ~= nil and brand.name ~= "NONE" then
                                    brandSuffix = " (" .. brand.title .. ")"
                                end
                            end

                            local displayTitle = baseName .. formatSuffix .. brandSuffix

                            -- STEP 4: Deduplication & Title Upgrade Strategy
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

    GlobalMarketStoreCache.isInitialized = true
    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("StoreCache: Initialization complete. Cached %d format variations.", itemCount)
    end
end

-- =========================================================================
-- API EXPORTS FOR UI
-- =========================================================================

-- Retrieves all available buying/selling formats (BigBags, Pallets, IBCs) for a specific Engine FillType
-- @param fillTypeName string: The Engine FillType Name (e.g., "WHEAT")
-- @return table: Array of formatData objects ready for the Dialog UI
function GlobalMarketStoreCache.getFormatsForFillType(fillTypeName)
    if fillTypeName == nil then return {} end
    local upperName = string.upper(fillTypeName)
    return GlobalMarketStoreCache.cache[upperName] or {}
end
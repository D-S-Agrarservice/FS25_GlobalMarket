--
-- FS25 - GlobalMarketStoreCache
-- Description: Pre-caches available shop items (BigBags, Pallets, IBCs) at mission start.
-- 1. Evaluates relevant store categories with fuzzy matching.
-- 2. Uses strict XML reading (getString/getFloat) to bypass schema requirements.
-- 3. Identifies MultipleItemPurchases and normalizes paths to prevent duplicates.
-- 4. Generates contextual Display Titles for Aliases (e.g., ChickenFood under Wheat).
-- 5. Queries the GlobalMarketAPI strictly for FillType economic validation.
--

GlobalMarketStoreCache = {}
GlobalMarketStoreCache.cache = {}
GlobalMarketStoreCache.isInitialized = false

-- ALIAS INTERCEPTOR: Maps filename keywords to custom Global Market identities.
-- Prevents specific packaged goods from vanishing under generic engine FillTypes.
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

-- Normalizes paths to ensure our duplicate check catches $data vs data mismatches
local function normalizePath(path)
    if path == nil then return "" end
    local p = string.lower(path)
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

        -- STEP 1: Filter by relevant packaging categories (Fuzzy matching to catch multi-categories like "bigbags palletanimals")
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

        -- Note: No VETO here. Generic fillablePallets and bigBags are allowed as valid containers.

        -- STEP 2: Process the relevant items
        if isRelevant then
            -- Use strict XML load without schema validation requirements
            local xmlFile = XMLFile.load("GMCacheItem", xmlPath)
            if xmlFile ~= nil then
                local capacity = 0
                local engineFillTypeStr = ""
                local targetFormatXml = normPath

                -- Extract capacity and fillTypes strictly using getString/getFloat to prevent schema errors
                local fillUnitRoot = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)"
                capacity = xmlFile:getFloat(fillUnitRoot .. "#capacity") or 0
                engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#fillTypes")

                if engineFillTypeStr == nil or engineFillTypeStr == "" then
                    engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#startFillType") or ""
                end

                -- MultipleItemPurchase Check: Redirect UI to the single physical item XML
                local multiPurchaseXml = xmlFile:getString("vehicle.multipleItemPurchase#filename")
                if multiPurchaseXml ~= nil and multiPurchaseXml ~= "" then
                    targetFormatXml = normalizePath(multiPurchaseXml)
                end

                xmlFile:delete()

                -- Default fallback for capacities that might be hidden deeply
                if capacity <= 0 then capacity = 1000 end

                -- STEP 3: Validate and Map to Global Market
                if engineFillTypeStr ~= "" then
                    -- Get the first fillType defined (pallets usually only have one relevant)
                    local primaryFillType = string.match(engineFillTypeStr, "%S+")
                    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(primaryFillType)

                    -- THE GATEKEEPER: Let the API decide based on the economic Engine FillType
                    if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then

                        -- The GM Market Key is STRICTLY the Engine FillType
                        local gmMarketKey = string.upper(fillTypeDesc.name)

                        if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                            GlobalMarketStoreCache.cache[gmMarketKey] = {}
                        end

                        -- STEP 4: Deduplication (Prevents UI Spam caused by MultiPurchase vs SingleItem pathing)
                        local alreadyExists = false
                        for _, existing in ipairs(GlobalMarketStoreCache.cache[gmMarketKey]) do
                            if existing.xml == targetFormatXml then
                                alreadyExists = true
                                break
                            end
                        end

                        if not alreadyExists then
                            -- STEP 5: Generate contextual display title based on alias keywords
                            local baseName = item.name

                            -- Alias Overrides for specific goods hiding under generic FillTypes
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

                            -- Store into Cache
                            table.insert(GlobalMarketStoreCache.cache[gmMarketKey], {
                                title = displayTitle,
                                xml = targetFormatXml,
                                capacity = capacity,
                                unitKey = unitKey
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
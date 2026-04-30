--
-- FS25 - GlobalMarketStoreCache
-- Description: Pre-caches available shop items (BigBags, Pallets, IBCs) at mission start.
-- 1. Evaluates relevant store categories.
-- 2. Uses strict XML reading (getString/getFloat) to bypass schema requirements.
-- 3. Identifies MultipleItemPurchases and links to their physical single items.
-- 4. Uses an Interceptor to remap generic engine FillTypes (like WHEAT) to Market Aliases (like CHICKENFOOD).
-- 5. Queries the GlobalMarketAPI strictly for FillType economic validation.
--

GlobalMarketStoreCache = {}
GlobalMarketStoreCache.cache = {}
GlobalMarketStoreCache.isInitialized = false

-- ALIAS INTERCEPTOR: Maps filename keywords to custom Global Market identities.
-- Prevents ChickenFood (Engine: WHEAT) from being grouped into the regular Wheat market.
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
        local xmlPathLower = string.lower(xmlPath)
        local catLower = item.categoryName and string.lower(item.categoryName) or ""

        local isRelevant = false
        local unitKey = "ui_gm_unit_pallet"

        -- STEP 1: Filter strictly by relevant packaging categories
        if catLower == "bigbags" or catLower == "bigbagpallets" then
            isRelevant = true
            unitKey = "ui_gm_unit_bigbag"
        elseif catLower == "pallets" or catLower == "ibc" or catLower == "palletanimals" or catLower == "palletfertilizerherbicide" then
            isRelevant = true
            unitKey = "ui_gm_unit_pallet"
        end

        -- STEP 2: Process the relevant items
        if isRelevant then
            -- Use strict XML load without schema validation requirements
            local xmlFile = XMLFile.load("GMCacheItem", xmlPath)
            if xmlFile ~= nil then
                local capacity = 0
                local engineFillTypeStr = ""
                local targetFormatXml = xmlPath

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
                    targetFormatXml = multiPurchaseXml
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

                        -- THE INTERCEPTOR: Remap Engine Type to GM Alias if applicable
                        local gmMarketKey = getInterceptorAlias(string.lower(targetFormatXml))
                        if gmMarketKey == nil then
                            -- Fallback to standard engine fillType if no alias applies
                            gmMarketKey = string.upper(fillTypeDesc.name)
                        end

                        -- Initialize cache array for this market key
                        if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                            GlobalMarketStoreCache.cache[gmMarketKey] = {}
                        end

                        -- STEP 4: Format Brand Title to prevent UI Redundancy (e.g., Corteva vs Helm IBCs)
                        local displayTitle = item.name
                        if item.brandIndex ~= nil and item.brandIndex ~= 0 then
                            local brand = g_brandManager:getBrandByIndex(item.brandIndex)
                            if brand ~= nil and brand.name ~= "NONE" then
                                displayTitle = displayTitle .. " (" .. brand.title .. ")"
                            end
                        end

                        -- Check for duplicates to prevent spamming the UI
                        local alreadyExists = false
                        for _, existing in ipairs(GlobalMarketStoreCache.cache[gmMarketKey]) do
                            -- We compare the targetFormatXml to prevent multi and single items creating duplicate targets
                            if existing.xml == targetFormatXml then
                                alreadyExists = true
                                break
                            end
                        end

                        -- Store into Cache
                        if not alreadyExists then
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
        GlobalMarket.debugManager:info("StoreCache: Initialization complete. Successfully cached %d format variations.", itemCount)
    end
end

-- =========================================================================
-- API EXPORTS FOR UI
-- =========================================================================

-- Retrieves all available buying/selling formats (BigBags, Pallets) for a specific Market Key
-- @param fillTypeName string: The GM Market Key (e.g. "WHEAT", "CHICKENFOOD")
-- @return table: Array of formatData objects ready for the Dialog UI
function GlobalMarketStoreCache.getFormatsForFillType(fillTypeName)
    if fillTypeName == nil then return {} end
    local upperName = string.upper(fillTypeName)
    return GlobalMarketStoreCache.cache[upperName] or {}
end
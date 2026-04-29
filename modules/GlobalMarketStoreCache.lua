--
-- FS25 - GlobalMarketStoreCache
-- Description: Pre-caches available shop items (BigBags, Pallets, IBCs) at mission start.
-- Dynamically builds a library of buyable formats per FillType.
-- Ignorance of the native 'showInStore' flag ensures hidden formats (like IBCs) are caught,
-- while the GlobalMarketAPI ensures strict adherence to the server's economy blacklist.
--

GlobalMarketStoreCache = {}
GlobalMarketStoreCache.cache = {}
GlobalMarketStoreCache.isInitialized = false

-- Runs exactly ONCE during mission start (e.g., triggered via onFinishedLoading)
function GlobalMarketStoreCache.init()
    if GlobalMarketStoreCache.isInitialized then return end
    if g_storeManager == nil or g_storeManager.items == nil then return end

    GlobalMarketStoreCache.cache = {}
    local itemCount = 0

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("StoreCache: Initializing Global Market format dictionary...")
    end

    -- Iterate over all registered store items in the game
    for _, item in ipairs(g_storeManager:getItems()) do
        local cat = item.categoryName and string.lower(item.categoryName) or ""
        local xmlPathLower = item.xmlFilename and string.lower(item.xmlFilename) or ""

        -- 1. Broad Filter: Catch anything that represents a packaged good
        -- We explicitly DO NOT check 'item.showInStore' here, because Giants hides
        -- items like the 2000L Herbicide IBC from the regular shop list.
        local isRelevant = string.find(cat, "pallet") or string.find(cat, "bigbag") or string.find(cat, "ibc") or
                           string.find(xmlPathLower, "bag") or string.find(xmlPathLower, "pallet") or string.find(xmlPathLower, "tank")

        if isRelevant then
            -- We must peek into the actual XML because capacity and fillTypes are often missing
            -- or incomplete in the generic g_storeManager specs.
            local xmlFile = XMLFile.load("GMCacheItem", item.xmlFilename)

            if xmlFile ~= nil then
                local capacity = 0
                local fillTypesStr = ""

                -- 2A. ParentFile Injection (e.g., ChickenFood BigBags inheriting base BigBag properties)
                if xmlFile:hasProperty("vehicle.parentFile") then
                    xmlFile:iterate("vehicle.parentFile.attributes.set", function(_, key)
                        local path = xmlFile:getValue(key .. "#path")
                        if path ~= nil then
                            if string.find(path, "capacity") then
                                capacity = xmlFile:getFloat(key .. "#value") or capacity
                            elseif string.find(path, "fillTypes") then
                                fillTypesStr = xmlFile:getValue(key .. "#value") or ""
                            end
                        end
                    end)
                else
                    -- 2B. Direct FillUnit definition (e.g., Herbicide IBC, Standard Pallets)
                    local rootKey = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)"
                    capacity = xmlFile:getFloat(rootKey .. "#capacity") or capacity

                    -- Some basegame pallets use 'startFillType' instead of 'fillTypes' if they are single-purpose
                    fillTypesStr = xmlFile:getValue(rootKey .. "#fillTypes") or xmlFile:getValue(rootKey .. "#startFillType") or ""
                end

                xmlFile:delete()

                -- Safety fallback for capacity
                if capacity <= 0 then capacity = 1000 end

                -- 3. Process the extracted data
                if fillTypesStr ~= "" then
                    local supportedTypes = string.split(fillTypesStr, " ")
                    local unitKey = "ui_gm_unit_pallet"

                    -- Determine the correct dynamic UI translation key based on the path/category
                    if string.find(cat, "bigbag") or string.find(xmlPathLower, "bigbag") or string.find(xmlPathLower, "bag") then
                        unitKey = "ui_gm_unit_bigbag"
                    end

                    for _, ftName in ipairs(supportedTypes) do
                        local fillTypeDesc = g_fillTypeManager:getFillTypeByName(ftName)

                        -- 4. THE GATEKEEPER: Validate against Engine and GlobalMarketAPI
                        if fillTypeDesc ~= nil then
                            if GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then
                                local upperName = string.upper(fillTypeDesc.name)

                                if GlobalMarketStoreCache.cache[upperName] == nil then
                                    GlobalMarketStoreCache.cache[upperName] = {}
                                end

                                -- Store the actual shop title (e.g., "Chicken Food BigBag") to decouple
                                -- the UX identity from the underlying physical content (WHEAT).
                                table.insert(GlobalMarketStoreCache.cache[upperName], {
                                    title = item.name,
                                    xml = item.xmlFilename,
                                    capacity = capacity,
                                    unitKey = unitKey
                                })

                                itemCount = itemCount + 1

                                if GlobalMarket.debugManager ~= nil then
                                    GlobalMarket.debugManager:trace("StoreCache: Added '%s' (%.0f L) to FillType %s", item.name, capacity, upperName)
                                end
                            else
                                if GlobalMarket.debugManager ~= nil then
                                    GlobalMarket.debugManager:trace("StoreCache: Rejected '%s' (FillType %s is blacklisted by GM API)", item.name, ftName)
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
        GlobalMarket.debugManager:info("StoreCache: Initialization complete. Successfully cached %d format variations.", itemCount)
    end
end

-- =========================================================================
-- API EXPORTS FOR UI
-- =========================================================================

-- Fast Lookup function for the GM UI Dialog
-- Returns an array of available formats (xml, title, capacity, unitKey)
-- @param fillTypeName string: The technical fillType name (e.g., "WHEAT")
function GlobalMarketStoreCache.getFormatsForFillType(fillTypeName)
    if fillTypeName == nil then return {} end
    local upperName = string.upper(fillTypeName)
    return GlobalMarketStoreCache.cache[upperName] or {}
end
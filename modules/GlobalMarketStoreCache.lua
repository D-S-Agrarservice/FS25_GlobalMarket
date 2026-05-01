--
-- FS25 - GlobalMarketStoreCache
-- Description: Pre-caches available shop items (BigBags, Pallets, IBCs) at mission start.
-- PHASE 1: Store Item Scan (Strict XML parsing, deduplication, upgrade logic).
-- PHASE 2: Engine FillType Bridge (Injects engine-defined fallback pallets if allowed by API).
--

GlobalMarketStoreCache = {}
GlobalMarketStoreCache.cache = {}
GlobalMarketStoreCache.isInitialized = false

-- Safely fetches localized text to prevent "Missing '...'" UI bugs
local function getLocalizedText(key, fallback)
    if g_i18n ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return fallback
end

-- Safely generates the localized format suffix (e.g. " (Bigbag)")
local function getFormatSuffix(unitKey)
    if unitKey == "ui_gm_unit_bigbag" then
        return " (" .. getLocalizedText("ui_gm_unit_bigbag", "Bigbag") .. ")"
    elseif unitKey == "ui_gm_unit_bigbagpallet" then
        return " (" .. getLocalizedText("ui_gm_unit_bigbagpallet", "Bigbag Pallet") .. ")"
    elseif unitKey == "ui_gm_unit_ibc" then
        return " (" .. getLocalizedText("ui_gm_unit_ibc", "IBC") .. ")"
    else
        return " (" .. getLocalizedText("ui_gm_unit_pallet", "Pallet") .. ")"
    end
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
        local catLower = item.categoryName and string.lower(item.categoryName) or ""

        -- STRICT BLOCK: Ignore generic engine dummy templates that default to WHEAT
        -- Note: Checking original paths now, as normalization is removed.
        local isTemplate = false
        if xmlPath ~= "" then
            local pLower = string.lower(xmlPath)
            if string.find(pLower, "data/objects/bigbag/bigbag.xml", 1, true) or string.find(pLower, "data/objects/bigbagpallet/bigbagpallet.xml", 1, true) then
                 isTemplate = true
            end
        end

        local isRelevant = false
        local unitKey = "ui_gm_unit_pallet"

        -- Filter by relevant packaging categories
        if string.find(catLower, "bigbags") then
            isRelevant = true
            unitKey = "ui_gm_unit_bigbag"
        elseif string.find(catLower, "bigbagpallets") then
            isRelevant = true
            unitKey = "ui_gm_unit_bigbagpallet"
        elseif string.find(catLower, "ibc") or string.find(catLower, "fertilizerherbicide") then
            isRelevant = true
            unitKey = "ui_gm_unit_ibc"
        elseif string.find(catLower, "pallets") or string.find(catLower, "animals") then
            isRelevant = true
            unitKey = "ui_gm_unit_pallet"
        end

        if isRelevant and not isTemplate then
            local xmlFile = XMLFile.load("GMCacheItem", xmlPath)
            if xmlFile ~= nil then
                local capacity = 0
                local engineFillTypeStr = ""
                local targetFormatXml = xmlPath

                local multiPurchaseXml = xmlFile:getString("vehicle.multipleItemPurchase#filename")

                -- MULTI-PURCHASE LOGIC: Extract fillTypes from the linked Single XML because Multi-XMLs have no fillUnit
                if multiPurchaseXml ~= nil and multiPurchaseXml ~= "" then
                    local absolutePath = Utils.getFilename(multiPurchaseXml, item.baseDir)
                    targetFormatXml = absolutePath

                    local singleXml = XMLFile.load("GMSingleItem", absolutePath)
                    if singleXml ~= nil then
                        local fillUnitRoot = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)"
                        capacity = singleXml:getFloat(fillUnitRoot .. "#capacity") or 0
                        engineFillTypeStr = singleXml:getString(fillUnitRoot .. "#fillTypes")
                        if engineFillTypeStr == nil or engineFillTypeStr == "" then
                            engineFillTypeStr = singleXml:getString(fillUnitRoot .. "#startFillType") or ""
                        end
                        singleXml:delete()
                    end
                else
                    -- SINGLE ITEM LOGIC
                    local fillUnitRoot = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)"
                    capacity = xmlFile:getFloat(fillUnitRoot .. "#capacity") or 0
                    engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#fillTypes")

                    if engineFillTypeStr == nil or engineFillTypeStr == "" then
                        engineFillTypeStr = xmlFile:getString(fillUnitRoot .. "#startFillType") or ""
                    end
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

                            if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                                GlobalMarketStoreCache.cache[gmMarketKey] = {}
                            end

                            local baseName = item.name or ""

                            -- ABSOLUTE LOGIC OVERRIDE: Any Wheat/Oat Bigbag IS Animal Food (ignores Giants L10n "Weizen-Bigbag")
                            if gmMarketKey == "WHEAT" and (unitKey == "ui_gm_unit_bigbag" or unitKey == "ui_gm_unit_bigbagpallet") then
                                baseName = getLocalizedText("fillType_chickenFood", "Chicken Food")
                            elseif gmMarketKey == "OAT" and (unitKey == "ui_gm_unit_bigbag" or unitKey == "ui_gm_unit_bigbagpallet") then
                                baseName = getLocalizedText("fillType_horseFood", "Horse Food")
                            elseif isGenericItemName(baseName) then
                                baseName = fillTypeDesc.title
                            end

                            local brandSuffix = ""
                            if item.brandIndex ~= nil and item.brandIndex ~= 0 then
                                local brand = g_brandManager:getBrandByIndex(item.brandIndex)
                                if brand ~= nil and brand.name ~= "NONE" then
                                    brandSuffix = " (" .. brand.title .. ")"
                                end
                            end

                            local displayTitle = baseName .. getFormatSuffix(unitKey) .. brandSuffix

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

                                    if GlobalMarket.debugManager ~= nil then
                                        GlobalMarket.debugManager:trace("StoreCache: Upgraded hidden entry to visible Parent '%s'", displayTitle)
                                    end
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

                                if GlobalMarket.debugManager ~= nil then
                                    GlobalMarket.debugManager:trace("StoreCache: Added '%s' (%.0f L) to Market Key %s", displayTitle, capacity, gmMarketKey)
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

            if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then
                if fillTypeDesc.palletFilename ~= nil and fillTypeDesc.palletFilename ~= "" then

                    local targetFormatXml = fillTypeDesc.palletFilename
                    local pLower = string.lower(targetFormatXml)

                    -- STRICT BLOCK: Ignore generic engine dummy templates in fallback bridge
                    local isTemplate = false
                    if string.find(pLower, "data/objects/bigbag/bigbag.xml", 1, true) or string.find(pLower, "data/objects/bigbagpallet/bigbagpallet.xml", 1, true) then
                        isTemplate = true
                    end

                    if not isTemplate then
                        local unitKey = "ui_gm_unit_pallet"
                        if string.find(pLower, "bigbagpallet") then
                            unitKey = "ui_gm_unit_bigbagpallet"
                        elseif string.find(pLower, "bigbag") then
                            unitKey = "ui_gm_unit_bigbag"
                        elseif string.find(pLower, "ibc") or string.find(pLower, "liquidtank") then
                            unitKey = "ui_gm_unit_ibc"
                        end

                        local isContainerAllowed = true
                        if GlobalMarketAPI.getIsContainerAllowedForFillType ~= nil then
                            isContainerAllowed = GlobalMarketAPI.getIsContainerAllowedForFillType(fillTypeDesc, unitKey)
                        end

                        if isContainerAllowed then
                            local gmMarketKey = string.upper(fillTypeDesc.name)

                            if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                                GlobalMarketStoreCache.cache[gmMarketKey] = {}
                            end

                            local storeItem = g_storeManager:getItemByXMLFilename(fillTypeDesc.palletFilename)
                            local baseName = storeItem ~= nil and storeItem.name or ""

                            -- ABSOLUTE LOGIC OVERRIDE for Phase 2
                            if gmMarketKey == "WHEAT" and (unitKey == "ui_gm_unit_bigbag" or unitKey == "ui_gm_unit_bigbagpallet") then
                                baseName = getLocalizedText("fillType_chickenFood", "Chicken Food")
                            elseif gmMarketKey == "OAT" and (unitKey == "ui_gm_unit_bigbag" or unitKey == "ui_gm_unit_bigbagpallet") then
                                baseName = getLocalizedText("fillType_horseFood", "Horse Food")
                            elseif isGenericItemName(baseName) then
                                baseName = fillTypeDesc.title
                            end

                            local palletTitle = baseName .. getFormatSuffix(unitKey)

                            local alreadyExists = false
                            for _, existing in ipairs(GlobalMarketStoreCache.cache[gmMarketKey]) do
                                if existing.xml == targetFormatXml or existing.title == palletTitle then
                                    alreadyExists = true
                                    break
                                end
                            end

                            if not alreadyExists then
                                table.insert(GlobalMarketStoreCache.cache[gmMarketKey], {
                                    title = palletTitle,
                                    xml = targetFormatXml,
                                    capacity = 1000,
                                    unitKey = unitKey,
                                    showInStore = storeItem ~= nil and storeItem.showInStore or false
                                })
                                itemCount = itemCount + 1
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
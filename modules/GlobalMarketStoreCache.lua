-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketStoreCache.lua
-- Store item scanner and fillType fallback bridge for pallets, BigBags, and IBC containers.
-- Author: D-S-Agrarservice
-- =========================================================================================

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
        or n == "fillablepallet" or n == "vegetablespallet"
end

-- Extracts capacity, fillTypes, and fillTypeCategories from a vehicle/pallet XML file.
-- Supports direct <fillUnit>, <parentFile><attributes><set>, <consumable><type><slot>, and <storeData><specs>.
local function extractItemFillData(xmlHandle)
    if xmlHandle == nil then
        return 0, "", ""
    end

    local fillUnitRoot = "vehicle.fillUnit.fillUnitConfigurations.fillUnitConfiguration(0).fillUnits.fillUnit(0)"
    local capacity = xmlHandle:getFloat(fillUnitRoot .. "#capacity") or 0
    local fillTypesStr = xmlHandle:getString(fillUnitRoot .. "#fillTypes") or ""
    if fillTypesStr == "" then
        fillTypesStr = xmlHandle:getString(fillUnitRoot .. "#startFillType") or ""
    end
    local fillTypeCategoriesStr = xmlHandle:getString(fillUnitRoot .. "#fillTypeCategories") or ""

    -- 1. Check <parentFile><attributes><set .../> inheritance (used by all FS25 BigBags & BigBagPallets)
    local setIndex = 0
    while true do
        local setKey = string.format("vehicle.parentFile.attributes.set(%d)", setIndex)
        if not xmlHandle:hasProperty(setKey) then
            break
        end

        local attrPath = xmlHandle:getString(setKey .. "#path") or ""
        local attrVal = xmlHandle:getString(setKey .. "#value") or ""

        if attrPath ~= "" and attrVal ~= "" then
            if fillTypesStr == "" and (string.find(attrPath, "fillUnit#fillTypes", 1, true) or string.find(attrPath, "fillUnit(0)#fillTypes", 1, true)) then
                fillTypesStr = attrVal
            elseif fillTypesStr == "" and (string.find(attrPath, "fillUnit#startFillType", 1, true) or string.find(attrPath, "fillUnit(0)#startFillType", 1, true)) then
                fillTypesStr = attrVal
            elseif capacity <= 0 and (string.find(attrPath, "fillUnit#capacity", 1, true) or string.find(attrPath, "fillUnit(0)#capacity", 1, true)) then
                capacity = tonumber(attrVal) or 0
            elseif fillTypeCategoriesStr == "" and (string.find(attrPath, "fillUnit#fillTypeCategories", 1, true) or string.find(attrPath, "fillUnit(0)#fillTypeCategories", 1, true)) then
                fillTypeCategoriesStr = attrVal
            end
        end

        setIndex = setIndex + 1
    end

    -- 2. Check <consumable> specialization (used by BALE_TWINE, BALE_NET, BALE_WRAP pallets)
    if fillTypesStr == "" then
        fillTypesStr = xmlHandle:getString("vehicle.consumable.type(0)#typeName")
            or xmlHandle:getString("vehicle.consumable.consumableConfigurations#typeName")
            or ""
    end

    if capacity <= 0 and xmlHandle:hasProperty("vehicle.consumable.type(0)") then
        local slotCount = 0
        while xmlHandle:hasProperty(string.format("vehicle.consumable.type(0).slot(%d)", slotCount)) do
            slotCount = slotCount + 1
        end
        if slotCount > 0 then
            capacity = slotCount
        end
    end

    -- 3. Check <storeData><specs> fallback
    if fillTypesStr == "" then
        fillTypesStr = xmlHandle:getString("vehicle.storeData.specs.fillTypes") or ""
    end
    if capacity <= 0 then
        capacity = xmlHandle:getFloat("vehicle.storeData.specs.capacity") or 0
    end

    return capacity, fillTypesStr, fillTypeCategoriesStr
end

-- Runs exactly ONCE during mission start (or on demand if queried earlier)
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
                local fillTypeCategoriesStr = ""
                local targetFormatXml = xmlPath

                local multiPurchaseXml = xmlFile:getString("vehicle.multipleItemPurchase#filename")

                -- MULTI-PURCHASE LOGIC: Extract fillTypes from the linked Single XML, with fallback to the Multi-XML
                if multiPurchaseXml ~= nil and multiPurchaseXml ~= "" then
                    local absolutePath = Utils.getFilename(multiPurchaseXml, item.baseDir)
                    targetFormatXml = absolutePath

                    local singleXml = XMLFile.load("GMSingleItem", absolutePath)
                    if singleXml ~= nil then
                        capacity, engineFillTypeStr, fillTypeCategoriesStr = extractItemFillData(singleXml)
                        singleXml:delete()
                    end

                    local mpCapacity, mpFillTypes, mpCategories = extractItemFillData(xmlFile)
                    if engineFillTypeStr == "" then
                        engineFillTypeStr = mpFillTypes
                    end
                    if fillTypeCategoriesStr == "" then
                        fillTypeCategoriesStr = mpCategories
                    end
                    if capacity <= 0 then
                        capacity = mpCapacity
                    end
                else
                    -- SINGLE ITEM LOGIC
                    capacity, engineFillTypeStr, fillTypeCategoriesStr = extractItemFillData(xmlFile)
                end

                xmlFile:delete()

                if capacity <= 0 then capacity = 1000 end

                -- Collect target FillType descriptors (either explicit fillTypes or specific category like ROOTCROP_BELT)
                local targetFillTypes = {}
                local isCategoryBased = false

                if engineFillTypeStr ~= "" then
                    for ftName in string.gmatch(engineFillTypeStr, "%S+") do
                        local ftDesc = g_fillTypeManager:getFillTypeByName(ftName)
                        if ftDesc ~= nil then
                            table.insert(targetFillTypes, ftDesc)
                        end
                    end
                elseif fillTypeCategoriesStr ~= "" and string.upper(fillTypeCategoriesStr) ~= "BULK" then
                    -- Expand specific pallet categories (e.g. ROOTCROP_BELT on vegetablesPallet.xml for SUGARBEET, CARROT, etc.)
                    isCategoryBased = true
                    local categoryFillTypes = g_fillTypeManager:getFillTypesByCategoryNames(fillTypeCategoriesStr)
                    if categoryFillTypes ~= nil then
                        for _, ftIndex in ipairs(categoryFillTypes) do
                            local ftDesc = g_fillTypeManager:getFillTypeByIndex(ftIndex)
                            if ftDesc ~= nil then
                                table.insert(targetFillTypes, ftDesc)
                            end
                        end
                    end
                end

                for _, fillTypeDesc in ipairs(targetFillTypes) do
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
                            elseif isCategoryBased or #targetFillTypes > 1 or isGenericItemName(baseName) then
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
                                if capacity > 0 and existingEntry.capacity == 1000 and capacity ~= 1000 then
                                    existingEntry.capacity = capacity
                                end
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
        local fieldFruitSet = {}
        local fieldFruitIndices = g_fillTypeManager:getFillTypesByCategoryNames("SELLINGSTATION_FIELDFRUITS")
        if fieldFruitIndices ~= nil then
            for _, ftIndex in ipairs(fieldFruitIndices) do
                fieldFruitSet[ftIndex] = true
            end
        end
        local defaultFillablePalletXml = Utils.getFilename("$data/objects/pallets/fillablePallet/fillablePallet.xml", "")

        for _, fillTypeDesc in pairs(g_fillTypeManager.fillTypes) do

            if fillTypeDesc ~= nil and GlobalMarketAPI ~= nil and GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc) then
                local gmMarketKey = string.upper(fillTypeDesc.name)
                local targetFormatXml = fillTypeDesc.palletFilename

                -- Fallback for field fruits (e.g. SUGARBEET, GREENBEAN, PEA) where maps_fillTypes.xml omitted <pallet filename="..."/>
                if (targetFormatXml == nil or targetFormatXml == "") and fieldFruitSet[fillTypeDesc.index] then
                    local existingList = GlobalMarketStoreCache.cache[gmMarketKey]
                    if existingList == nil or #existingList == 0 then
                        targetFormatXml = defaultFillablePalletXml
                    end
                end

                if targetFormatXml ~= nil and targetFormatXml ~= "" then
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
                            if GlobalMarketStoreCache.cache[gmMarketKey] == nil then
                                GlobalMarketStoreCache.cache[gmMarketKey] = {}
                            end

                            local storeItem = g_storeManager:getItemByXMLFilename(targetFormatXml)
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
                                local fallbackCap = 1000
                                local palletXml = XMLFile.load("GMCacheFallback", targetFormatXml)
                                if palletXml ~= nil then
                                    local parsedCap = extractItemFillData(palletXml)
                                    if parsedCap > 0 then
                                        fallbackCap = parsedCap
                                    end
                                    palletXml:delete()
                                end

                                table.insert(GlobalMarketStoreCache.cache[gmMarketKey], {
                                    title = palletTitle,
                                    xml = targetFormatXml,
                                    capacity = fallbackCap,
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
    if not GlobalMarketStoreCache.isInitialized then
        GlobalMarketStoreCache.init()
    end
    local upperName = string.upper(fillTypeName)
    return GlobalMarketStoreCache.cache[upperName] or {}
end

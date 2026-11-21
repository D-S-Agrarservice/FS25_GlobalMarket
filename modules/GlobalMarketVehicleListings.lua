-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleListings.lua
-- Used vehicle market (#16): listing groups, eligibility checks, portable vehicle snapshots
-- (configurations incl. custom paint, condition), dealer value and respawn from a snapshot.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketVehicleListings = {}

-- Listing groups, based on the basegame store category types (display order)
GlobalMarketVehicleListings.GROUP_ORDER = {
    "DRIVABLES", "LOADERS", "TRAILERS", "SOIL_PREPARATION", "SEEDING", "YIELD", "COMBINE",
    "FORAGE", "GRASSLAND", "BALING", "ANIMALS", "SPECIALCROPS", "FORESTRY", "MISC"
}

-- Store category types merged into one listing group
GlobalMarketVehicleListings.TYPE_TO_GROUP = {
    ROOTCROPS = "SPECIALCROPS",
    VEGETABLES = "SPECIALCROPS",
    SPECIALCROPS = "SPECIALCROPS",
    GRAPES_OLIVES = "SPECIALCROPS"
}

-- Store category types that never belong to the vehicle market
GlobalMarketVehicleListings.EXCLUDED_TYPES = {
    OBJECTS = true,
    HANDTOOLS = true,
    PLACEABLE = true
}

-- Own l10n key for the merged group (all other groups use the basegame type titles)
GlobalMarketVehicleListings.GROUP_TITLE_KEYS = {
    SPECIALCROPS = "ui_gm_vehicles_group_specialCrops"
}

-- =========================================================================
-- GROUPS
-- =========================================================================

---Returns true if a store category name is a pallet category (pallets are traded as goods, not vehicles)
---@param categoryName string|nil
---@return boolean
local function isPalletCategory(categoryName)
    if categoryName == nil then
        return false
    end
    local upper = string.upper(categoryName)
    return string.sub(upper, 1, 6) == "PALLET" or string.find(upper, "PALLETS", 1, true) ~= nil
end

---Returns the listing group of a store item, or nil if it cannot be traded on the vehicle market
---@param storeItem table|nil
---@return string|nil group
function GlobalMarketVehicleListings.getGroupForStoreItem(storeItem)
    if storeItem == nil or not StoreItemUtil.getIsVehicle(storeItem) then
        return nil
    end
    local categoryName = storeItem.categoryName
    if isPalletCategory(categoryName) then
        return nil
    end
    local category = (g_storeManager ~= nil) and g_storeManager:getCategoryByName(categoryName) or nil
    local typeName = (category ~= nil and category.type ~= nil) and string.upper(category.type) or "MISC"
    if GlobalMarketVehicleListings.EXCLUDED_TYPES[typeName] then
        return nil
    end
    local group = GlobalMarketVehicleListings.TYPE_TO_GROUP[typeName] or typeName
    for _, known in ipairs(GlobalMarketVehicleListings.GROUP_ORDER) do
        if known == group then
            return group
        end
    end
    -- Custom category types from mods end up in "Misc"
    return "MISC"
end

---Returns the localized title of a listing group
---@param group string
---@return string
function GlobalMarketVehicleListings.getGroupTitle(group)
    local key = GlobalMarketVehicleListings.GROUP_TITLE_KEYS[group]
    if key ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    local categoryType = (g_storeManager ~= nil and g_storeManager.categoryTypesByName ~= nil)
        and g_storeManager.categoryTypesByName[group] or nil
    if categoryType ~= nil and categoryType.title ~= nil then
        return g_i18n:convertText(categoryType.title)
    end
    return tostring(group)
end

-- =========================================================================
-- ELIGIBILITY (Server-authoritative, also used by the UI for hints)
-- =========================================================================

---Returns the fill unit indices used as vehicle consumers (fuel, DEF, air), which do not count as cargo
---@param vehicle table
---@return table set
local function getConsumerFillUnits(vehicle)
    local set = {}
    local spec = vehicle.spec_motorized
    if spec ~= nil and spec.consumers ~= nil then
        for _, consumer in pairs(spec.consumers) do
            if consumer.fillUnitIndex ~= nil then
                set[consumer.fillUnitIndex] = true
            end
        end
    end
    return set
end

---Returns true if somebody sits in the vehicle (driver or passenger, incl. the requester) or a helper drives it.
---The controlled state is known on all clients, unlike the driver's connection used by getIsInUse.
---@param vehicle table
---@return boolean
local function getIsOccupied(vehicle)
    if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() then
        return true
    end
    local passengers = vehicle.spec_enterablePassenger
    if passengers ~= nil and passengers.available and passengers.passengerSeats ~= nil then
        for _, seat in ipairs(passengers.passengerSeats) do
            if seat.isUsed then
                return true
            end
        end
    end
    return vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive()
end

---Checks whether a vehicle may be listed on the vehicle market by a farm
---@param vehicle table|nil
---@param farmId number
---@param connection table|nil Requesting connection (for the in-use check)
---@return boolean isEligible
---@return string|nil reason l10n-ready reason code if not eligible
function GlobalMarketVehicleListings.getEligibility(vehicle, farmId, connection)
    if vehicle == nil or vehicle.isDeleted or vehicle.configFileName == nil then
        return false, "invalid"
    end
    local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    if GlobalMarketVehicleListings.getGroupForStoreItem(storeItem) == nil then
        return false, "notTradeable"
    end
    -- Covers leased and mission vehicles
    if vehicle.propertyState ~= VehiclePropertyState.OWNED or vehicle:getOwnerFarmId() ~= farmId then
        return false, "notOwned"
    end
    if getIsOccupied(vehicle) or (vehicle.getIsInUse ~= nil and vehicle:getIsInUse(connection)) then
        return false, "inUse"
    end
    if vehicle.getAttacherVehicle ~= nil and vehicle:getAttacherVehicle() ~= nil then
        return false, "attached"
    end
    if vehicle.getAttachedImplements ~= nil and #vehicle:getAttachedImplements() > 0 then
        return false, "attached"
    end
    if vehicle.getFillUnits ~= nil then
        local consumers = getConsumerFillUnits(vehicle)
        for index, _ in ipairs(vehicle:getFillUnits()) do
            if not consumers[index] and vehicle:getFillUnitFillLevel(index) > 0.01 then
                return false, "hasCargo"
            end
        end
    end
    return true, nil
end

-- =========================================================================
-- SNAPSHOTS (portable: save IDs instead of config indices, network filenames)
-- =========================================================================

---Returns mod name and file hash of a store item (nil for basegame and DLC items)
---@param storeItem table
---@return string|nil modName
---@return string|nil fileHash
function GlobalMarketVehicleListings.getModInfo(storeItem)
    if storeItem == nil or not storeItem.isMod or storeItem.customEnvironment == nil then
        return nil, nil
    end
    local mod = g_modManager:getModByName(storeItem.customEnvironment)
    return storeItem.customEnvironment, (mod ~= nil) and mod.fileHash or nil
end

---Captures a portable snapshot of a vehicle (configurations incl. custom paint, condition)
---@param vehicle table
---@return table|nil snapshot
function GlobalMarketVehicleListings.captureSnapshot(vehicle)
    local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    local group = GlobalMarketVehicleListings.getGroupForStoreItem(storeItem)
    if group == nil then
        return nil
    end
    local modName, modFileHash = GlobalMarketVehicleListings.getModInfo(storeItem)
    local configs = {}
    local seen = {}
    local configurations = vehicle.configurations or {}
    local configurationData = vehicle.configurationData or {}

    local function addConfig(configName, configId, isBought)
        local saveId = ConfigurationUtil.getSaveIdByConfigId(vehicle.configFileName, configName, configId)
        if saveId == nil then
            return
        end
        local key = configName .. "|" .. tostring(saveId)
        if seen[key] ~= nil then
            seen[key].isBought = seen[key].isBought or isBought
            return
        end
        local entry = {
            name = configName,
            saveId = tostring(saveId),
            isActive = (configurations[configName] == configId),
            isBought = isBought
        }
        local data = configurationData[configName] ~= nil and configurationData[configName][configId] or nil
        if data ~= nil then
            if data.color ~= nil then
                entry.color = { data.color[1], data.color[2], data.color[3] }
            end
            entry.materialTemplateName = data.materialTemplateName
        end
        seen[key] = entry
        table.insert(configs, entry)
    end

    for configName, ids in pairs(vehicle.boughtConfigurations or {}) do
        for configId, _ in pairs(ids) do
            addConfig(configName, configId, true)
        end
    end
    -- Active configs that are not marked as bought (defaults) are kept as well
    for configName, configId in pairs(configurations) do
        addConfig(configName, configId, false)
    end
    table.sort(configs, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.saveId < b.saveId
    end)

    return {
        xmlFilename = NetworkUtil.convertToNetworkFilename(vehicle.configFileName),
        modName = modName,
        modFileHash = modFileHash,
        group = group,
        configs = configs,
        age = vehicle.age or 0,
        operatingTime = vehicle.operatingTime or 0,
        damage = (vehicle.getDamageAmount ~= nil) and vehicle:getDamageAmount() or 0,
        wear = (vehicle.getWearTotalAmount ~= nil) and vehicle:getWearTotalAmount() or 0
    }
end

---Resolves a snapshot against the local store (strict: every config save ID must exist exactly)
---@param snapshot table
---@return table|nil resolved {storeItem, configurations, boughtConfigurations, configurationData}
---@return string|nil reason "missingStoreItem" | "missingMod" | "modMismatch" | "configMismatch"
function GlobalMarketVehicleListings.resolveSnapshot(snapshot)
    if snapshot == nil or snapshot.xmlFilename == nil then
        return nil, "missingStoreItem"
    end
    if snapshot.modName ~= nil then
        local mod = g_modManager:getModByName(snapshot.modName)
        if mod == nil then
            return nil, "missingMod"
        end
        if snapshot.modFileHash ~= nil and mod.fileHash ~= snapshot.modFileHash then
            return nil, "modMismatch"
        end
    end
    local storeItem = g_storeManager:getItemByXMLFilename(NetworkUtil.convertFromNetworkFilename(snapshot.xmlFilename))
    if storeItem == nil then
        return nil, "missingStoreItem"
    end

    local configurations, boughtConfigurations, configurationData = {}, {}, {}
    for _, entry in ipairs(snapshot.configs or {}) do
        local items = (storeItem.configurations ~= nil) and storeItem.configurations[entry.name] or nil
        local configId = nil
        if items ~= nil then
            for index, item in ipairs(items) do
                if tostring(item.saveId) == entry.saveId then
                    configId = index
                    break
                end
            end
        end
        if configId == nil then
            return nil, "configMismatch"
        end
        if entry.isActive then
            configurations[entry.name] = configId
        end
        if entry.isBought then
            boughtConfigurations[entry.name] = boughtConfigurations[entry.name] or {}
            boughtConfigurations[entry.name][configId] = true
        end
        if entry.color ~= nil or entry.materialTemplateName ~= nil then
            configurationData[entry.name] = configurationData[entry.name] or {}
            configurationData[entry.name][configId] = {
                color = (entry.color ~= nil) and { entry.color[1], entry.color[2], entry.color[3] } or nil,
                materialTemplateName = entry.materialTemplateName
            }
        end
    end

    return {
        storeItem = storeItem,
        configurations = configurations,
        boughtConfigurations = boughtConfigurations,
        configurationData = configurationData
    }, nil
end

---Computes the basegame dealer value of a resolved snapshot (same formula as Vehicle:getSellPrice)
---@param snapshot table
---@param resolved table Result of resolveSnapshot
---@return number value
function GlobalMarketVehicleListings.getDealerValue(snapshot, resolved)
    local storeItem = resolved.storeItem
    local price = StoreItemUtil.getDefaultPrice(storeItem, resolved.configurations)
    if storeItem.lifetime == nil or storeItem.lifetime <= 0 then
        return price
    end
    local repairPrice = Wearable.calculateRepairPrice(price, snapshot.damage or 0)
    local repaintPrice = Wearable.calculateRepaintPrice(price, snapshot.wear or 0)
    return Vehicle.calculateSellPrice(storeItem, snapshot.age or 0, snapshot.operatingTime or 0, price, repairPrice, repaintPrice)
end

---Returns the asking price of a listing on this server (nil if the vehicle is not available here)
---@param listing table
---@return number|nil price
function GlobalMarketVehicleListings.getListingPrice(listing)
    local resolved = GlobalMarketVehicleListings.resolveSnapshot(listing.snapshot)
    if resolved == nil then
        return nil
    end
    return math.floor(GlobalMarketVehicleListings.getDealerValue(listing.snapshot, resolved) * (listing.priceFactor or 1) + 0.5)
end

---Returns "Brand Name" of a vehicle by its (network) xml filename
---@param xmlFilename string|nil
---@return string
function GlobalMarketVehicleListings.getDisplayName(xmlFilename)
    if xmlFilename == nil or xmlFilename == "" then
        return "?"
    end
    local storeItem = g_storeManager:getItemByXMLFilename(NetworkUtil.convertFromNetworkFilename(xmlFilename))
    if storeItem == nil then
        return xmlFilename
    end
    local brand = (g_brandManager ~= nil and storeItem.brandIndex ~= nil) and g_brandManager:getBrandByIndex(storeItem.brandIndex) or nil
    if brand ~= nil and brand.title ~= nil and brand.title ~= "" then
        return string.format("%s %s", brand.title, storeItem.name)
    end
    return storeItem.name or xmlFilename
end

-- =========================================================================
-- RESPAWN (Server)
-- =========================================================================

---Spawns the vehicle of a resolved snapshot at the store spawn places for a farm
---@param snapshot table
---@param resolved table Result of resolveSnapshot
---@param farmId number New owner
---@param callback function callback(target, vehicles, loadingState, args)
---@param target table|nil
---@param args table|nil
function GlobalMarketVehicleListings.spawnFromSnapshot(snapshot, resolved, farmId, callback, target, args)
    local data = VehicleLoadingData.new()
    data:setStoreItem(resolved.storeItem)
    data:setConfigurations(resolved.configurations)
    data:setBoughtConfigurations(resolved.boughtConfigurations)
    data:setConfigurationData(resolved.configurationData)
    if not data:setLoadingPlace(g_currentMission.storeSpawnPlaces, g_currentMission.usedStorePlaces) then
        callback(target, {}, VehicleLoadingState.NO_SPACE, args)
        return
    end
    data:setPropertyState(VehiclePropertyState.OWNED)
    data:setOwnerFarmId(farmId)
    -- Basegame applies age and operating time, Wearable:onSaleItemSet applies damage and wear
    data:setSaleItem({
        boughtConfigurations = resolved.boughtConfigurations,
        age = snapshot.age or 0,
        operatingTime = snapshot.operatingTime or 0,
        damage = snapshot.damage or 0,
        wear = snapshot.wear or 0
    })
    data:load(callback, target, args)
end

-- =========================================================================
-- XML PERSISTENCE
-- =========================================================================

---Writes a snapshot below an XML key
---@param xmlFile table
---@param key string
---@param snapshot table
function GlobalMarketVehicleListings.writeSnapshotToXml(xmlFile, key, snapshot)
    xmlFile:setString(key .. "#xmlFilename", snapshot.xmlFilename)
    if snapshot.modName ~= nil then
        xmlFile:setString(key .. "#modName", snapshot.modName)
    end
    if snapshot.modFileHash ~= nil then
        xmlFile:setString(key .. "#modFileHash", snapshot.modFileHash)
    end
    xmlFile:setString(key .. "#group", snapshot.group or "MISC")
    xmlFile:setInt(key .. "#age", snapshot.age or 0)
    xmlFile:setFloat(key .. "#operatingTime", snapshot.operatingTime or 0)
    xmlFile:setFloat(key .. "#damage", snapshot.damage or 0)
    xmlFile:setFloat(key .. "#wear", snapshot.wear or 0)
    for i, entry in ipairs(snapshot.configs or {}) do
        local cKey = string.format("%s.config(%d)", key, i - 1)
        xmlFile:setString(cKey .. "#name", entry.name)
        xmlFile:setString(cKey .. "#saveId", entry.saveId)
        xmlFile:setBool(cKey .. "#isActive", entry.isActive == true)
        xmlFile:setBool(cKey .. "#isBought", entry.isBought == true)
        if entry.color ~= nil then
            xmlFile:setString(cKey .. "#color", string.format("%.6f %.6f %.6f", entry.color[1], entry.color[2], entry.color[3]))
        end
        if entry.materialTemplateName ~= nil then
            xmlFile:setString(cKey .. "#materialTemplateName", entry.materialTemplateName)
        end
    end
end

---Reads a snapshot written by writeSnapshotToXml
---@param xmlFile table
---@param key string
---@return table|nil snapshot
function GlobalMarketVehicleListings.readSnapshotFromXml(xmlFile, key)
    local xmlFilename = xmlFile:getString(key .. "#xmlFilename")
    if xmlFilename == nil or xmlFilename == "" then
        return nil
    end
    local snapshot = {
        xmlFilename = xmlFilename,
        modName = xmlFile:getString(key .. "#modName"),
        modFileHash = xmlFile:getString(key .. "#modFileHash"),
        group = xmlFile:getString(key .. "#group", "MISC"),
        age = xmlFile:getInt(key .. "#age", 0),
        operatingTime = xmlFile:getFloat(key .. "#operatingTime", 0),
        damage = xmlFile:getFloat(key .. "#damage", 0),
        wear = xmlFile:getFloat(key .. "#wear", 0),
        configs = {}
    }
    xmlFile:iterate(key .. ".config", function(_, cKey)
        local entry = {
            name = xmlFile:getString(cKey .. "#name"),
            saveId = xmlFile:getString(cKey .. "#saveId"),
            isActive = xmlFile:getBool(cKey .. "#isActive", false),
            isBought = xmlFile:getBool(cKey .. "#isBought", false),
            materialTemplateName = xmlFile:getString(cKey .. "#materialTemplateName")
        }
        local colorStr = xmlFile:getString(cKey .. "#color")
        if colorStr ~= nil then
            local r, g, b = string.match(colorStr, "^%s*([%d%.%-]+)%s+([%d%.%-]+)%s+([%d%.%-]+)")
            if r ~= nil then
                entry.color = { tonumber(r), tonumber(g), tonumber(b) }
            end
        end
        if entry.name ~= nil and entry.saveId ~= nil then
            table.insert(snapshot.configs, entry)
        end
    end)
    return snapshot
end

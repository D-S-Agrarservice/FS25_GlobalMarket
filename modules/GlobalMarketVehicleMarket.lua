-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleMarket.lua
-- Used vehicle market (#16), Stage 1 core: listing store, listing a vehicle, returning it
-- to the seller (incl. retry queue), savegame persistence and debug console commands.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarket.VEHICLE_MARKET = {
    PRICE_FACTOR_MIN = 0.70,  -- Asking price band relative to the dealer value
    PRICE_FACTOR_MAX = 1.30,
    DURATION_MIN = 1,         -- Listing duration in in-game months
    DURATION_MAX = 12,
    MAX_PER_FARM = 10,
    MAX_TOTAL = 100,
    NPC_COMMISSION = 0.05     -- Dealer commission when an NPC buys (Stage 1, step 5)
}

GlobalMarket.VEHICLE_LISTING_STATUS = {
    OPEN = "OPEN",
    BUYING = "BUYING",
    RETURN_PENDING = "RETURN_PENDING"
}

-- =========================================================================
-- STATE
-- =========================================================================

---Initializes the vehicle market tables (called on map load)
function GlobalMarket:initVehicleMarket()
    self.vehicleListings = {}
    self.nextVehicleListingId = 1
end

---Returns a listing by its local ID
---@param listingId number
---@return table|nil listing
---@return number|nil index
function GlobalMarket:getVehicleListingById(listingId)
    for index, listing in ipairs(self.vehicleListings or {}) do
        if listing.id == listingId then
            return listing, index
        end
    end
    return nil, nil
end

---Counts the listings of a farm (all states, a pending return still blocks a slot)
---@param farmId number
---@return number
function GlobalMarket:getVehicleListingCountForFarm(farmId)
    local count = 0
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.sellerFarmId == farmId then
            count = count + 1
        end
    end
    return count
end

---Removes a listing from the store
---@param listing table
function GlobalMarket:removeVehicleListing(listing)
    local _, index = self:getVehicleListingById(listing.id)
    if index ~= nil then
        table.remove(self.vehicleListings, index)
    end
end

---Returns the display name of a farm
---@param farmId number
---@return string
local function getFarmName(farmId)
    local farm = (g_farmManager ~= nil) and g_farmManager:getFarmById(farmId) or nil
    return (farm ~= nil and farm.name ~= nil) and farm.name or ("Farm " .. tostring(farmId))
end

-- =========================================================================
-- LISTING A VEHICLE (Server)
-- =========================================================================

---Lists a farm vehicle on the market: validates, snapshots and removes it from the world
---@param vehicle table
---@param farmId number
---@param priceFactor number Asking price relative to the dealer value
---@param durationMonths number
---@param connection table|nil Requesting connection
---@return table|nil listing
---@return string|nil reason Error code if the listing was rejected
function GlobalMarket:createVehicleListing(vehicle, farmId, priceFactor, durationMonths, connection)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return nil, "notServer"
    end
    local cfg = GlobalMarket.VEHICLE_MARKET
    local isEligible, reason = GlobalMarketVehicleListings.getEligibility(vehicle, farmId, connection)
    if not isEligible then
        return nil, reason
    end
    priceFactor = tonumber(priceFactor)
    if priceFactor == nil or priceFactor < cfg.PRICE_FACTOR_MIN - 0.0001 or priceFactor > cfg.PRICE_FACTOR_MAX + 0.0001 then
        return nil, "priceOutOfRange"
    end
    durationMonths = math.floor(tonumber(durationMonths) or 0)
    if durationMonths < cfg.DURATION_MIN or durationMonths > cfg.DURATION_MAX then
        return nil, "durationOutOfRange"
    end
    self.vehicleListings = self.vehicleListings or {}
    if #self.vehicleListings >= cfg.MAX_TOTAL then
        return nil, "marketFull"
    end
    if self:getVehicleListingCountForFarm(farmId) >= cfg.MAX_PER_FARM then
        return nil, "farmLimitReached"
    end

    local snapshot = GlobalMarketVehicleListings.captureSnapshot(vehicle)
    if snapshot == nil then
        return nil, "notTradeable"
    end
    -- The snapshot must restore 1:1 on this server before the vehicle is removed
    local resolved, resolveReason = GlobalMarketVehicleListings.resolveSnapshot(snapshot)
    if resolved == nil then
        return nil, resolveReason
    end

    local id = self.nextVehicleListingId or 1
    self.nextVehicleListingId = id + 1
    local serverId = (self.ensureServerInstanceId ~= nil) and self:ensureServerInstanceId() or (self.serverInstanceId or "")
    local listing = {
        id = id,
        uid = string.format("%s_v%d", serverId, id),
        status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN,
        sellerFarmId = farmId,
        sellerName = getFarmName(farmId),
        isNpc = false,
        saleMode = "FIXED",
        priceFactor = priceFactor,
        monthsRemaining = durationMonths,
        snapshot = snapshot
    }
    table.insert(self.vehicleListings, listing)
    vehicle:delete()

    if self.debugManager ~= nil then
        self.debugManager:info("VehicleMarket: Listing #%d created by farm %d (%s, %.0f%% of dealer value, %d months).",
            id, farmId, tostring(snapshot.xmlFilename), priceFactor * 100, durationMonths)
    end
    return listing, nil
end

-- =========================================================================
-- RETURN TO SELLER (Server)
-- =========================================================================

---Returns a listed vehicle to its seller at the store spawn places.
---On missing space or a missing store item the listing stays as RETURN_PENDING and is retried later.
---@param listing table
function GlobalMarket:returnVehicleListing(listing)
    if listing == nil or listing.isReturning then
        return
    end
    -- NPC listings have no physical vehicle to return
    if listing.isNpc then
        self:removeVehicleListing(listing)
        return
    end
    listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.RETURN_PENDING
    local resolved, reason = GlobalMarketVehicleListings.resolveSnapshot(listing.snapshot)
    if resolved == nil then
        if self.debugManager ~= nil then
            self.debugManager:warning("VehicleMarket: Listing #%d cannot be returned yet (%s). Kept as pending.", listing.id, tostring(reason))
        end
        return
    end
    listing.isReturning = true
    GlobalMarketVehicleListings.spawnFromSnapshot(listing.snapshot, resolved, listing.sellerFarmId,
        self.onVehicleListingReturned, self, { listing = listing })
end

---Loading callback of returnVehicleListing
function GlobalMarket:onVehicleListingReturned(vehicles, loadingState, args)
    local listing = args ~= nil and args.listing or nil
    if listing == nil then
        return
    end
    listing.isReturning = false
    if loadingState == VehicleLoadingState.OK then
        self:removeVehicleListing(listing)
        if self.debugManager ~= nil then
            self.debugManager:info("VehicleMarket: Listing #%d returned to farm %d.", listing.id, listing.sellerFarmId)
        end
    elseif self.debugManager ~= nil then
        self.debugManager:warning("VehicleMarket: Return of listing #%d failed (loading state %s). Retrying later.",
            listing.id, tostring(loadingState))
    end
end

---Withdraws an open listing of a farm and returns the vehicle
---@param listingId number
---@param farmId number
---@return boolean success
---@return string|nil reason
function GlobalMarket:cancelVehicleListing(listingId, farmId)
    local listing = self:getVehicleListingById(listingId)
    if listing == nil then
        return false, "listingNotFound"
    end
    if listing.sellerFarmId ~= farmId then
        return false, "notOwner"
    end
    if listing.status ~= GlobalMarket.VEHICLE_LISTING_STATUS.OPEN then
        return false, "listingBusy"
    end
    self:returnVehicleListing(listing)
    return true, nil
end

---Retries all pending returns (hourly from step 2 on, or via console)
---@return number count Number of retried listings
function GlobalMarket:retryPendingVehicleReturns()
    local pending = {}
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.RETURN_PENDING and not listing.isReturning then
            table.insert(pending, listing)
        end
    end
    for _, listing in ipairs(pending) do
        self:returnVehicleListing(listing)
    end
    return #pending
end

-- =========================================================================
-- SAVEGAME
-- =========================================================================

---Writes all listings into globalMarket.xml
---@param xmlFile table
function GlobalMarket:saveVehicleMarketToXml(xmlFile)
    if xmlFile == nil then
        return
    end
    local rootKey = "globalMarket.vehicleMarket"
    xmlFile:setInt(rootKey .. "#nextListingId", self.nextVehicleListingId or 1)
    for i, listing in ipairs(self.vehicleListings or {}) do
        local key = string.format("%s.listing(%d)", rootKey, i - 1)
        -- An interrupted purchase is saved as open again
        local status = listing.status
        if status == GlobalMarket.VEHICLE_LISTING_STATUS.BUYING then
            status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN
        end
        xmlFile:setInt(key .. "#id", listing.id)
        xmlFile:setString(key .. "#uid", listing.uid or "")
        xmlFile:setString(key .. "#status", status)
        xmlFile:setInt(key .. "#sellerFarmId", listing.sellerFarmId or 0)
        xmlFile:setString(key .. "#sellerName", listing.sellerName or "")
        xmlFile:setBool(key .. "#isNpc", listing.isNpc == true)
        xmlFile:setString(key .. "#saleMode", listing.saleMode or "FIXED")
        xmlFile:setFloat(key .. "#priceFactor", listing.priceFactor or 1)
        xmlFile:setFloat(key .. "#monthsRemaining", listing.monthsRemaining or 0)
        GlobalMarketVehicleListings.writeSnapshotToXml(xmlFile, key .. ".vehicle", listing.snapshot)
    end
end

---Loads all listings from globalMarket.xml (listings whose vehicle is unknown locally are kept, not deleted)
---@param xmlFile table
function GlobalMarket:loadVehicleMarketFromXml(xmlFile)
    self:initVehicleMarket()
    if xmlFile == nil then
        return
    end
    local rootKey = "globalMarket.vehicleMarket"
    local maxId = 0
    xmlFile:iterate(rootKey .. ".listing", function(_, key)
        local snapshot = GlobalMarketVehicleListings.readSnapshotFromXml(xmlFile, key .. ".vehicle")
        local id = xmlFile:getInt(key .. "#id")
        if snapshot ~= nil and id ~= nil then
            local status = xmlFile:getString(key .. "#status", GlobalMarket.VEHICLE_LISTING_STATUS.OPEN)
            if status == GlobalMarket.VEHICLE_LISTING_STATUS.BUYING then
                status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN
            end
            table.insert(self.vehicleListings, {
                id = id,
                uid = xmlFile:getString(key .. "#uid", ""),
                status = status,
                sellerFarmId = xmlFile:getInt(key .. "#sellerFarmId", 0),
                sellerName = xmlFile:getString(key .. "#sellerName", ""),
                isNpc = xmlFile:getBool(key .. "#isNpc", false),
                saleMode = xmlFile:getString(key .. "#saleMode", "FIXED"),
                priceFactor = xmlFile:getFloat(key .. "#priceFactor", 1),
                monthsRemaining = xmlFile:getFloat(key .. "#monthsRemaining", 0),
                snapshot = snapshot
            })
            maxId = math.max(maxId, id)
        end
    end)
    self.nextVehicleListingId = math.max(xmlFile:getInt(rootKey .. "#nextListingId", 1), maxId + 1)
    if self.debugManager ~= nil then
        self.debugManager:info("VehicleMarket: Loaded %d listing(s).", #self.vehicleListings)
    end
end

-- =========================================================================
-- DEBUG CONSOLE (SP / MP host only)
-- =========================================================================

---Returns the vehicles of a farm that are vehicle-market items (eligible or not)
---@param farmId number
---@return table vehicles
function GlobalMarket:getVehicleMarketFarmVehicles(farmId)
    local result = {}
    local vehicleSystem = g_currentMission ~= nil and g_currentMission.vehicleSystem or nil
    if vehicleSystem == nil or vehicleSystem.vehicles == nil then
        return result
    end
    for _, vehicle in ipairs(vehicleSystem.vehicles) do
        if vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() == farmId and vehicle.configFileName ~= nil then
            local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
            if GlobalMarketVehicleListings.getGroupForStoreItem(storeItem) ~= nil then
                table.insert(result, vehicle)
            end
        end
    end
    return result
end

---Shared guard for the vehicle market console commands
---@return string|nil errorText
local function getConsoleGuardError()
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "Execute vehicle market commands on the server/SP host."
    end
    return nil
end

---Console: lists the own vehicles (with eligibility and dealer value) and all listings
function GlobalMarket:consoleCommandVehicleMarketList()
    local guardError = getConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local farmId = g_currentMission:getFarmId()
    local lines = { string.format("Vehicles of farm %d:", farmId) }
    for index, vehicle in ipairs(self:getVehicleMarketFarmVehicles(farmId)) do
        local isEligible, reason = GlobalMarketVehicleListings.getEligibility(vehicle, farmId, nil)
        local name = (vehicle.getFullName ~= nil) and vehicle:getFullName() or tostring(vehicle.configFileName)
        local snapshot = GlobalMarketVehicleListings.captureSnapshot(vehicle)
        local resolved = (snapshot ~= nil) and GlobalMarketVehicleListings.resolveSnapshot(snapshot) or nil
        local value = (resolved ~= nil) and GlobalMarketVehicleListings.getDealerValue(snapshot, resolved) or 0
        table.insert(lines, string.format("  [%d] %s | %s | dealer %.0f | %s", index, name,
            snapshot ~= nil and snapshot.group or "-", value, isEligible and "eligible" or ("blocked: " .. tostring(reason))))
    end
    table.insert(lines, string.format("Listings (%d):", #(self.vehicleListings or {})))
    for _, listing in ipairs(self.vehicleListings or {}) do
        table.insert(lines, string.format("  #%d %s | farm %d | %s | %.0f%% | %.1f months | %d configs",
            listing.id, listing.status, listing.sellerFarmId, tostring(listing.snapshot.xmlFilename),
            (listing.priceFactor or 1) * 100, listing.monthsRemaining or 0, #(listing.snapshot.configs or {})))
    end
    return table.concat(lines, "\n")
end

---Console: lists an own vehicle by its index from gmVehicleMarketList
---@param indexArg string
---@param pricePctArg string|nil Asking price in percent of the dealer value (default 100)
---@param monthsArg string|nil Duration in months (default 3)
function GlobalMarket:consoleCommandVehicleMarketSell(indexArg, pricePctArg, monthsArg)
    local guardError = getConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    local farmId = g_currentMission:getFarmId()
    local vehicle = self:getVehicleMarketFarmVehicles(farmId)[tonumber(indexArg) or 0]
    if vehicle == nil then
        return "Usage: gmVehicleMarketSell <index from gmVehicleMarketList> [pricePercent=100] [months=3]"
    end
    local listing, reason = self:createVehicleListing(vehicle, farmId, (tonumber(pricePctArg) or 100) / 100, tonumber(monthsArg) or 3, nil)
    if listing == nil then
        return "Listing rejected: " .. tostring(reason)
    end
    return string.format("Listing #%d created (%d configs).", listing.id, #listing.snapshot.configs)
end

---Console: returns a listing to its seller (withdraw) or retries all pending returns
---@param listingIdArg string|nil Listing ID, or "pending" to retry pending returns
function GlobalMarket:consoleCommandVehicleMarketReturn(listingIdArg)
    local guardError = getConsoleGuardError()
    if guardError ~= nil then
        return guardError
    end
    if listingIdArg == "pending" then
        return string.format("Retried %d pending return(s).", self:retryPendingVehicleReturns())
    end
    local listing = self:getVehicleListingById(tonumber(listingIdArg) or 0)
    if listing == nil then
        return "Usage: gmVehicleMarketReturn <listingId|pending>"
    end
    self:returnVehicleListing(listing)
    return string.format("Return of listing #%d started (status %s).", listing.id, listing.status)
end

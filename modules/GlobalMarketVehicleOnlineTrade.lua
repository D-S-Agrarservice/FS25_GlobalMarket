-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleOnlineTrade.lua
-- Cross-server vehicle market (#36, spec section 3.6): buying online listings and the
-- settlements LISTING_SOLD / LISTING_EXPIRED / LISTING_BOUGHT. A purchase is booked only
-- through the redelivered LISTING_BOUGHT settlement; vehicles without a free store place
-- are delivered later (persisted).
-- Author: D-S-Agrarservice
-- =========================================================================================

-- A purchase request without backend answer releases its money reservation after this time
GlobalMarketVehicleOnline.BUY_TIMEOUT_MS = 300000
-- Purchase requests remembered (persisted) until they are rejected or settled, see cleanupVehicleBuysForDeletedFarm
GlobalMarketVehicleOnline.MAX_BUY_LOG = 64

-- Backend rejection reasons mapped to the local reason texts
local BUY_REJECT_REASONS = {
    LISTING_NOT_FOUND = "listingNotFound",
    LISTING_SOLD = "listingBusy",
    LISTING_BUSY = "listingBusy",
    OWN_LISTING = "ownListing"
}

-- =========================================================================
-- BUYING (Server)
-- =========================================================================

---Returns an open online listing by its backend ID (foreign or own server)
---@param remoteId string
---@return table|nil listing
function GlobalMarket:findOnlineVehicleListingByRemoteId(remoteId)
    if remoteId == nil or remoteId == "" then
        return nil
    end
    for _, list in ipairs({ self.onlineVehicleListings or {}, self.vehicleListings or {} }) do
        for _, listing in ipairs(list) do
            if listing.isOnline and listing.remoteId == remoteId then
                return listing
            end
        end
    end
    return nil
end

---Returns the money a farm has reserved for open online purchase requests
---@param farmId number
---@return number
function GlobalMarket:getReservedOnlineVehicleMoney(farmId)
    local sum = 0
    for _, buy in pairs(self.pendingVehicleBuys or {}) do
        if buy.farmId == farmId then
            sum = sum + (buy.price or 0)
        end
    end
    return sum
end

---Remembers which farm sent a purchase request (outlives the reservation timeout and a restart)
---@param actionId string
---@param farmId number
function GlobalMarket:addVehicleBuyLog(actionId, farmId)
    self.vehicleBuyLog = self.vehicleBuyLog or {}
    table.insert(self.vehicleBuyLog, { actionId = actionId, farmId = farmId })
    while #self.vehicleBuyLog > GlobalMarketVehicleOnline.MAX_BUY_LOG do
        table.remove(self.vehicleBuyLog, 1)
    end
end

---Forgets a purchase request that was rejected or settled
---@param actionId string|nil
function GlobalMarket:removeVehicleBuyLog(actionId)
    for i, entry in ipairs(self.vehicleBuyLog or {}) do
        if entry.actionId == actionId then
            table.remove(self.vehicleBuyLog, i)
            return
        end
    end
end

---Sends BUY_LISTING for an online listing; money is reserved, charged with LISTING_BOUGHT
---@param remoteId string
---@param buyerFarmId number
---@param licensePlateData table|nil
---@return boolean started
---@return string|nil reason
function GlobalMarket:buyOnlineVehicleListing(remoteId, buyerFarmId, licensePlateData)
    if g_server == nil then
        return false, "notServer"
    end
    if not self:getAreOnlineVehiclesAvailable() then
        return false, "onlineUnavailable"
    end
    local listing = self:findOnlineVehicleListingByRemoteId(remoteId)
    if listing == nil then
        return false, "listingNotFound"
    end
    if listing.status ~= GlobalMarket.VEHICLE_LISTING_STATUS.OPEN then
        return false, "listingBusy"
    end
    if not listing.isRemote and listing.sellerFarmId == buyerFarmId then
        return false, "ownListing"
    end
    local resolved, reason = GlobalMarketVehicleListings.resolveSnapshot(listing.snapshot)
    if resolved == nil then
        return false, reason
    end
    local price = math.floor(GlobalMarketVehicleListings.getDealerValue(listing.snapshot, resolved) * (listing.priceFactor or 1) + 0.5)
    if g_currentMission:getMoney(buyerFarmId) - self:getReservedOnlineVehicleMoney(buyerFarmId) < price then
        return false, "notEnoughMoney"
    end
    local payload = { subAction = "BUY_LISTING", farmId = buyerFarmId,
        farmName = self:formatOnlineIssuerDisplayName(buyerFarmId), remoteId = remoteId }
    if not self:dispatchVehicleAction(payload) then
        return false, "onlineUnavailable"
    end
    self.pendingVehicleBuys = self.pendingVehicleBuys or {}
    self.pendingVehicleBuys[payload.actionId] = {
        farmId = buyerFarmId,
        remoteId = remoteId,
        price = price,
        licensePlateData = licensePlateData,
        createdAtMs = g_time or 0
    }
    self:addVehicleBuyLog(payload.actionId, buyerFarmId)
    listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.BUYING
    self:broadcastVehicleMarketState()
    return true, nil
end

---Applies the backend answer to an own BUY_LISTING request (the vehicle comes with LISTING_BOUGHT)
---@param result table
---@return boolean changed
function GlobalMarket:applyVehicleBuyResult(result)
    if result.status ~= "ACCEPTED" then
        self:removeVehicleBuyLog(result.actionId)
    end
    local buy = (self.pendingVehicleBuys or {})[result.actionId]
    if buy == nil then
        return false
    end
    if result.status == "ACCEPTED" then
        buy.accepted = true
        return false
    end
    self.pendingVehicleBuys[result.actionId] = nil
    local listing = self:findOnlineVehicleListingByRemoteId(buy.remoteId)
    if listing ~= nil and listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.BUYING then
        listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN
    end
    self:notifyVehicleMarketFarms(GlobalMarket.VEHICLE_NOTICE.RESULT, buy.farmId, 0,
        BUY_REJECT_REASONS[result.reason] or GlobalMarketVehicleOnline.getRejectCode(result.reason), "", 0, "")
    return true
end

---Releases purchase reservations without backend answer (called every frame on the server)
function GlobalMarket:updateOnlineVehicleBuys()
    local now = g_time or 0
    for actionId, buy in pairs(self.pendingVehicleBuys or {}) do
        if now - (buy.createdAtMs or 0) >= GlobalMarketVehicleOnline.BUY_TIMEOUT_MS then
            self.pendingVehicleBuys[actionId] = nil
            local listing = self:findOnlineVehicleListingByRemoteId(buy.remoteId)
            if not buy.accepted and listing ~= nil and listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.BUYING then
                listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN
                self:broadcastVehicleMarketState()
            end
        end
    end
end

-- =========================================================================
-- SETTLEMENTS (Server)
-- =========================================================================

---Finds the own online listing a settlement refers to (remoteId, or createActionId if the create result was lost)
---@param settlement table
---@return table|nil listing
function GlobalMarket:findOwnOnlineVehicleListing(settlement)
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isOnline and ((settlement.remoteId ~= "" and listing.remoteId == settlement.remoteId)
            or (settlement.createActionId ~= "" and listing.createActionId == settlement.createActionId)) then
            return listing
        end
    end
    return nil
end

---Returns true if a farm still exists on this savegame
---@param farmId number
---@return boolean
local function getFarmExists(farmId)
    return farmId ~= nil and farmId > 0 and g_farmManager ~= nil and g_farmManager:getFarmById(farmId) ~= nil
end

---LISTING_SOLD: pays the seller priceFactor x the dealer value at listing time and closes the listing
---@param settlement table
function GlobalMarket:applyVehicleSoldSettlement(settlement)
    local listing = self:findOwnOnlineVehicleListing(settlement)
    if listing == nil then
        return
    end
    local factor = (settlement.priceFactor or 0) > 0 and settlement.priceFactor or (listing.priceFactor or 1)
    local value = listing.listedValue or 0
    if value <= 0 then
        local resolved = GlobalMarketVehicleListings.resolveSnapshot(listing.snapshot)
        value = (resolved ~= nil) and GlobalMarketVehicleListings.getDealerValue(listing.snapshot, resolved) or 0
    end
    local payout = math.floor(value * factor + 0.5)
    self:removeVehicleListing(listing)
    if getFarmExists(listing.sellerFarmId) then
        g_currentMission:addMoney(payout, listing.sellerFarmId, MoneyType.SHOP_VEHICLE_SELL, true, true)
        self:notifyVehicleMarketFarms(GlobalMarket.VEHICLE_NOTICE.SOLD, listing.sellerFarmId, 0, "",
            listing.snapshot.xmlFilename, payout, settlement.otherName or "")
    end
end

---LISTING_EXPIRED: returns the escrowed vehicle to its seller
---@param settlement table
function GlobalMarket:applyVehicleExpiredSettlement(settlement)
    local listing = self:findOwnOnlineVehicleListing(settlement)
    if listing == nil then
        return
    end
    self:notifyVehicleMarketFarms(GlobalMarket.VEHICLE_NOTICE.EXPIRED, listing.sellerFarmId, 0, "", listing.snapshot.xmlFilename, 0, "")
    self:returnVehicleListing(listing)
end

---LISTING_BOUGHT: queues the vehicle for delivery to the buyer (charged once it stands at the dealer)
---@param settlement table
function GlobalMarket:applyVehicleBoughtSettlement(settlement)
    local buy = (self.pendingVehicleBuys or {})[settlement.buyActionId]
    if buy ~= nil then
        self.pendingVehicleBuys[settlement.buyActionId] = nil
    end
    self:removeVehicleBuyLog(settlement.buyActionId)
    -- The bought foreign listing is gone from the market
    for i, listing in ipairs(self.onlineVehicleListings or {}) do
        if listing.remoteId == settlement.remoteId then
            table.remove(self.onlineVehicleListings, i)
            break
        end
    end
    if self.isOrphanedOnlineRemoteId ~= nil and self:isOrphanedOnlineRemoteId(settlement.buyActionId) then
        -- Bought by a deleted farm (#30): acknowledged, never booked onto a farm with the same ID
        if self.debugManager ~= nil then
            self.debugManager:info("VehicleOnline: LISTING_BOUGHT %s belongs to a deleted farm, dropped.", settlement.settlementId)
        end
        return
    end
    if not getFarmExists(settlement.targetFarmId) or settlement.snapshot == nil then
        if self.debugManager ~= nil then
            self.debugManager:warning("VehicleOnline: LISTING_BOUGHT %s for missing farm %d or without vehicle, dropped.",
                settlement.settlementId, settlement.targetFarmId or 0)
        end
        return
    end
    local resolved = GlobalMarketVehicleListings.resolveSnapshot(settlement.snapshot)
    if resolved == nil then
        self:notifyVehicleMarketFarms(GlobalMarket.VEHICLE_NOTICE.RESULT, settlement.targetFarmId, 0, "notAvailable", "", 0, "")
        return
    end
    local value = GlobalMarketVehicleListings.getDealerValue(settlement.snapshot, resolved)
    self.pendingVehicleDeliveries = self.pendingVehicleDeliveries or {}
    table.insert(self.pendingVehicleDeliveries, {
        farmId = settlement.targetFarmId,
        price = math.floor(value * ((settlement.priceFactor or 0) > 0 and settlement.priceFactor or 1) + 0.5),
        snapshot = settlement.snapshot,
        licensePlateData = (buy ~= nil) and buy.licensePlateData or nil
    })
    self:processVehicleDeliveries()
end

---Applies settlements once (shared deduplication log with Stage 2). They are acknowledged after the next
---save (GlobalMarketSettlementAck), so a crash redelivers what the savegame does not contain.
---@param settlements table
---@return boolean changed
function GlobalMarket:applyVehicleSettlements(settlements)
    local ownServerId = self:ensureServerInstanceId()
    local acks = {}
    local changed = false
    for _, s in ipairs(settlements) do
        if s.targetServerId == "" or s.targetServerId == ownServerId then
            if not (self.processedSettlementLookup or {})[s.settlementId] then
                if s.type == "LISTING_SOLD" then
                    self:applyVehicleSoldSettlement(s)
                elseif s.type == "LISTING_EXPIRED" then
                    self:applyVehicleExpiredSettlement(s)
                elseif s.type == "LISTING_BOUGHT" then
                    self:applyVehicleBoughtSettlement(s)
                elseif self.debugManager ~= nil then
                    self.debugManager:warning("VehicleOnline: Unknown settlement type '%s' (%s) acknowledged.", s.type, s.settlementId)
                end
                self:markSettlementProcessed(s.settlementId)
                self:deferSettlementAck(GlobalMarketSettlementAck.VEHICLES, s.settlementId)
                changed = true
            elseif not self:isSettlementAckDeferred(s.settlementId) then
                -- Saved earlier, but the ACK was lost or not possible
                table.insert(acks, s.settlementId)
            end
        end
    end
    self:sendSettlementAck(GlobalMarketSettlementAck.VEHICLES, table.concat(acks, ","))
    return changed
end

-- =========================================================================
-- DELIVERIES (Server, persisted)
-- =========================================================================

---Spawns all waiting bought vehicles at the store places (retried hourly while there is no space)
function GlobalMarket:processVehicleDeliveries()
    for i = #(self.pendingVehicleDeliveries or {}), 1, -1 do
        local delivery = self.pendingVehicleDeliveries[i]
        if not delivery.isLoading then
            local resolved = GlobalMarketVehicleListings.resolveSnapshot(delivery.snapshot)
            if resolved == nil or not getFarmExists(delivery.farmId) then
                -- Mod removed or farm deleted since the purchase: nothing to deliver, nothing charged
                table.remove(self.pendingVehicleDeliveries, i)
                if self.debugManager ~= nil then
                    self.debugManager:warning("VehicleOnline: Dropped delivery of %s for farm %d.",
                        tostring(delivery.snapshot.xmlFilename), delivery.farmId or 0)
                end
            else
                delivery.isLoading = true
                GlobalMarketVehicleListings.spawnFromSnapshot(delivery.snapshot, resolved, delivery.farmId,
                    self.onVehicleDeliveryLoaded, self, { delivery = delivery })
            end
        end
    end
end

---Loading callback of processVehicleDeliveries: the buyer pays once the vehicle exists
function GlobalMarket:onVehicleDeliveryLoaded(vehicles, loadingState, args)
    local delivery = args ~= nil and args.delivery or nil
    if delivery == nil then
        return
    end
    delivery.isLoading = false
    if delivery.isFarmDeleted then
        -- The farm was deleted while its vehicle was loading: nobody owns or pays it
        for _, vehicle in ipairs(vehicles or {}) do
            if not vehicle.isDeleted then
                vehicle:delete()
            end
        end
        return
    end
    local N = GlobalMarket.VEHICLE_NOTICE
    if loadingState ~= VehicleLoadingState.OK then
        if not delivery.isNotified then
            delivery.isNotified = true
            self:notifyVehicleMarketFarms(N.DELIVERY_PENDING, delivery.farmId, 0, "", delivery.snapshot.xmlFilename, 0, "")
        end
        return
    end
    GlobalMarket.applyVehicleMarketLicensePlate(vehicles, delivery.licensePlateData)
    g_currentMission:addMoney(-delivery.price, delivery.farmId, MoneyType.SHOP_VEHICLE_BUY, true, true)
    for i, entry in ipairs(self.pendingVehicleDeliveries or {}) do
        if entry == delivery then
            table.remove(self.pendingVehicleDeliveries, i)
            break
        end
    end
    self:notifyVehicleMarketFarms(N.BOUGHT, delivery.farmId, 0, "", delivery.snapshot.xmlFilename, delivery.price, "")
    self:broadcastVehicleMarketState()
end

---Drops purchases and deliveries of a deleted farm, so a new farm with the reused ID inherits nothing (#30)
---@param farmId number
---@return boolean changed
function GlobalMarket:cleanupVehicleBuysForDeletedFarm(farmId)
    local changed = false
    -- Late LISTING_BOUGHT settlements are recognized by the actionId (persisted orphan list)
    for i = #(self.vehicleBuyLog or {}), 1, -1 do
        local entry = self.vehicleBuyLog[i]
        if entry.farmId == farmId then
            self:markOrphanedOnlineRemoteId(entry.actionId)
            table.remove(self.vehicleBuyLog, i)
        end
    end
    for actionId, buy in pairs(self.pendingVehicleBuys or {}) do
        if buy.farmId == farmId then
            self:markOrphanedOnlineRemoteId(actionId)
            self.pendingVehicleBuys[actionId] = nil
            local listing = self:findOnlineVehicleListingByRemoteId(buy.remoteId)
            if not buy.accepted and listing ~= nil and listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.BUYING then
                listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN
            end
            changed = true
        end
    end
    for i = #(self.pendingVehicleDeliveries or {}), 1, -1 do
        local delivery = self.pendingVehicleDeliveries[i]
        if delivery.farmId == farmId then
            -- A vehicle that is loading right now is removed in onVehicleDeliveryLoaded
            delivery.isFarmDeleted = true
            table.remove(self.pendingVehicleDeliveries, i)
            changed = true
        end
    end
    return changed
end

---Writes waiting deliveries and open purchase requests below the vehicle market key
---@param xmlFile table
---@param rootKey string
function GlobalMarket:saveVehicleDeliveriesToXml(xmlFile, rootKey)
    for i, delivery in ipairs(self.pendingVehicleDeliveries or {}) do
        local key = string.format("%s.delivery(%d)", rootKey, i - 1)
        xmlFile:setInt(key .. "#farmId", delivery.farmId)
        xmlFile:setInt(key .. "#price", delivery.price)
        xmlFile:setBool(key .. "#isNotified", delivery.isNotified == true)
        GlobalMarketVehicleListings.writeSnapshotToXml(xmlFile, key .. ".vehicle", delivery.snapshot)
    end
    for i, entry in ipairs(self.vehicleBuyLog or {}) do
        local key = string.format("%s.openBuy(%d)", rootKey, i - 1)
        xmlFile:setString(key .. "#actionId", entry.actionId)
        xmlFile:setInt(key .. "#farmId", entry.farmId)
    end
end

---Reads waiting deliveries and open purchase requests (license plates are not kept, a random one is used)
---@param xmlFile table
---@param rootKey string
function GlobalMarket:loadVehicleDeliveriesFromXml(xmlFile, rootKey)
    self.pendingVehicleDeliveries = {}
    xmlFile:iterate(rootKey .. ".delivery", function(_, key)
        local snapshot = GlobalMarketVehicleListings.readSnapshotFromXml(xmlFile, key .. ".vehicle")
        if snapshot ~= nil then
            table.insert(self.pendingVehicleDeliveries, {
                farmId = xmlFile:getInt(key .. "#farmId", 0),
                price = xmlFile:getInt(key .. "#price", 0),
                isNotified = xmlFile:getBool(key .. "#isNotified", false),
                snapshot = snapshot
            })
        end
    end)
    self.vehicleBuyLog = {}
    xmlFile:iterate(rootKey .. ".openBuy", function(_, key)
        local actionId = xmlFile:getString(key .. "#actionId", "")
        if actionId ~= "" then
            self:addVehicleBuyLog(actionId, xmlFile:getInt(key .. "#farmId", 0))
        end
    end)
end

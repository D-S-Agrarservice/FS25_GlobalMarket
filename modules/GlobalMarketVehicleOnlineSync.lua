-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleOnlineSync.lua
-- Cross-server vehicle market (#36, spec section 3.6): incoming read/gmVehicleSync_*.xml
-- (action="vehicleData"). The Data-Host parses the file and hands the packet to the server,
-- which applies action results, reconciles escrowed own listings with the listing snapshot
-- and keeps the foreign listings that exist on this server for display.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketVehicleOnline.MAX_REMOTE_LISTINGS = 200
GlobalMarketVehicleOnline.MAX_RESULTS = 64
GlobalMarketVehicleOnline.MAX_SETTLEMENTS = 64
-- A pending request is only reconciled after this time, so a snapshot built before the
-- backend processed the request never cancels or repeats it
GlobalMarketVehicleOnline.RECONCILE_GRACE_MS = 120000

-- =========================================================================
-- PARSING (Data-Host)
-- =========================================================================

---Parses <gmDataSync action="vehicleData"> into a packet and queues it for flushVehicleSyncPackets
---@param xmlFile table
function GlobalMarket:readVehicleSyncXml(xmlFile)
    local V = GlobalMarketVehicleOnline
    local packet = { hasListings = xmlFile:hasProperty("gmDataSync.listings"), listings = {}, actionResults = {}, settlements = {} }

    xmlFile:iterate("gmDataSync.listings.listing", function(_, key)
        if #packet.listings >= V.MAX_REMOTE_LISTINGS then
            return false
        end
        local remoteId = xmlFile:getString(key .. "#remoteId", "")
        local snapshot = V.readVehicleXml(xmlFile, key .. ".vehicle")
        if remoteId ~= "" and snapshot ~= nil then
            table.insert(packet.listings, {
                remoteId = remoteId,
                createActionId = xmlFile:getString(key .. "#createActionId", ""),
                saleMode = string.upper(xmlFile:getString(key .. "#saleMode", "FIXED")),
                sellerServerId = xmlFile:getString(key .. "#sellerServerId", ""),
                sellerFarmId = math.max(0, xmlFile:getInt(key .. "#sellerFarmId", 0)),
                sellerName = xmlFile:getString(key .. "#sellerName", "Online"),
                priceFactor = xmlFile:getFloat(key .. "#priceFactor", 1),
                remainingSeconds = math.max(0, xmlFile:getInt(key .. "#remainingSeconds", 0)),
                status = string.upper(xmlFile:getString(key .. "#status", "OPEN")),
                snapshot = snapshot
            })
        end
        return true
    end)

    xmlFile:iterate("gmDataSync.actionResults.result", function(_, key)
        if #packet.actionResults >= V.MAX_RESULTS then
            return false
        end
        local actionId = xmlFile:getString(key .. "#actionId", "")
        if actionId ~= "" then
            table.insert(packet.actionResults, {
                actionId = actionId,
                subAction = string.upper(xmlFile:getString(key .. "#subAction", "")),
                status = string.upper(xmlFile:getString(key .. "#status", "REJECTED")),
                reason = xmlFile:getString(key .. "#reason", ""),
                remoteId = xmlFile:getString(key .. "#remoteId", ""),
                remainingSeconds = math.max(0, xmlFile:getInt(key .. "#remainingSeconds", 0)),
                snapshot = V.readVehicleXml(xmlFile, key .. ".vehicle")
            })
        end
        return true
    end)

    xmlFile:iterate("gmDataSync.settlements.settlement", function(_, key)
        if #packet.settlements >= V.MAX_SETTLEMENTS then
            return false
        end
        local settlementId = xmlFile:getString(key .. "#settlementId", "")
        if settlementId ~= "" then
            table.insert(packet.settlements, {
                settlementId = settlementId,
                type = string.upper(xmlFile:getString(key .. "#type", "")),
                targetServerId = xmlFile:getString(key .. "#targetServerId", ""),
                targetFarmId = math.max(0, xmlFile:getInt(key .. "#targetFarmId", 0)),
                remoteId = xmlFile:getString(key .. "#remoteId", ""),
                buyActionId = xmlFile:getString(key .. "#buyActionId", ""),
                priceFactor = xmlFile:getFloat(key .. "#priceFactor", 1),
                otherName = xmlFile:getString(key .. "#buyerName", xmlFile:getString(key .. "#sellerName", "")),
                snapshot = V.readVehicleXml(xmlFile, key .. ".vehicle")
            })
        end
        return true
    end)

    self.pendingVehicleSyncPackets = self.pendingVehicleSyncPackets or {}
    table.insert(self.pendingVehicleSyncPackets, packet)
end

---Applies queued packets on the server, or relays them from a remote Data-Host to the server
function GlobalMarket:flushVehicleSyncPackets()
    local queue = self.pendingVehicleSyncPackets
    if queue == nil or #queue == 0 then
        return
    end
    self.pendingVehicleSyncPackets = {}
    for _, packet in ipairs(queue) do
        if g_server ~= nil then
            self:applyVehicleSyncPacket(packet)
        elseif g_client ~= nil and VehicleOnlineBridgeEvent ~= nil then
            g_client:getServerConnection():sendEvent(VehicleOnlineBridgeEvent.newSyncPacket(packet))
        end
    end
end

-- =========================================================================
-- APPLY (Server)
-- =========================================================================

---Applies one vehicleData packet (results first, then the listing snapshot)
---@param packet table
function GlobalMarket:applyVehicleSyncPacket(packet)
    if g_server == nil or packet == nil then
        return
    end
    local changed = false
    for _, result in ipairs(packet.actionResults or {}) do
        changed = self:applyVehicleActionResult(result) or changed
    end
    if packet.hasListings then
        changed = self:applyVehicleListingSnapshot(packet.listings or {}) or changed
    end
    if self.applyVehicleSettlements ~= nil and #(packet.settlements or {}) > 0 then
        changed = self:applyVehicleSettlements(packet.settlements) or changed
    end
    if changed then
        self:broadcastVehicleMarketState()
    end
end

---Finds the own online listing a request belongs to
---@param actionId string
---@return table|nil listing
---@return string|nil kind "CREATE" or "CANCEL"
function GlobalMarket:findOnlineVehicleListingByAction(actionId)
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isOnline then
            if listing.createActionId == actionId then
                return listing, "CREATE"
            elseif listing.cancelActionId == actionId then
                return listing, "CANCEL"
            end
        end
    end
    return nil, nil
end

---Applies the backend result of an own CREATE_LISTING or CANCEL_LISTING request
---@param result table
---@return boolean changed
function GlobalMarket:applyVehicleActionResult(result)
    local S = GlobalMarket.VEHICLE_LISTING_STATUS
    local N = GlobalMarket.VEHICLE_NOTICE
    local listing, kind = self:findOnlineVehicleListingByAction(result.actionId)
    if listing == nil then
        return false
    end
    local accepted = (result.status == "ACCEPTED")

    if kind == "CREATE" and listing.status == S.PENDING_CREATE then
        if accepted then
            listing.remoteId = (result.remoteId ~= "") and result.remoteId or listing.remoteId
            listing.status = S.OPEN
            if result.remainingSeconds > 0 then
                listing.remainingSeconds = result.remainingSeconds
            end
            self:notifyVehicleMarketFarms(N.LISTED, listing.sellerFarmId, 0, "", listing.snapshot.xmlFilename,
                GlobalMarketVehicleListings.getListingPrice(listing) or 0, "")
        else
            self:notifyVehicleMarketFarms(N.RESULT, listing.sellerFarmId, 0, "onlineRejected", "", 0, "")
            self:returnVehicleListing(listing)
        end
    elseif kind == "CANCEL" then
        if accepted then
            -- Covers a user withdrawal and the reconcile cancel of a lost CREATE (reason NOT_CREATED)
            self:returnVehicleListing(listing)
        elseif result.reason == "LISTING_SOLD" then
            -- The LISTING_SOLD settlement pays the seller; the listing waits for it
            listing.status = S.PENDING_CANCEL
        elseif listing.status == S.PENDING_CANCEL then
            listing.status = S.OPEN
            listing.cancelActionId = nil
            self:notifyVehicleMarketFarms(N.RESULT, listing.sellerFarmId, 0, "onlineRejected", "", 0, "")
        else
            -- Reconcile cancel of a PENDING_CREATE was refused: try again after the next snapshot
            listing.cancelActionId = nil
            listing.pendingSinceMs = g_time
        end
    else
        return false
    end
    if self.debugManager ~= nil then
        self.debugManager:info("VehicleOnline: %s result %s for listing #%d (%s).", kind, result.status, listing.id, result.reason or "")
    end
    return true
end

---Returns true if a pending own request is older than the reconcile grace time
---@param listing table
---@return boolean
local function isPastGrace(listing)
    if listing.pendingSinceMs == nil then
        -- Restored from the savegame: start the grace time now
        listing.pendingSinceMs = g_time or 0
        return false
    end
    return (g_time or 0) - listing.pendingSinceMs >= GlobalMarketVehicleOnline.RECONCILE_GRACE_MS
end

---Reconciles own online listings with a full listing snapshot and stores the foreign listings
---@param entries table Parsed listings
---@return boolean changed
function GlobalMarket:applyVehicleListingSnapshot(entries)
    local S = GlobalMarket.VEHICLE_LISTING_STATUS
    local ownServerId = self:ensureServerInstanceId()
    local ownByRemote, ownByCreate = {}, {}
    local remote = {}
    for _, entry in ipairs(entries) do
        if entry.sellerServerId == ownServerId then
            ownByRemote[entry.remoteId] = entry
            if entry.createActionId ~= "" then
                ownByCreate[entry.createActionId] = entry
            end
        elseif entry.status == "OPEN" and entry.saleMode == "FIXED"
            and GlobalMarketVehicleListings.resolveSnapshot(entry.snapshot) ~= nil then
            -- Only vehicles that exist exactly on this server (store item, mod hash, configurations)
            entry.snapshot.group = GlobalMarketVehicleListings.getGroupForStoreItem(
                GlobalMarketVehicleListings.resolveSnapshot(entry.snapshot).storeItem) or "MISC"
            table.insert(remote, {
                id = 0,
                uid = entry.remoteId,
                remoteId = entry.remoteId,
                isRemote = true,
                isOnline = true,
                status = S.OPEN,
                sellerFarmId = 0,
                sellerName = entry.sellerName,
                isNpc = false,
                saleMode = entry.saleMode,
                priceFactor = math.max(GlobalMarket.VEHICLE_MARKET.PRICE_FACTOR_MIN,
                    math.min(GlobalMarket.VEHICLE_MARKET.PRICE_FACTOR_MAX, entry.priceFactor or 1)),
                monthsRemaining = 0,
                remainingSeconds = entry.remainingSeconds,
                snapshot = entry.snapshot
            })
        end
    end

    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isOnline then
            local entry = (listing.remoteId ~= nil and ownByRemote[listing.remoteId])
                or (listing.createActionId ~= nil and ownByCreate[listing.createActionId]) or nil
            if listing.status == S.PENDING_CREATE then
                if entry ~= nil then
                    listing.remoteId = entry.remoteId
                    listing.status = S.OPEN
                    listing.remainingSeconds = entry.remainingSeconds
                elseif listing.cancelActionId == nil and isPastGrace(listing) then
                    -- CREATE result lost and the listing is unknown: cancel by createActionId, return on ACCEPTED
                    local payload = { subAction = "CANCEL_LISTING", farmId = listing.sellerFarmId, createActionId = listing.createActionId }
                    if self:dispatchVehicleAction(payload) then
                        listing.cancelActionId = payload.actionId
                    end
                end
            elseif listing.status == S.OPEN and entry ~= nil then
                listing.remainingSeconds = entry.remainingSeconds
            elseif listing.status == S.PENDING_CANCEL and entry ~= nil and entry.status == "OPEN" and isPastGrace(listing) then
                -- Cancel result lost: repeat the request with the same actionId (idempotent at the backend)
                self:dispatchVehicleAction({ subAction = "CANCEL_LISTING", actionId = listing.cancelActionId,
                    farmId = listing.sellerFarmId, remoteId = listing.remoteId })
                listing.pendingSinceMs = g_time
            end
        end
    end

    -- Admin switch off or offline: own listings are still reconciled, foreign ones are not shown
    self.onlineVehicleListings = self:getAreOnlineVehiclesAvailable() and remote or {}
    return true
end

---Server: drops the foreign online listings (offline, admin switch off)
function GlobalMarket:clearRemoteVehicleListings()
    if #(self.onlineVehicleListings or {}) == 0 then
        return
    end
    self.onlineVehicleListings = {}
    self:broadcastVehicleMarketState()
end

---Client: applies the foreign online listings received with the vehicle market state
---@param listings table
function GlobalMarket:applyRemoteVehicleListings(listings)
    self.onlineVehicleListings = listings or {}
end

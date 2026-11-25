-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleOnlineSync.lua
-- Cross-server vehicle market (#36, spec section 3.6): incoming read/gmVehicleSync_*.xml
-- (action="vehicleData"). The Data-Host parses the file and hands the packet to the server,
-- which applies action results, reconciles escrowed own listings with the listing snapshot
-- and keeps the foreign listings that exist on this server for display.
-- Author: D-S-Agrarservice
-- =========================================================================================

-- Foreign listings kept per file; the own ones (the only ones with a seller server ID) always fit
GlobalMarketVehicleOnline.MAX_REMOTE_LISTINGS = 200
GlobalMarketVehicleOnline.MAX_OWN_LISTINGS = 400
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
    local packet = { hasListings = xmlFile:hasProperty("gmDataSync.listings"), listings = {}, actionResults = {}, settlements = {},
        serverIdentity = GlobalMarketServerIdentity.readXml(xmlFile) }

    local numOwn, numForeign = 0, 0
    xmlFile:iterate("gmDataSync.listings.listing", function(_, key)
        local remoteId = xmlFile:getString(key .. "#remoteId", "")
        local isOwn = xmlFile:getString(key .. "#sellerServerId", "") ~= ""
        local hasSpace = (isOwn and numOwn < V.MAX_OWN_LISTINGS) or (not isOwn and numForeign < V.MAX_REMOTE_LISTINGS)
        local snapshot = hasSpace and V.readVehicleXml(xmlFile, key .. ".vehicle") or nil
        if remoteId ~= "" and snapshot ~= nil then
            numOwn = numOwn + (isOwn and 1 or 0)
            numForeign = numForeign + (isOwn and 0 or 1)
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
        local subAction = string.upper(xmlFile:getString(key .. "#subAction", ""))
        local status = string.upper(xmlFile:getString(key .. "#status", "REJECTED"))
        -- Accepted housekeeping needs no reaction and must not push real answers out of the list
        local isSilent = status == "ACCEPTED" and (subAction == "REQUEST_SYNC" or subAction == "ACK_SETTLEMENT")
        if actionId ~= "" and not isSilent then
            table.insert(packet.actionResults, {
                actionId = actionId,
                subAction = subAction,
                status = status,
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
                createActionId = xmlFile:getString(key .. "#createActionId", ""),
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
    -- The secret is sent only once (#42): store it before anything else
    self:applyServerIdentity(packet.serverIdentity)
    local changed = false
    for _, result in ipairs(packet.actionResults or {}) do
        local handled = self:applyVehicleActionResult(result)
        if not handled and result.reason == GlobalMarketServerIdentity.REASON_SECRET_INVALID then
            -- No own listing or purchase to report it on (e.g. REQUEST_SYNC)
            self:notifyOnlineIdentityRejected()
        end
        changed = handled or changed
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

---Returns the notice code of a backend rejection (a text of its own if the farm can act on the reason)
---@param reason string|nil
---@return string code
function GlobalMarketVehicleOnline.getRejectCode(reason)
    if reason == "LIMIT_REACHED" or reason == "EXPIRED" then
        return "online_" .. reason
    end
    return "onlineRejected"
end

---Handles a rejected savegame credential (#43): the backend did not look at the request, so nothing
---changes. The escrow and the purchase stay as they are until a real answer arrives.
---@param result table
---@return boolean handled
function GlobalMarket:applyVehicleIdentityRejection(result)
    local buy = (self.pendingVehicleBuys or {})[result.actionId]
    local listing = self:findOnlineVehicleListingByAction(result.actionId)
    local farmId = (buy ~= nil and buy.farmId) or (listing ~= nil and listing.sellerFarmId) or nil
    -- Repeated requests for the same listing only raise the rate-limited savegame-wide notice
    if farmId == nil or (listing ~= nil and listing.isIdentityNotified) then
        return false
    end
    if listing ~= nil then
        listing.isIdentityNotified = true
    end
    self:notifyVehicleMarketFarms(GlobalMarket.VEHICLE_NOTICE.RESULT, farmId, 0, "onlineIdentityRejected", "", 0, "")
    return true
end

---Applies the backend result of an own CREATE_LISTING or CANCEL_LISTING request
---@param result table
---@return boolean changed
function GlobalMarket:applyVehicleActionResult(result)
    if result.status ~= "ACCEPTED" and result.reason == GlobalMarketServerIdentity.REASON_SECRET_INVALID then
        return self:applyVehicleIdentityRejection(result)
    end
    if result.subAction == "BUY_LISTING" and self.applyVehicleBuyResult ~= nil then
        return self:applyVehicleBuyResult(result)
    end
    local S = GlobalMarket.VEHICLE_LISTING_STATUS
    local N = GlobalMarket.VEHICLE_NOTICE
    local listing, kind = self:findOnlineVehicleListingByAction(result.actionId)
    if listing == nil then
        return false
    end
    if listing.status == S.RETURN_PENDING then
        -- The vehicle is already on its way back: repeated results change nothing
        return false
    end
    local accepted = (result.status == "ACCEPTED")
    local rejectCode = GlobalMarketVehicleOnline.getRejectCode(result.reason)

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
            self:notifyVehicleMarketFarms(N.RESULT, listing.sellerFarmId, 0, rejectCode, "", 0, "")
            self:returnVehicleListing(listing)
        end
    elseif kind == "CANCEL" then
        if accepted then
            -- Covers a user withdrawal and the reconcile cancel of a lost CREATE (reason NOT_CREATED)
            self:returnVehicleListing(listing)
        elseif result.reason == "LISTING_SOLD" or result.reason == "EXPIRED" then
            -- The LISTING_SOLD settlement pays the seller, LISTING_EXPIRED returns the vehicle: the listing
            -- waits for it (PENDING_CANCEL without a cancelActionId is not asked for again)
            listing.status = S.PENDING_CANCEL
            listing.cancelActionId = nil
        elseif listing.status == S.PENDING_CANCEL then
            listing.status = S.OPEN
            listing.cancelActionId = nil
            self:notifyVehicleMarketFarms(N.RESULT, listing.sellerFarmId, 0, rejectCode, "", 0, "")
        else
            -- Reconcile cancel of a PENDING_CREATE was refused: try again after the grace time
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

---Sends CANCEL_LISTING for an own listing whose fate is unknown. Always a new actionId: the backend
---returns the result of an older one only for a limited time, while a repeated cancel is answered again.
---@param listing table
local function sendReconcileCancel(gm, listing)
    local payload = { subAction = "CANCEL_LISTING", farmId = listing.sellerFarmId }
    if (listing.remoteId or "") ~= "" then
        payload.remoteId = listing.remoteId
    else
        payload.createActionId = listing.createActionId
    end
    if gm:dispatchVehicleAction(payload) then
        listing.cancelActionId = payload.actionId
        listing.pendingSinceMs = g_time or 0
    end
end

---Server tick (1 s): asks again for own listings without an answer. Needs no sync file, so it also
---works while nothing changes on the board.
function GlobalMarket:reconcilePendingVehicleListings()
    if not self:getAreOnlineVehiclesAvailable() then
        return
    end
    local S = GlobalMarket.VEHICLE_LISTING_STATUS
    local needsSnapshot = false
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isOnline then
            if listing.status == S.PENDING_CANCEL and listing.cancelActionId ~= nil and isPastGrace(listing) then
                -- Cancel answer lost: the listing may be gone from the board already
                sendReconcileCancel(self, listing)
            elseif listing.status == S.PENDING_CREATE and isPastGrace(listing) then
                needsSnapshot = true
            end
        end
    end
    local now = g_time or 0
    if needsSnapshot and now - (self.vehicleSnapshotRequestedMs or -math.huge) >= GlobalMarketVehicleOnline.RECONCILE_GRACE_MS
        and self:dispatchVehicleAction({ subAction = "REQUEST_SYNC" }) then
        self.vehicleSnapshotRequestedMs = now
    end
end

---Replaces the foreign listings. Unchanged ones are only refreshed in place, so a repeated snapshot
---(e.g. while a settlement waits for the next save) does not resend the whole market to all clients.
---@param gm table
---@param remote table
---@return boolean changed
local function storeRemoteListings(gm, remote)
    gm.onlineVehicleListings = gm.onlineVehicleListings or {}
    local current = gm.onlineVehicleListings
    local isSame = (#current == #remote)
    for i, entry in ipairs(remote) do
        local known = current[i]
        isSame = isSame and known.remoteId == entry.remoteId and known.status == entry.status
            and known.priceFactor == entry.priceFactor and known.sellerName == entry.sellerName
    end
    if not isSame then
        gm.onlineVehicleListings = remote
        return true
    end
    for i, entry in ipairs(remote) do
        current[i].remainingSeconds = entry.remainingSeconds
    end
    return false
end

---Reconciles own online listings with a full listing snapshot and stores the foreign listings
---@param entries table Parsed listings
---@return boolean changed
function GlobalMarket:applyVehicleListingSnapshot(entries)
    local S = GlobalMarket.VEHICLE_LISTING_STATUS
    local ownServerId = self:ensureServerInstanceId()
    local ownByRemote, ownByCreate = {}, {}
    local remote = {}
    local changed = false
    local buying = {}
    for _, buy in pairs(self.pendingVehicleBuys or {}) do
        buying[buy.remoteId] = true
    end
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
                -- An own purchase request without answer keeps its listing locked
                status = buying[entry.remoteId] and S.BUYING or S.OPEN,
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
                    changed = true
                elseif isPastGrace(listing) then
                    -- CREATE result lost and the listing is unknown: cancel by createActionId, return on ACCEPTED
                    sendReconcileCancel(self, listing)
                end
            elseif listing.status == S.OPEN and entry ~= nil then
                listing.remainingSeconds = entry.remainingSeconds
            end
        end
    end

    -- Admin switch off or offline: own listings are still reconciled, foreign ones are not shown
    return storeRemoteListings(self, self:getAreOnlineVehiclesAvailable() and remote or {}) or changed
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

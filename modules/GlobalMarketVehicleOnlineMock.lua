-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleOnlineMock.lua
-- Debug-only mock backend for the cross-server vehicle market (#36): with
-- "gmTestOnlineVehicles on" the server answers its own vehicleAction requests like the
-- backend of spec 3.6 (results, full listing snapshot, redelivered settlements until
-- ACK_SETTLEMENT), so listing, withdrawing, buying, selling and expiry are testable
-- without GlobalMarketClient. Settlements are redelivered until the game was saved.
-- Never active outside the GM debug mode.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketVehicleOnlineMock = {}
-- The backend never sends the server ID of another savegame
GlobalMarketVehicleOnlineMock.FOREIGN_SERVER_ID = ""
GlobalMarketVehicleOnlineMock.PROCESS_INTERVAL_MS = 1000

---Returns a random store item a foreign mock seller can offer (same rules as NPC dealers)
local function pickStoreItem()
    local items = g_storeManager:getItems()
    for _ = 1, 40 do
        local item = items[math.random(1, #items)]
        if item ~= nil and item.showInStore and item.extraContentId == nil and item.bundleInfo == nil
            and (item.price or 0) > 0 and GlobalMarketVehicleListings.getGroupForStoreItem(item) ~= nil then
            return item
        end
    end
    return nil
end

---Adds foreign mock listings (vehicles that exist on this server)
---@param mock table
---@param count number
---@return number added
local function addForeignListings(mock, count)
    local added = 0
    for _ = 1, count do
        local storeItem = pickStoreItem()
        local snapshot = (storeItem ~= nil) and GlobalMarket.buildNpcVehicleSnapshot(storeItem) or nil
        if snapshot ~= nil and GlobalMarketVehicleListings.resolveSnapshot(snapshot) ~= nil then
            mock.nextId = mock.nextId + 1
            local remoteId = "mock_v_" .. mock.nextId
            mock.listings[remoteId] = {
                remoteId = remoteId, createActionId = "", saleMode = "FIXED",
                sellerServerId = GlobalMarketVehicleOnlineMock.FOREIGN_SERVER_ID, sellerFarmId = 1, sellerName = "Mock Nordhof [EU]",
                priceFactor = 0.85 + math.random(0, 8) * 0.05, remainingSeconds = 72 * 3600, status = "OPEN",
                snapshot = snapshot
            }
            added = added + 1
        end
    end
    return added
end

---Queues a settlement that the mock redelivers until it is acknowledged
local function addSettlement(mock, settlement)
    mock.nextId = mock.nextId + 1
    settlement.settlementId = "mock_s_" .. mock.nextId
    settlement.createActionId = settlement.createActionId or ""
    settlement.buyActionId = settlement.buyActionId or ""
    settlement.remoteId = settlement.remoteId or ""
    settlement.otherName = settlement.otherName or ""
    mock.settlements[settlement.settlementId] = settlement
end

---Processes one request like the backend would and returns its action result (nil = none)
---@param gm table
---@param mock table
---@param p table Outgoing payload
---@return table|nil result
local function handleRequest(gm, mock, p)
    local result = { actionId = p.actionId, subAction = p.subAction, status = "REJECTED", reason = "", remoteId = "", remainingSeconds = 0 }
    if p.subAction == "REQUEST_SYNC" then
        return nil
    elseif p.subAction == "ACK_SETTLEMENT" then
        for id in string.gmatch(p.settlementIds or "", "[^,]+") do
            mock.settlements[id] = nil
        end
        return nil
    elseif p.subAction == "CREATE_LISTING" then
        if mock.tombstones[p.actionId] then
            result.reason = "NOT_CREATED"
            return result
        end
        mock.nextId = mock.nextId + 1
        local remoteId = "mock_v_" .. mock.nextId
        mock.listings[remoteId] = {
            remoteId = remoteId, createActionId = p.actionId, saleMode = p.saleMode or "FIXED",
            sellerServerId = p.serverId, sellerFarmId = p.farmId or 0, sellerName = p.farmName or "",
            priceFactor = p.priceFactor or 1, remainingSeconds = (p.durationHours or 72) * 3600, status = "OPEN",
            snapshot = p.snapshot
        }
        result.status, result.remoteId, result.remainingSeconds = "ACCEPTED", remoteId, (p.durationHours or 72) * 3600
    elseif p.subAction == "CANCEL_LISTING" then
        local function find(list)
            for _, e in pairs(list) do
                if ((p.remoteId or "") ~= "" and e.remoteId == p.remoteId) or ((p.createActionId or "") ~= "" and e.createActionId == p.createActionId) then
                    return e
                end
            end
            return nil
        end
        -- Cancelling again returns the same answer
        local entry = find(mock.listings) or find(mock.cancelled)
        if entry ~= nil then
            mock.listings[entry.remoteId] = nil
            mock.cancelled[entry.remoteId] = entry
            result.status, result.remoteId, result.snapshot = "ACCEPTED", entry.remoteId, entry.snapshot
        elseif find(mock.sold) ~= nil then
            result.reason = "LISTING_SOLD"
        elseif find(mock.expired) ~= nil then
            result.reason = "EXPIRED"
        elseif (p.createActionId or "") ~= "" then
            mock.tombstones[p.createActionId] = true
            result.status, result.reason = "ACCEPTED", "NOT_CREATED"
        else
            result.reason = "LISTING_NOT_FOUND"
        end
    elseif p.subAction == "BUY_LISTING" then
        local entry = mock.listings[p.remoteId or ""]
        if entry == nil then
            result.reason = mock.sold[p.remoteId or ""] ~= nil and "LISTING_SOLD"
                or mock.expired[p.remoteId or ""] ~= nil and "EXPIRED" or "LISTING_NOT_FOUND"
        elseif entry.sellerServerId == p.serverId and entry.sellerFarmId == p.farmId then
            result.reason = "OWN_LISTING"
        else
            mock.listings[entry.remoteId] = nil
            mock.sold[entry.remoteId] = entry
            result.status, result.remoteId = "ACCEPTED", entry.remoteId
            addSettlement(mock, { type = "LISTING_BOUGHT", targetServerId = p.serverId, targetFarmId = p.farmId,
                remoteId = entry.remoteId, buyActionId = p.actionId, priceFactor = entry.priceFactor,
                otherName = entry.sellerName, snapshot = entry.snapshot })
            if entry.sellerServerId ~= GlobalMarketVehicleOnlineMock.FOREIGN_SERVER_ID then
                addSettlement(mock, { type = "LISTING_SOLD", targetServerId = entry.sellerServerId, targetFarmId = entry.sellerFarmId,
                    remoteId = entry.remoteId, createActionId = entry.createActionId, priceFactor = entry.priceFactor,
                    otherName = p.farmName or "" })
            end
        end
    else
        result.reason = "INVALID_REQUEST"
    end
    return result
end

---Server tick: answers queued requests once per interval with results, settlements and a full snapshot
---@param dt number
function GlobalMarket:updateVehicleOnlineMock(dt)
    local mock = self.vehicleMock
    if mock == nil then
        return
    end
    mock.timerMs = mock.timerMs + (dt or 0)
    if mock.timerMs < GlobalMarketVehicleOnlineMock.PROCESS_INTERVAL_MS or (#mock.outbox == 0 and not mock.pushPending) then
        return
    end
    mock.timerMs = 0
    mock.pushPending = false
    local outbox = mock.outbox
    mock.outbox = {}
    local results = {}
    for _, payload in ipairs(outbox) do
        local result = handleRequest(self, mock, payload)
        if result ~= nil and mock.loseResults > 0 then
            mock.loseResults = mock.loseResults - 1
            result = nil
            if self.debugManager ~= nil then
                self.debugManager:info("VehicleOnline (mock): Dropped the result of %s %s.", payload.subAction, payload.actionId)
            end
        end
        if result ~= nil then
            table.insert(results, result)
        end
    end
    local listings, settlements = {}, {}
    for _, entry in pairs(mock.listings) do
        table.insert(listings, entry)
    end
    for _, settlement in pairs(mock.settlements) do
        table.insert(settlements, settlement)
    end
    self:applyVehicleSyncPacket({ hasListings = true, listings = listings, actionResults = results, settlements = settlements })
end

---Developer console command: gmTestOnlineVehicles <on|off|status|spawn [n]|sell <id>|expire <id>|lose [n]|sync>
function GlobalMarket:consoleCommandTestOnlineVehicles(cmdArg, valueArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_server == nil then
        return "Execute gmTestOnlineVehicles directly on the server/SP host."
    end
    local arg = string.lower(tostring(cmdArg or "status"))
    local mock = self.vehicleMock
    if arg == "on" then
        if mock == nil then
            mock = { outbox = {}, listings = {}, settlements = {}, tombstones = {}, sold = {}, expired = {}, cancelled = {}, nextId = 0,
                timerMs = 0, loseResults = 0, pushPending = true }
            self.vehicleMock = mock
            addForeignListings(mock, 3)
        end
        self.debugForceOnlineVehicles = true
        self:broadcastVehicleMarketState()
        return "Vehicle mock backend ON (3 foreign listings). Use the vehicle market or: status, spawn, sell, expire, lose, sync, off."
    end
    if mock == nil then
        return "Vehicle mock backend is off. Start it with: gmTestOnlineVehicles on"
    end
    if arg == "off" then
        self.vehicleMock = nil
        self.debugForceOnlineVehicles = false
        self:clearRemoteVehicleListings()
        self:broadcastVehicleMarketState()
        return "Vehicle mock backend OFF. Own online listings stay in escrow until a backend answers."
    elseif arg == "spawn" then
        return string.format("Added %d foreign mock listing(s).", addForeignListings(mock, math.max(1, tonumber(valueArg) or 1)))
    elseif arg == "sell" or arg == "expire" then
        local listing = self:getVehicleListingById(tonumber(valueArg) or -1)
        if listing == nil or not listing.isOnline or listing.remoteId == nil or mock.listings[listing.remoteId] == nil then
            return "Usage: gmTestOnlineVehicles " .. arg .. " <listingId of an own open online listing>"
        end
        local entry = mock.listings[listing.remoteId]
        mock.listings[listing.remoteId] = nil
        local settlement = { type = (arg == "sell") and "LISTING_SOLD" or "LISTING_EXPIRED", targetServerId = self:ensureServerInstanceId(),
            targetFarmId = listing.sellerFarmId, remoteId = listing.remoteId, createActionId = listing.createActionId,
            priceFactor = listing.priceFactor, otherName = "Mock Südhof [EU]" }
        if arg == "expire" then
            settlement.snapshot = listing.snapshot
            mock.expired[listing.remoteId] = entry
        else
            mock.sold[listing.remoteId] = entry
        end
        addSettlement(mock, settlement)
        mock.pushPending = true
        return string.format("Queued %s for listing #%d.", settlement.type, listing.id)
    elseif arg == "lose" then
        mock.loseResults = math.max(1, tonumber(valueArg) or 1)
        return string.format("The next %d action result(s) are dropped (reconcile test, grace %d s).",
            mock.loseResults, GlobalMarketVehicleOnline.RECONCILE_GRACE_MS / 1000)
    elseif arg == "sync" then
        mock.pushPending = true
        return "Mock snapshot queued."
    end
    local numListings, numSettlements = 0, 0
    for _ in pairs(mock.listings) do
        numListings = numListings + 1
    end
    for _ in pairs(mock.settlements) do
        numSettlements = numSettlements + 1
    end
    return string.format("Vehicle mock: %d listing(s), %d unacknowledged settlement(s), %d queued request(s), %d result(s) to drop.",
        numListings, numSettlements, #mock.outbox, mock.loseResults)
end

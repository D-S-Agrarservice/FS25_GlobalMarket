-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleOnline.lua
-- Cross-server used vehicle market (#36, Stage 3, spec section 3.6): capability gate, admin
-- switch, spec XML conversion of vehicle snapshots and the outgoing vehicleAction export.
-- Listings stay local unless the active Data-Host's client reports vehiclesSupported and
-- the admin setting allows the online vehicle market.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketVehicleOnline = {}

-- Admin setting "Online vehicle market" (set by GlobalMarketSettings, synced)
GlobalMarket.VEHICLE_ONLINE_ENABLED = true

---Server: stores the vehiclesSupported capability of the active Data-Host and informs clients on change
---@param supported boolean
function GlobalMarket:setOnlineVehiclesSupported(supported)
    if g_server == nil then
        return
    end
    supported = (supported == true)
    if (self.onlineVehiclesSupported == true) == supported then
        return
    end
    self.onlineVehiclesSupported = supported
    if self.debugManager ~= nil then
        self.debugManager:info("VehicleOnline: Client capability vehiclesSupported=%s.", tostring(supported))
    end
    if self.broadcastVehicleMarketState ~= nil then
        self:broadcastVehicleMarketState()
    end
end

---Returns true when vehicles may be listed and bought across servers right now.
---Server: admin setting, online market and Data-Host capability; clients: last synced value.
---@return boolean
function GlobalMarket:getAreOnlineVehiclesAvailable()
    if g_server == nil then
        return self.onlineVehiclesAvailableSynced == true
    end
    return GlobalMarket.VEHICLE_ONLINE_ENABLED == true
        and self:getIsMarketOnline()
        and (self.onlineVehiclesSupported == true or self.debugForceOnlineVehicles == true)
end

---Client: applies the availability flag received with the vehicle market state
---@param available boolean
function GlobalMarket:applyOnlineVehiclesAvailable(available)
    self.onlineVehiclesAvailableSynced = (available == true)
end

---Reacts to the admin setting "Online vehicle market" (server and clients)
---@param enabled boolean
function GlobalMarket:onVehicleOnlineModeChanged(enabled)
    if self.debugManager ~= nil then
        self.debugManager:info("VehicleOnline: Online vehicle market %s by admin.", enabled and "enabled" or "disabled")
    end
    if g_server ~= nil and self.broadcastVehicleMarketState ~= nil then
        self:broadcastVehicleMarketState()
    end
end

-- =========================================================================
-- OUTGOING ACTIONS (write/vehicleAction_<date>_<seq>.xml, spec 3.6)
-- =========================================================================

GlobalMarket.VEHICLE_ONLINE = {
    DURATION_HOURS = { 24, 48, 72, 168 }, -- Real-time durations offered in the listing dialog
    FILE_PREFIX = "vehicleAction_"
}

---Writes a vehicle snapshot in the spec 3.6 <vehicle> format
---@param xmlFile table
---@param key string
---@param snap table Internal snapshot (GlobalMarketVehicleListings.captureSnapshot)
function GlobalMarketVehicleOnline.writeVehicleXml(xmlFile, key, snap)
    xmlFile:setString(key .. "#xmlFilename", snap.xmlFilename or "")
    if snap.modName ~= nil then
        xmlFile:setString(key .. "#modName", snap.modName)
    end
    if snap.modFileHash ~= nil then
        xmlFile:setString(key .. "#modFileHash", snap.modFileHash)
    end
    xmlFile:setString(key .. "#group", snap.group or "MISC")
    xmlFile:setInt(key .. "#ageMonths", math.floor((snap.age or 0) + 0.5))
    xmlFile:setString(key .. "#operatingHours", string.format("%.2f", (snap.operatingTime or 0) / 3600000))
    xmlFile:setString(key .. "#damage", string.format("%.4f", snap.damage or 0))
    xmlFile:setString(key .. "#wear", string.format("%.4f", snap.wear or 0))
    for i, entry in ipairs(snap.configs or {}) do
        local cKey = string.format("%s.config(%d)", key, i - 1)
        xmlFile:setString(cKey .. "#name", entry.name)
        xmlFile:setString(cKey .. "#saveId", entry.saveId)
        xmlFile:setBool(cKey .. "#isActive", entry.isActive == true)
        xmlFile:setBool(cKey .. "#isBought", entry.isBought == true)
        if entry.color ~= nil then
            xmlFile:setString(cKey .. "#color", string.format("%.6f %.6f %.6f", entry.color[1], entry.color[2], entry.color[3]))
        end
        if entry.materialTemplateName ~= nil then
            xmlFile:setString(cKey .. "#materialTemplate", entry.materialTemplateName)
        end
    end
end

---Reads a spec 3.6 <vehicle> element into an internal snapshot (nil if invalid)
---@param xmlFile table
---@param key string
---@return table|nil snap
function GlobalMarketVehicleOnline.readVehicleXml(xmlFile, key)
    local xmlFilename = xmlFile:getString(key .. "#xmlFilename")
    if xmlFilename == nil or xmlFilename == "" then
        return nil
    end
    local group = string.upper(xmlFile:getString(key .. "#group", "MISC"))
    if string.find(group, "^[%u_]+$") == nil or string.len(group) > 32 then
        group = "MISC"
    end
    local function clamp01(value)
        return math.max(0, math.min(1, tonumber(value) or 0))
    end
    local snap = {
        xmlFilename = xmlFilename,
        modName = xmlFile:getString(key .. "#modName"),
        modFileHash = xmlFile:getString(key .. "#modFileHash"),
        group = group,
        age = math.max(0, xmlFile:getInt(key .. "#ageMonths", 0)),
        operatingTime = math.max(0, xmlFile:getFloat(key .. "#operatingHours", 0)) * 3600000,
        damage = clamp01(xmlFile:getFloat(key .. "#damage", 0)),
        wear = clamp01(xmlFile:getFloat(key .. "#wear", 0)),
        configs = {}
    }
    xmlFile:iterate(key .. ".config", function(_, cKey)
        local entry = {
            name = xmlFile:getString(cKey .. "#name"),
            saveId = xmlFile:getString(cKey .. "#saveId"),
            isActive = xmlFile:getBool(cKey .. "#isActive", false),
            isBought = xmlFile:getBool(cKey .. "#isBought", false)
        }
        local template = xmlFile:getString(cKey .. "#materialTemplate")
        if template ~= nil and template ~= "" then
            entry.materialTemplateName = template
        end
        local colorStr = xmlFile:getString(cKey .. "#color")
        if colorStr ~= nil then
            local r, g, b = string.match(colorStr, "^%s*([%d%.%-]+)%s+([%d%.%-]+)%s+([%d%.%-]+)")
            if r ~= nil then
                entry.color = { tonumber(r), tonumber(g), tonumber(b) }
            end
        end
        if entry.name ~= nil and entry.saveId ~= nil then
            table.insert(snap.configs, entry)
        end
    end)
    return snap
end

---Server: sends a vehicleAction to the companion client of the active Data-Host
---@param payload table subAction, farmId, farmName, saleMode, priceFactor, durationHours,
---remoteId, createActionId, settlementIds, snapshot (actionId and serverId are filled in)
---@return boolean dispatched
function GlobalMarket:dispatchVehicleAction(payload)
    if g_server == nil or payload == nil or not self:getAreOnlineVehiclesAvailable() then
        return false
    end
    payload.actionId = payload.actionId or self:nextOnlineContractActionId()
    payload.serverId = payload.serverId or self:ensureServerInstanceId()
    if self.isDataHost then
        return self:exportVehicleAction(payload)
    elseif type(self.dataHostConnection) == "table" and VehicleOnlineBridgeEvent ~= nil then
        self.dataHostConnection:sendEvent(VehicleOnlineBridgeEvent.newExportAction(payload))
        return true
    end
    return false
end

---Data-Host: writes write/vehicleAction_<date>_<seq>.xml for the companion client
---@param payload table
---@return boolean written
function GlobalMarket:exportVehicleAction(payload)
    if not self.isDataHost or self.writeFolder == nil or payload == nil or (payload.subAction or "") == "" then
        return false
    end
    self.vehicleActionCounter = (self.vehicleActionCounter or 0) + 1
    local xmlPath = string.format("%s%s%s_%d.xml", self.writeFolder, GlobalMarket.VEHICLE_ONLINE.FILE_PREFIX,
        getDate("%Y%m%d_%H%M%S"), self.vehicleActionCounter)
    local xmlFile = XMLFile.create("gmVehicleAction", xmlPath, "gmDataSync")
    if xmlFile == nil then
        return false
    end
    xmlFile:setString("gmDataSync#action", "vehicleAction")
    local key = "gmDataSync.request(0)"
    xmlFile:setString(key .. "#subAction", payload.subAction)
    xmlFile:setString(key .. "#actionId", payload.actionId or "")
    xmlFile:setString(key .. "#serverId", payload.serverId or "")
    if (payload.farmId or 0) > 0 then
        xmlFile:setInt(key .. "#farmId", payload.farmId)
    end
    if (payload.farmName or "") ~= "" then
        xmlFile:setString(key .. "#farmName", payload.farmName)
    end
    if (payload.saleMode or "") ~= "" then
        xmlFile:setString(key .. "#saleMode", payload.saleMode)
    end
    if (payload.priceFactor or 0) > 0 then
        xmlFile:setString(key .. "#priceFactor", string.format("%.2f", payload.priceFactor))
    end
    if (payload.durationHours or 0) > 0 then
        xmlFile:setInt(key .. "#durationHours", payload.durationHours)
    end
    if (payload.remoteId or "") ~= "" then
        xmlFile:setString(key .. "#remoteId", payload.remoteId)
    end
    if (payload.createActionId or "") ~= "" then
        xmlFile:setString(key .. "#createActionId", payload.createActionId)
    end
    if (payload.settlementIds or "") ~= "" then
        xmlFile:setString(key .. "#settlementIds", payload.settlementIds)
    end
    if payload.snapshot ~= nil then
        GlobalMarketVehicleOnline.writeVehicleXml(xmlFile, key .. ".vehicle", payload.snapshot)
    end
    xmlFile:save()
    xmlFile:delete()
    if self.debugManager ~= nil then
        self.debugManager:info("VehicleOnline: Exported vehicleAction '%s' (actionId=%s).", payload.subAction, tostring(payload.actionId))
    end
    return true
end

-- =========================================================================
-- OWN ONLINE LISTINGS & ESCROW (Server)
-- =========================================================================

---Returns true if hours is one of the offered online durations
---@param hours number|nil
---@return boolean
function GlobalMarketVehicleOnline.isValidDuration(hours)
    for _, value in ipairs(GlobalMarket.VEHICLE_ONLINE.DURATION_HOURS) do
        if value == hours then
            return true
        end
    end
    return false
end

---Marks a new listing as online (escrow, PENDING_CREATE) and sends CREATE_LISTING.
---The caller removes the vehicle from the world only if this returns true.
---@param listing table Listing built by createVehicleListing (not yet stored)
---@param hours number Real-time duration
---@return boolean submitted
function GlobalMarket:submitOnlineVehicleListing(listing, hours)
    local actionId = self:nextOnlineContractActionId()
    local submitted = self:dispatchVehicleAction({
        subAction = "CREATE_LISTING",
        actionId = actionId,
        farmId = listing.sellerFarmId,
        farmName = self:formatOnlineIssuerDisplayName(listing.sellerFarmId),
        saleMode = listing.saleMode or "FIXED",
        priceFactor = listing.priceFactor,
        durationHours = hours,
        snapshot = listing.snapshot
    })
    if not submitted then
        return false
    end
    listing.isOnline = true
    listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.PENDING_CREATE
    listing.createActionId = actionId
    listing.durationHours = hours
    listing.remainingSeconds = hours * 3600
    return true
end

---Sends CANCEL_LISTING for an open online listing; the vehicle returns once the backend accepted
---@param listing table
---@return boolean success
---@return string|nil reason
function GlobalMarket:requestCancelOnlineVehicleListing(listing)
    if (listing.remoteId or "") == "" then
        return false, "listingBusy"
    end
    local payload = { subAction = "CANCEL_LISTING", farmId = listing.sellerFarmId, remoteId = listing.remoteId }
    if not self:dispatchVehicleAction(payload) then
        return false, "onlineUnavailable"
    end
    listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.PENDING_CANCEL
    listing.cancelActionId = payload.actionId
    self:broadcastVehicleMarketState()
    return true, nil
end

---Withdraws the online listing of a deleted farm at the backend (best effort, the vehicle has no owner)
---@param listing table
function GlobalMarket:withdrawOnlineVehicleListingForDeletedFarm(listing)
    local payload = { subAction = "CANCEL_LISTING", farmId = listing.sellerFarmId }
    if (listing.remoteId or "") ~= "" then
        payload.remoteId = listing.remoteId
    else
        payload.createActionId = listing.createActionId
    end
    if not self:dispatchVehicleAction(payload) and self.debugManager ~= nil then
        self.debugManager:warning("VehicleOnline: Could not withdraw online listing #%d of deleted farm %d (offline).",
            listing.id, listing.sellerFarmId or 0)
    end
end

---Writes the online fields of a listing into globalMarket.xml
---@param xmlFile table
---@param key string
---@param listing table
function GlobalMarketVehicleOnline.saveListingOnlineFields(xmlFile, key, listing)
    xmlFile:setBool(key .. "#isOnline", true)
    xmlFile:setString(key .. "#remoteId", listing.remoteId or "")
    xmlFile:setString(key .. "#createActionId", listing.createActionId or "")
    xmlFile:setString(key .. "#cancelActionId", listing.cancelActionId or "")
    xmlFile:setInt(key .. "#durationHours", listing.durationHours or 0)
    xmlFile:setInt(key .. "#remainingSeconds", math.floor(listing.remainingSeconds or 0))
end

---Reads the online fields of a listing (no-op for local listings)
---@param xmlFile table
---@param key string
---@param listing table
function GlobalMarketVehicleOnline.loadListingOnlineFields(xmlFile, key, listing)
    if not xmlFile:getBool(key .. "#isOnline", false) then
        return
    end
    local function optString(name)
        local value = xmlFile:getString(key .. "#" .. name, "")
        return (value ~= "") and value or nil
    end
    listing.isOnline = true
    listing.remoteId = optString("remoteId")
    listing.createActionId = optString("createActionId")
    listing.cancelActionId = optString("cancelActionId")
    listing.durationHours = xmlFile:getInt(key .. "#durationHours", 0)
    listing.remainingSeconds = xmlFile:getInt(key .. "#remainingSeconds", 0)
end

---Counts down the real-time remaining seconds of open online listings (server and clients, display only)
---@param dt number
function GlobalMarket:updateOnlineVehicleTimers(dt)
    self.vehicleOnlineTimerMs = (self.vehicleOnlineTimerMs or 0) + (dt or 0)
    if self.vehicleOnlineTimerMs < 1000 then
        return
    end
    local elapsedSec = math.floor(self.vehicleOnlineTimerMs / 1000)
    self.vehicleOnlineTimerMs = self.vehicleOnlineTimerMs - elapsedSec * 1000
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isOnline and listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.OPEN and (listing.remainingSeconds or 0) > 0 then
            listing.remainingSeconds = math.max(0, listing.remainingSeconds - elapsedSec)
        end
    end
end

-- =========================================================================
-- TICK
-- =========================================================================

---Requests a full listing snapshot whenever the online vehicle market becomes available or the
---Data-Host changes (the snapshot also reconciles escrowed listings from stage 3 on)
---@param dt number
function GlobalMarket:updateVehicleOnline(dt)
    self:updateOnlineVehicleTimers(dt)
    if g_server == nil then
        return
    end
    local available = self:getAreOnlineVehiclesAvailable()
    local host = available and self.dataHostConnection or nil
    if available and (not self.vehicleOnlineWasAvailable or host ~= self.vehicleOnlineSyncedHost) then
        if self:dispatchVehicleAction({ subAction = "REQUEST_SYNC" }) then
            self.vehicleOnlineSyncedHost = host
        end
    end
    self.vehicleOnlineWasAvailable = available
end

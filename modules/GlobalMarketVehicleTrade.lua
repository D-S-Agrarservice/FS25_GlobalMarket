-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleTrade.lua
-- Used vehicle market (#16), Stage 1 trading: purchase, hourly expiry & return retries,
-- client state sync, HUD notices and cleanup of deleted farms.
-- Author: D-S-Agrarservice
-- =========================================================================================

-- Resolve failures that all mean "not available on this server"
local NOT_AVAILABLE_REASONS = {
    missingStoreItem = true,
    missingMod = true,
    modMismatch = true,
    configMismatch = true
}

-- =========================================================================
-- STATE SYNC
-- =========================================================================

---Server: sends the full listing state to all clients and refreshes the local UI
function GlobalMarket:broadcastVehicleMarketState()
    if g_server ~= nil and SyncVehicleMarketEvent ~= nil then
        g_server:broadcastEvent(SyncVehicleMarketEvent.new(self.vehicleListings or {}))
    end
    self:onVehicleMarketChanged()
end

---Client: applies a received listing state
---@param listings table
function GlobalMarket:applyVehicleMarketState(listings)
    self.vehicleListings = listings or {}
    self:onVehicleMarketChanged()
end

---Refreshes the vehicle market UI if it is open (UI hook from step 3 on)
function GlobalMarket:onVehicleMarketChanged()
    local ui = self.ui or (g_currentMission ~= nil and g_currentMission.globalMarketUi) or nil
    if ui ~= nil and ui.onVehicleMarketChanged ~= nil then
        ui:onVehicleMarketChanged()
    end
end

-- =========================================================================
-- HUD NOTICES
-- =========================================================================

---Server: sends a notice to the requesting connection only (local SP/host: shown directly)
---@param connection table|nil
---@param kind number GlobalMarket.VEHICLE_NOTICE
---@param code string Reason code for RESULT notices
---@param xmlFilename string
---@param amount number
function GlobalMarket:notifyVehicleMarketRequester(connection, kind, code, xmlFilename, amount)
    if connection ~= nil and not connection:getIsLocal() and VehicleMarketActionEvent ~= nil then
        connection:sendEvent(VehicleMarketActionEvent.newNotice(kind, 0, 0, code, xmlFilename, amount, ""))
        return
    end
    self:showVehicleMarketNotice(kind, 0, 0, code, xmlFilename, amount, "")
end

---Server: broadcasts a notice; clients filter by target farm (0 = all) and excluded farm
---@param kind number
---@param targetFarmId number
---@param excludeFarmId number
---@param code string
---@param xmlFilename string
---@param amount number
---@param otherName string
function GlobalMarket:notifyVehicleMarketFarms(kind, targetFarmId, excludeFarmId, code, xmlFilename, amount, otherName)
    if g_server ~= nil and VehicleMarketActionEvent ~= nil then
        g_server:broadcastEvent(VehicleMarketActionEvent.newNotice(kind, targetFarmId, excludeFarmId, code, xmlFilename, amount, otherName))
    end
    self:showVehicleMarketNotice(kind, targetFarmId, excludeFarmId, code, xmlFilename, amount, otherName)
end

---Returns the localized text of a reason code (HUD results and UI hints)
---@param code string
---@return string
function GlobalMarket.getVehicleMarketReasonText(code)
    local cfg = GlobalMarket.VEHICLE_MARKET
    if NOT_AVAILABLE_REASONS[code] then
        code = "notAvailable"
    end
    local key = "ui_gm_vehicles_reason_" .. tostring(code)
    if not g_i18n:hasText(key) then
        key = "ui_gm_vehicles_reason_invalid"
    end
    local text = g_i18n:getText(key)
    if code == "priceOutOfRange" then
        return string.format(text, math.floor(cfg.PRICE_FACTOR_MIN * 100 + 0.5), math.floor(cfg.PRICE_FACTOR_MAX * 100 + 0.5))
    elseif code == "durationOutOfRange" then
        return string.format(text, cfg.DURATION_MIN, cfg.DURATION_MAX)
    elseif code == "farmLimitReached" then
        return string.format(text, cfg.MAX_PER_FARM)
    end
    return text
end

---Client/host: shows a vehicle market notice if it concerns the local farm
function GlobalMarket:showVehicleMarketNotice(kind, targetFarmId, excludeFarmId, code, xmlFilename, amount, otherName)
    if g_dedicatedServer ~= nil or g_currentMission == nil or g_currentMission.hud == nil then
        return
    end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end
    if (targetFarmId or 0) > 0 and farmId ~= targetFarmId then
        return
    end
    if (excludeFarmId or 0) > 0 and farmId == excludeFarmId then
        return
    end

    local N = GlobalMarket.VEHICLE_NOTICE
    local name = GlobalMarketVehicleListings.getDisplayName(xmlFilename)
    local money = g_i18n:formatMoney(amount or 0, 0, true, true)
    local color = FSBaseMission.INGAME_NOTIFICATION_OK or { 1, 1, 1, 1 }
    local text
    if kind == N.RESULT then
        text = GlobalMarket.getVehicleMarketReasonText(code)
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or { 1, 1, 1, 1 }
        -- The HUD is hidden behind the menu: show the reason where the player is
        if GlobalMarket.showResultInMarketMenu ~= nil and GlobalMarket.showResultInMarketMenu(text) then
            return
        end
    elseif kind == N.LISTED then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_listed"), name, money)
    elseif kind == N.NEW_LISTING then
        -- Personal comfort setting (not synced)
        if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil
            and GlobalMarketSettings.current.showVehicleNotices == false then
            return
        end
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_newListing"), name, money)
        color = FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.BOUGHT then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_bought"), name, money)
    elseif kind == N.SOLD then
        local buyerName = (code == "npc") and g_i18n:getText("ui_gm_vehicles_npcSeller") or tostring(otherName)
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_sold"), name, money, buyerName)
    elseif kind == N.RETURNED then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_returned"), name)
        color = FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.RETURN_PENDING then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_returnPending"), name)
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or { 1, 1, 1, 1 }
    elseif kind == N.EXPIRED then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_expired"), name)
        color = FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.ONLINE_SUBMITTED then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_onlineSubmitted"), name)
        color = FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.ONLINE_BUY_SUBMITTED then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_onlineBuySubmitted"), name, money)
        color = FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }
    elseif kind == N.DELIVERY_PENDING then
        text = string.format(g_i18n:getText("ui_gm_vehicles_notice_deliveryPending"), name)
        color = FSBaseMission.INGAME_NOTIFICATION_CRITICAL or { 1, 1, 1, 1 }
    end
    if text ~= nil and g_currentMission.hud.addSideNotification ~= nil then
        g_currentMission.hud:addSideNotification(color, text, 8000)
    end
end

-- =========================================================================
-- PURCHASE (Server)
-- =========================================================================

---Buys an open listing for a farm: the vehicle is built from the listing data (never from client data)
---@param listingId number
---@param buyerFarmId number
---@param licensePlateData table|nil License plate chosen by the buyer (random if nil)
---@return boolean started
---@return string|nil reason
function GlobalMarket:buyVehicleListing(listingId, buyerFarmId, licensePlateData)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return false, "notServer"
    end
    local listing = self:getVehicleListingById(listingId)
    if listing == nil then
        return false, "listingNotFound"
    end
    -- Online listings are bought through the backend only (#36, stage 5)
    if listing.status ~= GlobalMarket.VEHICLE_LISTING_STATUS.OPEN or listing.isOnline then
        return false, "listingBusy"
    end
    if not listing.isNpc and listing.sellerFarmId == buyerFarmId then
        return false, "ownListing"
    end
    local resolved, reason = GlobalMarketVehicleListings.resolveSnapshot(listing.snapshot)
    if resolved == nil then
        return false, reason
    end
    local price = math.floor(GlobalMarketVehicleListings.getDealerValue(listing.snapshot, resolved) * (listing.priceFactor or 1) + 0.5)
    if g_currentMission:getMoney(buyerFarmId) < price then
        return false, "notEnoughMoney"
    end

    -- Lock the listing so concurrent buyers are rejected while the vehicle loads
    listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.BUYING
    self:broadcastVehicleMarketState()
    GlobalMarketVehicleListings.spawnFromSnapshot(listing.snapshot, resolved, buyerFarmId,
        self.onVehicleListingBought, self, { listing = listing, buyerFarmId = buyerFarmId, price = price,
            licensePlateData = licensePlateData })
    return true, nil
end

---Loading callback of buyVehicleListing: settles money only after the vehicle exists
function GlobalMarket:onVehicleListingBought(vehicles, loadingState, args)
    local listing = args.listing
    local buyerFarmId = args.buyerFarmId
    local price = args.price
    local N = GlobalMarket.VEHICLE_NOTICE
    if loadingState ~= VehicleLoadingState.OK then
        listing.status = GlobalMarket.VEHICLE_LISTING_STATUS.OPEN
        local code = (loadingState == VehicleLoadingState.NO_SPACE) and "noSpace" or "loadFailed"
        self:notifyVehicleMarketFarms(N.RESULT, buyerFarmId, 0, code, listing.snapshot.xmlFilename, 0, "")
        self:broadcastVehicleMarketState()
        return
    end

    GlobalMarket.applyVehicleMarketLicensePlate(vehicles, args.licensePlateData)
    g_currentMission:addMoney(-price, buyerFarmId, MoneyType.SHOP_VEHICLE_BUY, true, true)
    local buyerName = GlobalMarket.getVehicleMarketFarmName(buyerFarmId)
    if not listing.isNpc then
        g_currentMission:addMoney(price, listing.sellerFarmId, MoneyType.SHOP_VEHICLE_SELL, true, true)
        self:notifyVehicleMarketFarms(N.SOLD, listing.sellerFarmId, 0, "", listing.snapshot.xmlFilename, price, buyerName)
    end
    self:notifyVehicleMarketFarms(N.BOUGHT, buyerFarmId, 0, "", listing.snapshot.xmlFilename, price, "")
    self:removeVehicleListing(listing)
    self:broadcastVehicleMarketState()

    if self.debugManager ~= nil then
        self.debugManager:info("VehicleMarket: Listing #%d sold to farm %d for %d.", listing.id, buyerFarmId, price)
    end
end

-- =========================================================================
-- HOURLY TICK (Server)
-- =========================================================================

---Counts down open listings, returns expired vehicles and retries pending returns
---@param customMonthDelta number|nil Override for console tests
function GlobalMarket:updateVehicleMarketHourly(customMonthDelta)
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    local listings = self.vehicleListings or {}
    if #listings == 0 and (GlobalMarket.VEHICLE_NPC_LEVEL or 0) <= 0 then
        return
    end
    local daysPerPeriod = (g_currentMission.environment ~= nil and g_currentMission.environment.daysPerPeriod) or 1
    local monthDelta = customMonthDelta or (1.0 / (24.0 * math.max(1, daysPerPeriod)))

    local expired = {}
    for _, listing in ipairs(listings) do
        -- Online listings run on real time and expire through the backend (#36)
        if listing.status == GlobalMarket.VEHICLE_LISTING_STATUS.OPEN and not listing.isOnline then
            listing.monthsRemaining = (listing.monthsRemaining or 0) - monthDelta
            if listing.monthsRemaining <= 0 then
                table.insert(expired, listing)
            end
        end
    end
    for _, listing in ipairs(expired) do
        if not listing.isNpc then
            self:notifyVehicleMarketFarms(GlobalMarket.VEHICLE_NOTICE.EXPIRED, listing.sellerFarmId, 0, "", listing.snapshot.xmlFilename, 0, "")
        end
        self:returnVehicleListing(listing)
    end
    self:retryPendingVehicleReturns()
    -- Bought online vehicles waiting for a free store place (#36)
    if self.processVehicleDeliveries ~= nil then
        self:processVehicleDeliveries()
    end
    if self.updateVehicleMarketNpcs ~= nil then
        self:updateVehicleMarketNpcs(monthDelta)
    end
    self:broadcastVehicleMarketState()
end

-- =========================================================================
-- FARM CLEANUP (Server, #30 pattern)
-- =========================================================================

---Removes the listings of a deleted farm (the vehicles have no owner to return to)
---@param farmId number
---@return boolean changed
function GlobalMarket:cleanupVehicleListingsForDeletedFarm(farmId)
    local kept = {}
    local changed = false
    for _, listing in ipairs(self.vehicleListings or {}) do
        if not listing.isNpc and listing.sellerFarmId == farmId and listing.status ~= GlobalMarket.VEHICLE_LISTING_STATUS.BUYING then
            -- Online listings are withdrawn at the backend as well (#36)
            if listing.isOnline then
                self:withdrawOnlineVehicleListingForDeletedFarm(listing)
            end
            changed = true
        else
            table.insert(kept, listing)
        end
    end
    if changed then
        self.vehicleListings = kept
        self:broadcastVehicleMarketState()
    end
    return changed
end

---Applies a license plate to freshly loaded vehicles (license plates are never part of a listing)
---@param vehicles table
---@param licensePlateData table|nil Buyer's choice; a random plate is used if nil
function GlobalMarket.applyVehicleMarketLicensePlate(vehicles, licensePlateData)
    if g_licensePlateManager == nil or not g_licensePlateManager:getAreLicensePlatesAvailable() then
        return
    end
    local plate = licensePlateData
    if plate == nil or plate.characters == nil then
        plate = g_licensePlateManager:getRandomLicensePlateData()
    end
    for _, vehicle in ipairs(vehicles or {}) do
        if vehicle.setLicensePlatesData ~= nil and vehicle.getHasLicensePlates ~= nil and vehicle:getHasLicensePlates() then
            vehicle:setLicensePlatesData(plate)
        end
    end
end

---Returns the display name of a farm
---@param farmId number
---@return string
function GlobalMarket.getVehicleMarketFarmName(farmId)
    local farm = (g_farmManager ~= nil) and g_farmManager:getFarmById(farmId) or nil
    return (farm ~= nil and farm.name ~= nil) and farm.name or ("Farm " .. tostring(farmId))
end

-- =========================================================================
-- DEBUG CONSOLE
-- =========================================================================

---Console: advances all listing timers (expiry test)
---@param monthsArg string|nil
function GlobalMarket:consoleCommandAdvanceVehicleMarket(monthsArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "Execute gmAdvanceVehicleMarket on the server/SP host."
    end
    local delta = tonumber(monthsArg) or 1.0
    if delta <= 0 then
        delta = 1.0
    end
    self:updateVehicleMarketHourly(delta)
    return string.format("Advanced vehicle market listings by +%.2f month(s).", delta)
end

---Console: turns a listing into an NPC dealer listing (SP test: buy back an own listed vehicle)
---@param listingIdArg string
function GlobalMarket:consoleCommandVehicleMarketMakeNpc(listingIdArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return "Execute gmVehicleMarketMakeNpc on the server/SP host."
    end
    local listing = self:getVehicleListingById(tonumber(listingIdArg) or 0)
    if listing == nil or listing.status ~= GlobalMarket.VEHICLE_LISTING_STATUS.OPEN then
        return "Usage: gmVehicleMarketMakeNpc <id of an open listing>"
    end
    listing.isNpc = true
    listing.sellerFarmId = 0
    listing.sellerName = ""
    self:broadcastVehicleMarketState()
    return string.format("Listing #%d is now an NPC dealer listing (no seller payout, not returned on expiry).", listing.id)
end

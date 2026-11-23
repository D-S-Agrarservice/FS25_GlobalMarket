-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleOnline.lua
-- Cross-server used vehicle market (#36, Stage 3, spec section 3.6): capability gate and
-- admin switch. Listings stay local unless the active Data-Host's client reports
-- vehiclesSupported and the admin setting allows the online vehicle market.
-- Author: D-S-Agrarservice
-- =========================================================================================

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

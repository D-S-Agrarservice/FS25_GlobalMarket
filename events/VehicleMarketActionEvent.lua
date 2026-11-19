-- =========================================================================================
-- FS25_GlobalMarket - VehicleMarketActionEvent.lua
-- Used vehicle market (#16): client-to-server requests (list, withdraw, buy) and
-- server-to-client HUD notices (results, sold, bought, returned, expired).
-- Author: D-S-Agrarservice
-- =========================================================================================

VehicleMarketActionEvent = {}
local VehicleMarketActionEvent_mt = Class(VehicleMarketActionEvent, Event)
InitEventClass(VehicleMarketActionEvent, "VehicleMarketActionEvent")

VehicleMarketActionEvent.ACTION_CREATE = 1
VehicleMarketActionEvent.ACTION_CANCEL = 2
VehicleMarketActionEvent.ACTION_BUY = 3

function VehicleMarketActionEvent.emptyNew()
    return Event.new(VehicleMarketActionEvent_mt)
end

---Client-to-server request
---@param action number ACTION_*
---@param farmId number
---@param vehicle table|nil Vehicle to list (ACTION_CREATE)
---@param listingId number|nil Target listing (ACTION_CANCEL / ACTION_BUY)
---@param priceFactor number|nil
---@param durationMonths number|nil
function VehicleMarketActionEvent.new(action, farmId, vehicle, listingId, priceFactor, durationMonths)
    local self = VehicleMarketActionEvent.emptyNew()
    self.isNotice = false
    self.action = action or 0
    self.farmId = farmId or 0
    self.vehicle = vehicle
    self.listingId = listingId or 0
    self.priceFactor = priceFactor or 1
    self.durationMonths = durationMonths or 1
    return self
end

---Server-to-client HUD notice
function VehicleMarketActionEvent.newNotice(kind, targetFarmId, excludeFarmId, code, xmlFilename, amount, otherName)
    local self = VehicleMarketActionEvent.emptyNew()
    self.isNotice = true
    self.kind = kind or 0
    self.targetFarmId = targetFarmId or 0
    self.excludeFarmId = excludeFarmId or 0
    self.code = code or ""
    self.xmlFilename = xmlFilename or ""
    self.amount = amount or 0
    self.otherName = otherName or ""
    return self
end

function VehicleMarketActionEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isNotice)
    if self.isNotice then
        streamWriteUInt8(streamId, self.kind)
        streamWriteUIntN(streamId, self.targetFarmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteUIntN(streamId, self.excludeFarmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, self.code)
        streamWriteString(streamId, self.xmlFilename)
        streamWriteInt32(streamId, math.floor(self.amount + 0.5))
        streamWriteString(streamId, self.otherName)
        return
    end
    streamWriteUInt8(streamId, self.action)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    local hasVehicle = (self.vehicle ~= nil and self.vehicle.isRegistered == true)
    streamWriteBool(streamId, hasVehicle)
    if hasVehicle then
        NetworkUtil.writeNodeObject(streamId, self.vehicle)
    end
    streamWriteInt32(streamId, self.listingId)
    streamWriteFloat32(streamId, self.priceFactor)
    streamWriteUInt8(streamId, self.durationMonths)
end

function VehicleMarketActionEvent:readStream(streamId, connection)
    self.isNotice = streamReadBool(streamId)
    if self.isNotice then
        self.kind = streamReadUInt8(streamId)
        self.targetFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self.excludeFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self.code = streamReadString(streamId)
        self.xmlFilename = streamReadString(streamId)
        self.amount = streamReadInt32(streamId)
        self.otherName = streamReadString(streamId)
    else
        self.action = streamReadUInt8(streamId)
        self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self.vehicle = nil
        if streamReadBool(streamId) then
            self.vehicle = NetworkUtil.readNodeObject(streamId)
        end
        self.listingId = streamReadInt32(streamId)
        self.priceFactor = streamReadFloat32(streamId)
        self.durationMonths = streamReadUInt8(streamId)
    end
    self:run(connection)
end

---Routes a request directly on the server (SP / host) or sends it from an MP client
function VehicleMarketActionEvent.dispatch(action, farmId, vehicle, listingId, priceFactor, durationMonths)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return false
    end
    if g_server ~= nil then
        VehicleMarketActionEvent.executeOnServer(gm, action, farmId, vehicle, listingId, priceFactor, durationMonths, nil)
        return true
    end
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(VehicleMarketActionEvent.new(action, farmId, vehicle, listingId, priceFactor, durationMonths))
        return true
    end
    return false
end

---Executes a validated request on the authoritative server and reports the result to the requester
function VehicleMarketActionEvent.executeOnServer(gm, action, farmId, vehicle, listingId, priceFactor, durationMonths, connection)
    local N = GlobalMarket.VEHICLE_NOTICE
    local permission = (action == VehicleMarketActionEvent.ACTION_BUY) and Farm.PERMISSION.BUY_VEHICLE or Farm.PERMISSION.SELL_VEHICLE
    if not g_currentMission:getHasPlayerPermission(permission, connection, farmId) then
        gm:notifyVehicleMarketRequester(connection, N.RESULT, "noPermission", "", 0)
        return
    end

    if action == VehicleMarketActionEvent.ACTION_CREATE then
        local listing, reason = gm:createVehicleListing(vehicle, farmId, priceFactor, durationMonths, connection)
        if listing ~= nil then
            gm:notifyVehicleMarketRequester(connection, N.LISTED, "", listing.snapshot.xmlFilename,
                GlobalMarketVehicleListings.getListingPrice(listing) or 0)
        else
            gm:notifyVehicleMarketRequester(connection, N.RESULT, reason or "invalid", "", 0)
        end
    elseif action == VehicleMarketActionEvent.ACTION_CANCEL then
        local ok, reason = gm:cancelVehicleListing(listingId, farmId)
        if not ok then
            gm:notifyVehicleMarketRequester(connection, N.RESULT, reason or "invalid", "", 0)
        end
    elseif action == VehicleMarketActionEvent.ACTION_BUY then
        local ok, reason = gm:buyVehicleListing(listingId, farmId)
        if not ok then
            gm:notifyVehicleMarketRequester(connection, N.RESULT, reason or "invalid", "", 0)
        end
    end
end

function VehicleMarketActionEvent:run(connection)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return
    end
    if self.isNotice then
        -- Server-to-client only
        if connection:getIsServer() then
            gm:showVehicleMarketNotice(self.kind, self.targetFarmId, self.excludeFarmId, self.code,
                self.xmlFilename, self.amount, self.otherName)
        end
        return
    end
    -- Requests are processed on the server only
    if connection:getIsServer() then
        return
    end
    if self.farmId == nil or self.farmId <= 0 or self.farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end
    -- Verify the sender belongs to the claimed farm
    if g_currentMission.userManager ~= nil and g_farmManager ~= nil then
        local user = g_currentMission.userManager:getUserByConnection(connection)
        if user == nil then
            return
        end
        local senderFarm = g_farmManager:getFarmByUserId(user:getId())
        if senderFarm == nil or senderFarm.farmId ~= self.farmId then
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:warning("VehicleMarket (Server): Blocked spoofed farmId %d from user %s.",
                    self.farmId, tostring(user:getNickname()))
            end
            return
        end
    end
    VehicleMarketActionEvent.executeOnServer(gm, self.action, self.farmId, self.vehicle, self.listingId,
        self.priceFactor, self.durationMonths, connection)
end

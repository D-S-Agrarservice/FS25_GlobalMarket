-- =========================================================================================
-- FS25_GlobalMarket - AnimalMarketActionEvent.lua
-- Livestock market (#15): client-to-server requests (list, withdraw, buy, load onto trailer)
-- and server-to-client HUD notices (results, listed, sold, bought, returned, expired, loaded).
-- Author: D-S-Agrarservice
-- =========================================================================================

AnimalMarketActionEvent = {}
local AnimalMarketActionEvent_mt = Class(AnimalMarketActionEvent, Event)
InitEventClass(AnimalMarketActionEvent, "AnimalMarketActionEvent")

AnimalMarketActionEvent.ACTION_CREATE = 1
AnimalMarketActionEvent.ACTION_CANCEL = 2
AnimalMarketActionEvent.ACTION_BUY = 3
AnimalMarketActionEvent.ACTION_LOAD = 4
-- Admin test helpers (debug console of a logged-in admin; no farm needed)
AnimalMarketActionEvent.ACTION_ADMIN_MAKE_NPC = 5
AnimalMarketActionEvent.ACTION_ADMIN_ADVANCE = 6
AnimalMarketActionEvent.ACTION_ADMIN_RETRY_RETURNS = 7
AnimalMarketActionEvent.ACTION_ADMIN_SPAWN_NPC = 8
-- Great demand for meat animals (Stage 1b)
AnimalMarketActionEvent.ACTION_DEMAND_SELL = 9
AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_START = 10
AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_END = 11
-- Auctions (Stage 2): CREATE uses priceFactor = start, months = buy-now factor (0 = none), durationMonths = hours
AnimalMarketActionEvent.ACTION_AUCTION_CREATE = 12
AnimalMarketActionEvent.ACTION_AUCTION_BID = 13
AnimalMarketActionEvent.ACTION_AUCTION_BUY_NOW = 14

---Returns true for the admin test helper actions
---@param action number
---@return boolean
local function getIsAdminAction(action)
    return action == AnimalMarketActionEvent.ACTION_ADMIN_MAKE_NPC
        or action == AnimalMarketActionEvent.ACTION_ADMIN_ADVANCE
        or action == AnimalMarketActionEvent.ACTION_ADMIN_RETRY_RETURNS
        or action == AnimalMarketActionEvent.ACTION_ADMIN_SPAWN_NPC
        or action == AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_START
        or action == AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_END
end

function AnimalMarketActionEvent.emptyNew()
    return Event.new(AnimalMarketActionEvent_mt)
end

---Client-to-server request
---@param action number ACTION_*
---@param farmId number
---@param args table|nil
---  object: barn or trailer to list from (CREATE / DEMAND_SELL), target barn (BUY, optional), trailer (LOAD, optional)
---  clusterId, numAnimals: CREATE / DEMAND_SELL; priceFactor, durationMonths: CREATE
---  targetId: listing ID (CANCEL / BUY / ADMIN_MAKE_NPC), pickup box ID (LOAD, 0 = all) count (ADMIN_SPAWN_NPC) or animal type index (ADMIN_DEMAND_START, 0 = random)
---  deliveryMode: GlobalMarket.ANIMAL_DELIVERY (BUY)
---  months: months to advance (ADMIN_ADVANCE) or buy-now factor (AUCTION_CREATE)
---  AUCTION_CREATE: priceFactor = start factor, durationMonths = duration in hours; AUCTION_BID: priceFactor = bid factor
function AnimalMarketActionEvent.new(action, farmId, args)
    local self = AnimalMarketActionEvent.emptyNew()
    args = args or {}
    self.isNotice = false
    self.action = action or 0
    self.farmId = farmId or 0
    self.object = args.object
    self.clusterId = args.clusterId or 0
    self.numAnimals = args.numAnimals or 0
    self.targetId = args.targetId or 0
    self.priceFactor = args.priceFactor or 1
    self.durationMonths = args.durationMonths or 1
    self.deliveryMode = args.deliveryMode or 0
    self.months = args.months or 0
    return self
end

---Server-to-client HUD notice
function AnimalMarketActionEvent.newNotice(kind, targetFarmId, excludeFarmId, code, subTypeName, numAnimals, amount, otherName)
    local self = AnimalMarketActionEvent.emptyNew()
    self.isNotice = true
    self.kind = kind or 0
    self.targetFarmId = targetFarmId or 0
    self.excludeFarmId = excludeFarmId or 0
    self.code = code or ""
    self.subTypeName = subTypeName or ""
    self.numAnimals = numAnimals or 0
    self.amount = amount or 0
    self.otherName = otherName or ""
    return self
end

function AnimalMarketActionEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isNotice)
    if self.isNotice then
        streamWriteUInt8(streamId, self.kind)
        streamWriteUIntN(streamId, self.targetFarmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteUIntN(streamId, self.excludeFarmId, FarmManager.FARM_ID_SEND_NUM_BITS)
        streamWriteString(streamId, self.code)
        streamWriteString(streamId, self.subTypeName)
        streamWriteUInt16(streamId, math.max(0, math.min(math.floor(self.numAnimals), 65535)))
        streamWriteInt32(streamId, math.floor(self.amount + 0.5))
        streamWriteString(streamId, self.otherName)
        return
    end
    streamWriteUInt8(streamId, self.action)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    local hasObject = (self.object ~= nil and self.object.isRegistered == true)
    streamWriteBool(streamId, hasObject)
    if hasObject then
        NetworkUtil.writeNodeObject(streamId, self.object)
    end
    streamWriteInt32(streamId, math.floor(self.clusterId))
    streamWriteUInt16(streamId, math.max(0, math.min(math.floor(self.numAnimals), 65535)))
    streamWriteInt32(streamId, math.floor(self.targetId))
    streamWriteFloat32(streamId, self.priceFactor)
    streamWriteUInt8(streamId, math.max(0, math.min(math.floor(self.durationMonths), 255)))
    streamWriteUInt8(streamId, math.max(0, math.min(math.floor(self.deliveryMode), 255)))
    streamWriteFloat32(streamId, self.months)
end

function AnimalMarketActionEvent:readStream(streamId, connection)
    self.isNotice = streamReadBool(streamId)
    if self.isNotice then
        self.kind = streamReadUInt8(streamId)
        self.targetFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self.excludeFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self.code = streamReadString(streamId)
        self.subTypeName = streamReadString(streamId)
        self.numAnimals = streamReadUInt16(streamId)
        self.amount = streamReadInt32(streamId)
        self.otherName = streamReadString(streamId)
    else
        self.action = streamReadUInt8(streamId)
        self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
        self.object = nil
        if streamReadBool(streamId) then
            self.object = NetworkUtil.readNodeObject(streamId)
        end
        self.clusterId = streamReadInt32(streamId)
        self.numAnimals = streamReadUInt16(streamId)
        self.targetId = streamReadInt32(streamId)
        self.priceFactor = streamReadFloat32(streamId)
        self.durationMonths = streamReadUInt8(streamId)
        self.deliveryMode = streamReadUInt8(streamId)
        self.months = streamReadFloat32(streamId)
    end
    self:run(connection)
end

---Routes a request directly on the server (SP / host) or sends it from an MP client
---@param action number
---@param farmId number
---@param args table|nil See AnimalMarketActionEvent.new
---@return boolean sent
function AnimalMarketActionEvent.dispatch(action, farmId, args)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return false
    end
    if g_server ~= nil then
        AnimalMarketActionEvent.executeOnServer(gm, action, farmId, args or {}, nil)
        return true
    end
    if g_client ~= nil then
        g_client:getServerConnection():sendEvent(AnimalMarketActionEvent.new(action, farmId, args))
        return true
    end
    return false
end

---Executes a validated request on the authoritative server and reports failures to the requester
---@param gm table GlobalMarket instance
---@param action number
---@param farmId number
---@param args table
---@param connection table|nil nil for local requests (SP / host)
function AnimalMarketActionEvent.executeOnServer(gm, action, farmId, args, connection)
    local N = GlobalMarket.ANIMAL_NOTICE
    if getIsAdminAction(action) then
        -- Local requests (SP / host) are always allowed, remote ones only for logged-in admins
        if connection ~= nil and not connection:getIsLocal()
            and not g_currentMission.userManager:getIsConnectionMasterUser(connection) then
            gm:notifyAnimalMarketRequester(connection, N.RESULT, "noPermission")
            return
        end
    elseif not g_currentMission:getHasPlayerPermission(Farm.PERMISSION.TRADE_ANIMALS, connection, farmId) then
        gm:notifyAnimalMarketRequester(connection, N.RESULT, "noPermission")
        return
    end

    local ok, reason = true, nil
    if action == AnimalMarketActionEvent.ACTION_ADMIN_MAKE_NPC then
        ok, reason = gm:makeAnimalListingNpc(args.targetId)
    elseif action == AnimalMarketActionEvent.ACTION_ADMIN_ADVANCE then
        gm:updateAnimalMarketHourly(math.max(0.01, args.months or 1))
    elseif action == AnimalMarketActionEvent.ACTION_ADMIN_RETRY_RETURNS then
        gm:retryAnimalPickupReturns()
    elseif action == AnimalMarketActionEvent.ACTION_ADMIN_SPAWN_NPC then
        gm:spawnNpcAnimalListings(args.targetId)
    elseif action == AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_START then
        if gm.animalDemand == nil then
            gm:startAnimalDemand(args.targetId)
        end
    elseif action == AnimalMarketActionEvent.ACTION_ADMIN_DEMAND_END then
        gm:endAnimalDemand()
    elseif action == AnimalMarketActionEvent.ACTION_AUCTION_CREATE then
        local listing
        listing, reason = gm:createAnimalAuction(args.object, args.clusterId, args.numAnimals, farmId,
            args.priceFactor, args.months, args.durationMonths)
        ok = listing ~= nil
    elseif action == AnimalMarketActionEvent.ACTION_AUCTION_BID then
        ok, reason = gm:bidOnAnimalAuction(args.targetId, farmId, args.priceFactor)
    elseif action == AnimalMarketActionEvent.ACTION_AUCTION_BUY_NOW then
        ok, reason = gm:buyNowAnimalAuction(args.targetId, farmId)
    elseif action == AnimalMarketActionEvent.ACTION_DEMAND_SELL then
        ok, reason = gm:sellAnimalsToDemand(args.object, args.clusterId, args.numAnimals, farmId)
    elseif action == AnimalMarketActionEvent.ACTION_CREATE then
        local listing
        listing, reason = gm:createAnimalListing(args.object, args.clusterId, args.numAnimals, farmId,
            args.priceFactor, args.durationMonths)
        ok = listing ~= nil
    elseif action == AnimalMarketActionEvent.ACTION_CANCEL then
        ok, reason = gm:cancelAnimalListing(args.targetId, farmId)
    elseif action == AnimalMarketActionEvent.ACTION_BUY then
        local targetBarn = GlobalMarketAnimalListings.getIsBarn(args.object) and args.object or nil
        ok, reason = gm:buyAnimalListing(args.targetId, farmId, args.deliveryMode, targetBarn)
    elseif action == AnimalMarketActionEvent.ACTION_LOAD then
        local trailer = GlobalMarketAnimalListings.getIsTrailer(args.object) and args.object
            or GlobalMarket.getAnimalMarketTrailerAtDealer(farmId)
        if trailer == nil then
            ok, reason = false, "noTrailer"
        else
            local moved
            if (args.targetId or 0) <= 0 then
                moved, reason = gm:loadAllAnimalPickupsOntoTrailer(trailer, farmId)
            else
                moved, reason = gm:loadAnimalPickupOntoTrailer(args.targetId, trailer, farmId)
            end
            ok = moved > 0
        end
    else
        ok, reason = false, "invalid"
    end
    if not ok then
        gm:notifyAnimalMarketRequester(connection, N.RESULT, reason or "invalid")
    end
end

function AnimalMarketActionEvent:run(connection)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return
    end
    if self.isNotice then
        -- Server-to-client only
        if connection:getIsServer() then
            gm:showAnimalMarketNotice(self.kind, self.targetFarmId, self.excludeFarmId, self.code,
                self.subTypeName, self.numAnimals, self.amount, self.otherName)
        end
        return
    end
    -- Requests are processed on the server only
    if connection:getIsServer() then
        return
    end
    -- Admin helpers are checked against the admin login in executeOnServer and need no farm
    if getIsAdminAction(self.action) then
        AnimalMarketActionEvent.executeOnServer(gm, self.action, 0, { targetId = self.targetId, months = self.months }, connection)
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
                GlobalMarket.debugManager:warning("AnimalMarket (Server): Blocked spoofed farmId %d from user %s.",
                    self.farmId, tostring(user:getNickname()))
            end
            return
        end
    end
    AnimalMarketActionEvent.executeOnServer(gm, self.action, self.farmId, {
        object = self.object,
        clusterId = self.clusterId,
        numAnimals = self.numAnimals,
        targetId = self.targetId,
        priceFactor = self.priceFactor,
        durationMonths = self.durationMonths,
        deliveryMode = self.deliveryMode,
        months = self.months
    }, connection)
end

-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractsStations.lua
-- Map SellingStations & unowned ProductionPoints as physical delivery targets for NPC contracts (#27).
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketContractsStations = {}
GlobalMarketContractsStations.SYNC_INTERVAL_MS = 1000

-- =========================================================================
-- STATION DISCOVERY & RESOLUTION (Server)
-- =========================================================================

---Returns true if a selling station may act as NPC contract buyer (unowned map sell point or production)
---@param station table|nil
---@return boolean
local function isStationEligible(station)
    if station == nil or station.isSellingPoint ~= true or station.owningPlaceable == nil then
        return false
    end
    if station.allowMissions == false or station.hideFromPricesMenu == true or station.acceptedFillTypes == nil then
        return false
    end
    local placeable = station.owningPlaceable
    if placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() ~= AccessHandler.EVERYONE then
        return false
    end
    return true
end

---Resolves a human-readable station name (station name, falling back to the placeable name)
---@param station table
---@return string
local function getStationName(station)
    local name = nil
    if station.stationName ~= nil and station.stationName ~= "" then
        name = station.stationName
    elseif station.owningPlaceable ~= nil and station.owningPlaceable.getName ~= nil then
        name = station.owningPlaceable:getName()
    end
    if name == nil or name == "" then
        name = "NPC"
    end
    return name
end

---Returns the world X/Z position used for the map hotspot of a station
---@param station table
---@return number posX
---@return number posZ
local function getStationWorldPosition(station)
    local placeable = station.owningPlaceable
    if placeable ~= nil and placeable.getHotspot ~= nil and placeable.spec_hotspots ~= nil then
        local hotspot = placeable:getHotspot()
        if hotspot ~= nil and hotspot.getWorldPosition ~= nil then
            local x, z = hotspot:getWorldPosition()
            if x ~= nil and z ~= nil then
                return x, z
            end
        end
    end
    if placeable ~= nil and placeable.rootNode ~= nil and entityExists(placeable.rootNode) then
        local x, _, z = getWorldTranslation(placeable.rootNode)
        return x, z
    end
    return 0, 0
end

---Collects all eligible map stations accepting the given fillType
---@param fillTypeName string
---@return table candidates List of { station, placeable, index }
function GlobalMarket:findContractStationsForFillType(fillTypeName)
    local candidates = {}
    local storageSystem = g_currentMission ~= nil and g_currentMission.storageSystem or nil
    local fillTypeIndex = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil
    if storageSystem == nil or fillTypeIndex == nil then
        return candidates
    end

    for _, station in pairs(storageSystem:getUnloadingStations()) do
        if isStationEligible(station) and station.acceptedFillTypes[fillTypeIndex] == true then
            local placeable = station.owningPlaceable
            local index = storageSystem:getPlaceableUnloadingStationIndex(placeable, station)
            local uniqueId = placeable.getUniqueId ~= nil and placeable:getUniqueId() or nil
            if index ~= nil and uniqueId ~= nil and uniqueId ~= "" then
                table.insert(candidates, { station = station, placeable = placeable, index = index })
            end
        end
    end
    return candidates
end

---Assigns a random eligible map station as buyer of a local NPC contract (issuer name becomes the station name)
---@param contract table
---@return boolean assigned
function GlobalMarket:assignContractStation(contract)
    if contract == nil or contract.origin ~= "NPC" or contract.isOnline then
        return false
    end
    local candidates = self:findContractStationsForFillType(contract.fillType)
    if #candidates == 0 then
        return false
    end
    local pick = candidates[math.random(1, #candidates)]
    local posX, posZ = getStationWorldPosition(pick.station)

    contract.stationPlaceableId = pick.placeable:getUniqueId()
    contract.stationIndex = pick.index
    contract.stationPosX = posX
    contract.stationPosZ = posZ
    contract.stationRef = pick.station
    contract.issuerName = getStationName(pick.station)
    return true
end

---Drops the station target of a contract (falls back to menu delivery only, issuer name is kept)
---@param contract table
function GlobalMarket:clearContractStation(contract)
    contract.stationPlaceableId = nil
    contract.stationIndex = nil
    contract.stationPosX = nil
    contract.stationPosZ = nil
    contract.stationRef = nil
end

---Resolves the live SellingStation of a contract; clears the target if it vanished or got owned
---@param contract table
---@return table|nil station
function GlobalMarket:resolveContractStation(contract)
    if contract == nil or contract.stationPlaceableId == nil or contract.stationPlaceableId == "" then
        return nil
    end
    local mission = g_currentMission
    if mission == nil or mission.storageSystem == nil or mission.placeableSystem == nil then
        return nil
    end
    local storageSystem = mission.storageSystem

    local station = contract.stationRef
    if station == nil or not storageSystem:getIsUnloadingStationAvailable(station) then
        station = nil
        local placeable = mission.placeableSystem:getPlaceableByUniqueId(contract.stationPlaceableId)
        if placeable ~= nil then
            station = storageSystem:getPlaceableUnloadingStation(placeable, contract.stationIndex or 1)
        end
    end

    if not isStationEligible(station) then
        if self.debugManager ~= nil then
            self.debugManager:info("Contracts: Station target of contract #%d is no longer available. Falling back to menu delivery.", contract.id or 0)
        end
        self:clearContractStation(contract)
        return nil
    end
    contract.stationRef = station
    return station
end

---Rebuilds the [station] -> {contracts} lookup used by the unloading hook (server only, on state changes)
function GlobalMarket:rebuildContractStationIndex()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end
    local index = {}
    for _, c in ipairs(self.contracts or {}) do
        if c.status == "ACTIVE" and c.origin == "NPC" and not c.isOnline and c.stationPlaceableId ~= nil and c.stationPlaceableId ~= "" then
            local station = self:resolveContractStation(c)
            if station ~= nil then
                c.stationFillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(c.fillType)
                local list = index[station]
                if list == nil then
                    list = {}
                    index[station] = list
                end
                table.insert(list, c)
            end
        end
    end
    self.gmStationContracts = index
end

-- =========================================================================
-- CREDIT SETTLEMENT (Server, throttled)
-- =========================================================================

---Settles all liters unloaded at stations since the last flush and syncs the new contract state
function GlobalMarket:flushStationContractCredits()
    self.stationCreditsDirty = false
    self.stationCreditsForceFlush = false
    self.stationCreditsTimerMs = 0
    if self.contracts == nil then
        return
    end

    local anyCredit = false
    for i = #self.contracts, 1, -1 do
        local c = self.contracts[i]
        if c ~= nil and (c.pendingStationLiters or 0) > 0 then
            local liters = c.pendingStationLiters
            c.pendingStationLiters = 0
            anyCredit = true
            local completed = self:creditContractLiters(c, i, c.contractorFarmId, liters, false)
            if not completed and self.debugManager ~= nil then
                self.debugManager:info("Contracts: Farm %d unloaded %.0f L at '%s' for contract #%d (%.0f/%.0f L).",
                    c.contractorFarmId or 0, liters, tostring(c.issuerName), c.id or 0, c.deliveredLiters or 0, c.totalLiters or 0)
            end
        end
    end

    if anyCredit then
        self:broadcastContractsState()
    end
end

---Frame update: flushes pending station credits at most once per SYNC_INTERVAL_MS (or immediately on completion)
---@param dt number
function GlobalMarket:updateStationContracts(dt)
    if not self.stationCreditsDirty then
        return
    end
    self.stationCreditsTimerMs = (self.stationCreditsTimerMs or 0) + dt
    if self.stationCreditsForceFlush or self.stationCreditsTimerMs >= GlobalMarketContractsStations.SYNC_INTERVAL_MS then
        self:flushStationContractCredits()
    end
end

-- =========================================================================
-- ENGINE HOOK: SellingStation:addFillLevelFromTool (Server only)
-- =========================================================================
-- Bulk (Dischargeable), bales (BaleUnloadTrigger), pallets (PalletUnloadTrigger) and trains all end here.
-- Like basegame missions, the credited part is consumed without a station sale; only the excess is sold normally.

local function sellingStationAddFillLevelHook(station, superFunc, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil or gm.gmStationContracts == nil or deltaFillLevel == nil or deltaFillLevel <= 0 then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    end
    local list = gm.gmStationContracts[station]
    if list == nil then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    end

    local contract = nil
    for _, c in ipairs(list) do
        if c.contractorFarmId == farmId and c.stationFillTypeIndex == fillTypeIndex and c.status == "ACTIVE" then
            contract = c
            break
        end
    end
    if contract == nil or not station:getIsFillTypeAllowed(fillTypeIndex, extraAttributes) then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    end

    -- Basegame missions of the same farm & fillType keep priority at this station
    if station.missions ~= nil then
        for _, mission in pairs(station.missions) do
            if mission.fillSold ~= nil and mission.fillTypeIndex == fillTypeIndex and mission.farmId == farmId then
                return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
            end
        end
    end

    local openLiters = (contract.totalLiters or 0) - (contract.deliveredLiters or 0) - (contract.pendingStationLiters or 0)
    if openLiters <= 0.001 then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, fillInfo, toolType, extraAttributes)
    end

    local credited = math.min(deltaFillLevel, openLiters)
    contract.pendingStationLiters = (contract.pendingStationLiters or 0) + credited
    gm.stationCreditsDirty = true
    if credited >= openLiters - 0.5 then
        gm.stationCreditsForceFlush = true
    end

    local moved = credited
    local excess = deltaFillLevel - credited
    if excess > 0.001 then
        moved = moved + (superFunc(station, farmId, excess, fillTypeIndex, fillInfo, toolType, extraAttributes) or 0)
    else
        if station.startFx ~= nil then
            station:startFx(fillTypeIndex)
        end
        if station.activateSimpleFillplanes ~= nil then
            station:activateSimpleFillplanes(fillTypeIndex)
        end
    end
    return moved
end

if SellingStation ~= nil and SellingStation.addFillLevelFromTool ~= nil and not GlobalMarketContractsStations.isHooked then
    SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(SellingStation.addFillLevelFromTool, sellingStationAddFillLevelHook)
    GlobalMarketContractsStations.isHooked = true
end

-- =========================================================================
-- MAP MARKER (Client UI, basegame prices menu pattern)
-- =========================================================================

---Returns the basegame map hotspot of a contract's target station (nil if not resolvable locally)
---Read-only lookup: never clears station data, so it is safe on MP clients.
---@param contract table|nil
---@return table|nil hotspot
function GlobalMarket:getContractStationHotspot(contract)
    if contract == nil or contract.isOnline or contract.stationPlaceableId == nil or contract.stationPlaceableId == "" then
        return nil
    end
    local mission = g_currentMission
    if mission == nil or mission.placeableSystem == nil then
        return nil
    end
    -- Hash lookup on every call (no cached stationRef): a removed placeable never hands out a stale hotspot
    local placeable = mission.placeableSystem:getPlaceableByUniqueId(contract.stationPlaceableId)
    if placeable == nil or placeable.getHotspot == nil or placeable.spec_hotspots == nil then
        return nil
    end
    return placeable:getHotspot(1)
end

---Returns true if the contract's target station is the currently tagged map target
---@param contract table|nil
---@return boolean
function GlobalMarket:getIsContractStationMarked(contract)
    local mission = g_currentMission
    if mission == nil or mission.currentMapTargetHotspot == nil then
        return false
    end
    local hotspot = self:getContractStationHotspot(contract)
    return hotspot ~= nil and hotspot == mission.currentMapTargetHotspot
end

---Toggles the map target marker (incl. navigation) on the contract's target station
---@param contract table|nil
---@return boolean isMarked State after toggling
function GlobalMarket:toggleContractStationMarker(contract)
    local mission = g_currentMission
    local hotspot = self:getContractStationHotspot(contract)
    if mission == nil or mission.setMapTargetHotspot == nil or hotspot == nil then
        return false
    end
    if mission.currentMapTargetHotspot == hotspot then
        mission:setMapTargetHotspot(nil)
        return false
    end
    mission:setMapTargetHotspot(hotspot)
    return true
end

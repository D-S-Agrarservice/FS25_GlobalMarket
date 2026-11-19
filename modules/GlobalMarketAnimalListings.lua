-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketAnimalListings.lua
-- Livestock market (#15): listing sources (barns, livestock trailers at the animal dealer),
-- eligibility checks, escrow snapshots of animal clusters (full state via the cluster's own
-- clone/save/stream functions), dealer values and placement into barns or trailers.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketAnimalListings = {}

-- Source/target kinds of a listing
GlobalMarketAnimalListings.SOURCE_BARN = 1
GlobalMarketAnimalListings.SOURCE_TRAILER = 2

-- Mods that replace the basegame cluster system; the animal market stays disabled while one is active
GlobalMarketAnimalListings.INCOMPATIBLE_MODS = {
    "FS25_RealisticLivestock"
}

-- =========================================================================
-- AVAILABILITY & COMPATIBILITY
-- =========================================================================

---Returns the name of an active mod that is incompatible with the animal market, or nil
---@return string|nil modName
function GlobalMarketAnimalListings.getIncompatibleMod()
    if g_modIsLoaded == nil then
        return nil
    end
    for _, modName in ipairs(GlobalMarketAnimalListings.INCOMPATIBLE_MODS) do
        if g_modIsLoaded[modName] then
            return modName
        end
    end
    return nil
end

---Returns true if the animal market can run in the current mission
---@return boolean
function GlobalMarketAnimalListings.getIsAvailable()
    local mission = g_currentMission
    if mission == nil or mission.animalSystem == nil or mission.husbandrySystem == nil then
        return false
    end
    return GlobalMarketAnimalListings.getIncompatibleMod() == nil
end

-- =========================================================================
-- SUBTYPES & DISPLAY
-- =========================================================================

---Returns the local subtype index for a subtype name (nil if the subtype does not exist here)
---@param subTypeName string|nil
---@return number|nil
function GlobalMarketAnimalListings.getSubTypeIndexByName(subTypeName)
    if subTypeName == nil or g_currentMission == nil or g_currentMission.animalSystem == nil then
        return nil
    end
    local subType = g_currentMission.animalSystem:getSubTypeByName(subTypeName)
    return (subType ~= nil) and subType.subTypeIndex or nil
end

---Returns the localized title of a subtype (breed), e.g. "Holstein"
---@param subTypeIndex number|nil
---@param fallback string|nil
---@return string
function GlobalMarketAnimalListings.getSubTypeTitle(subTypeIndex, fallback)
    local animalSystem = (g_currentMission ~= nil) and g_currentMission.animalSystem or nil
    local subType = (animalSystem ~= nil and subTypeIndex ~= nil) and animalSystem:getSubTypeByIndex(subTypeIndex) or nil
    if subType ~= nil and subType.fillTypeIndex ~= nil then
        local title = g_fillTypeManager:getFillTypeTitleByIndex(subType.fillTypeIndex)
        if title ~= nil and title ~= "" then
            return title
        end
    end
    return fallback or "?"
end

---Returns the animal type name (e.g. "COW") of a subtype
---@param subTypeIndex number|nil
---@return string|nil
function GlobalMarketAnimalListings.getTypeName(subTypeIndex)
    local animalSystem = (g_currentMission ~= nil) and g_currentMission.animalSystem or nil
    if animalSystem == nil or subTypeIndex == nil then
        return nil
    end
    local typeIndex = animalSystem:getTypeIndexBySubTypeIndex(subTypeIndex)
    local animalType = (typeIndex ~= nil) and animalSystem:getTypeByIndex(typeIndex) or nil
    return (animalType ~= nil) and animalType.name or nil
end

-- =========================================================================
-- SOURCES (barns and livestock trailers)
-- =========================================================================

---Returns true if a livestock trailer currently stands in an animal dealer trigger
---@param trailer table|nil
---@return boolean
function GlobalMarketAnimalListings.getIsTrailerAtDealer(trailer)
    if trailer == nil or trailer.isDeleted or trailer.getLoadingTrigger == nil then
        return false
    end
    local trigger = trailer:getLoadingTrigger()
    return trigger ~= nil and trigger.isDealer == true and trigger.husbandry == nil
end

---Returns true if an object is a barn with animals (placeable with the husbandry animals specialization)
---@param object table|nil
---@return boolean
function GlobalMarketAnimalListings.getIsBarn(object)
    return object ~= nil and object.spec_husbandryAnimals ~= nil and object.getClusterSystem ~= nil
end

---Returns true if an object is a livestock trailer
---@param object table|nil
---@return boolean
function GlobalMarketAnimalListings.getIsTrailer(object)
    return object ~= nil and object.spec_livestockTrailer ~= nil and object.getClusterSystem ~= nil
end

---Returns the source kind of an object (SOURCE_BARN / SOURCE_TRAILER) or nil
---@param object table|nil
---@return number|nil
function GlobalMarketAnimalListings.getSourceKind(object)
    if GlobalMarketAnimalListings.getIsBarn(object) then
        return GlobalMarketAnimalListings.SOURCE_BARN
    elseif GlobalMarketAnimalListings.getIsTrailer(object) then
        return GlobalMarketAnimalListings.SOURCE_TRAILER
    end
    return nil
end

---Returns all barns of a farm (optionally only those supporting a subtype)
---@param farmId number
---@param subTypeIndex number|nil
---@return table barns
function GlobalMarketAnimalListings.getFarmBarns(farmId, subTypeIndex)
    local result = {}
    local husbandrySystem = (g_currentMission ~= nil) and g_currentMission.husbandrySystem or nil
    if husbandrySystem == nil or farmId == nil then
        return result
    end
    local typeIndex = nil
    if subTypeIndex ~= nil then
        typeIndex = g_currentMission.animalSystem:getTypeIndexBySubTypeIndex(subTypeIndex)
    end
    for _, placeable in ipairs(husbandrySystem:getPlaceablesByFarm(farmId, typeIndex)) do
        if GlobalMarketAnimalListings.getIsBarn(placeable) then
            table.insert(result, placeable)
        end
    end
    return result
end

---Checks whether a cluster of a source may be listed by a farm
---@param source table|nil Barn or livestock trailer
---@param farmId number
---@param clusterId number|nil
---@param numAnimals number|nil
---@return boolean isEligible
---@return string|nil reason l10n-ready reason code if not eligible
function GlobalMarketAnimalListings.getEligibility(source, farmId, clusterId, numAnimals)
    if not GlobalMarketAnimalListings.getIsAvailable() then
        return false, "unavailable"
    end
    local kind = GlobalMarketAnimalListings.getSourceKind(source)
    if kind == nil or source.isDeleted then
        return false, "invalid"
    end
    if source:getOwnerFarmId() ~= farmId then
        return false, "notOwned"
    end
    if kind == GlobalMarketAnimalListings.SOURCE_TRAILER and not GlobalMarketAnimalListings.getIsTrailerAtDealer(source) then
        return false, "notAtDealer"
    end
    local cluster = (clusterId ~= nil) and source:getClusterById(clusterId) or nil
    if cluster == nil then
        return false, "invalid"
    end
    if numAnimals == nil or numAnimals < 1 or numAnimals > cluster:getNumAnimals() then
        return false, "notEnoughAnimals"
    end
    if cluster.getCanBeSold ~= nil and not cluster:getCanBeSold() then
        return false, "notTradeable"
    end
    return true, nil
end

-- =========================================================================
-- SNAPSHOTS (escrow: detached clusters with the full animal state)
-- =========================================================================

---Creates a detached copy of a cluster with a given number of animals (same path as the basegame move)
---@param cluster table
---@param numAnimals number
---@return table copy
local function copyCluster(cluster, numAnimals)
    local copy = cluster:clone()
    copy.numAnimals = 0
    copy:changeNumAnimals(numAnimals)
    copy.clusterSystem = nil
    return copy
end

---Builds a snapshot table around a detached cluster
---@param cluster table Detached cluster
---@return table snapshot
local function newSnapshot(cluster)
    local subType = g_currentMission.animalSystem:getSubTypeByIndex(cluster:getSubTypeIndex())
    return {
        subTypeName = subType.name,
        cluster = cluster
    }
end

---Takes animals out of a source into escrow (Server). Call getEligibility first.
---@param source table Barn or livestock trailer
---@param clusterId number
---@param numAnimals number
---@return table|nil snapshot
function GlobalMarketAnimalListings.takeFromSource(source, clusterId, numAnimals)
    local cluster = source:getClusterById(clusterId)
    if cluster == nil or cluster:getNumAnimals() < numAnimals then
        return nil
    end
    local snapshot = newSnapshot(copyCluster(cluster, numAnimals))
    cluster:changeNumAnimals(-numAnimals)
    source:getClusterSystem():updateNow()
    return snapshot
end

---Returns the number of animals in a snapshot
---@param snapshot table
---@return number
function GlobalMarketAnimalListings.getNumAnimals(snapshot)
    if snapshot.cluster ~= nil then
        return snapshot.cluster:getNumAnimals()
    end
    return (snapshot.raw ~= nil) and snapshot.raw.numAnimals or 0
end

---Returns true if the subtype of a snapshot exists on this server
---@param snapshot table|nil
---@return boolean
function GlobalMarketAnimalListings.getIsResolved(snapshot)
    return snapshot ~= nil and snapshot.cluster ~= nil
end

---Returns the display values of a snapshot (works for unresolved snapshots as well)
---@param snapshot table
---@return table info {subTypeIndex, title, typeName, numAnimals, age, health, reproduction, name, isPregnant, isBreedingReady}
function GlobalMarketAnimalListings.getInfo(snapshot)
    local cluster = snapshot.cluster
    local raw = snapshot.raw or {}
    local info = {
        subTypeIndex = (cluster ~= nil) and cluster:getSubTypeIndex() or nil,
        numAnimals = GlobalMarketAnimalListings.getNumAnimals(snapshot),
        age = (cluster ~= nil) and cluster.age or (raw.age or 0),
        health = (cluster ~= nil) and cluster.health or (raw.health or 0),
        reproduction = (cluster ~= nil) and cluster.reproduction or (raw.reproduction or 0),
        name = (cluster ~= nil and cluster.getName ~= nil) and cluster:getName() or raw.name,
        isPregnant = false,
        isBreedingReady = false
    }
    info.title = GlobalMarketAnimalListings.getSubTypeTitle(info.subTypeIndex, snapshot.subTypeName)
    info.typeName = GlobalMarketAnimalListings.getTypeName(info.subTypeIndex)
    if cluster ~= nil and cluster:getSupportsReproduction() then
        local subType = g_currentMission.animalSystem:getSubTypeByIndex(info.subTypeIndex)
        info.isPregnant = info.reproduction > 0
        info.isBreedingReady = subType ~= nil and info.age >= subType.reproductionMinAgeMonth
            and cluster:getHealthFactor() >= subType.reproductionMinHealth
    end
    return info
end

-- =========================================================================
-- VALUES
-- =========================================================================

---Returns the basegame dealer value of a snapshot (what the dealer would pay, incl. health/fitness)
---@param snapshot table
---@return number|nil value nil if the subtype does not exist here
function GlobalMarketAnimalListings.getDealerValue(snapshot)
    if snapshot.values ~= nil then
        return snapshot.values.dealerValue
    end
    local cluster = snapshot.cluster
    if cluster == nil then
        return nil
    end
    return cluster:getSellPrice() * cluster:getNumAnimals()
end

---Returns the dealer's new price for animals of this subtype and age, or nil if the dealer does not sell this age stage
---@param snapshot table
---@return number|nil price Buy price incl. transport fee for all animals of the snapshot
function GlobalMarketAnimalListings.getDealerNewPrice(snapshot)
    if snapshot.values ~= nil then
        return snapshot.values.newPrice
    end
    local cluster = snapshot.cluster
    if cluster == nil then
        return nil
    end
    local animalSystem = g_currentMission.animalSystem
    local subTypeIndex = cluster:getSubTypeIndex()
    local visual = animalSystem:getVisualByAge(subTypeIndex, cluster.age)
    if visual == nil or visual.store == nil or not visual.store.canBeBought then
        return nil
    end
    local numAnimals = cluster:getNumAnimals()
    local buyPrice = animalSystem:getAnimalBuyPrice(subTypeIndex, cluster.age) or 0
    return buyPrice * numAnimals + cluster:getTranportationFee(numAnimals)
end

---Returns the basegame transport fee for delivering the animals of a snapshot to a barn
---@param snapshot table
---@return number
function GlobalMarketAnimalListings.getTransportFee(snapshot)
    if snapshot.values ~= nil then
        return snapshot.values.transportFee
    end
    local cluster = snapshot.cluster
    if cluster == nil then
        return 0
    end
    return cluster:getTranportationFee(cluster:getNumAnimals())
end

---Returns the asking price of a listing on this server (nil if the subtype does not exist here)
---@param listing table
---@return number|nil price
function GlobalMarketAnimalListings.getListingPrice(listing)
    local value = GlobalMarketAnimalListings.getDealerValue(listing.snapshot)
    if value == nil then
        return nil
    end
    return math.floor(value * (listing.priceFactor or 1) + 0.5)
end

-- Cache: subtype index -> meat animal flag (subtype indices are per mission, see resetCaches)
local meatAnimalCache = {}

---Clears per-mission caches (call when a mission is loaded)
function GlobalMarketAnimalListings.resetCaches()
    meatAnimalCache = {}
end

---Returns true if a subtype is a meat animal: no milk, wool, egg or other pallet output, not rideable
---and kept in groups (single-animal clusters like horses or alpacas are companions, not meat animals)
---@param subTypeIndex number|nil
---@return boolean
function GlobalMarketAnimalListings.getIsMeatAnimal(subTypeIndex)
    if subTypeIndex == nil then
        return false
    end
    if meatAnimalCache[subTypeIndex] ~= nil then
        return meatAnimalCache[subTypeIndex]
    end
    local animalSystem = g_currentMission.animalSystem
    local subType = animalSystem:getSubTypeByIndex(subTypeIndex)
    local isMeat = false
    if subType ~= nil and subType.output ~= nil and subType.rideableFilename == nil
        and subType.output.milk == nil and subType.output.pallets == nil then
        local probe = animalSystem:createClusterFromSubTypeIndex(subTypeIndex)
        isMeat = probe ~= nil and probe:getMaxNumAnimals() > 1
    end
    meatAnimalCache[subTypeIndex] = isMeat
    return isMeat
end

-- =========================================================================
-- PLACEMENT (Server)
-- =========================================================================

---Returns how many animals of a snapshot fit into a target (barn or livestock trailer) of a farm
---@param target table|nil
---@param snapshot table
---@param farmId number
---@return number freeSlots
---@return string|nil reason if nothing fits
function GlobalMarketAnimalListings.getFreeSlots(target, snapshot, farmId)
    local cluster = snapshot.cluster
    if cluster == nil then
        return 0, "unavailable"
    end
    local kind = GlobalMarketAnimalListings.getSourceKind(target)
    if kind == nil or target.isDeleted then
        return 0, "invalid"
    end
    if target:getOwnerFarmId() ~= farmId then
        return 0, "notOwned"
    end
    local subTypeIndex = cluster:getSubTypeIndex()
    if not target:getSupportsAnimalSubType(subTypeIndex) then
        return 0, "notSupported"
    end
    local free = target:getNumOfFreeAnimalSlots(subTypeIndex)
    if kind == GlobalMarketAnimalListings.SOURCE_BARN then
        -- Same global limit check as the basegame dealer
        free = math.min(free, g_currentMission.husbandrySystem:getNumOfFreeAnimalSlots(farmId, subTypeIndex))
    end
    free = math.max(0, math.floor(free))
    if free == 0 then
        return 0, "noSpace"
    end
    return free, nil
end

---Moves up to numAnimals animals of a snapshot into a target (Server). Call getFreeSlots first.
---@param target table Barn or livestock trailer
---@param snapshot table
---@param numAnimals number
---@return number moved
function GlobalMarketAnimalListings.placeIntoTarget(target, snapshot, numAnimals)
    local cluster = snapshot.cluster
    if cluster == nil then
        return 0
    end
    local moved = math.min(numAnimals, cluster:getNumAnimals())
    if moved <= 0 then
        return 0
    end
    if cluster:getSupportsMerging() then
        target:addCluster(copyCluster(cluster, moved))
    else
        -- Single-animal clusters (horses, alpacas) keep their identity
        target:addCluster(copyCluster(cluster, 1))
        moved = 1
    end
    cluster:changeNumAnimals(-moved)
    local clusterSystem = target:getClusterSystem()
    if clusterSystem ~= nil then
        clusterSystem:updateNow()
    end
    return moved
end

---Returns the first barn of a farm with space for at least one animal of a snapshot
---@param farmId number
---@param snapshot table
---@return table|nil barn
function GlobalMarketAnimalListings.findBarnWithSpace(farmId, snapshot)
    if snapshot.cluster == nil then
        return nil
    end
    for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farmId, snapshot.cluster:getSubTypeIndex())) do
        if GlobalMarketAnimalListings.getFreeSlots(barn, snapshot, farmId) > 0 then
            return barn
        end
    end
    return nil
end

-- =========================================================================
-- XML PERSISTENCE
-- =========================================================================

---Writes a snapshot below an XML key (uses the cluster's own savegame format)
---@param xmlFile table
---@param key string
---@param snapshot table
function GlobalMarketAnimalListings.writeSnapshotToXml(xmlFile, key, snapshot)
    xmlFile:setString(key .. "#subType", snapshot.subTypeName or "")
    if snapshot.cluster ~= nil then
        snapshot.cluster:saveToXMLFile(xmlFile, key, nil)
        return
    end
    -- Subtype not available (e.g. pack disabled): keep the base values
    local raw = snapshot.raw or {}
    xmlFile:setInt(key .. "#numAnimals", raw.numAnimals or 0)
    xmlFile:setInt(key .. "#age", raw.age or 0)
    xmlFile:setInt(key .. "#health", raw.health or 0)
    xmlFile:setInt(key .. "#reproduction", raw.reproduction or 0)
    if raw.name ~= nil then
        xmlFile:setString(key .. "#name", raw.name)
    end
end

---Reads a snapshot written by writeSnapshotToXml
---@param xmlFile table
---@param key string
---@return table|nil snapshot
function GlobalMarketAnimalListings.readSnapshotFromXml(xmlFile, key)
    local subTypeName = xmlFile:getString(key .. "#subType")
    if subTypeName == nil or subTypeName == "" then
        return nil
    end
    local snapshot = { subTypeName = subTypeName }
    local subTypeIndex = GlobalMarketAnimalListings.getSubTypeIndexByName(subTypeName)
    if subTypeIndex ~= nil then
        local cluster = g_currentMission.animalSystem:createClusterFromSubTypeIndex(subTypeIndex)
        if cluster:loadFromXMLFile(xmlFile, key) and cluster:getNumAnimals() > 0 then
            snapshot.cluster = cluster
            return snapshot
        end
    end
    snapshot.raw = {
        numAnimals = xmlFile:getInt(key .. "#numAnimals", 0),
        age = xmlFile:getInt(key .. "#age", 0),
        health = xmlFile:getInt(key .. "#health", 0),
        reproduction = xmlFile:getInt(key .. "#reproduction", 0),
        name = xmlFile:getString(key .. "#name")
    }
    if snapshot.raw.numAnimals <= 0 then
        return nil
    end
    return snapshot
end

-- =========================================================================
-- NETWORK STREAMS
-- Clients only display listings, so a compact view is sent instead of the full cluster stream:
-- base values, name and the server-computed prices (the server keeps the authoritative cluster).
-- =========================================================================

---Writes the client view of a snapshot to a network stream (Server)
---@param streamId number
---@param snapshot table
function GlobalMarketAnimalListings.writeSnapshotToStream(streamId, snapshot)
    local info = GlobalMarketAnimalListings.getInfo(snapshot)
    streamWriteString(streamId, snapshot.subTypeName or "")
    streamWriteUInt16(streamId, math.min(info.numAnimals or 0, 65535))
    streamWriteUInt8(streamId, math.min(math.floor(info.age or 0), 255))
    streamWriteUInt8(streamId, math.min(math.floor(info.health or 0), 100))
    streamWriteUInt8(streamId, math.min(math.floor(info.reproduction or 0), 100))
    streamWriteString(streamId, info.name or "")
    local newPrice = GlobalMarketAnimalListings.getDealerNewPrice(snapshot)
    streamWriteFloat32(streamId, GlobalMarketAnimalListings.getDealerValue(snapshot) or -1)
    streamWriteFloat32(streamId, newPrice or -1)
    streamWriteFloat32(streamId, GlobalMarketAnimalListings.getTransportFee(snapshot))
end

---Reads a client view written by writeSnapshotToStream (Client)
---@param streamId number
---@return table snapshot
function GlobalMarketAnimalListings.readSnapshotFromStream(streamId)
    local snapshot = { subTypeName = streamReadString(streamId) }
    local raw = {
        numAnimals = streamReadUInt16(streamId),
        age = streamReadUInt8(streamId),
        health = streamReadUInt8(streamId),
        reproduction = streamReadUInt8(streamId),
        name = streamReadString(streamId)
    }
    if raw.name == "" then
        raw.name = nil
    end
    local dealerValue = streamReadFloat32(streamId)
    local newPrice = streamReadFloat32(streamId)
    snapshot.values = {
        dealerValue = (dealerValue >= 0) and dealerValue or nil,
        newPrice = (newPrice >= 0) and newPrice or nil,
        transportFee = streamReadFloat32(streamId)
    }
    -- Display cluster for info/flags (never placed into the world)
    local subTypeIndex = GlobalMarketAnimalListings.getSubTypeIndexByName(snapshot.subTypeName)
    if subTypeIndex ~= nil then
        local cluster = g_currentMission.animalSystem:createClusterFromSubTypeIndex(subTypeIndex)
        cluster.numAnimals = raw.numAnimals
        cluster.age = raw.age
        cluster.health = raw.health
        cluster.reproduction = raw.reproduction
        if raw.name ~= nil and cluster.name ~= nil then
            cluster.name = raw.name
        end
        snapshot.cluster = cluster
    else
        snapshot.raw = raw
    end
    return snapshot
end

-- =========================================================================
-- DEBUG CONSOLE
-- =========================================================================

---Formats one cluster line for the console
---@param prefix string
---@param snapshotLike table Snapshot (or a temporary one around a live cluster)
---@return string
local function formatConsoleLine(prefix, snapshotLike)
    local info = GlobalMarketAnimalListings.getInfo(snapshotLike)
    local newPrice = GlobalMarketAnimalListings.getDealerNewPrice(snapshotLike)
    local flags = {}
    if info.isPregnant then
        table.insert(flags, string.format("pregnant %d%%", info.reproduction))
    elseif info.isBreedingReady then
        table.insert(flags, "breeding-ready")
    end
    if GlobalMarketAnimalListings.getIsMeatAnimal(info.subTypeIndex) then
        table.insert(flags, "meat")
    end
    return string.format("%s %s%s x%d | %d months | health %d%% | dealer %.0f | new %s | fee %.0f | %s",
        prefix, info.title, info.name ~= nil and (" '" .. info.name .. "'") or "", info.numAnimals, info.age, info.health,
        GlobalMarketAnimalListings.getDealerValue(snapshotLike) or 0,
        newPrice ~= nil and string.format("%.0f", newPrice) or "n/a",
        GlobalMarketAnimalListings.getTransportFee(snapshotLike),
        #flags > 0 and table.concat(flags, ", ") or "-")
end

---Console: lists the animals of the own barns and livestock trailers with eligibility and values
---@return string
function GlobalMarket:consoleCommandAnimalMarketList()
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_currentMission == nil then
        return "No mission running."
    end
    local incompatible = GlobalMarketAnimalListings.getIncompatibleMod()
    if incompatible ~= nil then
        return string.format("Animal market disabled: incompatible mod '%s' is active.", incompatible)
    end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return "Join a farm first (the dedicated server console has no farm)."
    end
    local lines = { string.format("Animals of farm %d:", farmId) }
    local function addSource(source, label)
        table.insert(lines, label)
        for _, cluster in ipairs(source:getClusterSystem():getClusters()) do
            local isEligible, reason = GlobalMarketAnimalListings.getEligibility(source, farmId, cluster.id, cluster:getNumAnimals())
            local prefix = string.format("  [cluster %d] %s", cluster.id, isEligible and "ok" or ("blocked: " .. tostring(reason)))
            table.insert(lines, formatConsoleLine(prefix, { cluster = cluster }))
        end
    end
    for _, barn in ipairs(GlobalMarketAnimalListings.getFarmBarns(farmId, nil)) do
        addSource(barn, string.format("Barn '%s' (%d/%d):", barn:getName(), barn:getNumOfAnimals(), barn:getMaxNumOfAnimals()))
    end
    for _, trailer in ipairs(g_currentMission.husbandrySystem.livestockTrailers or {}) do
        if trailer:getOwnerFarmId() == farmId then
            local name = (trailer.getFullName ~= nil) and trailer:getFullName() or "trailer"
            addSource(trailer, string.format("Trailer '%s'%s:", name,
                GlobalMarketAnimalListings.getIsTrailerAtDealer(trailer) and " (at animal dealer)" or ""))
        end
    end
    return table.concat(lines, "\n")
end

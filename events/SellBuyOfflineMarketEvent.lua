-- =========================================================================================
-- FS25_GlobalMarket - SellBuyOfflineMarketEvent.lua
-- Client-to-server event transmitting offline market buy and sell transaction requests.
-- Author: D-S-Agrarservice
-- =========================================================================================

SellBuyOfflineMarketEvent = {}
local SellBuyOfflineMarketEvent_mt = Class(SellBuyOfflineMarketEvent, Event)

InitEventClass(SellBuyOfflineMarketEvent, "SellBuyOfflineMarketEvent")

-- Creates an empty instance for reading from the network stream
function SellBuyOfflineMarketEvent.emptyNew()
    return Event.new(SellBuyOfflineMarketEvent_mt)
end

-- Creates a populated instance for writing to the network stream
function SellBuyOfflineMarketEvent.new(mode, filltypeName, level, storageObject, count, isObjectStorage, playerFarmId, formatXml, capacityPerObject)
    local self = SellBuyOfflineMarketEvent.emptyNew()

    self.mode = mode
    self.filltypeName = filltypeName
    self.level = math.floor(level)
    self.count = count
    self.isObjectStorage = isObjectStorage or false
    self.playerFarmId = playerFarmId

    -- formatXml can be either a String (Pallet Path) or a Number (Bale Index)
    self.formatXml = formatXml
    self.capacityPerObject = capacityPerObject or 0

    -- Store direct registered Network Object (Storage/ManureHeap/Placeable) and resolve owning Placeable fallback
    self.storageObject = storageObject
    self.targetPlaceable = nil
    self.storageIndex = 1

    if storageObject ~= nil then
        if self.isObjectStorage then
            self.targetPlaceable = storageObject
        elseif g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.resolveBulkStorageOwner ~= nil then
            local ownerPlaceable, _, _, resolvedIndex = g_currentMission.globalMarket:resolveBulkStorageOwner(storageObject)
            self.targetPlaceable = ownerPlaceable
            self.storageIndex = resolvedIndex or 1
        end
    end

    return self
end

-- Serializes the transaction payload into the network stream
function SellBuyOfflineMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.mode)
    streamWriteString(streamId, self.filltypeName)
    streamWriteInt32(streamId, self.level)

    -- 1. Primary: Transmit registered Network Object (Storage, ManureHeap, or Placeable) directly
    local hasDirectStorageNode = (self.storageObject ~= nil and self.storageObject.isRegistered == true)
    streamWriteBool(streamId, hasDirectStorageNode)
    if hasDirectStorageNode then
        NetworkUtil.writeNodeObject(streamId, self.storageObject)
    end

    -- 2. Fallback: Also transmit resolved owning Placeable and storage index
    local hasTargetPlaceable = (self.targetPlaceable ~= nil and self.targetPlaceable.isRegistered == true)
    streamWriteBool(streamId, hasTargetPlaceable)
    if hasTargetPlaceable then
        NetworkUtil.writeNodeObject(streamId, self.targetPlaceable)
    end
    streamWriteInt8(streamId, self.storageIndex or 1)

    streamWriteInt32(streamId, self.count)
    streamWriteBool(streamId, self.isObjectStorage)
    streamWriteInt16(streamId, self.playerFarmId)

    -- SMART TRANSMISSION: Check if formatXml is a BaleIndex (Number) or PalletPath (String)
    local isBaleIndex = type(self.formatXml) == "number"
    streamWriteBool(streamId, isBaleIndex)

    if isBaleIndex then
        streamWriteInt32(streamId, self.formatXml) -- Send as a number
    else
        local safeString = (self.formatXml ~= nil and type(self.formatXml) == "string") and self.formatXml or ""
        streamWriteString(streamId, safeString) -- Send as a string
    end

    streamWriteInt32(streamId, self.capacityPerObject)
end

-- Deserializes the transaction payload from the network stream
function SellBuyOfflineMarketEvent:readStream(streamId, connection)
    self.mode = streamReadInt8(streamId)
    self.filltypeName = streamReadString(streamId)
    self.level = streamReadInt32(streamId)

    -- 1. Primary: Read direct registered Network Object
    local hasDirectStorageNode = streamReadBool(streamId)
    local directStorageObject = nil
    if hasDirectStorageNode then
        directStorageObject = NetworkUtil.readNodeObject(streamId)
    end

    -- 2. Fallback: Read owning Placeable and storage index
    local hasTargetPlaceable = streamReadBool(streamId)
    self.targetPlaceable = nil
    if hasTargetPlaceable then
        self.targetPlaceable = NetworkUtil.readNodeObject(streamId)
    end
    self.storageIndex = streamReadInt8(streamId)

    self.count = streamReadInt32(streamId)
    self.isObjectStorage = streamReadBool(streamId)
    self.playerFarmId = streamReadInt16(streamId)

    -- SMART TRANSMISSION: Reconstruct as BaleIndex (Number) or PalletPath (String)
    local isBaleIndex = streamReadBool(streamId)

    if isBaleIndex then
        self.formatXml = streamReadInt32(streamId)
    else
        self.formatXml = streamReadString(streamId)
    end

    self.capacityPerObject = streamReadInt32(streamId)

    -- Reconstruct the original storageObject for backend compatibility across all placeable types
    self.storageObject = directStorageObject
    if self.storageObject == nil and self.targetPlaceable ~= nil then
        if self.isObjectStorage then
            self.storageObject = self.targetPlaceable
        elseif self.targetPlaceable.spec_silo ~= nil and self.targetPlaceable.spec_silo.storages ~= nil then
            self.storageObject = self.targetPlaceable.spec_silo.storages[self.storageIndex]
        elseif self.targetPlaceable.spec_siloExtension ~= nil and self.targetPlaceable.spec_siloExtension.storage ~= nil then
            self.storageObject = self.targetPlaceable.spec_siloExtension.storage
        elseif self.targetPlaceable.spec_husbandry ~= nil and self.targetPlaceable.spec_husbandry.storage ~= nil then
            self.storageObject = self.targetPlaceable.spec_husbandry.storage
        elseif self.targetPlaceable.spec_manureHeap ~= nil and self.targetPlaceable.spec_manureHeap.manureHeap ~= nil then
            self.storageObject = self.targetPlaceable.spec_manureHeap.manureHeap
        elseif self.targetPlaceable.spec_productionPoint ~= nil and self.targetPlaceable.spec_productionPoint.productionPoint ~= nil then
            self.storageObject = self.targetPlaceable.spec_productionPoint.productionPoint.storage
        end
    end

    self:run(connection)
end

-- Executes the core transaction logic (Server only)
function SellBuyOfflineMarketEvent:run(connection)
    -- Only execute on the server. Clients do not need to process this event locally,
    -- as the base game syncs money and fill levels automatically via engine events.
    if not connection:getIsServer() then

        if GlobalMarket.debugManager ~= nil then
            local modeStr = (self.mode == 1) and "SELL" or "BUY"
            local typeStr = self.isObjectStorage and "OBJECT" or "BULK"
            GlobalMarket.debugManager:info("Network (Server): Received %s request for %s (%s) from Farm %d", modeStr, tostring(self.filltypeName), typeStr, self.playerFarmId)

            -- Detailed payload trace to ensure stream data is not corrupted
            GlobalMarket.debugManager:trace("Payload -> Level: %d, Storage: %s, Format: %s, Cap: %d", self.level, tostring(self.storageObject), tostring(self.formatXml), self.capacityPerObject)
        end

        if g_currentMission.globalMarket ~= nil then
            if self.storageObject ~= nil then
                -- Revert empty strings back to nil to prevent false positive matching
                local xmlToPass = (self.formatXml ~= "") and self.formatXml or nil
                local capToPass = (self.capacityPerObject > 0) and self.capacityPerObject or nil

                -- Route the client's request through the server's authoritative transaction backend
                -- Pass the resolved storage object table to the transaction handler
                g_currentMission.globalMarket:onSellBuy(
                    self.mode, self.filltypeName, self.level, self.storageObject, self.count,
                    nil, nil, self.isObjectStorage, self.playerFarmId, xmlToPass, capToPass
                )
            else
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:error("Network (Server): Transaction aborted. Received storageObject is nil (Sync mismatch).")
                end
            end
        end
    end
end

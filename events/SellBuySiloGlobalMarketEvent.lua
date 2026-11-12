-- =========================================================================================
-- FS25_GlobalMarket - SellBuySiloGlobalMarketEvent.lua
-- Network event synchronizing bulk and liquid silo market transactions.
-- Author: D-S-Agrarservice
-- =========================================================================================

SellBuySiloGlobalMarketEvent = {}
local SellBuySiloGlobalMarketEvent_mt = Class(SellBuySiloGlobalMarketEvent, Event)

SellBuySiloGlobalMarketEvent.ACTION_SELL = 1
SellBuySiloGlobalMarketEvent.ACTION_BUY = 2

InitEventClass(SellBuySiloGlobalMarketEvent, "SellBuySiloGlobalMarketEvent")

-- Creates an empty instance for reading from the network stream
function SellBuySiloGlobalMarketEvent.emptyNew()
    return Event.new(SellBuySiloGlobalMarketEvent_mt)
end

-- Creates a populated instance for writing to the network stream
function SellBuySiloGlobalMarketEvent.new(action, price, playerFarmId, fillType, fillLevel, storage, playerUserId)
    local self = SellBuySiloGlobalMarketEvent.emptyNew()

    self.action = action
    self.price = math.floor(price)
    self.playerFarmId = playerFarmId
    self.fillType = fillType
    -- Ensure fillLevel is an integer before sending via streamWriteInt32
    self.fillLevel = math.floor(fillLevel)
    self.playerUserId = playerUserId

    -- Store direct registered Network Object (Storage/ManureHeap) and resolve owning Placeable fallback
    self.storage = storage
    self.targetPlaceable = nil
    self.storageIndex = 1

    if storage ~= nil and type(storage) == "table" then
        if g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.resolveBulkStorageOwner ~= nil then
            local ownerPlaceable, _, _, resolvedIndex = g_currentMission.globalMarket:resolveBulkStorageOwner(storage)
            self.targetPlaceable = ownerPlaceable
            self.storageIndex = resolvedIndex or 1
        end
    end

    return self
end

-- Serializes the transaction payload into the network stream
function SellBuySiloGlobalMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action)
    streamWriteInt32(streamId, self.price)
    streamWriteInt16(streamId, self.playerFarmId) -- Farm ID serialized as Int16
    streamWriteString(streamId, self.fillType)
    streamWriteInt32(streamId, self.fillLevel)

    -- 1. Primary: Transmit registered Network Object (Storage or ManureHeap) directly
    local hasDirectStorageNode = (self.storage ~= nil and self.storage.isRegistered == true)
    streamWriteBool(streamId, hasDirectStorageNode)
    if hasDirectStorageNode then
        NetworkUtil.writeNodeObject(streamId, self.storage)
    end

    -- 2. Fallback: Also transmit resolved owning Placeable and storage index
    local hasTargetPlaceable = (self.targetPlaceable ~= nil and self.targetPlaceable.isRegistered == true)
    streamWriteBool(streamId, hasTargetPlaceable)
    if hasTargetPlaceable then
        NetworkUtil.writeNodeObject(streamId, self.targetPlaceable)
    end
    streamWriteInt8(streamId, self.storageIndex or 1)

    streamWriteInt16(streamId, self.playerUserId)
end

-- Deserializes the transaction payload from the network stream
function SellBuySiloGlobalMarketEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    self.price = streamReadInt32(streamId)
    self.playerFarmId = streamReadInt16(streamId) -- Farm ID deserialized as Int16
    self.fillType = streamReadString(streamId)
    self.fillLevel = streamReadInt32(streamId)

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

    self.playerUserId = streamReadInt16(streamId)

    -- Reconstruct raw storage for backend execution across all placeable types
    self.storage = directStorageObject
    if self.storage == nil and self.targetPlaceable ~= nil then
        if self.targetPlaceable.spec_silo ~= nil and self.targetPlaceable.spec_silo.storages ~= nil then
            self.storage = self.targetPlaceable.spec_silo.storages[self.storageIndex]
        elseif self.targetPlaceable.spec_siloExtension ~= nil and self.targetPlaceable.spec_siloExtension.storage ~= nil then
            self.storage = self.targetPlaceable.spec_siloExtension.storage
        elseif self.targetPlaceable.spec_husbandry ~= nil and self.targetPlaceable.spec_husbandry.storage ~= nil then
            self.storage = self.targetPlaceable.spec_husbandry.storage
        elseif self.targetPlaceable.spec_manureHeap ~= nil and self.targetPlaceable.spec_manureHeap.manureHeap ~= nil then
            self.storage = self.targetPlaceable.spec_manureHeap.manureHeap
        elseif self.targetPlaceable.spec_productionPoint ~= nil and self.targetPlaceable.spec_productionPoint.productionPoint ~= nil then
            self.storage = self.targetPlaceable.spec_productionPoint.productionPoint.storage
        end
    end

    self:run(connection)
end

-- Executes the core event logic based on network authority (Server vs. Client)
function SellBuySiloGlobalMarketEvent:run(connection)
    if not connection:getIsServer() then
        -- ===================================================
        -- SERVER-SIDE LOGIC
        -- ===================================================
        if GlobalMarket.debugManager ~= nil then
            local actionStr = (self.action == self.ACTION_SELL) and "SELL" or "BUY"
            GlobalMarket.debugManager:info("Network (Server): Received %s Silo request from UserID %d (Farm %d).", actionStr, self.playerUserId, self.playerFarmId)
            GlobalMarket.debugManager:trace("Payload -> FillType: %s, Level: %d, Price: %d, StorageId: %s", tostring(self.fillType), self.fillLevel, self.price, tostring(self.storage))
        end

        if g_currentMission.globalMarket ~= nil then
            if self.storage ~= nil then
                -- Execute the physical transaction on the server
                if self.action == SellBuySiloGlobalMarketEvent.ACTION_SELL then
                    g_currentMission.globalMarket:sellSilo(self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId)
                else
                    g_currentMission.globalMarket:buySilo(self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId)
                end

                -- Broadcast the successful transaction to all clients to keep UI in sync
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:debug("Network (Server): Silo transaction processed. Broadcasting update to all clients.")
                end
                -- Include sender in broadcast so the initiating client also unlocks its UI
                g_server:broadcastEvent(SellBuySiloGlobalMarketEvent.new(self.action, self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId))
            else
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:error("Network (Server): Silo Transaction aborted. Received storage is nil (Sync mismatch).")
                end
            end
        else
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:error("Network (Server): Silo Transaction aborted. g_currentMission.globalMarket is nil!")
            end
        end
    else
        -- ===================================================
        -- CLIENT-SIDE LOGIC
        -- ===================================================
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:debug("Network (Client): Received Silo transaction broadcast from server.")
        end

        -- If this specific client was the one who initiated the transaction, close their loading UI
        if g_currentMission.playerUserId == self.playerUserId then
            local gm = g_currentMission.globalMarket
            if gm ~= nil then
                if gm.closeSelectLevelUi == 1 then
                    gm.closeSelectLevelUi = 2
                elseif gm.closeSelectLevelUi == 3 then
                    if g_currentMission.globalMarketSelectLevelUi ~= nil then
                        g_currentMission.globalMarketSelectLevelUi:close()
                    end
                    gm.closeSelectLevelUi = 0
                end
            end
        end

        -- Refresh the UI to show the updated stock levels and prices
        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
    end
end

--
-- FS25 - GlobalMarket - SellBuySiloGlobalMarketEvent
-- Description: Handles network synchronization for buying/selling bulk goods (Silos).
-- Routes client requests to the server, and broadcasts updates back to clients.
--

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
    -- Safety fix: Ensure fillLevel is an integer before sending via streamWriteInt32
    self.fillLevel = math.floor(fillLevel)
    self.playerUserId = playerUserId

    -- FIX: Safe Network Node resolution to prevent transmitting raw Lua tables
    self.targetPlaceable = nil
    self.storageIndex = 1

    if storage ~= nil and type(storage) == "table" then
        if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
            for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                    for i, s in ipairs(placeable.spec_silo.storages) do
                        if s == storage then
                            self.targetPlaceable = placeable
                            self.storageIndex = i
                            break
                        end
                    end
                end
                if self.targetPlaceable ~= nil then break end
            end
        end
    end

    return self
end

-- Serializes the transaction payload into the network stream
function SellBuySiloGlobalMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action)
    streamWriteInt32(streamId, self.price)
    streamWriteInt16(streamId, self.playerFarmId) -- FIX: Datatype matched to Int16
    streamWriteString(streamId, self.fillType)
    streamWriteInt32(streamId, self.fillLevel)

    -- FIX: Send the resolved Network Node and Index
    NetworkUtil.writeNodeObject(streamId, self.targetPlaceable)
    streamWriteInt8(streamId, self.storageIndex)

    streamWriteInt16(streamId, self.playerUserId)
end

-- Deserializes the transaction payload from the network stream
function SellBuySiloGlobalMarketEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    self.price = streamReadInt32(streamId)
    self.playerFarmId = streamReadInt16(streamId) -- FIX: Datatype matched to Int16
    self.fillType = streamReadString(streamId)
    self.fillLevel = streamReadInt32(streamId)

    -- FIX: Read the Network Node and Index
    self.targetPlaceable = NetworkUtil.readNodeObject(streamId)
    self.storageIndex = streamReadInt8(streamId)

    self.playerUserId = streamReadInt16(streamId)

    -- FIX: Reconstruct raw storage for backend execution
    self.storage = nil
    if self.targetPlaceable ~= nil and self.targetPlaceable.spec_silo ~= nil and self.targetPlaceable.spec_silo.storages ~= nil then
        self.storage = self.targetPlaceable.spec_silo.storages[self.storageIndex]
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

                -- Broadcast the successful transaction to all OTHER clients to keep UI in sync
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:debug("Network (Server): Silo transaction processed. Broadcasting update to all clients.")
                end
                -- FIX: Removed connection exclusion in broadcast so the sender also gets unlocked
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
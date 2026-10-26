--
-- FS25 - GlobalMarket - SellBuyMarketGlobalMarketEvent
-- Description: Handles network synchronization for buying/selling online market objects.
-- Routes client requests to the server, and broadcasts updates back to clients.
--

SellBuyMarketGlobalMarketEvent = {}
local SellBuyMarketGlobalMarketEvent_mt = Class(SellBuyMarketGlobalMarketEvent, Event)

SellBuyMarketGlobalMarketEvent.ACTION_SELL = 1
SellBuyMarketGlobalMarketEvent.ACTION_BUY = 2
SellBuyMarketGlobalMarketEvent.ACTION_EXPORT_TX = 3

InitEventClass(SellBuyMarketGlobalMarketEvent, "SellBuyMarketGlobalMarketEvent")

-- Creates an empty instance for reading from the network stream
function SellBuyMarketGlobalMarketEvent.emptyNew()
    return Event.new(SellBuyMarketGlobalMarketEvent_mt)
end

-- Creates a populated instance for writing to the network stream
function SellBuyMarketGlobalMarketEvent.new(action, price, playerFarmId, count, attributes, storage, playerUserId)
    local self = SellBuyMarketGlobalMarketEvent.emptyNew()

    self.action = action
    self.price = math.floor(price or 0)
    self.playerFarmId = playerFarmId or 0
    self.count = count or 0
    self.attributes = attributes or ""
    self.storage = storage
    self.playerUserId = playerUserId or 0

    return self
end

-- Serializes the transaction payload into the network stream
function SellBuyMarketGlobalMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action)
    if self.action == SellBuyMarketGlobalMarketEvent.ACTION_EXPORT_TX then
        streamWriteString(streamId, self.attributes)
        streamWriteInt32(streamId, self.count)
        streamWriteInt8(streamId, self.price)
        return
    end
    streamWriteInt32(streamId, self.price)
    streamWriteInt16(streamId, self.playerFarmId) -- FIX: Datatype matched to Int16
    streamWriteInt32(streamId, self.count)
    streamWriteString(streamId, self.attributes)
    NetworkUtil.writeNodeObject(streamId, self.storage)
    streamWriteInt16(streamId, self.playerUserId)
end

-- Deserializes the transaction payload from the network stream
function SellBuyMarketGlobalMarketEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    if self.action == SellBuyMarketGlobalMarketEvent.ACTION_EXPORT_TX then
        self.attributes = streamReadString(streamId)
        self.count = streamReadInt32(streamId)
        self.price = streamReadInt8(streamId)
        self:run(connection)
        return
    end
    self.price = streamReadInt32(streamId)
    self.playerFarmId = streamReadInt16(streamId) -- FIX: Datatype matched to Int16
    self.count = streamReadInt32(streamId)
    self.attributes = streamReadString(streamId)
    self.storage = NetworkUtil.readNodeObject(streamId)
    self.playerUserId = streamReadInt16(streamId)

    self:run(connection)
end

-- Executes the core event logic based on network authority (Server vs. Client)
function SellBuyMarketGlobalMarketEvent:run(connection)
    if self.action == SellBuyMarketGlobalMarketEvent.ACTION_EXPORT_TX then
        if connection:getIsServer() and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.exportTransaction ~= nil then
            local txType = (self.price == SellBuyMarketGlobalMarketEvent.ACTION_BUY) and "BUY" or "SELL"
            g_currentMission.globalMarket:exportTransaction(self.attributes, self.count, txType)
        end
        return
    end
    if not connection:getIsServer() then
        -- ===================================================
        -- SERVER-SIDE LOGIC
        -- ===================================================
        if GlobalMarket.debugManager ~= nil then
            local actionStr = (self.action == self.ACTION_SELL) and "SELL" or "BUY"
            GlobalMarket.debugManager:info("Network (Server): Received %s request from UserID %d (Farm %d).", actionStr, self.playerUserId, self.playerFarmId)
            GlobalMarket.debugManager:trace("Payload -> Count: %d, Price: %d, StorageId: %s", self.count, self.price, tostring(self.storage))
        end

        if g_currentMission.globalMarket ~= nil then
            -- Execute the physical transaction on the server
            if self.action == SellBuyMarketGlobalMarketEvent.ACTION_SELL then
                g_currentMission.globalMarket:sellObject(self.price, self.playerFarmId, self.count, self.attributes, self.storage, self.playerUserId)
            else
                g_currentMission.globalMarket:buyObject(self.price, self.playerFarmId, self.count, self.attributes, self.storage, self.playerUserId)
            end

            -- Broadcast the successful transaction to all OTHER clients for UI sync
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:debug("Network (Server): Transaction processed. Broadcasting update to all clients.")
            end
            -- FIX: Removed connection exclusion in broadcast so the sender also gets unlocked
            g_server:broadcastEvent(SellBuyMarketGlobalMarketEvent.new(self.action, self.price, self.playerFarmId, self.count, self.attributes, self.storage, self.playerUserId))
        else
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:error("Network (Server): Transaction aborted. g_currentMission.globalMarket is nil!")
            end
        end
    else
        -- ===================================================
        -- CLIENT-SIDE LOGIC
        -- ===================================================
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:debug("Network (Client): Received transaction broadcast from server.")
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
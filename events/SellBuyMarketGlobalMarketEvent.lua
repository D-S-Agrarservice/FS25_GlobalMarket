--
-- FS25 - GlobalMarket - SellBuyMarketGlobalMarketEvent
--

SellBuyMarketGlobalMarketEvent = {}
local SellBuyMarketGlobalMarketEvent_mt = Class(SellBuyMarketGlobalMarketEvent, Event)

SellBuyMarketGlobalMarketEvent.ACTION_SELL = 1
SellBuyMarketGlobalMarketEvent.ACTION_BUY = 2

InitEventClass(SellBuyMarketGlobalMarketEvent, "SellBuyMarketGlobalMarketEvent")

function SellBuyMarketGlobalMarketEvent.emptyNew()
    return Event.new(SellBuyMarketGlobalMarketEvent_mt)
end

function SellBuyMarketGlobalMarketEvent.new(action, price, playerFarmId, count, attributes, storage, playerUserId)
    local self = SellBuyMarketGlobalMarketEvent.emptyNew()

    self.action = action
    self.price = math.floor(price)
    self.playerFarmId = playerFarmId
    self.count = count
    self.attributes = attributes
    self.storage = storage
    self.playerUserId = playerUserId

    return self
end

function SellBuyMarketGlobalMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action)
    streamWriteInt32(streamId, self.price)
    streamWriteInt8(streamId, self.playerFarmId)
    streamWriteInt32(streamId, self.count)
    streamWriteString(streamId, self.attributes)
    NetworkUtil.writeNodeObject(streamId, self.storage)
    streamWriteInt16(streamId, self.playerUserId)
end

function SellBuyMarketGlobalMarketEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    self.price = streamReadInt32(streamId)
    self.playerFarmId = streamReadInt8(streamId)
    self.count = streamReadInt32(streamId)
    self.attributes = streamReadString(streamId)
    self.storage = NetworkUtil.readNodeObject(streamId)
    self.playerUserId = streamReadInt16(streamId)

    self:run(connection)
end

function SellBuyMarketGlobalMarketEvent:run(connection)
    if not connection:getIsServer() then
        -- Logic on the Server side
        GlobalMarket.debugLog("Server: Received SellBuyMarketGlobalMarketEvent (Action: %d, Count: %d)", self.action, self.count)

        if g_currentMission.globalMarket ~= nil then
            if self.action == SellBuyMarketGlobalMarketEvent.ACTION_SELL then
                g_currentMission.globalMarket:sellObject(self.price, self.playerFarmId, self.count, self.attributes, self.storage, self.playerUserId)
            else
                g_currentMission.globalMarket:buyObject(self.price, self.playerFarmId, self.count, self.attributes, self.storage, self.playerUserId)
            end

            -- Broadcast the transaction to all other clients
            g_server:broadcastEvent(SellBuyMarketGlobalMarketEvent.new(self.action, self.price, self.playerFarmId, self.count, self.attributes, self.storage, self.playerUserId), nil, connection)
        end
    else
        -- Logic on the Client side
        GlobalMarket.debugLog("Client: Received SellBuyMarketGlobalMarketEvent update.")

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

        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
    end
end
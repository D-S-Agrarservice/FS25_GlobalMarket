--
-- FS25 - GlobalMarket - SellBuyOfflineMarketEvent
--

SellBuyOfflineMarketEvent = {}
local SellBuyOfflineMarketEvent_mt = Class(SellBuyOfflineMarketEvent, Event)

InitEventClass(SellBuyOfflineMarketEvent, "SellBuyOfflineMarketEvent")

function SellBuyOfflineMarketEvent.emptyNew()
    return Event.new(SellBuyOfflineMarketEvent_mt)
end

function SellBuyOfflineMarketEvent.new(price, playerFarmId, level, filltypeName, storage, playerUserId)
    local self = SellBuyOfflineMarketEvent.emptyNew()

    self.price = math.floor(price)
    self.playerFarmId = playerFarmId
    -- Safety fix: Ensure level is an integer before sending via streamWriteInt32
    self.level = math.floor(level)
    self.filltypeName = filltypeName
    self.storage = storage
    self.playerUserId = playerUserId

    return self
end

function SellBuyOfflineMarketEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.price)
    streamWriteInt16(streamId, self.playerFarmId)
    streamWriteInt32(streamId, self.level)
    streamWriteString(streamId, self.filltypeName)
    NetworkUtil.writeNodeObject(streamId, self.storage)
    streamWriteInt16(streamId, self.playerUserId)
end

function SellBuyOfflineMarketEvent:readStream(streamId, connection)
    self.price = streamReadInt32(streamId)
    self.playerFarmId = streamReadInt16(streamId)
    self.level = streamReadInt32(streamId)
    self.filltypeName = streamReadString(streamId)
    self.storage = NetworkUtil.readNodeObject(streamId)
    self.playerUserId = streamReadInt16(streamId)

    self:run(connection)
end

function SellBuyOfflineMarketEvent:run(connection)
    local moneyType = MoneyType.SOLD_PRODUCTS
    if self.price < 0 then
        moneyType = MoneyType.BOUGHT_MATERIALS
    end

    if not connection:getIsServer() then
        GlobalMarket.debugLog("Server: Received SellBuyOfflineMarketEvent (FillType: %s, Level: %d, Price: %d)", self.filltypeName, self.level, self.price)
    else
        GlobalMarket.debugLog("Client: Received SellBuyOfflineMarketEvent broadcast.")
    end

    if g_currentMission.globalMarket ~= nil then
        -- Execute the transaction on the local instance
        g_currentMission.globalMarket:sellBuyOfflineMarket(self.price, moneyType, self.playerFarmId, self.level, self.filltypeName, self.storage, self.playerUserId)

        -- If this is the server receiving a client's request, broadcast to all other clients
        if not connection:getIsServer() then
            g_server:broadcastEvent(SellBuyOfflineMarketEvent.new(self.price, self.playerFarmId, self.level, self.filltypeName, self.storage, self.playerUserId), nil, connection)
        end
    end
end
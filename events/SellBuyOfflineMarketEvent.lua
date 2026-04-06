--
-- FS25 - GlobalMarket - SellBuyOfflineMarketEvent
--

SellBuyOfflineMarketEvent = {}
local SellBuyOfflineMarketEvent_mt = Class(SellBuyOfflineMarketEvent, Event)

InitEventClass(SellBuyOfflineMarketEvent, "SellBuyOfflineMarketEvent")

function SellBuyOfflineMarketEvent.emptyNew()
    return Event.new(SellBuyOfflineMarketEvent_mt)
end

function SellBuyOfflineMarketEvent.new(mode, filltypeName, level, storageObject, count, isObjectStorage, playerFarmId)
    local self = SellBuyOfflineMarketEvent.emptyNew()

    self.mode = mode
    self.filltypeName = filltypeName
    self.level = math.floor(level)
    self.storageObject = storageObject
    self.count = count
    self.isObjectStorage = isObjectStorage or false
    self.playerFarmId = playerFarmId

    return self
end

function SellBuyOfflineMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.mode)
    streamWriteString(streamId, self.filltypeName)
    streamWriteInt32(streamId, self.level)
    NetworkUtil.writeNodeObject(streamId, self.storageObject)
    streamWriteInt32(streamId, self.count)
    streamWriteBool(streamId, self.isObjectStorage)
    streamWriteInt16(streamId, self.playerFarmId)
end

function SellBuyOfflineMarketEvent:readStream(streamId, connection)
    self.mode = streamReadInt8(streamId)
    self.filltypeName = streamReadString(streamId)
    self.level = streamReadInt32(streamId)
    self.storageObject = NetworkUtil.readNodeObject(streamId)
    self.count = streamReadInt32(streamId)
    self.isObjectStorage = streamReadBool(streamId)
    self.playerFarmId = streamReadInt16(streamId)

    self:run(connection)
end

function SellBuyOfflineMarketEvent:run(connection)
    -- Only execute on the server. Clients do not need to process this event locally, 
    -- as the base game syncs money and fill levels automatically.
    if not connection:getIsServer() then
        GlobalMarket.debugLog("Server: Received SellBuyOfflineMarketEvent (Mode: %d, FillType: %s, isObject: %s)", self.mode, self.filltypeName, tostring(self.isObjectStorage))

        if g_currentMission.globalMarket ~= nil and self.storageObject ~= nil then
            -- Route the client's request through the server's transaction backend
            g_currentMission.globalMarket:onSellBuy(self.mode, self.filltypeName, self.level, self.storageObject.rootNode, self.count, nil, nil, self.isObjectStorage, self.playerFarmId)
        end
    end
end
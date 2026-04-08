--
-- FS25 - GlobalMarket - SellBuyOfflineMarketEvent
--

SellBuyOfflineMarketEvent = {}
local SellBuyOfflineMarketEvent_mt = Class(SellBuyOfflineMarketEvent, Event)

InitEventClass(SellBuyOfflineMarketEvent, "SellBuyOfflineMarketEvent")

function SellBuyOfflineMarketEvent.emptyNew()
    return Event.new(SellBuyOfflineMarketEvent_mt)
end

function SellBuyOfflineMarketEvent.new(mode, filltypeName, level, storageObject, count, isObjectStorage, playerFarmId, formatXml, capacityPerObject)
    local self = SellBuyOfflineMarketEvent.emptyNew()

    self.mode = mode
    self.filltypeName = filltypeName
    self.level = math.floor(level)
    self.storageObject = storageObject
    self.count = count
    self.isObjectStorage = isObjectStorage or false
    self.playerFarmId = playerFarmId

    -- NEW parameters with safe fallbacks for bulk network transmission
    self.formatXml = formatXml or ""
    self.capacityPerObject = capacityPerObject or 0

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

    -- NEW parameters appended to the stream
    streamWriteString(streamId, self.formatXml)
    streamWriteInt32(streamId, self.capacityPerObject)
end

function SellBuyOfflineMarketEvent:readStream(streamId, connection)
    self.mode = streamReadInt8(streamId)
    self.filltypeName = streamReadString(streamId)
    self.level = streamReadInt32(streamId)
    self.storageObject = NetworkUtil.readNodeObject(streamId)
    self.count = streamReadInt32(streamId)
    self.isObjectStorage = streamReadBool(streamId)
    self.playerFarmId = streamReadInt16(streamId)

    -- NEW parameters read from the stream
    self.formatXml = streamReadString(streamId)
    self.capacityPerObject = streamReadInt32(streamId)

    self:run(connection)
end

function SellBuyOfflineMarketEvent:run(connection)
    -- Only execute on the server. Clients do not need to process this event locally, 
    -- as the base game syncs money and fill levels automatically.
    if not connection:getIsServer() then
        GlobalMarket.debugLog("Server: Received SellBuyOfflineMarketEvent (Mode: %d, FillType: %s, isObject: %s)", self.mode, self.filltypeName, tostring(self.isObjectStorage))

        if g_currentMission.globalMarket ~= nil and self.storageObject ~= nil then
            -- Convert network safe fallbacks back to nil if they are empty
            local xmlToPass = self.formatXml ~= "" and self.formatXml or nil
            local capToPass = self.capacityPerObject > 0 and self.capacityPerObject or nil

            -- Route the client's request through the server's transaction backend including new parameters
            g_currentMission.globalMarket:onSellBuy(self.mode, self.filltypeName, self.level, self.storageObject.rootNode, self.count, nil, nil, self.isObjectStorage, self.playerFarmId, xmlToPass, capToPass)
        end
    end
end
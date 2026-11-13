-- =========================================================================================
-- FS25_GlobalMarket - SellBuyMarketGlobalMarketEvent.lua
-- Relays validated online market transaction exports from the server to the Data-Host.
-- Author: D-S-Agrarservice
-- =========================================================================================

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

-- Creates a populated instance for relaying an online transaction export to the Data-Host
function SellBuyMarketGlobalMarketEvent.new(action, price, _, count, attributes)
    local self = SellBuyMarketGlobalMarketEvent.emptyNew()

    self.action = action or SellBuyMarketGlobalMarketEvent.ACTION_EXPORT_TX
    self.price = math.floor(price or SellBuyMarketGlobalMarketEvent.ACTION_SELL)
    self.count = math.floor(count or 0)
    self.attributes = attributes or ""

    return self
end

-- Serializes the transaction export payload into the network stream
function SellBuyMarketGlobalMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action)
    streamWriteString(streamId, self.attributes)
    streamWriteInt32(streamId, self.count)
    streamWriteInt8(streamId, self.price)
end

-- Deserializes the transaction export payload from the network stream
function SellBuyMarketGlobalMarketEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    self.attributes = streamReadString(streamId)
    self.count = streamReadInt32(streamId)
    self.price = streamReadInt8(streamId)

    self:run(connection)
end

-- Executes the transaction file export on the designated Data-Host client
function SellBuyMarketGlobalMarketEvent:run(connection)
    if self.action == SellBuyMarketGlobalMarketEvent.ACTION_EXPORT_TX then
        if connection:getIsServer() and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.exportTransaction ~= nil then
            local txType = (self.price == SellBuyMarketGlobalMarketEvent.ACTION_BUY) and "BUY" or "SELL"
            g_currentMission.globalMarket:exportTransaction(self.attributes, self.count, txType)
        end
    end
end

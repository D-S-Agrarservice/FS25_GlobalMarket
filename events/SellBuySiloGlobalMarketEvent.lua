--
-- FS25 - GlobalMarket - SellBuySiloGlobalMarketEvent
--

SellBuySiloGlobalMarketEvent = {}
local SellBuySiloGlobalMarketEvent_mt = Class(SellBuySiloGlobalMarketEvent, Event)

SellBuySiloGlobalMarketEvent.ACTION_SELL = 1
SellBuySiloGlobalMarketEvent.ACTION_BUY = 2

InitEventClass(SellBuySiloGlobalMarketEvent, "SellBuySiloGlobalMarketEvent")

function SellBuySiloGlobalMarketEvent.emptyNew()
    return Event.new(SellBuySiloGlobalMarketEvent_mt)
end

function SellBuySiloGlobalMarketEvent.new(action, price, playerFarmId, fillType, fillLevel, storage, playerUserId)
    local self = SellBuySiloGlobalMarketEvent.emptyNew()

    self.action = action
    self.price = math.floor(price)
    self.playerFarmId = playerFarmId
    self.fillType = fillType
    self.fillLevel = fillLevel
    self.storage = storage
    self.playerUserId = playerUserId

    return self
end

function SellBuySiloGlobalMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.action)
    streamWriteInt32(streamId, self.price)
    streamWriteInt8(streamId, self.playerFarmId)
    streamWriteString(streamId, self.fillType)
    streamWriteInt32(streamId, self.fillLevel)
    NetworkUtil.writeNodeObject(streamId, self.storage)
    streamWriteInt16(streamId, self.playerUserId)
end

function SellBuySiloGlobalMarketEvent:readStream(streamId, connection)
    self.action = streamReadInt8(streamId)
    self.price = streamReadInt32(streamId)
    self.playerFarmId = streamReadInt8(streamId)
    self.fillType = streamReadString(streamId)
    self.fillLevel = streamReadInt32(streamId)
    self.storage = NetworkUtil.readNodeObject(streamId)
    self.playerUserId = streamReadInt16(streamId)

    self:run(connection)
end

function SellBuySiloGlobalMarketEvent:run(connection)
    if not connection:getIsServer() then
        -- Logic on the Server side
        if g_currentMission.globalMarket ~= nil then
            if self.action == SellBuySiloGlobalMarketEvent.ACTION_SELL then
                g_currentMission.globalMarket:sellSilo(self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId)
            else
                g_currentMission.globalMarket:buySilo(self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId)
            end

            -- Broadcast to all other clients to keep silo levels in sync
            g_server:broadcastEvent(SellBuySiloGlobalMarketEvent.new(self.action, self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId), nil, connection)
        end
    else
        -- Logic on the Client side (Feedback for the UI)
        if g_currentMission.playerUserId == self.playerUserId then
            local gm = g_currentMission.globalMarket
            if gm.closeSelectLevelUi == 1 then
                gm.closeSelectLevelUi = 2
            elseif gm.closeSelectLevelUi == 3 then
                if g_currentMission.globalMarketSelectLevelUi ~= nil then
                    g_currentMission.globalMarketSelectLevelUi:close()
                end
                gm.closeSelectLevelUi = 0
            end
        end

        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
    end
end
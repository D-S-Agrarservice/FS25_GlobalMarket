--
-- FS22 - GlobalMarket - SellBuyOfflineMarketEvent
--
-- @Interface: 1.9.1.0 b23678
-- @Author: KR-Softwares
-- @Date: 12.05.2023
-- @Version: 1.0.0.0
--
-- @Support: -
--
-- Changelog:
-- 	v1.0.0.0 (12.05.2023):
--		Release fs22
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
	self.level = level
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
    g_currentMission.globalMarket:sellBuyOfflineMarket(self.price, moneyType, self.playerFarmId, self.level, self.filltypeName, self.storage, self.playerUserId)            
    if not connection:getIsServer() then		
		g_server:broadcastEvent(SellBuyOfflineMarketEvent.new(self.price, self.playerFarmId, self.level, self.filltypeName, self.storage, self.playerUserId))
	end
end
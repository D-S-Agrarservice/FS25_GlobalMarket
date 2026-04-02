--
-- FS22 - GlobalMarket - SellBuySiloGlobalMarketEvent
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
		if self.action == SellBuySiloGlobalMarketEvent.ACTION_SELL then
			g_currentMission.globalMarket:sellSilo(self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId)
		else
			g_currentMission.globalMarket:buySilo(self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId)
		end
		
		g_server:broadcastEvent(SellBuySiloGlobalMarketEvent.new(self.action, self.price, self.playerFarmId, self.fillType, self.fillLevel, self.storage, self.playerUserId))
	else
		if g_currentMission.playerUserId == self.playerUserId then
			if g_currentMission.globalMarket.closeSelectLevelUi == 1 then 
				g_currentMission.globalMarket.closeSelectLevelUi = 2 
			elseif g_currentMission.globalMarket.closeSelectLevelUi == 3 then 
				g_currentMission.globalMarketSelectLevelUi:close()
				g_currentMission.globalMarket.closeSelectLevelUi = 0
			end	
		end

		if g_currentMission.globalMarketUi ~= nil then
			g_currentMission.globalMarketUi:updateContent()
		end
	end
end
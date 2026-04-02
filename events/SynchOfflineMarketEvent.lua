--
-- FS22 - GlobalMarket - SynchOfflineMarketEvent
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

SynchOfflineMarketEvent = {}
local SynchOfflineMarketEvent_mt = Class(SynchOfflineMarketEvent, Event)

InitEventClass(SynchOfflineMarketEvent, "SynchOfflineMarketEvent")

function SynchOfflineMarketEvent.emptyNew()
	return Event.new(SynchOfflineMarketEvent_mt)
end

function SynchOfflineMarketEvent.new()
	local self = SynchOfflineMarketEvent.emptyNew()
	return self
end

function SynchOfflineMarketEvent:writeStream(streamId, connection)       
    streamWriteInt16(streamId, #g_currentMission.globalMarket.offlineMarketFillTypes)
    for _,ft in pairs(g_currentMission.globalMarket.offlineMarketFillTypes) do
        streamWriteString(streamId, ft.fillType)
        streamWriteInt32(streamId, ft.fillLevel)
        streamWriteFloat32(streamId, ft.normalPrice)
        streamWriteFloat32(streamId, ft.price)
    end
end

function SynchOfflineMarketEvent:readStream(streamId, connection)
    local n = streamReadInt16(streamId)
    g_currentMission.globalMarket.offlineMarketFillTypes = {}
    for i=1, n do
        table.insert(g_currentMission.globalMarket.offlineMarketFillTypes, {
            fillType = streamReadString(streamId),
            fillLevel = streamReadInt32(streamId),
            normalPrice = streamReadFloat32(streamId),
            price = streamReadFloat32(streamId)
        })
    end	
	self:run(connection)
end

function SynchOfflineMarketEvent:run(connection)
	if connection:getIsServer() then
		if g_currentMission.globalMarketUi ~= nil then
			g_currentMission.globalMarketUi:updateContent()
		end
	end
end
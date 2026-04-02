--
-- FS22 - GlobalMarket - InitOfflineMarketEvent
--
-- @Interface: 1.9.1.0 b23678
-- @Author: KR-Softwares
-- @Date: 12.05.2023
-- @Version: 1.0.0.0
--
-- @Support: kk-softwares.de
--
-- Changelog:
-- 	v1.0.0.0 (12.05.2023):
--		Release fs22
--

InitOfflineMarketEvent = {}
local InitOfflineMarketEvent_mt = Class(InitOfflineMarketEvent, Event)

InitEventClass(InitOfflineMarketEvent, "InitOfflineMarketEvent")

function InitOfflineMarketEvent.emptyNew()
	return Event.new(InitOfflineMarketEvent_mt)
end

function InitOfflineMarketEvent.new()
	local self = InitOfflineMarketEvent.emptyNew()
	return self
end

function InitOfflineMarketEvent:writeStream(streamId, connection)       

end

function InitOfflineMarketEvent:readStream(streamId, connection)
	self:run(connection)
end

function InitOfflineMarketEvent:run(connection)
	if not connection:getIsServer() then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
	end
end
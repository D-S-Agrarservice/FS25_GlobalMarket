--
-- FS25 - GlobalMarket - ExeStatusEvent
-- Description: Client notifies the server about the status of their local external EXE.
--

ExeStatusEvent = {}
local ExeStatusEvent_mt = Class(ExeStatusEvent, Event)

InitEventClass(ExeStatusEvent, "ExeStatusEvent")

function ExeStatusEvent.emptyNew()
    return Event.new(ExeStatusEvent_mt)
end

function ExeStatusEvent.new(isExeRunning, hasBackendConnection)
    local self = ExeStatusEvent.emptyNew()
    self.isExeRunning = isExeRunning
    -- Add the backend connection state
    self.hasBackendConnection = hasBackendConnection
    return self
end

function ExeStatusEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isExeRunning)
    -- Transmit the backend connection state
    streamWriteBool(streamId, self.hasBackendConnection)
end

function ExeStatusEvent:readStream(streamId, connection)
    self.isExeRunning = streamReadBool(streamId)
    -- Receive the backend connection state
    self.hasBackendConnection = streamReadBool(streamId)
    self:run(connection)
end

function ExeStatusEvent:run(connection)
    if connection:getIsServer() then return end

    if g_currentMission.globalMarket ~= nil then
        -- Forward both states to the core handler
        g_currentMission.globalMarket:handleClientExeStatus(connection, self.isExeRunning, self.hasBackendConnection)
    end
end
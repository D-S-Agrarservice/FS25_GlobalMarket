-- =========================================================================================
-- FS25_GlobalMarket - ExeStatusEvent.lua
-- Client-to-server event reporting local companion client and backend connection status.
-- Author: D-S-Agrarservice
-- =========================================================================================

ExeStatusEvent = {}
local ExeStatusEvent_mt = Class(ExeStatusEvent, Event)

InitEventClass(ExeStatusEvent, "ExeStatusEvent")

function ExeStatusEvent.emptyNew()
    return Event.new(ExeStatusEvent_mt)
end

function ExeStatusEvent.new(isExeRunning, hasBackendConnection, marketName, isPrivateMarket, contractsSupported)
    local self = ExeStatusEvent.emptyNew()
    self.isExeRunning = isExeRunning == true
    self.hasBackendConnection = hasBackendConnection == true
    self.marketName = marketName
    self.isPrivateMarket = isPrivateMarket == true
    self.contractsSupported = contractsSupported == true
    return self
end

function ExeStatusEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isExeRunning == true)
    streamWriteBool(streamId, self.hasBackendConnection == true)
    streamWriteString(streamId, self.marketName or "")
    streamWriteBool(streamId, self.isPrivateMarket == true)
    streamWriteBool(streamId, self.contractsSupported == true)
end

function ExeStatusEvent:readStream(streamId, connection)
    self.isExeRunning = streamReadBool(streamId)
    self.hasBackendConnection = streamReadBool(streamId)
    local rawName = streamReadString(streamId)
    self.marketName = (rawName ~= "") and rawName or nil
    self.isPrivateMarket = streamReadBool(streamId)
    self.contractsSupported = streamReadBool(streamId)
    self:run(connection)
end

function ExeStatusEvent:run(connection)
    if connection:getIsServer() then return end

    if g_currentMission.globalMarket ~= nil then
        g_currentMission.globalMarket:handleClientExeStatus(
            connection,
            self.isExeRunning,
            self.hasBackendConnection,
            self.marketName,
            self.isPrivateMarket,
            self.contractsSupported
        )
    end
end
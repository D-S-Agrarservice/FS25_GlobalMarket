--
-- FS25 - GlobalMarket - SynchOfflineMarketEvent
--

SynchOfflineMarketEvent = {}
local SynchOfflineMarketEvent_mt = Class(SynchOfflineMarketEvent, Event)

InitEventClass(SynchOfflineMarketEvent, "SynchOfflineMarketEvent")

function SynchOfflineMarketEvent.emptyNew()
    return Event.new(SynchOfflineMarketEvent_mt)
end

function SynchOfflineMarketEvent.new()
    return SynchOfflineMarketEvent.emptyNew()
end

function SynchOfflineMarketEvent:writeStream(streamId, connection)
    local market = g_currentMission.globalMarket
    local entries = market.offlineMarketFillTypes
    local numEntries = #entries

    streamWriteInt16(streamId, numEntries)

    for i = 1, numEntries do
        local ft = entries[i]
        streamWriteString(streamId, ft.fillType)
        -- Ensure fillLevel is sent as a clean integer to prevent stream corruption
        streamWriteInt32(streamId, math.floor(ft.fillLevel))
        streamWriteFloat32(streamId, ft.normalPrice)
        streamWriteFloat32(streamId, ft.price)
    end
end

function SynchOfflineMarketEvent:readStream(streamId, connection)
    local n = streamReadInt16(streamId)

    self.offlineMarketFillTypes = {}

    -- CRITICAL: Always read from the stream to prevent network desync!
    for i = 1, n do
        local fillType = streamReadString(streamId)
        local fillLevel = streamReadInt32(streamId)
        local normalPrice = streamReadFloat32(streamId)
        local price = streamReadFloat32(streamId)

        table.insert(self.offlineMarketFillTypes, {
            fillType = fillType,
            fillLevel = fillLevel,
            normalPrice = normalPrice,
            price = price
        })
    end

    -- Proceed to execute the logic
    self:run(connection)
end

function SynchOfflineMarketEvent:run(connection)
    -- If we are on the client, apply the read data and refresh the UI
    if not connection:getIsServer() then
        if g_currentMission.globalMarket ~= nil then
            GlobalMarket.debugLog("Client: Received offline market sync. Updating local data.")
            g_currentMission.globalMarket.offlineMarketFillTypes = self.offlineMarketFillTypes

            if g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        else
            GlobalMarket.debugLog("Client: Received sync, but GlobalMarket is not initialized yet. Data discarded to prevent crash.")
        end
    end
end
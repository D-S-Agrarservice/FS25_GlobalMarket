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
    local numEntries = #market.offlineMarketFillTypes

    streamWriteInt16(streamId, numEntries)
    for _, ft in pairs(market.offlineMarketFillTypes) do
        streamWriteString(streamId, ft.fillType)
        streamWriteInt32(streamId, ft.fillLevel)
        streamWriteFloat32(streamId, ft.normalPrice)
        streamWriteFloat32(streamId, ft.price)
    end
end

function SynchOfflineMarketEvent:readStream(streamId, connection)
    local n = streamReadInt16(streamId)

    -- Ensure globalMarket object is initialized on client before writing data
    if g_currentMission.globalMarket ~= nil then
        g_currentMission.globalMarket.offlineMarketFillTypes = {}
        for i = 1, n do
            table.insert(g_currentMission.globalMarket.offlineMarketFillTypes, {
                fillType = streamReadString(streamId),
                fillLevel = streamReadInt32(streamId),
                normalPrice = streamReadFloat32(streamId),
                price = streamReadFloat32(streamId)
            })
        end
    end

    self:run(connection)
end

function SynchOfflineMarketEvent:run(connection)
    -- If we are on the client, refresh the UI if it's currently open
    if not connection:getIsServer() then
        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
    end
end
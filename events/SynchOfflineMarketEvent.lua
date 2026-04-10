--
-- FS25 - GlobalMarket - SynchOfflineMarketEvent
-- Description: Server-to-Client event. Pushes the authoritative state (prices, fill levels)
-- of the entire offline market to joining or active clients to keep UIs synchronized.
--

SynchOfflineMarketEvent = {}
local SynchOfflineMarketEvent_mt = Class(SynchOfflineMarketEvent, Event)

InitEventClass(SynchOfflineMarketEvent, "SynchOfflineMarketEvent")

-- Creates an empty instance for reading from the network stream
function SynchOfflineMarketEvent.emptyNew()
    return Event.new(SynchOfflineMarketEvent_mt)
end

-- Creates a new instance for writing to the network stream
function SynchOfflineMarketEvent.new()
    return SynchOfflineMarketEvent.emptyNew()
end

-- Serializes the entire market state into the network stream (Server side)
function SynchOfflineMarketEvent:writeStream(streamId, connection)
    local market = g_currentMission.globalMarket
    local entries = market.offlineMarketFillTypes
    local numEntries = #entries

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("Network (Server): Broadcasting offline market sync payload (%d items).", numEntries)
    end

    streamWriteInt16(streamId, numEntries)

    -- Loop through all active fillTypes and send their current simulated state
    for i = 1, numEntries do
        local ft = entries[i]
        streamWriteString(streamId, ft.fillType)
        -- Ensure fillLevel is sent as a clean integer to prevent stream corruption
        streamWriteInt32(streamId, math.floor(ft.fillLevel))
        streamWriteFloat32(streamId, ft.normalPrice or 0)
        streamWriteFloat32(streamId, ft.price)
    end
end

-- Deserializes the market state from the network stream (Client side)
function SynchOfflineMarketEvent:readStream(streamId, connection)
    local n = streamReadInt16(streamId)

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:trace("Network (Client): Reading offline market sync stream. Expecting %d items.", n)
    end

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

    -- Proceed to execute the logic and apply the read data
    self:run(connection)
end

-- Executes the core synchronization logic based on network authority
function SynchOfflineMarketEvent:run(connection)
    -- If we are on the client, apply the read data to the local instance and refresh the UI
    if not connection:getIsServer() then
        if g_currentMission.globalMarket ~= nil then
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:debug("Network (Client): Received offline market sync. Updating local data.")
                -- Perform a deep table dump only if trace level is active to prevent standard log spam
                GlobalMarket.debugManager:traceTable("Network (Client): Dump of synchronized market data", self.offlineMarketFillTypes)
            end

            g_currentMission.globalMarket.offlineMarketFillTypes = self.offlineMarketFillTypes

            if g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        else
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:error("Network (Client): Received sync payload, but GlobalMarket is not initialized yet. Data discarded to prevent crash.")
            end
        end
    end
end
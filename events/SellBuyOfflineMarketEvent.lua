--
-- FS25 - GlobalMarket - SellBuyOfflineMarketEvent
-- Description: Client-to-Server event. Transmits player transaction requests (buying/selling)
-- for the simulated offline market to the server for authoritative processing.
--

SellBuyOfflineMarketEvent = {}
local SellBuyOfflineMarketEvent_mt = Class(SellBuyOfflineMarketEvent, Event)

InitEventClass(SellBuyOfflineMarketEvent, "SellBuyOfflineMarketEvent")

-- Creates an empty instance for reading from the network stream
function SellBuyOfflineMarketEvent.emptyNew()
    return Event.new(SellBuyOfflineMarketEvent_mt)
end

-- Creates a populated instance for writing to the network stream
function SellBuyOfflineMarketEvent.new(mode, filltypeName, level, storageObject, count, isObjectStorage, playerFarmId, formatXml, capacityPerObject)
    local self = SellBuyOfflineMarketEvent.emptyNew()

    self.mode = mode
    self.filltypeName = filltypeName
    self.level = math.floor(level)
    self.count = count
    self.isObjectStorage = isObjectStorage or false
    self.playerFarmId = playerFarmId

    -- NEW parameters with safe fallbacks for bulk network transmission
    self.formatXml = formatXml or ""
    self.capacityPerObject = capacityPerObject or 0

    -- FIX: Safe Network Node resolution to prevent transmitting raw Lua tables
    self.targetPlaceable = nil
    self.storageIndex = 1

    if storageObject ~= nil then
        if self.isObjectStorage then
            self.targetPlaceable = storageObject
        else
            if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
                for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                    if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                        for i, s in ipairs(placeable.spec_silo.storages) do
                            if s == storageObject then
                                self.targetPlaceable = placeable
                                self.storageIndex = i
                                break
                            end
                        end
                    end
                    if self.targetPlaceable ~= nil then break end
                end
            end
        end
    end

    return self
end

-- Serializes the transaction payload into the network stream
function SellBuyOfflineMarketEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.mode)
    streamWriteString(streamId, self.filltypeName)
    streamWriteInt32(streamId, self.level)

    -- FIX: Send the resolved Network Node and Index instead of the raw storage object
    NetworkUtil.writeNodeObject(streamId, self.targetPlaceable)
    streamWriteInt8(streamId, self.storageIndex)

    streamWriteInt32(streamId, self.count)
    streamWriteBool(streamId, self.isObjectStorage)
    streamWriteInt16(streamId, self.playerFarmId)

    -- NEW parameters appended to the stream
    streamWriteString(streamId, self.formatXml)
    streamWriteInt32(streamId, self.capacityPerObject)
end

-- Deserializes the transaction payload from the network stream
function SellBuyOfflineMarketEvent:readStream(streamId, connection)
    self.mode = streamReadInt8(streamId)
    self.filltypeName = streamReadString(streamId)
    self.level = streamReadInt32(streamId)

    -- FIX: Read the Network Node and Index
    self.targetPlaceable = NetworkUtil.readNodeObject(streamId)
    self.storageIndex = streamReadInt8(streamId)

    self.count = streamReadInt32(streamId)
    self.isObjectStorage = streamReadBool(streamId)
    self.playerFarmId = streamReadInt16(streamId)

    -- NEW parameters read from the stream
    self.formatXml = streamReadString(streamId)
    self.capacityPerObject = streamReadInt32(streamId)

    -- FIX: Reconstruct the original storageObject for backend compatibility
    self.storageObject = nil
    if self.targetPlaceable ~= nil then
        if self.isObjectStorage then
            self.storageObject = self.targetPlaceable
        else
            if self.targetPlaceable.spec_silo ~= nil and self.targetPlaceable.spec_silo.storages ~= nil then
                self.storageObject = self.targetPlaceable.spec_silo.storages[self.storageIndex]
            end
        end
    end

    self:run(connection)
end

-- Executes the core transaction logic (Server only)
function SellBuyOfflineMarketEvent:run(connection)
    -- Only execute on the server. Clients do not need to process this event locally,
    -- as the base game syncs money and fill levels automatically via engine events.
    if not connection:getIsServer() then

        if GlobalMarket.debugManager ~= nil then
            local modeStr = (self.mode == 1) and "SELL" or "BUY"
            local typeStr = self.isObjectStorage and "OBJECT" or "BULK"
            GlobalMarket.debugManager:info("Network (Server): Received %s request for %s (%s) from Farm %d", modeStr, tostring(self.filltypeName), typeStr, self.playerFarmId)

            -- Detailed payload trace to ensure stream data is not corrupted
            GlobalMarket.debugManager:trace("Payload -> Level: %d, Storage: %s, XML: %s, Cap: %d", self.level, tostring(self.storageObject), tostring(self.formatXml), self.capacityPerObject)
        end

        if g_currentMission.globalMarket ~= nil then
            if self.storageObject ~= nil then
                -- Convert network safe fallbacks back to nil if they are empty
                local xmlToPass = (self.formatXml ~= "") and self.formatXml or nil
                local capToPass = (self.capacityPerObject > 0) and self.capacityPerObject or nil

                -- Route the client's request through the server's authoritative transaction backend
                -- FIX: Pass the actual storage object table instead of just the rootNode ID
                g_currentMission.globalMarket:onSellBuy(self.mode, self.filltypeName, self.level, self.storageObject, self.count, nil, nil, self.isObjectStorage, self.playerFarmId, xmlToPass, capToPass)
            else
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:error("Network (Server): Transaction aborted. Received storageObject is nil (Sync mismatch).")
                end
            end
        end
    end
end
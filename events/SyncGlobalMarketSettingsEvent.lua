--
-- FS25 - GlobalMarket - SyncGlobalMarketSettingsEvent
-- Description: Synchronizes admin settings from the UI to the server and all clients.
--

SyncGlobalMarketSettingsEvent = {}
local SyncGlobalMarketSettingsEvent_mt = Class(SyncGlobalMarketSettingsEvent, Event)
InitEventClass(SyncGlobalMarketSettingsEvent, "SyncGlobalMarketSettingsEvent")

function SyncGlobalMarketSettingsEvent.emptyNew()
    return Event.new(SyncGlobalMarketSettingsEvent_mt)
end

function SyncGlobalMarketSettingsEvent.new(baseIndex, literIndex, isDetailed, isDebug, debugLevel, debugDur)
    local self = SyncGlobalMarketSettingsEvent.emptyNew()
    self.baseIndex = baseIndex
    self.literIndex = literIndex
    self.isDetailed = isDetailed
    self.isDebug = isDebug
    self.debugLevel = debugLevel
    self.debugDur = debugDur
    return self
end

function SyncGlobalMarketSettingsEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.baseIndex)
    streamWriteInt8(streamId, self.literIndex)
    streamWriteBool(streamId, self.isDetailed)
    streamWriteBool(streamId, self.isDebug)
    streamWriteInt8(streamId, self.debugLevel)
    streamWriteInt8(streamId, self.debugDur)
end

function SyncGlobalMarketSettingsEvent:readStream(streamId, connection)
    self.baseIndex = streamReadInt8(streamId)
    self.literIndex = streamReadInt8(streamId)
    self.isDetailed = streamReadBool(streamId)
    self.isDebug = streamReadBool(streamId)
    self.debugLevel = streamReadInt8(streamId)
    self.debugDur = streamReadInt8(streamId)
    self:run(connection)
end

function SyncGlobalMarketSettingsEvent:run(connection)
    -- SECURITY: If the server receives this from a client, verify Admin rights!
    if not connection:getIsServer() then
        local user = g_currentMission.userManager:getUserByConnection(connection)
        if user == nil or not user:getIsMasterUser() then
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:warning("Network: Unauthorized settings change attempt blocked.")
            end
            return
        end
    end

    -- Apply settings locally
    GlobalMarketSettings.current.deliveryBaseIndex = self.baseIndex
    GlobalMarketSettings.current.deliveryLiterIndex = self.literIndex
    GlobalMarketSettings.current.isDetailedFinance = self.isDetailed
    GlobalMarketSettings.current.isDebugActive = self.isDebug
    GlobalMarketSettings.current.debugLevelIndex = self.debugLevel
    GlobalMarketSettings.current.debugDurationIndex = self.debugDur

    -- Update Global Variables
    GlobalMarket.DELIVER_COST = GlobalMarketSettings.OPTIONS.DELIVERY_BASE[self.baseIndex]
    GlobalMarket.DELIVER_COST_PERLITER = GlobalMarketSettings.OPTIONS.DELIVERY_LITER[self.literIndex]

    if GlobalMarketSettings.applyDebugSettings ~= nil then
        GlobalMarketSettings:applyDebugSettings()
    end

    if GlobalMarketSettings.refreshMenuState ~= nil then
        GlobalMarketSettings:refreshMenuState()
    end

    -- If we are the Server and just received this from an Admin, save to XML and broadcast to all others
    if not connection:getIsServer() then
        if GlobalMarketSettings.saveToXML ~= nil then
            GlobalMarketSettings:saveToXML()
        end
        g_server:broadcastEvent(SyncGlobalMarketSettingsEvent.new(self.baseIndex, self.literIndex, self.isDetailed, self.isDebug, self.debugLevel, self.debugDur), nil, connection, nil)
    end
end
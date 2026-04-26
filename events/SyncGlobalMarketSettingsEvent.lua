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

function SyncGlobalMarketSettingsEvent.new(baseIndex, literIndex, isDetailed, isDebug, debugLevel, debugDur, compatModeIndex)
    local self = SyncGlobalMarketSettingsEvent.emptyNew()
    self.baseIndex = baseIndex
    self.literIndex = literIndex
    self.isDetailed = isDetailed
    self.isDebug = isDebug
    self.debugLevel = debugLevel
    self.debugDur = debugDur
    self.compatModeIndex = compatModeIndex or 3 -- Default to Strict if nil
    return self
end

function SyncGlobalMarketSettingsEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.baseIndex)
    streamWriteInt8(streamId, self.literIndex)
    streamWriteBool(streamId, self.isDetailed)
    streamWriteBool(streamId, self.isDebug)
    streamWriteInt8(streamId, self.debugLevel)
    streamWriteInt8(streamId, self.debugDur)
    streamWriteInt8(streamId, self.compatModeIndex)
end

function SyncGlobalMarketSettingsEvent:readStream(streamId, connection)
    self.baseIndex = streamReadInt8(streamId)
    self.literIndex = streamReadInt8(streamId)
    self.isDetailed = streamReadBool(streamId)
    self.isDebug = streamReadBool(streamId)
    self.debugLevel = streamReadInt8(streamId)
    self.debugDur = streamReadInt8(streamId)
    self.compatModeIndex = streamReadInt8(streamId)
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

    -- 1. DETECT CHANGES BEFORE APPLYING
    -- Check what exactly the Admin changed to trigger the correct on-screen broadcast
    local financeChanged = false
    local deliveryChanged = false
    local compatChanged = false

    if GlobalMarketSettings.current ~= nil then
        financeChanged = (GlobalMarketSettings.current.isDetailedFinance ~= self.isDetailed)
        deliveryChanged = (GlobalMarketSettings.current.deliveryBaseIndex ~= self.baseIndex) or (GlobalMarketSettings.current.deliveryLiterIndex ~= self.literIndex)
        compatChanged = (GlobalMarketSettings.current.compatModeIndex ~= self.compatModeIndex)
    end

    -- 2. APPLY SETTINGS LOCALLY
    GlobalMarketSettings.current.deliveryBaseIndex = self.baseIndex
    GlobalMarketSettings.current.deliveryLiterIndex = self.literIndex
    GlobalMarketSettings.current.isDetailedFinance = self.isDetailed
    GlobalMarketSettings.current.isDebugActive = self.isDebug
    GlobalMarketSettings.current.debugLevelIndex = self.debugLevel
    GlobalMarketSettings.current.debugDurationIndex = self.debugDur
    GlobalMarketSettings.current.compatModeIndex = self.compatModeIndex

    -- Update Global Variables
    GlobalMarket.DELIVER_COST = GlobalMarketSettings.OPTIONS.DELIVERY_BASE[self.baseIndex]
    GlobalMarket.DELIVER_COST_PERLITER = GlobalMarketSettings.OPTIONS.DELIVERY_LITER[self.literIndex]

    -- Update Finance Module Cache immediately to ensure the next transaction uses the correct MoneyType
    if GlobalMarketFinance ~= nil then
        GlobalMarketFinance.isDetailedCached = self.isDetailed
    end

    if GlobalMarketSettings.applyDebugSettings ~= nil then
        GlobalMarketSettings:applyDebugSettings()
    end

    if GlobalMarketSettings.refreshMenuState ~= nil then
        GlobalMarketSettings:refreshMenuState()
    end

    -- Dynamically notify the compatibility manager to re-evaluate current mods if the setting changed
    if compatChanged and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.compatibilityManager ~= nil then
        g_currentMission.globalMarket.compatibilityManager:checkActiveMods()
    end

    -- 3. NETWORK & BROADCAST LOGIC
    if not connection:getIsServer() then
        -- SERVER SIDE: Save to XML and broadcast to all others
        if GlobalMarketSettings.saveToXML ~= nil then
            GlobalMarketSettings:saveToXML()
        end
        g_server:broadcastEvent(SyncGlobalMarketSettingsEvent.new(self.baseIndex, self.literIndex, self.isDetailed, self.isDebug, self.debugLevel, self.debugDur, self.compatModeIndex), nil, connection, nil)
    else
        -- CLIENT SIDE: We received the broadcast from the server.

        -- Save settings to the local disk persistently using the existing save function.
        if GlobalMarketSettings.saveToXML ~= nil then
            GlobalMarketSettings:saveToXML()
        end

        -- Trigger specific On-Screen Broadcast based on what actually changed
        if g_currentMission ~= nil then
            if financeChanged and deliveryChanged then
                local msg = g_i18n:getText("ui_gm_notification_settings_both")
                if msg == nil or msg == "ui_gm_notification_settings_both" then
                    msg = "GlobalMarket: Delivery costs updated. (Finance stats require restart!)"
                end
                g_currentMission:showBlinkingWarning(msg, 6000)

            elseif financeChanged then
                local msg = g_i18n:getText("ui_gm_notification_settings_finance")
                if msg == nil or msg == "ui_gm_notification_settings_finance" then
                    msg = "GlobalMarket: Finance stats updated! (Requires game restart)"
                end
                g_currentMission:showBlinkingWarning(msg, 5000)

            elseif deliveryChanged then
                local msg = g_i18n:getText("ui_gm_notification_settings_delivery")
                if msg == nil or msg == "ui_gm_notification_settings_delivery" then
                    msg = "GlobalMarket: Delivery costs have been updated!"
                end
                g_currentMission:showBlinkingWarning(msg, 5000)
            end

            -- Optional: We don't necessarily need a blinking warning for Compatibility changes,
            -- as it's an admin backend setting, but the logic is here if you want to add one.
        end
    end
end
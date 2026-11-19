-- =========================================================================================
-- FS25_GlobalMarket - SyncGlobalMarketSettingsEvent.lua
-- Network event synchronizing global admin market settings across server and clients.
-- Author: D-S-Agrarservice
-- =========================================================================================

SyncGlobalMarketSettingsEvent = {}
local SyncGlobalMarketSettingsEvent_mt = Class(SyncGlobalMarketSettingsEvent, Event)
InitEventClass(SyncGlobalMarketSettingsEvent, "SyncGlobalMarketSettingsEvent")

function SyncGlobalMarketSettingsEvent.emptyNew()
    return Event.new(SyncGlobalMarketSettingsEvent_mt)
end

function SyncGlobalMarketSettingsEvent.new(
    baseIndex, literIndex, isDetailed, isDebug, debugLevel, debugDur, compatModeIndex,
    isIconPulse, showStatusIcon, dealerMarkupIndex, capacityIndex, storageDecayIndex,
    greatDemandModeIndex, npcActivityModeIndex, onlineContractsModeIndex,
    maxFarmContractsIndex, npcContractsTargetIndex, npcOffersTargetIndex, vehicleNpcModeIndex
)
    local self = SyncGlobalMarketSettingsEvent.emptyNew()
    self.baseIndex = baseIndex
    self.literIndex = literIndex
    self.isDetailed = isDetailed
    self.isDebug = isDebug
    self.debugLevel = debugLevel
    self.debugDur = debugDur
    self.compatModeIndex = compatModeIndex or 3
    self.isIconPulse = isIconPulse
    self.showStatusIcon = showStatusIcon
    self.dealerMarkupIndex = dealerMarkupIndex
    self.capacityIndex = capacityIndex
    self.storageDecayIndex = storageDecayIndex or 3
    self.greatDemandModeIndex = greatDemandModeIndex or 1
    self.npcActivityModeIndex = npcActivityModeIndex or 1
    self.onlineContractsModeIndex = onlineContractsModeIndex or 1
    self.maxFarmContractsIndex = maxFarmContractsIndex or 3
    self.npcContractsTargetIndex = npcContractsTargetIndex or 3
    self.npcOffersTargetIndex = npcOffersTargetIndex or 3
    self.vehicleNpcModeIndex = vehicleNpcModeIndex or 3
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
    streamWriteBool(streamId, self.isIconPulse)
    streamWriteBool(streamId, self.showStatusIcon)
    streamWriteInt8(streamId, self.dealerMarkupIndex)
    streamWriteInt8(streamId, self.capacityIndex)
    streamWriteInt8(streamId, self.storageDecayIndex or 3)
    streamWriteInt8(streamId, self.greatDemandModeIndex or 1)
    streamWriteInt8(streamId, self.npcActivityModeIndex or 1)
    streamWriteInt8(streamId, self.onlineContractsModeIndex or 1)
    streamWriteInt8(streamId, self.maxFarmContractsIndex or 3)
    streamWriteInt8(streamId, self.npcContractsTargetIndex or 3)
    streamWriteInt8(streamId, self.npcOffersTargetIndex or 3)
    streamWriteInt8(streamId, self.vehicleNpcModeIndex or 3)
end

function SyncGlobalMarketSettingsEvent:readStream(streamId, connection)
    self.baseIndex = streamReadInt8(streamId)
    self.literIndex = streamReadInt8(streamId)
    self.isDetailed = streamReadBool(streamId)
    self.isDebug = streamReadBool(streamId)
    self.debugLevel = streamReadInt8(streamId)
    self.debugDur = streamReadInt8(streamId)
    self.compatModeIndex = streamReadInt8(streamId)
    self.isIconPulse = streamReadBool(streamId)
    self.showStatusIcon = streamReadBool(streamId)
    self.dealerMarkupIndex = streamReadInt8(streamId)
    self.capacityIndex = streamReadInt8(streamId)
    self.storageDecayIndex = streamReadInt8(streamId)
    self.greatDemandModeIndex = streamReadInt8(streamId)
    self.npcActivityModeIndex = streamReadInt8(streamId)
    self.onlineContractsModeIndex = streamReadInt8(streamId)
    self.maxFarmContractsIndex = streamReadInt8(streamId)
    self.npcContractsTargetIndex = streamReadInt8(streamId)
    self.npcOffersTargetIndex = streamReadInt8(streamId)
    self.vehicleNpcModeIndex = streamReadInt8(streamId)
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
    local financeChanged = false
    local deliveryChanged = false
    local compatChanged = false
    local capacityChanged = false
    local gdModeChanged = false
    local npcModeChanged = false
    local onlineContractsModeChanged = false
    local contractLimitsChanged = false
    local vehicleNpcChanged = false

    if GlobalMarketSettings.current ~= nil then
        financeChanged = false
        deliveryChanged = (GlobalMarketSettings.current.deliveryBaseIndex ~= self.baseIndex)
            or (GlobalMarketSettings.current.deliveryLiterIndex ~= self.literIndex)
            or (GlobalMarketSettings.current.dealerMarkupIndex ~= self.dealerMarkupIndex)
            or (GlobalMarketSettings.current.storageDecayIndex ~= self.storageDecayIndex)
        compatChanged = (GlobalMarketSettings.current.compatModeIndex ~= self.compatModeIndex)
        capacityChanged = (GlobalMarketSettings.current.capacityIndex ~= self.capacityIndex)
        gdModeChanged = (GlobalMarketSettings.current.greatDemandModeIndex ~= self.greatDemandModeIndex)
        npcModeChanged = (GlobalMarketSettings.current.npcActivityModeIndex ~= self.npcActivityModeIndex)
        onlineContractsModeChanged = (GlobalMarketSettings.current.onlineContractsModeIndex ~= self.onlineContractsModeIndex)
        contractLimitsChanged = (GlobalMarketSettings.current.maxFarmContractsIndex ~= self.maxFarmContractsIndex)
            or (GlobalMarketSettings.current.npcContractsTargetIndex ~= self.npcContractsTargetIndex)
            or (GlobalMarketSettings.current.npcOffersTargetIndex ~= self.npcOffersTargetIndex)
        vehicleNpcChanged = (GlobalMarketSettings.current.vehicleNpcModeIndex ~= self.vehicleNpcModeIndex)
    end

    -- 2. APPLY SETTINGS LOCALLY
    GlobalMarketSettings.current.deliveryBaseIndex = self.baseIndex
    GlobalMarketSettings.current.deliveryLiterIndex = self.literIndex
    -- Note: isDetailedFinance is a local per-player UI comfort setting and is not overwritten by network sync.
    GlobalMarketSettings.current.isDebugActive = self.isDebug
    GlobalMarketSettings.current.debugLevelIndex = self.debugLevel
    GlobalMarketSettings.current.debugDurationIndex = self.debugDur
    GlobalMarketSettings.current.compatModeIndex = self.compatModeIndex
    -- Note: isIconPulseActive is a local per-player UI comfort setting and is not overwritten by network sync.
    -- Note: showStatusIcon is a local per-player UI comfort setting and is not overwritten by network sync.
    GlobalMarketSettings.current.dealerMarkupIndex = self.dealerMarkupIndex
    GlobalMarketSettings.current.capacityIndex = self.capacityIndex
    GlobalMarketSettings.current.storageDecayIndex = self.storageDecayIndex or 3
    GlobalMarketSettings.current.greatDemandModeIndex = self.greatDemandModeIndex or 1
    GlobalMarketSettings.current.npcActivityModeIndex = self.npcActivityModeIndex or 1
    GlobalMarketSettings.current.onlineContractsModeIndex = self.onlineContractsModeIndex or 1
    GlobalMarketSettings.current.maxFarmContractsIndex = self.maxFarmContractsIndex or 3
    GlobalMarketSettings.current.npcContractsTargetIndex = self.npcContractsTargetIndex or 3
    GlobalMarketSettings.current.npcOffersTargetIndex = self.npcOffersTargetIndex or 3
    GlobalMarketSettings.current.vehicleNpcModeIndex = self.vehicleNpcModeIndex or 3
    if GlobalMarketSettings.OPTIONS.VEHICLE_NPC_MODE ~= nil then
        GlobalMarket.VEHICLE_NPC_LEVEL = GlobalMarketSettings.OPTIONS.VEHICLE_NPC_MODE[self.vehicleNpcModeIndex] or 2
    end
    if vehicleNpcChanged and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil
        and g_currentMission.globalMarket.onVehicleNpcModeChanged ~= nil then
        g_currentMission.globalMarket:onVehicleNpcModeChanged(GlobalMarket.VEHICLE_NPC_LEVEL)
    end

    -- Update Global Variables
    GlobalMarket.DELIVER_COST = GlobalMarketSettings.OPTIONS.DELIVERY_BASE[self.baseIndex]
    GlobalMarket.DELIVER_COST_PERLITER = GlobalMarketSettings.OPTIONS.DELIVERY_LITER[self.literIndex]
    if GlobalMarketSettings.OPTIONS.DEALER_MARKUP ~= nil then
        GlobalMarket.DEALER_MARKUP = GlobalMarketSettings.OPTIONS.DEALER_MARKUP[self.dealerMarkupIndex]
    end

    if GlobalMarketSettings.OPTIONS.MARKET_CAPACITY ~= nil then
        GlobalMarket.MARKET_CAPACITY = GlobalMarketSettings.OPTIONS.MARKET_CAPACITY[self.capacityIndex]
    end

    if GlobalMarketSettings.OPTIONS.STORAGE_DECAY ~= nil then
        GlobalMarket.STORAGE_DECAY_MONTHS = GlobalMarketSettings.OPTIONS.STORAGE_DECAY[self.storageDecayIndex] or 6
    end

    if GlobalMarketSettings.OPTIONS.GREAT_DEMAND_MODE ~= nil then
        GlobalMarket.GREAT_DEMAND_MODE = GlobalMarketSettings.OPTIONS.GREAT_DEMAND_MODE[self.greatDemandModeIndex] or 1
    end

    if GlobalMarketSettings.OPTIONS.NPC_ACTIVITY_MODE ~= nil then
        GlobalMarket.NPC_ACTIVITY_MODE = GlobalMarketSettings.OPTIONS.NPC_ACTIVITY_MODE[self.npcActivityModeIndex] or 1
    end

    if GlobalMarketSettings.OPTIONS.ONLINE_CONTRACTS_MODE ~= nil then
        GlobalMarket.ONLINE_CONTRACTS_MODE = GlobalMarketSettings.OPTIONS.ONLINE_CONTRACTS_MODE[self.onlineContractsModeIndex] or 1
    end

    if gdModeChanged and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.onGreatDemandModeChanged ~= nil then
        g_currentMission.globalMarket:onGreatDemandModeChanged(GlobalMarket.GREAT_DEMAND_MODE)
    end

    if npcModeChanged and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.onNpcActivityModeChanged ~= nil then
        g_currentMission.globalMarket:onNpcActivityModeChanged(GlobalMarket.NPC_ACTIVITY_MODE)
    end

    if onlineContractsModeChanged and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.onOnlineContractsModeChanged ~= nil then
        g_currentMission.globalMarket:onOnlineContractsModeChanged(GlobalMarket.ONLINE_CONTRACTS_MODE)
    end

    -- Contract board limits (#26): always apply values; server trims/replenishes the NPC board only on change
    if contractLimitsChanged and GlobalMarketSettings.onContractLimitsUpdated ~= nil then
        GlobalMarketSettings:onContractLimitsUpdated()
    elseif GlobalMarketSettings.applyContractLimits ~= nil then
        GlobalMarketSettings:applyContractLimits()
    end

    if GlobalMarketSettings.applyDebugSettings ~= nil then
        GlobalMarketSettings:applyDebugSettings()
    end

    if GlobalMarketSettings.refreshMenuState ~= nil then
        GlobalMarketSettings:refreshMenuState()
    end

    if compatChanged and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.compatibilityManager ~= nil then
        g_currentMission.globalMarket.compatibilityManager:checkActiveMods()
    end

    -- 3. NETWORK & BROADCAST LOGIC
    if not connection:getIsServer() then
        -- SERVER SIDE
        if GlobalMarketSettings.saveToXML ~= nil then
            GlobalMarketSettings:saveToXML()
        end

        g_server:broadcastEvent(SyncGlobalMarketSettingsEvent.new(
            self.baseIndex, self.literIndex, self.isDetailed, self.isDebug, self.debugLevel, self.debugDur,
            self.compatModeIndex, self.isIconPulse, self.showStatusIcon, self.dealerMarkupIndex,
            self.capacityIndex, self.storageDecayIndex, self.greatDemandModeIndex, self.npcActivityModeIndex,
            self.onlineContractsModeIndex, self.maxFarmContractsIndex, self.npcContractsTargetIndex, self.npcOffersTargetIndex,
            self.vehicleNpcModeIndex
        ), nil, connection, nil)
    else
        -- CLIENT SIDE
        if GlobalMarketSettings.saveToXML ~= nil then
            GlobalMarketSettings:saveToXML()
        end

        if g_currentMission ~= nil then
            if capacityChanged then
                local msg = g_i18n:getText("ui_gm_notification_settings_capacity")
                if msg == nil or msg == "ui_gm_notification_settings_capacity" then 
                    msg = "GlobalMarket: Market capacity has been updated! Prices will adjust gradually." 
                end
                g_currentMission:showBlinkingWarning(msg, 6000)
            end

            -- Existing warnings
            if financeChanged and deliveryChanged then
                local msg = g_i18n:getText("ui_gm_notification_settings_both")
                if msg == nil or msg == "ui_gm_notification_settings_both" then msg = "GlobalMarket: Delivery costs updated. (Finance stats require restart!)" end
                g_currentMission:showBlinkingWarning(msg, 6000)
            elseif financeChanged then
                local msg = g_i18n:getText("ui_gm_notification_settings_finance")
                if msg == nil or msg == "ui_gm_notification_settings_finance" then msg = "GlobalMarket: Finance stats updated! (Requires game restart)" end
                g_currentMission:showBlinkingWarning(msg, 5000)
            elseif deliveryChanged then
                local msg = g_i18n:getText("ui_gm_notification_settings_delivery")
                if msg == nil or msg == "ui_gm_notification_settings_delivery" then msg = "GlobalMarket: Delivery costs have been updated!" end
                g_currentMission:showBlinkingWarning(msg, 5000)
            end
        end
    end
end

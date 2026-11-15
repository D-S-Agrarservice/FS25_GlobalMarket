-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketBranding.lua
-- 3-tier online market branding (synced private market title & local modSettings logo).
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketBranding = {}
GlobalMarketBranding.MAX_MARKET_NAME_LEN = 48
-- GIANTS Engine requires power-of-two BC3/DXT5 .dds textures with prebuilt mipmaps (e.g. 512x256 2:1 canvas)
GlobalMarketBranding.DEFAULT_LOGO_CANDIDATES = {
    "marketLogo.dds",
    "logos/marketLogo.dds"
}

---Sanitizes an incoming custom market name string for safe HUD/UI rendering and MP streaming
---@param rawName string|nil
---@return string|nil
function GlobalMarketBranding.sanitizeMarketName(rawName)
    if type(rawName) ~= "string" then
        return nil
    end

    local clean = string.gsub(rawName, "%c+", " ")
    clean = string.gsub(clean, "%s+", " ")
    clean = string.gsub(clean, "^%s+", "")
    clean = string.gsub(clean, "%s+$", "")

    if clean == "" then
        return nil
    end

    if string.len(clean) > GlobalMarketBranding.MAX_MARKET_NAME_LEN then
        clean = string.sub(clean, 1, GlobalMarketBranding.MAX_MARKET_NAME_LEN)
        clean = string.gsub(clean, "%s+$", "")
    end

    return (clean ~= "") and clean or nil
end

---Validates a relative logo filename inside modSettings/FS25_GlobalMarket/ (.dds only to avoid GIANTS raw/mip warnings)
---@param rawLogoFile string|nil
---@return string|nil
function GlobalMarketBranding.sanitizeLogoRelPath(rawLogoFile)
    if type(rawLogoFile) ~= "string" then
        return nil
    end

    local clean = string.gsub(rawLogoFile, "\\", "/")
    clean = string.gsub(clean, "^%s+", "")
    clean = string.gsub(clean, "%s+$", "")

    if clean == "" or string.find(clean, "..", 1, true) ~= nil or string.find(clean, ":", 1, true) ~= nil then
        return nil
    end

    local isBareFile = string.match(clean, "^[%w_%-%.]+$") ~= nil
    local isLogosSubFile = string.match(clean, "^logos/[%w_%-%.]+$") ~= nil
    if not isBareFile and not isLogosSubFile then
        return nil
    end

    if string.match(string.lower(clean), "%.dds$") == nil then
        return nil
    end

    return clean
end

---Initializes branding fields on the GlobalMarket instance
function GlobalMarket:initBrandingState()
    self.onlineMarketName = nil
    self.isPrivateOnlineMarket = false
    self.sessionLockedMarketName = nil
    self.localExeMarketName = nil
    self.localExeIsPrivateMarket = false
    self.localCustomLogoFile = nil
    self.localHasCustomLogo = false
    self.brandingLogoReloadPending = false
    self.debugBrandingOverrideActive = false
    self.debugBrandingMarketName = nil
    self.debugBrandingLogoPath = nil
end

---Reads optional 3-tier branding metadata from globalMarketOnline.xml
---@param xmlFile table Loaded XMLFile instance for globalMarketOnline.xml
---@return boolean changed True when any local branding attribute changed
function GlobalMarket:readHeartbeatBranding(xmlFile)
    if xmlFile == nil then
        return false
    end

    local rawName = xmlFile:getString("globalMarketOnline#marketName") or xmlFile:getString("globalMarketOnline.marketName")
    local rawLogo = xmlFile:getString("globalMarketOnline#logoFile") or xmlFile:getString("globalMarketOnline.logoFile")
    local rawTier = xmlFile:getInt("globalMarketOnline#brandingTier") or xmlFile:getInt("globalMarketOnline.brandingTier")
    local cleanName = GlobalMarketBranding.sanitizeMarketName(rawName)
    local cleanLogo = GlobalMarketBranding.sanitizeLogoRelPath(rawLogo)

    local hasLogoFlag = xmlFile:getBool("globalMarketOnline#hasCustomLogo", false)
        or xmlFile:getBool("globalMarketOnline.hasCustomLogo", false)
        or (cleanLogo ~= nil)
        or (rawTier == 1 or rawTier == 3)

    local isPrivate = xmlFile:getBool("globalMarketOnline#isPrivateMarket",
        xmlFile:getBool("globalMarketOnline.isPrivateMarket", cleanName ~= nil))
        or (rawTier == 2 or rawTier == 3)

    -- Enforce tier boundaries when explicit brandingTier (1, 2, 3) is supplied by GlobalMarketClient
    if rawTier == 1 then
        cleanName = nil
        isPrivate = false
    elseif rawTier == 2 then
        cleanLogo = nil
        hasLogoFlag = false
    elseif rawTier == 0 then
        cleanName = nil
        isPrivate = false
        cleanLogo = nil
        hasLogoFlag = false
    end

    local logoChanged = (cleanLogo ~= self.localCustomLogoFile)
        or (hasLogoFlag ~= self.localHasCustomLogo)
        or (not self.isExeRunningLocal and hasLogoFlag)

    local changed = (cleanName ~= self.localExeMarketName)
        or (isPrivate ~= self.localExeIsPrivateMarket)
        or logoChanged

    self.localExeMarketName = cleanName
    self.localExeIsPrivateMarket = (isPrivate == true)
    self.localCustomLogoFile = cleanLogo
    self.localHasCustomLogo = (hasLogoFlag == true)

    if logoChanged then
        self.brandingLogoReloadPending = true
    end

    return changed
end

---Clears local companion client branding when globalMarketOnline.xml goes offline
---@return boolean changed
function GlobalMarket:clearLocalBranding()
    local changed = (self.localExeMarketName ~= nil)
        or (self.localExeIsPrivateMarket == true)
        or (self.localCustomLogoFile ~= nil)
        or (self.localHasCustomLogo == true)

    self.localExeMarketName = nil
    self.localExeIsPrivateMarket = false
    self.localCustomLogoFile = nil
    self.localHasCustomLogo = false

    return changed
end

---Reads optional branding overrides from gmDataSync (action="marketData") packets on the Data-Host
---@param xmlFile table Loaded XMLFile instance for gmDataSync
function GlobalMarket:readMarketSyncBranding(xmlFile)
    if xmlFile == nil then
        return
    end

    local rawName = xmlFile:getString("gmDataSync#marketName") or xmlFile:getString("gmDataSync.marketName")
    local rawPrivAttr = xmlFile:getBool("gmDataSync#isPrivateMarket")
    local rawTier = xmlFile:getInt("gmDataSync#brandingTier")
    local rawLogo = xmlFile:getString("gmDataSync#logoFile") or xmlFile:getString("gmDataSync.logoFile")

    if rawName ~= nil or rawPrivAttr ~= nil or rawTier ~= nil then
        local cleanName = (rawTier == 1 or rawTier == 0) and nil or GlobalMarketBranding.sanitizeMarketName(rawName)
        local isPriv = (rawTier ~= 1 and rawTier ~= 0) and ((rawPrivAttr == true) or (rawTier == 2 or rawTier == 3) or (cleanName ~= nil))
        self.localExeMarketName = cleanName
        self.localExeIsPrivateMarket = isPriv
    end

    if rawLogo ~= nil then
        local cleanLogo = GlobalMarketBranding.sanitizeLogoRelPath(rawLogo)
        if cleanLogo ~= self.localCustomLogoFile then
            self.localCustomLogoFile = cleanLogo
            self.localHasCustomLogo = (cleanLogo ~= nil)
            self.brandingLogoReloadPending = true
        end
    end
end

---Returns true if a tracked companion client entry is active and connected to the backend
---@param state table|nil Entry from self.clientExeStates
---@return boolean
function GlobalMarketBranding.isStateReady(state)
    return state ~= nil and state.isExeRunning == true and state.hasBackendConnection == true
end

---Extracts the sanitized private market name from a client state (nil for Official Market)
---@param state table|nil Entry from self.clientExeStates
---@return string|nil
function GlobalMarketBranding.getStatePrivateMarketName(state)
    if state == nil or state.isPrivateMarket == false then
        return nil
    end
    return GlobalMarketBranding.sanitizeMarketName(state.marketName)
end

---Clears the server session private market lock in RAM
function GlobalMarket:resetSessionMarketLock()
    self.sessionLockedMarketName = nil
end

---Restores all market items to their Offline baseline without clearing online branding
function GlobalMarket:resetMarketItemsForMarketSwitch()
    if self.offlineMarketFillTypes == nil or self.restoreItemOfflineState == nil then
        return
    end
    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    for _, item in pairs(self.offlineMarketFillTypes) do
        self:restoreItemOfflineState(item, currentLimit)
    end
end

---Checks whether a companion client state is permitted to act as Data-Host under the session lock
---@param state table|nil Entry from self.clientExeStates
---@return boolean
function GlobalMarket:isClientEligibleForSessionMarket(state)
    if not GlobalMarketBranding.isStateReady(state) then
        return false
    end
    local privName = GlobalMarketBranding.getStatePrivateMarketName(state)
    if state.isPrivateMarket == true and privName == nil then
        return false
    end
    if self.sessionLockedMarketName ~= nil then
        return privName == self.sessionLockedMarketName
    end
    return true
end

---Checks whether another active connection holds the locked private market token
---@param excludedConn any Connection being stepped down or evaluated
---@param lockedName string|nil Locked private market name
---@return boolean
function GlobalMarket:hasOtherClientForLockedMarket(excludedConn, lockedName)
    if lockedName == nil or self.clientExeStates == nil then
        return false
    end
    for conn, state in pairs(self.clientExeStates) do
        if conn ~= excludedConn and GlobalMarketBranding.isStateReady(state) then
            if GlobalMarketBranding.getStatePrivateMarketName(state) == lockedName then
                return true
            end
        end
    end
    return false
end

---Selects the highest-priority eligible Data-Host connection for the active session
---@return any|nil
function GlobalMarket:selectNextDataHostConnection()
    if self.clientExeStates == nil then
        return nil
    end

    local localState = self.clientExeStates["LOCAL_HOST"]
    local localEligible = self:isClientEligibleForSessionMarket(localState)
    local localPrivName = GlobalMarketBranding.getStatePrivateMarketName(localState)

    if localEligible and (self.sessionLockedMarketName ~= nil or localPrivName ~= nil) then
        return "LOCAL_HOST"
    end

    for conn, state in pairs(self.clientExeStates) do
        if conn ~= "LOCAL_HOST" and self:isClientEligibleForSessionMarket(state) then
            if GlobalMarketBranding.getStatePrivateMarketName(state) ~= nil then
                return conn
            end
        end
    end

    if localEligible then
        return "LOCAL_HOST"
    end

    for conn, state in pairs(self.clientExeStates) do
        if conn ~= "LOCAL_HOST" and self:isClientEligibleForSessionMarket(state) then
            return conn
        end
    end

    return nil
end

---Determines whether an incoming ready connection should preempt the current Data-Host
---@param connection any Incoming connection key ("LOCAL_HOST" or MP Connection)
---@param state table|nil Incoming client state entry
---@return boolean
function GlobalMarket:shouldPreemptActiveDataHost(connection, state)
    if self.dataHostConnection == nil or self.dataHostConnection == connection then
        return false
    end
    if not self:isClientEligibleForSessionMarket(state) then
        return false
    end

    local activeState = (self.clientExeStates ~= nil) and self.clientExeStates[self.dataHostConnection] or nil
    local activePrivName = GlobalMarketBranding.getStatePrivateMarketName(activeState)
    local incomingPrivName = GlobalMarketBranding.getStatePrivateMarketName(state)

    if connection == "LOCAL_HOST" then
        if activePrivName ~= nil and incomingPrivName == nil then
            return false
        end
        return true
    end

    return self.sessionLockedMarketName == nil and activePrivName == nil and incomingPrivName ~= nil
end

---Checks whether any remote player remains connected on the server
---@return boolean
function GlobalMarket:hasRemainingRemotePlayers()
    if g_currentMission ~= nil and g_currentMission.userManager ~= nil then
        local userManager = g_currentMission.userManager
        if userManager.getNumberOfUsers ~= nil then
            local userCount = userManager:getNumberOfUsers()
            if userCount ~= nil then
                return userCount > 1
            end
        end
    end
    if g_currentMission ~= nil and g_currentMission.connectionsToPlayer ~= nil then
        if next(g_currentMission.connectionsToPlayer) ~= nil then
            return true
        end
    end
    if self.clientExeStates ~= nil then
        for conn, _ in pairs(self.clientExeStates) do
            if conn ~= "LOCAL_HOST" then
                return true
            end
        end
    end
    return false
end

---Releases the session private market lock when a Dedicated Server becomes completely empty
---@return boolean released
function GlobalMarket:clearSessionMarketLockIfServerEmpty()
    if g_dedicatedServer == nil or self.sessionLockedMarketName == nil then
        return false
    end
    if self.dataHostConnection == "LOCAL_HOST" then
        local localState = (self.clientExeStates ~= nil) and self.clientExeStates["LOCAL_HOST"] or nil
        if self:isClientEligibleForSessionMarket(localState) then
            return false
        end
    end
    if self:hasRemainingRemotePlayers() then
        return false
    end

    local previousLock = self.sessionLockedMarketName
    self.sessionLockedMarketName = nil
    if self.debugManager ~= nil then
        self.debugManager:info(string.format(
            "Sync: Dedicated server is empty. Released session market lock '%s'.",
            tostring(previousLock)
        ))
    end
    return true
end

---Dispatches the server map whitelist to the specified Data-Host connection
---@param connection any Active Data-Host connection key ("LOCAL_HOST" or MP Connection)
function GlobalMarket:dispatchDataHostWhitelist(connection)
    if connection == "LOCAL_HOST" then
        if self.receiveDataHostToken ~= nil then
            self:receiveDataHostToken(self.serverWhitelist)
        end
    elseif SyncMarketWhitelistEvent ~= nil and type(connection) == "table" and connection.sendEvent ~= nil then
        connection:sendEvent(SyncMarketWhitelistEvent.new(self.serverWhitelist, true))
    end
end

---Applies branding from the promoted Data-Host connection state on the Server
---@param hostState table|nil Entry from self.clientExeStates[nextConn]
function GlobalMarket:applyDataHostBranding(hostState)
    local privName = GlobalMarketBranding.getStatePrivateMarketName(hostState)
    local cleanName = (hostState ~= nil) and GlobalMarketBranding.sanitizeMarketName(hostState.marketName) or nil
    if privName ~= nil then
        self.sessionLockedMarketName = privName
    end
    self.onlineMarketName = cleanName
    self.isPrivateOnlineMarket = (hostState ~= nil and hostState.isPrivateMarket == true) or (cleanName ~= nil)
end

---Applies host branding on failover or promotion and clears stale items if market identity changed
---@param hostState table|nil Entry from self.clientExeStates[nextConn]
---@param prevWasOnline boolean Whether server was already online before selecting the new host
function GlobalMarket:onDataHostSelectedBranding(hostState, prevWasOnline)
    local prevName = self.onlineMarketName
    local prevPriv = (self.isPrivateOnlineMarket == true)
    self:applyDataHostBranding(hostState)

    if prevWasOnline and (self.onlineMarketName ~= prevName or self.isPrivateOnlineMarket ~= prevPriv) then
        self:resetMarketItemsForMarketSwitch()
    end
    self:refreshBrandingUiIfOpen()
end

---Updates server branding live if the active Data-Host changes its token/marketName mid-session
---@param connection any Active Data-Host connection key ("LOCAL_HOST" or MP Connection)
function GlobalMarket:updateActiveDataHostBranding(connection)
    local hostState = (self.clientExeStates ~= nil) and self.clientExeStates[connection] or nil
    local newPrivName = GlobalMarketBranding.getStatePrivateMarketName(hostState)
    local newName = (hostState ~= nil) and GlobalMarketBranding.sanitizeMarketName(hostState.marketName) or nil
    local newPriv = (hostState ~= nil and hostState.isPrivateMarket == true) or (newName ~= nil)

    if newPriv and newName == nil then
        if self.assignNextDataHost ~= nil then
            self:assignNextDataHost()
        end
        return
    end

    if newName == self.onlineMarketName and newPriv == self.isPrivateOnlineMarket
        and newPrivName == self.sessionLockedMarketName then
        return
    end

    local lockedName = self.sessionLockedMarketName
    if lockedName ~= nil and newPrivName ~= lockedName and self:hasOtherClientForLockedMarket(connection, lockedName) then
        if self.assignNextDataHost ~= nil then
            self:assignNextDataHost()
        end
        return
    end

    local identityChanged = (newName ~= self.onlineMarketName or newPriv ~= self.isPrivateOnlineMarket)
    self.sessionLockedMarketName = newPrivName
    self.onlineMarketName = newName
    self.isPrivateOnlineMarket = newPriv

    if identityChanged then
        self:resetMarketItemsForMarketSwitch()
    end

    self:refreshBrandingUiIfOpen()
    self:dispatchDataHostWhitelist(connection)

    if self.refreshMarketPrices ~= nil then
        self:refreshMarketPrices()
    end
    if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
        g_server:broadcastEvent(SynchOfflineMarketEvent.new())
    end
end

---Validates incoming Data-Host market sync branding against the active session lock
---@param connection any Active Data-Host connection ("LOCAL_HOST" or MP Connection)
---@param marketName string|nil Market name carried by sync payload
---@param isPrivateMarket boolean|nil Private market flag carried by sync payload
---@return boolean isAllowed True if packet branding is accepted and payload may be applied
function GlobalMarket:onDataHostPacketBranding(connection, marketName, isPrivateMarket)
    if self.dataHostConnection ~= connection then
        return false
    end

    local cleanName = GlobalMarketBranding.sanitizeMarketName(marketName)
    local newPriv = (isPrivateMarket == true) or (cleanName ~= nil)
    if newPriv and cleanName == nil then
        return false
    end

    local packetState = {
        isExeRunning = true,
        hasBackendConnection = true,
        marketName = cleanName,
        isPrivateMarket = newPriv
    }
    local packetPrivName = GlobalMarketBranding.getStatePrivateMarketName(packetState)

    if self.clientExeStates ~= nil and self.clientExeStates[connection] ~= nil then
        self.clientExeStates[connection].marketName = cleanName
        self.clientExeStates[connection].isPrivateMarket = newPriv
    end

    if self.sessionLockedMarketName ~= nil and packetPrivName ~= self.sessionLockedMarketName then
        if self:hasOtherClientForLockedMarket(connection, self.sessionLockedMarketName) then
            if self.assignNextDataHost ~= nil then
                self:assignNextDataHost()
            end
            return false
        end
        self.sessionLockedMarketName = packetPrivName
        self:resetMarketItemsForMarketSwitch()
        self:dispatchDataHostWhitelist(connection)
        return true
    end

    if self.sessionLockedMarketName == nil and packetPrivName ~= nil then
        self.sessionLockedMarketName = packetPrivName
        self:resetMarketItemsForMarketSwitch()
        self:dispatchDataHostWhitelist(connection)
        return true
    end

    if cleanName ~= self.onlineMarketName or newPriv ~= self.isPrivateOnlineMarket then
        self:resetMarketItemsForMarketSwitch()
    end

    return true
end

---Validates, applies, and broadcasts an authoritative server market data payload
---@param connection any Active Data-Host connection ("LOCAL_HOST" or MP Connection)
---@param marketData table Parsed market payload from companion client
---@param marketName string|nil Market name carried by payload
---@param isPrivateMarket boolean|nil Private market flag carried by payload
function GlobalMarket:applyAndBroadcastServerMarketPacket(connection, marketData, marketName, isPrivateMarket)
    if not self:onDataHostPacketBranding(connection, marketName, isPrivateMarket) then
        return
    end
    self:applySyncedBranding(marketName, isPrivateMarket)
    if self.applySyncedMarketData ~= nil then
        self:applySyncedMarketData(marketData)
    end
    if g_server ~= nil and MarketDataSyncEvent ~= nil then
        g_server:broadcastEvent(MarketDataSyncEvent.newFromServerState(self))
    end
end

---Applies authoritative server branding received via MarketDataSyncEvent or SynchOfflineMarketEvent
---@param marketName string|nil
---@param isPrivateMarket boolean|nil
function GlobalMarket:applySyncedBranding(marketName, isPrivateMarket)
    local cleanName = GlobalMarketBranding.sanitizeMarketName(marketName)
    local newPriv = (isPrivateMarket == true) or (cleanName ~= nil)
    local changed = (cleanName ~= self.onlineMarketName or newPriv ~= self.isPrivateOnlineMarket)
    if self.isOnline == true and changed then
        self:resetMarketItemsForMarketSwitch()
    end
    self.onlineMarketName = cleanName
    self.isPrivateOnlineMarket = newPriv
    if changed then
        self:refreshBrandingUiIfOpen()
    end
end

---Resets authoritative online market branding when falling back to Offline mode
function GlobalMarket:clearOnlineMarketBranding()
    self.onlineMarketName = nil
    self.isPrivateOnlineMarket = false
end

---Resolves the validated full local filesystem path for the custom market logo, or nil if unavailable
---@return string|nil
function GlobalMarket:resolveLocalLogoFullPath()
    if self.debugBrandingOverrideActive then
        if self.debugBrandingLogoPath ~= nil and fileExists(self.debugBrandingLogoPath) then
            return self.debugBrandingLogoPath
        end
        return nil
    end

    if not self:getIsMarketOnline() or not self.isExeRunningLocal or not self.hasBackendConnection then
        return nil
    end

    -- On Standby MP clients, only display local logo if connected to the same market as the active Data-Host
    if not self.isDataHost and (self.localExeMarketName or "") ~= (self.onlineMarketName or "") then
        return nil
    end

    local baseFolder = self.settingsFolder or (getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/")

    if self.localCustomLogoFile ~= nil then
        local explicitPath = baseFolder .. self.localCustomLogoFile
        if fileExists(explicitPath) then
            return explicitPath
        end
    end

    if self.localHasCustomLogo then
        for _, candidate in ipairs(GlobalMarketBranding.DEFAULT_LOGO_CANDIDATES) do
            local candidatePath = baseFolder .. candidate
            if fileExists(candidatePath) then
                return candidatePath
            end
        end
    end

    return nil
end

---Refreshes the GlobalMarket menu header immediately if the frame is currently visible
function GlobalMarket:refreshBrandingUiIfOpen()
    local ui = self.ui or (g_currentMission ~= nil and g_currentMission.globalMarketUi or nil)
    if ui ~= nil and ui:getIsVisible() then
        GlobalMarketBranding.updateMenuHeader(ui, self)
    end
end

---Updates marketStatusTitle, marketStatusDesc, and marketCustomLogo on GlobalMarketUI
---@param ui table GlobalMarketUI controller instance
---@param gm table GlobalMarket instance
function GlobalMarketBranding.updateMenuHeader(ui, gm)
    if ui == nil or gm == nil then
        return
    end

    local isOnline = gm:getIsMarketOnline() or (gm.debugBrandingOverrideActive == true)
    local effectiveName = gm.debugBrandingOverrideActive and gm.debugBrandingMarketName or gm.onlineMarketName

    if ui.marketStatusTitle ~= nil and ui.marketStatusDesc ~= nil then
        if isOnline then
            if effectiveName ~= nil and effectiveName ~= "" then
                local fmt = ui.i18n:getText("ui_ingameMenuGlobalMarketOnlineCustom")
                ui.marketStatusTitle:setText(string.format(fmt, effectiveName))
                ui.marketStatusDesc:setText(ui.i18n:getText("ui_ingameMenuGlobalMarketOnlineCustomDesc"))
            else
                ui.marketStatusTitle:setText(ui.i18n:getText("ui_ingameMenuGlobalMarketOnline"))
                ui.marketStatusDesc:setText(ui.i18n:getText("ui_ingameMenuGlobalMarketOnlineDesc"))
            end
        else
            ui.marketStatusTitle:setText(ui.i18n:getText("ui_ingameMenuGlobalMarketOffline"))
            ui.marketStatusDesc:setText(ui.i18n:getText("ui_ingameMenuGlobalMarketOfflineDesc"))
        end
    end

    if ui.marketCustomLogo ~= nil then
        local logoPath = isOnline and gm:resolveLocalLogoFullPath() or nil
        if logoPath ~= nil then
            if gm.brandingLogoReloadPending or ui.loadedCustomLogoPath ~= logoPath then
                if gm.brandingLogoReloadPending and ui.marketCustomLogo.overlay ~= nil then
                    GuiOverlay.deleteOverlay(ui.marketCustomLogo.overlay)
                end
                ui.marketCustomLogo:setImageFilename(logoPath)
                ui.loadedCustomLogoPath = logoPath
                gm.brandingLogoReloadPending = false
            end

            local hasOverlay = ui.marketCustomLogo.overlay ~= nil
                and ui.marketCustomLogo.overlay.overlay ~= nil
                and ui.marketCustomLogo.overlay.overlay ~= 0
            ui.marketCustomLogo:setVisible(hasOverlay)
        else
            ui.marketCustomLogo:setVisible(false)
        end
    end
end

---Debug console command to preview all 3 online branding tiers ingame (requires GM Debug Mode)
function GlobalMarket:consoleCommandTestBranding(tierArg, nameOrLogoArg, logoArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end

    if tierArg == nil or tierArg == "" or tierArg == "off" or tierArg == "0" then
        self.debugBrandingOverrideActive = false
        self.debugBrandingMarketName = nil
        self.debugBrandingLogoPath = nil
        self.brandingLogoReloadPending = true
        self:refreshBrandingUiIfOpen()
        return "GM Branding Preview disabled (restored live market header)."
    end

    local tier = tonumber(tierArg)
    if tier ~= 1 and tier ~= 2 and tier ~= 3 then
        return "Usage: gmTestBranding <0|off | 1 [logoFile] | 2 [marketName] | 3 [marketName] [logoFile]>"
    end

    local baseFolder = self.settingsFolder or (getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/")
    local chosenLogoFile = (tier == 1) and nameOrLogoArg or logoArg
    local resolvedLogo = nil

    if tier == 1 or tier == 3 then
        local cleanRel = GlobalMarketBranding.sanitizeLogoRelPath(chosenLogoFile)
        if cleanRel ~= nil and fileExists(baseFolder .. cleanRel) then
            resolvedLogo = baseFolder .. cleanRel
        else
            for _, candidate in ipairs(GlobalMarketBranding.DEFAULT_LOGO_CANDIDATES) do
                if fileExists(baseFolder .. candidate) then
                    resolvedLogo = baseFolder .. candidate
                    break
                end
            end
            if resolvedLogo == nil then
                resolvedLogo = GlobalMarket.dir .. "icon_GM.dds"
            end
        end
    end

    self.debugBrandingOverrideActive = true
    self.debugBrandingMarketName = (tier == 2 or tier == 3)
        and (GlobalMarketBranding.sanitizeMarketName(nameOrLogoArg) or "WeekendFarmers")
        or nil
    self.debugBrandingLogoPath = resolvedLogo
    self.brandingLogoReloadPending = true
    self:refreshBrandingUiIfOpen()

    return string.format("GM Branding Preview Tier %d active (Market='%s', Logo='%s')",
        tier, tostring(self.debugBrandingMarketName or "Official"), tostring(resolvedLogo or "None"))
end

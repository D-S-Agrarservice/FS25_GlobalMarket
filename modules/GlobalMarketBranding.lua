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

---Applies branding from the promoted Data-Host connection state on the Server
---@param hostState table|nil Entry from self.clientExeStates[nextConn]
function GlobalMarket:applyDataHostBranding(hostState)
    local cleanName = (hostState ~= nil) and GlobalMarketBranding.sanitizeMarketName(hostState.marketName) or nil
    self.onlineMarketName = cleanName
    self.isPrivateOnlineMarket = (hostState ~= nil and hostState.isPrivateMarket == true) or (cleanName ~= nil)
end

---Updates server branding live if the active Data-Host changes its token/marketName mid-session
---@param connection any Active Data-Host connection key ("LOCAL_HOST" or MP Connection)
function GlobalMarket:updateActiveDataHostBranding(connection)
    local hostState = (self.clientExeStates ~= nil) and self.clientExeStates[connection] or nil
    local newName = (hostState ~= nil) and GlobalMarketBranding.sanitizeMarketName(hostState.marketName) or nil
    local newPriv = (hostState ~= nil and hostState.isPrivateMarket == true) or (newName ~= nil)

    if newName ~= self.onlineMarketName or newPriv ~= self.isPrivateOnlineMarket then
        self.onlineMarketName = newName
        self.isPrivateOnlineMarket = newPriv
        self:refreshBrandingUiIfOpen()
        -- Re-export server map whitelist so a newly selected market backend receives all active map fillTypes
        if connection == "LOCAL_HOST" then
            if self.receiveDataHostToken ~= nil then
                self:receiveDataHostToken(self.serverWhitelist)
            end
        elseif SyncMarketWhitelistEvent ~= nil and type(connection) == "table" and connection.sendEvent ~= nil then
            connection:sendEvent(SyncMarketWhitelistEvent.new(self.serverWhitelist, true))
        end
        if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    end
end

---Applies authoritative server branding received via MarketDataSyncEvent or SynchOfflineMarketEvent
---@param marketName string|nil
---@param isPrivateMarket boolean|nil
function GlobalMarket:applySyncedBranding(marketName, isPrivateMarket)
    local cleanName = GlobalMarketBranding.sanitizeMarketName(marketName)
    self.onlineMarketName = cleanName
    self.isPrivateOnlineMarket = (isPrivateMarket == true) or (cleanName ~= nil)
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

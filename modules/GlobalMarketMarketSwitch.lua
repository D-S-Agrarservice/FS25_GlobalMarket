-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketMarketSwitch.lua
-- In-game market switch (#38): the active Data-Host (in-game admin) selects one of the market
-- profiles saved in the local GlobalMarketClient. The mod only writes a request file; the
-- client switches and the existing heartbeat path updates header, whitelist and prices.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketMarketSwitch = {}

-- Button stays locked after a request (the client rate-limits as well)
GlobalMarketMarketSwitch.COOLDOWN_MS = 30000
-- Time the heartbeat has to report the requested market before an error is shown
GlobalMarketMarketSwitch.TIMEOUT_MS = 20000
GlobalMarketMarketSwitch.MAX_PROFILES = 32
GlobalMarketMarketSwitch.MAX_ID_LEN = 32

---Returns a lower-case hex profile id or nil
---@param rawId string|nil
---@return string|nil
local function sanitizeProfileId(rawId)
    if type(rawId) ~= "string" then
        return nil
    end
    local id = string.lower(string.match(rawId, "^%s*(.-)%s*$") or "")
    if id == "" or string.len(id) > GlobalMarketMarketSwitch.MAX_ID_LEN or string.find(id, "^%x+$") == nil then
        return nil
    end
    return id
end

---Resets all market switch state (called on init and when the client goes offline)
function GlobalMarket:clearMarketProfiles()
    self.marketSwitchSupported = false
    self.marketProfiles = {}
    self.marketProfilesActiveId = nil
end

---Reads the market profile list from globalMarketOnline.xml (written by GlobalMarketClient):
---<globalMarketOnline marketSwitchSupported="true"><marketProfiles activeId="..."><profile id label marketName /></marketProfiles>
---@param xmlFile table Loaded XMLFile instance for globalMarketOnline.xml
function GlobalMarket:readHeartbeatMarketProfiles(xmlFile)
    if xmlFile == nil then
        return
    end

    local supported = xmlFile:getBool("globalMarketOnline#marketSwitchSupported", false) == true
    local profiles = {}
    local activeId = nil
    if supported then
        activeId = sanitizeProfileId(xmlFile:getString("globalMarketOnline.marketProfiles#activeId"))
        xmlFile:iterate("globalMarketOnline.marketProfiles.profile", function(_, key)
            if #profiles >= GlobalMarketMarketSwitch.MAX_PROFILES then
                return false
            end
            local id = sanitizeProfileId(xmlFile:getString(key .. "#id"))
            if id ~= nil then
                table.insert(profiles, {
                    id = id,
                    label = GlobalMarketBranding.sanitizeMarketName(xmlFile:getString(key .. "#label")),
                    marketName = GlobalMarketBranding.sanitizeMarketName(xmlFile:getString(key .. "#marketName")),
                    brandingTier = xmlFile:getInt(key .. "#brandingTier")
                })
            end
            return true
        end)
    end

    self.marketSwitchSupported = supported
    self.marketProfiles = profiles
    self.marketProfilesActiveId = activeId

    -- Request confirmed: the heartbeat reports the requested market
    local pending = self.marketSwitchPending
    if pending ~= nil and pending.profileId == (activeId or "") then
        self.marketSwitchPending = nil
        if self.debugManager ~= nil then
            self.debugManager:info("MarketSwitch: Client confirmed market '%s'.", pending.profileId ~= "" and pending.profileId or "official")
        end
    end
end

---Returns true if the local player may switch the market from inside the game
---@return boolean
function GlobalMarket:getCanSwitchMarket()
    local mission = g_currentMission
    if mission == nil or g_dedicatedServer ~= nil then
        return false
    end
    if not (mission:getIsServer() or mission.isMasterUser) then
        return false
    end
    if not (self.isDataHost and self.isExeRunningLocal and self.hasBackendConnection) then
        return false
    end
    return self.marketSwitchSupported == true and self.marketProfiles ~= nil and #self.marketProfiles > 0
end

---Returns the remaining cooldown in milliseconds (0 = ready)
---@return number
function GlobalMarket:getMarketSwitchCooldownMs()
    if self.marketSwitchLastRequestTime == nil or g_time == nil then
        return 0
    end
    return math.max(0, GlobalMarketMarketSwitch.COOLDOWN_MS - (g_time - self.marketSwitchLastRequestTime))
end

---Writes write/marketSwitch_<date>_<seq>.xml for the local GlobalMarketClient
---@param profileId string Profile id, "" = official Global Market
---@return boolean success
function GlobalMarket:requestMarketSwitch(profileId)
    if not self:getCanSwitchMarket() or self:getMarketSwitchCooldownMs() > 0 or self.writeFolder == nil then
        return false
    end

    self.marketSwitchCounter = (self.marketSwitchCounter or 0) + 1
    local xmlPath = string.format("%smarketSwitch_%s_%d.xml", self.writeFolder, getDate("%Y%m%d_%H%M%S"), self.marketSwitchCounter)
    local xmlFile = XMLFile.create("gmMarketSwitch", xmlPath, "gmDataSync")
    if xmlFile == nil then
        return false
    end
    xmlFile:setString("gmDataSync#action", "selectMarket")
    xmlFile:setString("gmDataSync#profileId", profileId or "")
    xmlFile:save()
    xmlFile:delete()

    self.marketSwitchLastRequestTime = g_time
    self.marketSwitchPending = { profileId = profileId or "", startTime = g_time }
    if self.debugManager ~= nil then
        self.debugManager:info("MarketSwitch: Requested market '%s'.", (profileId ~= nil and profileId ~= "") and profileId or "official")
    end
    return true
end

---Shows a market switch error as dialog while the menu is open, otherwise in the HUD
---@param text string
local function showSwitchError(text)
    if GlobalMarket.showResultInMarketMenu ~= nil and GlobalMarket.showResultInMarketMenu(text) then
        return
    end
    if g_currentMission ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
    end
end

---Per-frame tick: reports a request the client did not confirm in time
---@param dt number
function GlobalMarket:updateMarketSwitch(dt)
    local pending = self.marketSwitchPending
    if pending == nil or g_time == nil then
        return
    end
    if g_time - pending.startTime > GlobalMarketMarketSwitch.TIMEOUT_MS then
        self.marketSwitchPending = nil
        if self.debugManager ~= nil then
            self.debugManager:warning("MarketSwitch: Client did not confirm market '%s' within %d ms.", pending.profileId, GlobalMarketMarketSwitch.TIMEOUT_MS)
        end
        showSwitchError(g_i18n:getText("ui_gm_marketSwitch_timeout"))
    end
end

-- =========================================================================
-- MENU (spot market toolbar)
-- =========================================================================

---Returns the display text of a profile for the selection dialog
---@param profile table
---@return string
local function getProfileText(profile)
    local name = profile.label or profile.marketName
        or string.format(g_i18n:getText("ui_gm_marketSwitch_profileFallback"), profile.id)
    -- No branding tier yet = the client never completed a handshake with this profile
    if profile.brandingTier == nil and profile.marketName == nil then
        name = string.format(g_i18n:getText("ui_gm_marketSwitch_notConnected"), name)
    end
    return name
end

---Updates visibility and cooldown text of the market switch button
---@param frame table GlobalMarketUI
function GlobalMarketMarketSwitch.updateButton(frame)
    local button = frame.btnMarketSwitch
    local gm = (g_currentMission ~= nil) and g_currentMission.globalMarket or nil
    if button == nil then
        return
    end

    local canSwitch = gm ~= nil and gm:getCanSwitchMarket()
    if button.visible ~= canSwitch then
        button:setVisible(canSwitch)
    end
    if not canSwitch then
        return
    end

    local remainingMs = gm:getMarketSwitchCooldownMs()
    local text
    if remainingMs > 0 then
        text = string.format(g_i18n:getText("ui_gm_marketSwitch_buttonCooldown"), math.ceil(remainingMs / 1000))
    else
        text = g_i18n:getText("ui_gm_marketSwitch_button")
    end
    if frame.marketSwitchButtonText ~= text then
        frame.marketSwitchButtonText = text
        button:setText(text)
        button:setDisabled(remainingMs > 0)
    end
end

---Toolbar button: opens the market selection
function GlobalMarketUI:onClickMarketSwitch()
    local gm = g_currentMission.globalMarket
    if gm == nil or not gm:getCanSwitchMarket() or gm:getMarketSwitchCooldownMs() > 0 then
        return
    end

    -- Option 1 = official Global Market, then one entry per saved profile
    local ids = { "" }
    local texts = { g_i18n:getText("ui_gm_marketSwitch_official") }
    for _, profile in ipairs(gm.marketProfiles) do
        table.insert(ids, profile.id)
        table.insert(texts, getProfileText(profile))
    end
    local activeIndex = 1
    for i, id in ipairs(ids) do
        if id == (gm.marketProfilesActiveId or "") then
            activeIndex = i
            texts[i] = string.format(g_i18n:getText("ui_gm_marketSwitch_active"), texts[i])
        end
    end

    OptionDialog.show(function(state)
        local profileId = ids[state]
        if profileId == nil or state == activeIndex then
            return
        end
        local isMultiplayer = g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer
        if not isMultiplayer then
            if not gm:requestMarketSwitch(profileId) then
                showSwitchError(g_i18n:getText("ui_gm_marketSwitch_failed"))
            end
            return
        end
        local targetName = (profileId == "") and texts[1] or texts[state]
        YesNoDialog.show(function(yes)
            if yes and not gm:requestMarketSwitch(profileId) then
                showSwitchError(g_i18n:getText("ui_gm_marketSwitch_failed"))
            end
        end, nil, string.format(g_i18n:getText("ui_gm_marketSwitch_confirmMp"), targetName),
            g_i18n:getText("ui_gm_marketSwitch_title"))
    end, g_i18n:getText("ui_gm_marketSwitch_text"), g_i18n:getText("ui_gm_marketSwitch_title"), texts, activeIndex)
end

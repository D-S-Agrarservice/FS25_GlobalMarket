-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketServerNotice.lua
-- Maintenance, restart and info notices of the backend (#41, spec section 3.1.3), read from the
-- heartbeat of the companion client (0.9.16+). Shown once per notice plus a reminder 10 minutes
-- before the start, and as "maintenance" instead of "offline" in the market menu. The active
-- Data-Host shares the notice with the server, so players without a client see it too.
-- All times are relative: os.time() is not available, the file carries its own timestamp.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketServerNotice = {}

GlobalMarketServerNotice.TYPE_MAINTENANCE = "maintenance"
GlobalMarketServerNotice.TYPE_RESTART = "restart"
GlobalMarketServerNotice.TYPE_INFO = "info"
GlobalMarketServerNotice.REASON_MAINTENANCE = "maintenance"

GlobalMarketServerNotice.MAX_ID_LENGTH = 64
GlobalMarketServerNotice.MAX_MESSAGE_BYTES = 120
GlobalMarketServerNotice.MAX_SECONDS = 31 * 24 * 3600
GlobalMarketServerNotice.REMINDER_SEC = 600
-- Same windows as the client: an outage counts as maintenance from 5 min before the start,
-- a notice expires 30 min after its end
GlobalMarketServerNotice.EARLY_SEC = 300
GlobalMarketServerNotice.EXPIRE_SEC = 1800
GlobalMarketServerNotice.DEFAULT_RESTART_SEC = 600
GlobalMarketServerNotice.DEFAULT_MAINTENANCE_SEC = 21600
GlobalMarketServerNotice.DISPLAY_MS = 15000

-- =========================================================================
-- NOTICE DATA
-- =========================================================================

---Cleans a text of the backend: no control characters, limited, never cut inside a character
---@param rawText string|nil
---@param maxBytes number
---@return string clean "" if empty
local function sanitizeText(rawText, maxBytes)
    if type(rawText) ~= "string" then
        return ""
    end
    local clean = string.gsub(rawText, "%c+", " ")
    clean = string.gsub(clean, "%s+", " ")
    if string.len(clean) > maxBytes then
        clean = string.sub(clean, 1, maxBytes)
        clean = string.gsub(clean, "[\192-\255][\128-\191]*$", "")
    end
    clean = string.gsub(clean, "^%s+", "")
    clean = string.gsub(clean, "%s+$", "")
    return clean
end

---Limits a relative time
---@param seconds number|nil
---@return number|nil
local function clampSeconds(seconds)
    if seconds == nil then
        return nil
    end
    local limit = GlobalMarketServerNotice.MAX_SECONDS
    return math.max(-limit, math.min(limit, seconds))
end

---Builds a notice, nil if the id is missing. Unknown types are treated like an info.
---@param data table id, type, startsIn, endsIn (seconds from now, optional), message
---@return table|nil notice
function GlobalMarketServerNotice.create(data)
    local N = GlobalMarketServerNotice
    local id = sanitizeText(data.id, N.MAX_ID_LENGTH)
    if id == "" then
        return nil
    end
    local noticeType = string.lower(tostring(data.type or ""))
    if noticeType ~= N.TYPE_MAINTENANCE and noticeType ~= N.TYPE_RESTART then
        noticeType = N.TYPE_INFO
    end
    return {
        id = id,
        type = noticeType,
        startsIn = clampSeconds(data.startsIn),
        endsIn = clampSeconds(data.endsIn),
        message = sanitizeText(data.message, N.MAX_MESSAGE_BYTES),
        readAtMs = g_time or 0
    }
end

---Returns true for notices that announce a downtime
---@param notice table
---@return boolean
function GlobalMarketServerNotice.getIsDowntime(notice)
    return notice.type ~= GlobalMarketServerNotice.TYPE_INFO
end

---Returns the seconds until start and end (negative = past, nil = unknown)
---@param notice table
---@return number|nil startsIn
---@return number|nil endsIn
function GlobalMarketServerNotice.getTimes(notice)
    local elapsed = ((g_time or 0) - (notice.readAtMs or 0)) / 1000
    return notice.startsIn ~= nil and notice.startsIn - elapsed or nil, notice.endsIn ~= nil and notice.endsIn - elapsed or nil
end

---Returns true if a notice is over
---@param notice table
---@return boolean
function GlobalMarketServerNotice.getIsExpired(notice)
    local N = GlobalMarketServerNotice
    local startsIn, endsIn = N.getTimes(notice)
    if endsIn == nil then
        if not N.getIsDowntime(notice) or startsIn == nil then
            -- Without an end it lasts as long as it is reported (readAtMs is renewed with every heartbeat)
            return (g_time or 0) - (notice.readAtMs or 0) > N.DEFAULT_MAINTENANCE_SEC * 1000
        end
        endsIn = startsIn + (notice.type == N.TYPE_RESTART and N.DEFAULT_RESTART_SEC or N.DEFAULT_MAINTENANCE_SEC - N.EXPIRE_SEC)
    end
    return endsIn + N.EXPIRE_SEC <= 0
end

-- =========================================================================
-- TEXTS
-- =========================================================================

---Returns a localized duration ("45 min", "1 h 30 min")
---@param seconds number
---@return string
function GlobalMarketServerNotice.formatDuration(seconds)
    local minutes = math.max(1, math.ceil(seconds / 60))
    if minutes < 60 then
        return string.format(g_i18n:getText("ui_gm_notice_minutes"), minutes)
    end
    local hours = math.floor(minutes / 60)
    minutes = minutes % 60
    if minutes == 0 then
        return string.format(g_i18n:getText("ui_gm_notice_hours"), hours)
    end
    return string.format(g_i18n:getText("ui_gm_notice_hoursMinutes"), hours, minutes)
end

---Returns the localized text of a notice (nil = nothing to show)
---@param notice table
---@return string|nil
function GlobalMarketServerNotice.getText(notice)
    local N = GlobalMarketServerNotice
    if not N.getIsDowntime(notice) then
        return notice.message ~= "" and string.format(g_i18n:getText("ui_gm_notice_info"), notice.message) or nil
    end
    local startsIn, endsIn = N.getTimes(notice)
    local isPlanned = startsIn ~= nil and startsIn > 0
    local text
    if notice.type == N.TYPE_RESTART then
        text = isPlanned and string.format(g_i18n:getText("ui_gm_notice_restart"), N.formatDuration(startsIn))
            or g_i18n:getText("ui_gm_notice_restartActive")
    elseif isPlanned and endsIn ~= nil and endsIn > startsIn then
        text = string.format(g_i18n:getText("ui_gm_notice_maintenanceDuration"), N.formatDuration(startsIn), N.formatDuration(endsIn - startsIn))
    elseif isPlanned then
        text = string.format(g_i18n:getText("ui_gm_notice_maintenance"), N.formatDuration(startsIn))
    elseif endsIn ~= nil and endsIn > 0 then
        text = string.format(g_i18n:getText("ui_gm_notice_maintenanceActiveTime"), N.formatDuration(endsIn))
    else
        text = g_i18n:getText("ui_gm_notice_maintenanceActive")
    end
    if notice.message ~= "" then
        text = string.format("%s (%s)", text, notice.message)
    end
    return text
end

-- =========================================================================
-- HEARTBEAT (player PC with a companion client)
-- =========================================================================

---Reads serverNotice and offlineReason from globalMarketOnline.xml
---@param xmlFile table
---@param timestamp number Unix seconds the file was written at
---@param isActive boolean the client is running (the timestamp advances)
function GlobalMarket:readHeartbeatNotice(xmlFile, timestamp, isActive)
    if not isActive then
        self:clearHeartbeatNotice()
        return
    end
    -- Only set while the client has no backend connection; unknown reasons stay without effect
    local isConnected = xmlFile:getBool("globalMarketOnline#isConnected", true)
    self.localOfflineReason = not isConnected and xmlFile:getString("globalMarketOnline#offlineReason") or nil

    local key = "globalMarketOnline.serverNotice"
    local id = xmlFile:getString(key .. "#id")
    if id == nil then
        self.localServerNotice = nil
        return
    end
    local startsAt, endsAt = xmlFile:getInt(key .. "#startsAt"), xmlFile:getInt(key .. "#endsAt")
    local noticeType, message = xmlFile:getString(key .. "#type"), xmlFile:getString(key .. "#message")
    self.localServerNotice = GlobalMarketServerNotice.create({
        id = id,
        type = noticeType,
        startsIn = startsAt ~= nil and startsAt - timestamp or nil,
        endsIn = endsAt ~= nil and endsAt - timestamp or nil,
        message = message
    })
    if self.localServerNotice ~= nil then
        self.localServerNotice.signature = string.format("%s|%s|%s|%s|%s", id, tostring(noticeType), tostring(startsAt), tostring(endsAt), tostring(message))
    end
end

---Forgets the notice of the local client (not running any more)
function GlobalMarket:clearHeartbeatNotice()
    self.localServerNotice = nil
    self.localOfflineReason = nil
end

-- =========================================================================
-- MULTIPLAYER
-- =========================================================================

---Server: stores the notice of the active Data-Host and informs all clients
---@param notice table|nil nil = no notice any more
function GlobalMarket:setSyncedServerNotice(notice)
    if g_server == nil then
        return
    end
    self.syncedServerNotice = notice
    if ServerNoticeEvent ~= nil then
        g_server:broadcastEvent(ServerNoticeEvent.new(notice))
    end
end

---Active Data-Host: hands a new or changed notice to the server
function GlobalMarket:shareServerNotice()
    if not self.isDataHost then
        self.sharedNoticeSignature = nil
        return
    end
    local notice = self.localServerNotice
    local signature = notice ~= nil and notice.signature or nil
    if signature == self.sharedNoticeSignature then
        return
    end
    self.sharedNoticeSignature = signature
    if g_server ~= nil then
        self:setSyncedServerNotice(notice)
    elseif g_client ~= nil and ServerNoticeEvent ~= nil then
        g_client:getServerConnection():sendEvent(ServerNoticeEvent.new(notice))
    end
end

-- =========================================================================
-- DISPLAY
-- =========================================================================

---Returns the notice to show: own client first, then the one shared by the Data-Host
---@return table|nil
function GlobalMarket:getServerNotice()
    local notice = self.debugServerNotice or self.localServerNotice or self.syncedServerNotice
    if notice ~= nil and GlobalMarketServerNotice.getIsExpired(notice) then
        return nil
    end
    return notice
end

---Returns true while the backend is down for maintenance
---@return boolean
function GlobalMarket:getIsMaintenanceActive()
    if self.debugMaintenance then
        return true
    end
    if self:getIsMarketOnline() then
        return false
    end
    if self.isExeRunningLocal then
        -- The own client knows best (e.g. "unreachable" outside the announced window)
        return self.localOfflineReason == GlobalMarketServerNotice.REASON_MAINTENANCE
    end
    local notice = self.syncedServerNotice
    if notice == nil or not GlobalMarketServerNotice.getIsDowntime(notice) or GlobalMarketServerNotice.getIsExpired(notice) then
        return false
    end
    local startsIn = GlobalMarketServerNotice.getTimes(notice)
    return startsIn ~= nil and startsIn <= GlobalMarketServerNotice.EARLY_SEC
end

---Returns title and description for the market menu header during maintenance
---@return string|nil title
---@return string|nil description
function GlobalMarket:getMaintenanceHeader()
    if not self:getIsMaintenanceActive() then
        return nil, nil
    end
    local remaining
    local notice = self:getServerNotice()
    if notice ~= nil and GlobalMarketServerNotice.getIsDowntime(notice) then
        local startsIn, endsIn = GlobalMarketServerNotice.getTimes(notice)
        if endsIn == nil and startsIn ~= nil and notice.type == GlobalMarketServerNotice.TYPE_RESTART then
            endsIn = startsIn + GlobalMarketServerNotice.DEFAULT_RESTART_SEC
        end
        remaining = endsIn
    end
    local description = g_i18n:getText("ui_gm_notice_headerDesc")
    if remaining ~= nil and remaining > 0 then
        description = string.format(g_i18n:getText("ui_gm_notice_headerDescTime"), GlobalMarketServerNotice.formatDuration(remaining))
    end
    return g_i18n:getText("ui_gm_notice_headerTitle"), description
end

---Shows a new notice once, and a reminder shortly before a downtime starts
---@param notice table
function GlobalMarket:showServerNotice(notice)
    -- Hidden behind a menu: shown as soon as the player is back in the game
    if g_currentMission.hud == nil or g_currentMission.hud.addSideNotification == nil or g_gui:getIsGuiVisible() then
        return
    end
    self.shownServerNotices = self.shownServerNotices or {}
    local shown = self.shownServerNotices[notice.id]
    local startsIn = GlobalMarketServerNotice.getTimes(notice)
    local isReminderDue = GlobalMarketServerNotice.getIsDowntime(notice)
        and (startsIn == nil or startsIn <= GlobalMarketServerNotice.REMINDER_SEC)
    if shown ~= nil and (shown.isReminded or not isReminderDue) then
        return
    end
    self.shownServerNotices[notice.id] = { isReminded = isReminderDue }
    local text = GlobalMarketServerNotice.getText(notice)
    if text ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_INFO or { 1, 1, 1, 1 }, text, GlobalMarketServerNotice.DISPLAY_MS)
        if self.debugManager ~= nil then
            self.debugManager:info("ServerNotice: %s", text)
        end
    end
end

---Per-frame tick, works once per second
---@param dt number
function GlobalMarket:updateServerNotice(dt)
    self.serverNoticeTimerMs = (self.serverNoticeTimerMs or 0) + (dt or 0)
    if self.serverNoticeTimerMs < 1000 then
        return
    end
    self.serverNoticeTimerMs = 0
    if self.syncedServerNotice ~= nil and GlobalMarketServerNotice.getIsExpired(self.syncedServerNotice) then
        self.syncedServerNotice = nil
    end
    if g_dedicatedServer ~= nil or g_currentMission == nil or not g_currentMission.isMissionStarted then
        return
    end
    self:shareServerNotice()

    local notice = self:getServerNotice()
    if notice ~= nil then
        self:showServerNotice(notice)
    end
    -- Header of the open market menu: maintenance begins, ends or counts down
    local _, description = self:getMaintenanceHeader()
    if description ~= self.shownMaintenanceText then
        self.shownMaintenanceText = description
        if self.refreshBrandingUiIfOpen ~= nil then
            self:refreshBrandingUiIfOpen()
        end
    end
end

-- =========================================================================
-- DEBUG CONSOLE
-- =========================================================================

---Console: shows a notice without backend and client (GM debug mode)
---@param typeArg string planned [minutes] [duration] | restart [minutes] | info [text] | maintenance [minutes left] | off
function GlobalMarket:consoleCommandTestNotice(typeArg, valueArg, durationArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    local N = GlobalMarketServerNotice
    local arg = string.lower(tostring(typeArg or ""))
    local value = tonumber(valueArg)
    self.debugNoticeCounter = (self.debugNoticeCounter or 0) + 1
    local id = "debug-" .. self.debugNoticeCounter
    self.debugServerNotice, self.debugMaintenance = nil, nil
    if arg == "planned" then
        local start = (value or 45) * 60
        self.debugServerNotice = N.create({ id = id, type = N.TYPE_MAINTENANCE, startsIn = start, endsIn = start + (tonumber(durationArg) or 60) * 60, message = "Test" })
    elseif arg == "restart" then
        self.debugServerNotice = N.create({ id = id, type = N.TYPE_RESTART, startsIn = (value or 5) * 60 })
    elseif arg == "info" then
        self.debugServerNotice = N.create({ id = id, type = N.TYPE_INFO, message = valueArg or "Test" })
    elseif arg == "maintenance" then
        self.debugServerNotice = N.create({ id = id, type = N.TYPE_MAINTENANCE, startsIn = -60, endsIn = (value or 30) * 60 })
        self.debugMaintenance = true
    elseif arg ~= "off" then
        return "Usage: gmTestNotice planned [minutes] [duration] | restart [minutes] | info [text] | maintenance [minutes left] | off"
    end
    return "GM notice test: " .. arg .. " (close the console and menus to see it, 'off' restores the live state)."
end

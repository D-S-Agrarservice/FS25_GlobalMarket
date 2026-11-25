-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketWarningEvent.lua
-- Server -> clients: shows a critical ingame notification from a GlobalMarket l10n key
-- (e.g. "restart required" after the server picked up a newer mod compatibility list).
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketWarningEvent = {}
local GlobalMarketWarningEvent_mt = Class(GlobalMarketWarningEvent, Event)
InitEventClass(GlobalMarketWarningEvent, "GlobalMarketWarningEvent")

function GlobalMarketWarningEvent.emptyNew()
    return Event.new(GlobalMarketWarningEvent_mt)
end

---@param textKey string l10n key (ui_gm_*)
function GlobalMarketWarningEvent.new(textKey)
    local self = GlobalMarketWarningEvent.emptyNew()
    self.textKey = textKey or ""
    return self
end

---Server: sends the warning to all clients and shows it on a listen host
---@param textKey string
function GlobalMarketWarningEvent.broadcast(textKey)
    if g_server ~= nil then
        g_server:broadcastEvent(GlobalMarketWarningEvent.new(textKey))
    end
    GlobalMarketWarningEvent.show(textKey)
end

---Client/host: shows the warning as a critical ingame notification
---@param textKey string
function GlobalMarketWarningEvent.show(textKey)
    if g_dedicatedServer ~= nil or g_currentMission == nil or g_i18n == nil then
        return
    end
    if string.sub(textKey or "", 1, 6) ~= "ui_gm_" or not g_i18n:hasText(textKey) then
        return
    end
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, g_i18n:getText(textKey))
end

function GlobalMarketWarningEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.textKey or "")
end

function GlobalMarketWarningEvent:readStream(streamId, connection)
    self.textKey = streamReadString(streamId)
    self:run(connection)
end

function GlobalMarketWarningEvent:run(connection)
    -- Warnings come from the server only
    if connection:getIsServer() then
        GlobalMarketWarningEvent.show(self.textKey)
    end
end

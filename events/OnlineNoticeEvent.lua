-- =========================================================================================
-- FS25_GlobalMarket - OnlineNoticeEvent.lua
-- Server -> clients: the backend rejected an own online contract request (#42).
-- Carries only the target farm and the reason code; clients show the localized text.
-- Author: D-S-Agrarservice
-- =========================================================================================

OnlineNoticeEvent = {}
local OnlineNoticeEvent_mt = Class(OnlineNoticeEvent, Event)
InitEventClass(OnlineNoticeEvent, "OnlineNoticeEvent")

function OnlineNoticeEvent.emptyNew()
    return Event.new(OnlineNoticeEvent_mt)
end

---@param targetFarmId number 0 = all farms
---@param reason string backend reason code
function OnlineNoticeEvent.new(targetFarmId, reason)
    local self = OnlineNoticeEvent.emptyNew()
    self.targetFarmId = targetFarmId or 0
    self.reason = reason or ""
    return self
end

function OnlineNoticeEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.targetFarmId or 0, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteString(streamId, self.reason or "")
end

function OnlineNoticeEvent:readStream(streamId, connection)
    self.targetFarmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.reason = streamReadString(streamId)
    self:run(connection)
end

function OnlineNoticeEvent:run(connection)
    -- Notices come from the server only
    if not connection:getIsServer() then
        return
    end
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm ~= nil and gm.showOnlineNotice ~= nil then
        gm:showOnlineNotice(self.targetFarmId, self.reason)
    end
end

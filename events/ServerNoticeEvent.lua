-- =========================================================================================
-- FS25_GlobalMarket - ServerNoticeEvent.lua
-- Maintenance notice of the backend (#41): active Data-Host -> server -> all clients.
-- Times are sent as seconds from now, every side keeps its own clock.
-- Author: D-S-Agrarservice
-- =========================================================================================

ServerNoticeEvent = {}
local ServerNoticeEvent_mt = Class(ServerNoticeEvent, Event)
InitEventClass(ServerNoticeEvent, "ServerNoticeEvent")

function ServerNoticeEvent.emptyNew()
    return Event.new(ServerNoticeEvent_mt)
end

---@param notice table|nil nil = no notice any more
function ServerNoticeEvent.new(notice)
    local self = ServerNoticeEvent.emptyNew()
    self.notice = notice
    return self
end

---@param streamId number
---@param seconds number|nil
local function writeSeconds(streamId, seconds)
    streamWriteBool(streamId, seconds ~= nil)
    if seconds ~= nil then
        streamWriteInt32(streamId, math.floor(seconds + 0.5))
    end
end

---@param streamId number
---@return number|nil seconds
local function readSeconds(streamId)
    if streamReadBool(streamId) then
        return streamReadInt32(streamId)
    end
    return nil
end

function ServerNoticeEvent:writeStream(streamId, connection)
    local notice = self.notice
    streamWriteBool(streamId, notice ~= nil)
    if notice == nil then
        return
    end
    local startsIn, endsIn = GlobalMarketServerNotice.getTimes(notice)
    streamWriteString(streamId, notice.id)
    streamWriteString(streamId, notice.type)
    writeSeconds(streamId, startsIn)
    writeSeconds(streamId, endsIn)
    streamWriteString(streamId, notice.message)
end

function ServerNoticeEvent:readStream(streamId, connection)
    if streamReadBool(streamId) then
        local id = streamReadString(streamId)
        local noticeType = streamReadString(streamId)
        local startsIn = readSeconds(streamId)
        local endsIn = readSeconds(streamId)
        local message = streamReadString(streamId)
        self.notice = GlobalMarketServerNotice.create({ id = id, type = noticeType, startsIn = startsIn, endsIn = endsIn, message = message })
    end
    self:run(connection)
end

function ServerNoticeEvent:run(connection)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return
    end
    if connection:getIsServer() then
        gm.syncedServerNotice = self.notice
    elseif gm.dataHostConnection == connection then
        -- Only the active Data-Host may announce something to all players
        gm:setSyncedServerNotice(self.notice)
    end
end

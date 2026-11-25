-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketServerIdentity.lua
-- Savegame credential for the shared online pool (#42): the backend issues a secret once per
-- serverInstanceId. The server stores it in the savegame and hands it only to the active
-- Data-Host, which adds it to every contractAction / vehicleAction request. Also turns backend
-- rejection reasons of own online contract requests into HUD notices for the affected farm.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketServerIdentity = {}

GlobalMarketServerIdentity.MAX_SECRET_LENGTH = 256
GlobalMarketServerIdentity.REASON_SECRET_INVALID = "SERVER_SECRET_INVALID"
-- Mod-side reason: the online market cannot be reached right now
GlobalMarketServerIdentity.REASON_OFFLINE = "OFFLINE"
-- The backend repeats action results for 10 minutes: one savegame-wide identity notice per window
GlobalMarketServerIdentity.IDENTITY_NOTICE_COOLDOWN_MS = 600000

-- Backend rejection reason -> l10n suffix (ui_gm_online_reason_<suffix>)
GlobalMarketServerIdentity.REASON_TEXT = {
    SERVER_SECRET_INVALID = "identityRejected",
    FILLTYPE_NOT_GLOBAL_APPROVED = "notApproved",
    LIMIT_REACHED = "limitReached",
    ALREADY_ACCEPTED = "alreadyAccepted",
    EXPIRED = "expired",
    OFFER_SOLD_OUT = "soldOut",
    INSUFFICIENT_LITERS = "insufficientLiters",
    OWN_LISTING = "ownListing",
    NOT_FOUND = "notAvailable",
    NOT_OPEN = "notAvailable",
    NOT_ACTIVE = "notAvailable",
    ALREADY_DELIVERED = "notAvailable",
    OFFLINE = "offline"
}

-- Own player requests whose rejection the farm should see (REQUEST_SYNC / ACK_SETTLEMENT stay silent)
GlobalMarketServerIdentity.NOTICE_SUB_ACTIONS = {
    CREATE_CONTRACT = true,
    CANCEL_CONTRACT = true,
    ACCEPT_CONTRACT = true,
    DELIVER_CONTRACT = true,
    CREATE_OFFER = true,
    CANCEL_OFFER = true,
    BUY_OFFER = true
}

---Returns true for a plausible backend secret (opaque token, no markup or whitespace)
---@param secret any
---@return boolean
function GlobalMarketServerIdentity.isValidSecret(secret)
    return type(secret) == "string" and secret ~= ""
        and #secret <= GlobalMarketServerIdentity.MAX_SECRET_LENGTH
        and string.find(secret, "^[%w%-_%.~%+/=]+$") ~= nil
end

---Reads <serverIdentity serverId="..." serverSecret="..."/> under the root of a sync file
---@param xmlFile table
---@return table|nil identity { serverId, serverSecret }
function GlobalMarketServerIdentity.readXml(xmlFile)
    local key = "gmDataSync.serverIdentity"
    if xmlFile == nil or not xmlFile:hasProperty(key) then
        return nil
    end
    local serverId = xmlFile:getString(key .. "#serverId") or ""
    local secret = xmlFile:getString(key .. "#serverSecret") or ""
    if serverId == "" or not GlobalMarketServerIdentity.isValidSecret(secret) then
        return nil
    end
    return { serverId = serverId, serverSecret = secret }
end

---Writes an optional identity into a Data-Host -> server relay packet
---@param streamId number
---@param identity table|nil
function GlobalMarketServerIdentity.writeStream(streamId, identity)
    streamWriteBool(streamId, identity ~= nil)
    if identity ~= nil then
        streamWriteString(streamId, identity.serverId or "")
        streamWriteString(streamId, identity.serverSecret or "")
    end
end

---Reads an optional identity written by writeStream
---@param streamId number
---@return table|nil identity
function GlobalMarketServerIdentity.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    return { serverId = streamReadString(streamId), serverSecret = streamReadString(streamId) }
end

---Server: the secret to send with outgoing actions ("" until the backend issued one)
---@return string
function GlobalMarket:getServerSecret()
    if g_server ~= nil and GlobalMarketServerIdentity.isValidSecret(self.serverSecret) then
        return self.serverSecret
    end
    return ""
end

---Server: stores a secret issued by the backend for this savegame (overwrites an older one)
---@param identity table|nil { serverId, serverSecret }
---@return boolean stored
function GlobalMarket:applyServerIdentity(identity)
    if g_server == nil or identity == nil then
        return false
    end
    if not self:isOwnOnlineServer(identity.serverId) or not GlobalMarketServerIdentity.isValidSecret(identity.serverSecret) then
        if self.debugManager ~= nil then
            self.debugManager:warning("ServerIdentity: Ignored an online credential that does not belong to this savegame.")
        end
        return false
    end
    if self.serverSecret == identity.serverSecret then
        return false
    end
    self.serverSecret = identity.serverSecret
    if self.debugManager ~= nil then
        self.debugManager:info("ServerIdentity: Stored the online credential issued for this savegame.")
    end
    return true
end

---Returns the localized text of a backend rejection reason
---@param reason string|nil
---@return string
function GlobalMarket.getOnlineReasonText(reason)
    local suffix = GlobalMarketServerIdentity.REASON_TEXT[reason or ""]
    local key = (suffix ~= nil) and ("ui_gm_online_reason_" .. suffix) or nil
    if key == nil or not g_i18n:hasText(key) then
        key = "ui_gm_vehicles_reason_onlineRejected"
    end
    return g_i18n:getText(key)
end

---Server: farm of the own pending request a contract action result answers (nil = no notice)
---Entries are matched by actionId only, so repeated results of an already handled request stay silent.
---@param res table action result
---@return number|nil farmId
function GlobalMarket:getOnlineResultFarmId(res)
    local sub = res.subAction
    if sub == "ACCEPT_CONTRACT" or sub == "BUY_OFFER" or sub == "DELIVER_CONTRACT" then
        local pending = (self.pendingContractActions or {})[res.actionId]
        return pending ~= nil and pending.farmId or nil
    end
    local isOffer = (sub == "CREATE_OFFER" or sub == "CANCEL_OFFER")
    local list = isOffer and self.directOffers or self.contracts
    local _, entry = GlobalMarketContracts.findOnlineEntry(list, res.actionId, nil)
    if entry == nil then
        return nil
    end
    return isOffer and entry.sellerFarmId or entry.issuerFarmId
end

---Server: tells the farm why the backend rejected its online contract request
---@param res table action result (status ~= ACCEPTED)
---@param farmId number|nil farm of the request (from getOnlineResultFarmId)
function GlobalMarket:notifyOnlineContractRejected(res, farmId)
    if g_server == nil or res == nil then
        return
    end
    local isIdentity = (res.reason == GlobalMarketServerIdentity.REASON_SECRET_INVALID)
    if isIdentity and self.debugManager ~= nil then
        self.debugManager:warning("ServerIdentity: The backend rejected this savegame's online credential (%s). Support can reset it.",
            tostring(res.subAction))
    end
    if GlobalMarketServerIdentity.NOTICE_SUB_ACTIONS[res.subAction] and (farmId or 0) > 0 then
        self:broadcastOnlineNotice(farmId, res.reason or "")
    elseif isIdentity then
        self:notifyOnlineIdentityRejected()
    end
end

---Server: savegame-wide notice for a rejected credential (all farms, rate-limited)
function GlobalMarket:notifyOnlineIdentityRejected()
    if g_server == nil then
        return
    end
    local now = g_time or 0
    if self.lastIdentityNoticeMs ~= nil and (now - self.lastIdentityNoticeMs) < GlobalMarketServerIdentity.IDENTITY_NOTICE_COOLDOWN_MS then
        return
    end
    self.lastIdentityNoticeMs = now
    self:broadcastOnlineNotice(0, GlobalMarketServerIdentity.REASON_SECRET_INVALID)
end

---Server: sends a rejection notice to all clients (they filter by farm) and shows it on the host
---@param targetFarmId number 0 = all farms
---@param reason string
function GlobalMarket:broadcastOnlineNotice(targetFarmId, reason)
    if g_server ~= nil and OnlineNoticeEvent ~= nil then
        g_server:broadcastEvent(OnlineNoticeEvent.new(targetFarmId, reason))
    end
    self:showOnlineNotice(targetFarmId, reason)
end

---Client/host: shows a rejection notice if it concerns the local farm
---@param targetFarmId number 0 = all farms
---@param reason string
function GlobalMarket:showOnlineNotice(targetFarmId, reason)
    if g_dedicatedServer ~= nil or g_currentMission == nil or g_currentMission.hud == nil then
        return
    end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end
    if (targetFarmId or 0) > 0 and farmId ~= targetFarmId then
        return
    end
    local text = GlobalMarket.getOnlineReasonText(reason)
    -- The HUD is hidden behind the menu: show the reason where the player is
    if GlobalMarket.showResultInMarketMenu ~= nil and GlobalMarket.showResultInMarketMenu(text) then
        return
    end
    if g_currentMission.hud.addSideNotification ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL or { 1, 1, 1, 1 }, text, 8000)
    end
end

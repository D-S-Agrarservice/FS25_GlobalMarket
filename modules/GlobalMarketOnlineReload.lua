-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketOnlineReload.lua
-- Online listings after loading an older savegame (game left without saving, crash). The
-- backend keeps what happened online, the savegame may not know it:
-- * listing online, no escrow here: the money, goods or vehicle never left this savegame, so
--   the listing is withdrawn and neither its sales nor its return are booked.
-- * escrow here, listing not online any more: the backend is asked, and the escrow comes back
--   if the listing was withdrawn before the older savegame was loaded.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketOnlineReload = {}

-- Time before a listing that is missing on one side is acted on, and between repeated requests
GlobalMarketOnlineReload.GRACE_MS = 120000

-- Settlements that move money or goods against an own escrow
local CONTRACT_ESCROW_SETTLEMENTS = { CONTRACT_DELIVERY = true, CONTRACT_EXPIRED_OPEN = true, CONTRACT_DEFAULT_REFUND = true }
local OFFER_ESCROW_SETTLEMENTS = { OFFER_SOLD = true, OFFER_RETURNED = true }

-- =========================================================================
-- ASSIGNING LISTINGS WITH A LOST CREATE ANSWER
-- =========================================================================

---Assigns an own backend listing to the local entry that still waits for its CREATE answer
---@param list table contracts or directOffers
---@param farmKey string "issuerFarmId" or "sellerFarmId"
---@param info table remoteId, farmId, fillType, totalLiters (exact) or minLiters, bonusPct (contracts)
---@return table|nil entry
function GlobalMarket:bindPendingOnlineCreate(list, farmKey, info)
    local fillType = string.upper(info.fillType or "")
    for _, entry in ipairs(list or {}) do
        local total = math.floor((entry.totalLiters or 0) + 0.5)
        if entry.isOnline and entry.status == "PENDING_CREATE" and (entry.remoteId or "") == ""
            and entry[farmKey] == info.farmId and string.upper(entry.fillType or "") == fillType
            and (info.totalLiters == nil or math.abs(total - info.totalLiters) <= 0.5)
            and (info.minLiters == nil or total >= info.minLiters - 0.5)
            and (info.bonusPct == nil or entry.bonusPct == info.bonusPct) then
            entry.remoteId = info.remoteId
            entry.status = "OPEN"
            entry.pendingActionId = nil
            entry.pendingSinceMs = nil
            return entry
        end
    end
    return nil
end

-- =========================================================================
-- LISTINGS WITHOUT ESCROW
-- =========================================================================

---Returns true if a settlement belongs to an own listing whose escrow is not in this savegame
---@param s table settlement
---@return boolean
function GlobalMarket:isUnbookedOnlineSettlement(s)
    local isContract = CONTRACT_ESCROW_SETTLEMENTS[s.type] == true
    if not isContract and not OFFER_ESCROW_SETTLEMENTS[s.type] then
        return false
    end
    -- Withdrawn in this session: e.g. a sale just before the withdrawal is still paid
    if self.settledCancelRemoteIds ~= nil and self.settledCancelRemoteIds[s.remoteId] then
        return false
    end
    local list = isContract and self.contracts or self.directOffers
    local _, entry = GlobalMarketContracts.findOnlineEntry(list, nil, s.remoteId)
    if entry == nil then
        entry = self:bindPendingOnlineCreate(list, isContract and "issuerFarmId" or "sellerFarmId", {
            remoteId = s.remoteId, farmId = s.targetFarmId, fillType = s.fillType, minLiters = s.liters })
    end
    -- A contract keeps at least its bonus in escrow until it is closed
    local isUnbooked = entry == nil or (isContract and (entry.escrowRemaining or 0) <= 0)
    if isUnbooked and self.debugManager ~= nil then
        self.debugManager:warning("OnlineReload: %s for %s is not booked, this savegame holds no escrow for it.", s.type, tostring(s.remoteId))
    end
    return isUnbooked
end

---Returns true if a withdrawal request for a listing may be sent (again)
---@param gm table
---@param remoteId string
---@return boolean
local function isWithdrawDue(gm, remoteId)
    gm.unbookedWithdrawMs = gm.unbookedWithdrawMs or {}
    local now = g_time or 0
    local sentAt = gm.unbookedWithdrawMs[remoteId]
    return sentAt == nil or now - sentAt >= GlobalMarketOnlineReload.GRACE_MS
end

---Remembers a sent withdrawal request
---@param gm table
---@param remoteId string
local function markWithdrawn(gm, remoteId)
    gm.unbookedWithdrawMs[remoteId] = g_time or 0
    if gm.debugManager ~= nil then
        gm.debugManager:info("OnlineReload: Withdrawing %s, this savegame holds no escrow for it.", remoteId)
    end
end

---Withdraws an own contract or direct offer without escrow
---@param subAction string CANCEL_CONTRACT or CANCEL_OFFER
---@param farmId number
---@param remoteId string
function GlobalMarket:withdrawUnbookedOnlineEntry(subAction, farmId, remoteId)
    if isWithdrawDue(self, remoteId) and self:dispatchOnlineContractAction({
        subAction = subAction,
        actionId = self:nextOnlineContractActionId(),
        serverId = self:ensureServerInstanceId(),
        farmId = farmId,
        remoteId = remoteId
    }) then
        markWithdrawn(self, remoteId)
    end
end

---Withdraws own vehicle listings whose vehicle is not in escrow here
---@param ownByRemote table remoteId -> snapshot entry of this savegame
function GlobalMarket:withdrawUnbookedVehicleListings(ownByRemote)
    local known = {}
    for _, listing in ipairs(self.vehicleListings or {}) do
        if listing.isOnline then
            known[listing.remoteId or ""] = true
            known[listing.createActionId or ""] = true
        end
    end
    for remoteId, entry in pairs(ownByRemote) do
        local isKnown = known[remoteId] or (entry.createActionId ~= "" and known[entry.createActionId])
        if not isKnown and entry.status == "OPEN" and isWithdrawDue(self, remoteId)
            and self:dispatchVehicleAction({ subAction = "CANCEL_LISTING", farmId = entry.sellerFarmId, remoteId = remoteId }) then
            markWithdrawn(self, remoteId)
        end
    end
end

-- =========================================================================
-- ESCROW WITHOUT LISTING
-- =========================================================================

---Returns true if a cancel answer says that the listing does not exist (any more). While its escrow is
---still here, the withdrawal was never booked in this savegame.
---@param res table action result
---@return boolean
function GlobalMarket.isOnlineListingGone(res)
    return (res.subAction == "CANCEL_CONTRACT" or res.subAction == "CANCEL_OFFER")
        and res.status ~= "ACCEPTED" and (res.reason == "NOT_OPEN" or res.reason == "NOT_FOUND")
end

---Returns true if an own entry stays although the board does not list it (settlement or answer pending)
---@param entry table
---@param isOwnIssuer boolean
---@param isOwnContractor boolean
---@return boolean
function GlobalMarket:keepMissingOnlineEntry(entry, isOwnIssuer, isOwnContractor)
    if entry.status == "PENDING_CANCEL" then
        return true
    end
    local isKept = (isOwnIssuer and entry.status == "OPEN") or (isOwnContractor and entry.status == "ACTIVE")
    if isKept then
        entry.missingSinceMs = entry.missingSinceMs or (g_time or 0)
    end
    return isKept
end

---Returns true while a delivery to a contract waits for its answer
---@param gm table
---@param remoteId string
---@return boolean
local function hasPendingDelivery(gm, remoteId)
    for _, act in pairs(gm.pendingContractActions or {}) do
        if act.subAction == "DELIVER_CONTRACT" and act.remoteId == remoteId then
            return true
        end
    end
    return false
end

---Server tick (1 s): asks for own listings that are missing on the board and drops contracts that
---were finished online before an older savegame was loaded
function GlobalMarket:reconcileMissingOnlineEntries()
    if g_server == nil or not self:getAreOnlineContractsSupported() then
        return
    end
    local now = g_time or 0
    local changed = false
    local function isDue(entry)
        return entry.isOnline and entry.missingSinceMs ~= nil and now - entry.missingSinceMs >= GlobalMarketOnlineReload.GRACE_MS
    end
    local function ask(entry, subAction, farmId)
        -- The answer tells what happened; the escrow only moves with it (or with a settlement)
        local actionId = self:nextOnlineContractActionId()
        if entry.isMissingAsked or not self:dispatchOnlineContractAction({ subAction = subAction, actionId = actionId,
            serverId = self:ensureServerInstanceId(), farmId = farmId, remoteId = entry.remoteId }) then
            return
        end
        entry.isMissingAsked = true
        entry.status = "PENDING_CANCEL"
        entry.pendingActionId = actionId
        entry.pendingSinceMs = now
        changed = true
    end

    for i = #(self.contracts or {}), 1, -1 do
        local c = self.contracts[i]
        if isDue(c) then
            if c.status == "OPEN" and self:isOwnOnlineServer(c.issuerServerId) then
                ask(c, "CANCEL_CONTRACT", c.issuerFarmId)
            elseif c.status == "ACTIVE" and not hasPendingDelivery(self, c.remoteId) then
                table.remove(self.contracts, i)
                changed = true
            end
        end
    end
    for _, o in ipairs(self.directOffers or {}) do
        if isDue(o) and o.status == "OPEN" and self:isOwnOnlineServer(o.sellerServerId) then
            ask(o, "CANCEL_OFFER", o.sellerFarmId)
        end
    end
    if changed and self.broadcastContractsState ~= nil then
        self:broadcastContractsState()
    end
end

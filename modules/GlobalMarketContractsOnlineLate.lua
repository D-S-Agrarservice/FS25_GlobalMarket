-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractsOnlineLate.lua
-- Stage 2: late, lost and rejected backend answers. The companion client repeats an action until
-- the backend answered, so an answer can arrive long after the request (or after a restart):
-- locally withdrawn listings are cancelled at the backend, purchases stay open until they are
-- answered, rejected deliveries are reversed and unanswered cancels are repeated.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketContractsOnlineLate = {}
GlobalMarketContractsOnlineLate.MAX_ORPHANED_ACTIONS = 128
GlobalMarketContractsOnlineLate.MAX_PENDING_ACTIONS = 64
-- An unanswered cancel is repeated after this time
GlobalMarketContractsOnlineLate.CANCEL_RETRY_MS = 120000

-- Actions that must not be forgotten before the backend answered (money or goods depend on it)
local KEEP_UNTIL_ANSWERED = { BUY_OFFER = true, DELIVER_CONTRACT = true }

-- =========================================================================
-- ORPHANED ACTIONS (withdrawn locally or farm deleted)
-- =========================================================================

---Remembers a sent action whose listing no longer exists here (persisted, bounded FIFO)
---@param actionId string|nil
---@param subAction string
---@param farmId number
function GlobalMarket:markOrphanedOnlineAction(actionId, subAction, farmId)
    if actionId == nil or actionId == "" then
        return
    end
    self.orphanedActionIds = self.orphanedActionIds or {}
    self.orphanedActionOrder = self.orphanedActionOrder or {}
    if self.orphanedActionIds[actionId] == nil then
        table.insert(self.orphanedActionOrder, actionId)
    end
    self.orphanedActionIds[actionId] = { subAction = subAction, farmId = farmId }
    while #self.orphanedActionOrder > GlobalMarketContractsOnlineLate.MAX_ORPHANED_ACTIONS do
        self.orphanedActionIds[table.remove(self.orphanedActionOrder, 1)] = nil
    end
end

-- =========================================================================
-- PENDING ACTIONS
-- =========================================================================

---Stores a sent action that waits for its backend answer
---@param actionId string
---@param act table
function GlobalMarket:addPendingContractAction(actionId, act)
    self.pendingContractActions = self.pendingContractActions or {}
    self.pendingContractSeq = (self.pendingContractSeq or 0) + 1
    act.seq = self.pendingContractSeq
    act.createdAtMs = g_time or 0
    self.pendingContractActions[actionId] = act

    local count, oldestId, oldestSeq = 0, nil, nil
    for id, entry in pairs(self.pendingContractActions) do
        count = count + 1
        if oldestSeq == nil or (entry.seq or 0) < oldestSeq then
            oldestId, oldestSeq = id, entry.seq or 0
        end
    end
    if count > GlobalMarketContractsOnlineLate.MAX_PENDING_ACTIONS and oldestId ~= nil then
        self.pendingContractActions[oldestId] = nil
    end
end

---Marks an unanswered purchase as late: money is no longer reserved, goods go to the Pickup Inbox
---(the chosen storage may be gone by then)
---@param act table
local function releaseAction(act)
    act.isLate = true
    act.reservedCash = 0
    act.targetStorage = nil
    act.isObjectStorage = false
    act.formatXml = nil
    act.capacityPerObject = nil
end

---Releases unanswered actions; purchases and deliveries stay known until the backend answered
---@param timeoutMs number|nil nil = all (Data-Host lost)
---@return boolean changed
function GlobalMarket:releasePendingContractActions(timeoutMs)
    local now = g_time or 0
    local changed = false
    for actionId, act in pairs(self.pendingContractActions or {}) do
        if not act.isLate and (timeoutMs == nil or now - (act.createdAtMs or 0) >= timeoutMs) then
            if KEEP_UNTIL_ANSWERED[act.subAction] then
                releaseAction(act)
            else
                if act.subAction == "ACCEPT_CONTRACT" and act.remoteId ~= nil then
                    local _, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, act.remoteId)
                    if c ~= nil and c.pendingAcceptFarmId == act.farmId then
                        c.pendingAcceptFarmId = nil
                        changed = true
                    end
                end
                self.pendingContractActions[actionId] = nil
            end
        end
    end
    return changed
end

-- =========================================================================
-- DELIVERIES
-- =========================================================================

---Books the backend answer to DELIVER_CONTRACT: liters the backend did not credit are returned
---to the Pickup Inbox and the payout for them is taken back
---@param res table action result
function GlobalMarket:applyOnlineDeliveryResult(res)
    local act = (self.pendingContractActions or {})[res.actionId]
    if act == nil or act.subAction ~= "DELIVER_CONTRACT" then
        return
    end
    self.pendingContractActions[res.actionId] = nil

    local rejected = act.liters or 0
    if res.status == "ACCEPTED" then
        -- The client always writes grantedLiters, 0 = not reported
        local granted = res.grantedLiters or 0
        rejected = (granted > 0.5) and math.max(0, rejected - granted) or 0
    end
    if rejected <= 0.5 then
        return
    end

    local payback = math.floor(((rejected / 1000) * (act.pricePer1000 or 0)) + 0.5)
    if rejected >= (act.liters or 0) then
        payback = (act.payout or 0) + (act.bonus or 0)
    end
    if payback > 0 then
        g_currentMission:addMoney(payback * -1, act.farmId, MoneyType.GM_CONTRACTS or MoneyType.GM_SELL, true, true)
    end
    if self.addPickupInboxItem ~= nil then
        self:addPickupInboxItem(act.farmId, act.fillType, rejected, "DELIVERY_REJECTED", string.format("#%s", tostring(act.remoteId)))
    end

    -- Open the contract again; a completed one comes back with the next board
    if self.completedContractorRemoteIds ~= nil then
        self.completedContractorRemoteIds[act.remoteId] = nil
    end
    local _, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, act.remoteId)
    if c ~= nil then
        c.deliveredLiters = math.max(0, (c.deliveredLiters or 0) - rejected)
    end
    if self.debugManager ~= nil then
        self.debugManager:warning("ContractsOnline: Delivery of %.0f L to %s was not credited (%s), reversed.",
            rejected, tostring(act.remoteId), tostring(res.reason))
    end
end

-- =========================================================================
-- CANCELS
-- =========================================================================

---Server (1 s step): repeats cancels that were never answered
function GlobalMarket:retryUnansweredCancels()
    if g_server == nil or not self:getAreOnlineContractsSupported() then
        return
    end
    local now = g_time or 0
    local lists = {
        { self.contracts, "CANCEL_CONTRACT", "issuerFarmId" },
        { self.directOffers, "CANCEL_OFFER", "sellerFarmId" }
    }
    for _, def in ipairs(lists) do
        for _, entry in ipairs(def[1] or {}) do
            if entry.isOnline and entry.status == "PENDING_CANCEL" and (entry.pendingActionId or "") ~= ""
                and now - (entry.pendingSinceMs or 0) >= GlobalMarketContractsOnlineLate.CANCEL_RETRY_MS then
                entry.pendingSinceMs = now
                -- Always a new actionId: the backend returns the result of an older one only for a limited
                -- time. If that one worked, the repeated cancel is answered with NOT_OPEN (isOnlineListingGone).
                local actionId = self:nextOnlineContractActionId()
                if self:dispatchOnlineContractAction({
                    subAction = def[2],
                    actionId = actionId,
                    serverId = self:ensureServerInstanceId(),
                    farmId = entry[def[3]],
                    remoteId = entry.remoteId
                }) then
                    entry.pendingActionId = actionId
                end
            end
        end
    end
end

-- =========================================================================
-- SAVEGAME
-- =========================================================================

---Writes unanswered purchases, deliveries and orphaned actions
---@param xmlFile table
---@param rootKey string
function GlobalMarket:saveLateContractActionsToXml(xmlFile, rootKey)
    local i = 0
    for actionId, act in pairs(self.pendingContractActions or {}) do
        if KEEP_UNTIL_ANSWERED[act.subAction] then
            local key = string.format("%s.pendingActions.action(%d)", rootKey, i)
            i = i + 1
            xmlFile:setString(key .. "#id", actionId)
            xmlFile:setString(key .. "#subAction", act.subAction)
            xmlFile:setInt(key .. "#farmId", act.farmId or 0)
            xmlFile:setString(key .. "#remoteId", act.remoteId or "")
            xmlFile:setString(key .. "#fillType", act.fillType or "")
            xmlFile:setFloat(key .. "#liters", act.liters or act.requestedLiters or 0)
            xmlFile:setInt(key .. "#priceDeltaPct", act.priceDeltaPct or 0)
            xmlFile:setFloat(key .. "#pricePer1000", act.pricePer1000 or 0)
            xmlFile:setInt(key .. "#payout", act.payout or 0)
            xmlFile:setInt(key .. "#bonus", act.bonus or 0)
        end
    end
    for n, actionId in ipairs(self.orphanedActionOrder or {}) do
        local info = (self.orphanedActionIds or {})[actionId]
        if info ~= nil then
            local key = string.format("%s.orphanedActions.action(%d)", rootKey, n - 1)
            xmlFile:setString(key .. "#id", actionId)
            xmlFile:setString(key .. "#subAction", info.subAction or "")
            xmlFile:setInt(key .. "#farmId", info.farmId or 0)
        end
    end
end

---Reads unanswered purchases, deliveries and orphaned actions
---@param xmlFile table
---@param rootKey string
function GlobalMarket:loadLateContractActionsFromXml(xmlFile, rootKey)
    xmlFile:iterate(rootKey .. ".pendingActions.action", function(_, key)
        local actionId = xmlFile:getString(key .. "#id") or ""
        local subAction = xmlFile:getString(key .. "#subAction") or ""
        if actionId ~= "" and KEEP_UNTIL_ANSWERED[subAction] then
            local liters = xmlFile:getFloat(key .. "#liters") or 0
            local act = {
                subAction = subAction,
                farmId = xmlFile:getInt(key .. "#farmId") or 0,
                remoteId = xmlFile:getString(key .. "#remoteId") or "",
                fillType = xmlFile:getString(key .. "#fillType") or "",
                liters = liters,
                requestedLiters = liters,
                priceDeltaPct = xmlFile:getInt(key .. "#priceDeltaPct") or 0,
                pricePer1000 = xmlFile:getFloat(key .. "#pricePer1000") or 0,
                payout = xmlFile:getInt(key .. "#payout") or 0,
                bonus = xmlFile:getInt(key .. "#bonus") or 0
            }
            self:addPendingContractAction(actionId, act)
            releaseAction(act)
        end
    end)
    xmlFile:iterate(rootKey .. ".orphanedActions.action", function(_, key)
        self:markOrphanedOnlineAction(xmlFile:getString(key .. "#id"), xmlFile:getString(key .. "#subAction") or "",
            xmlFile:getInt(key .. "#farmId") or 0)
    end)
end

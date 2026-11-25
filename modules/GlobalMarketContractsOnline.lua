-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractsOnline.lua
-- Stage 2: Cross-server online contracts/offers engine, Pending->Ack, and XML sync.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketContracts.ONLINE_MODE_ALL = 1
GlobalMarketContracts.ONLINE_MODE_CONTRACTS_ONLY = 2
GlobalMarketContracts.ONLINE_MODE_OFFERS_ONLY = 3
GlobalMarketContracts.ONLINE_MODE_LOCAL_ONLY = 4

GlobalMarketContracts.ONLINE_CONTRACT_HOURS = { 24, 48, 72, 168 }
GlobalMarketContracts.ONLINE_OFFER_HOURS = { 24, 48, 72 }
GlobalMarketContracts.PENDING_ACTION_TIMEOUT_MS = 30000
GlobalMarketContracts.MAX_PROCESSED_SETTLEMENTS = 256

---Initializes runtime state for Stage 2 online contracts & direct offers
function GlobalMarket:initOnlineContractsSystem()
    self.serverInstanceId = self.serverInstanceId or nil
    self.onlineActionCounter = self.onlineActionCounter or 0
    self.pendingContractActions = {}
    self.pendingContractSyncPackets = {}
    self.processedSettlementIds = {}
    self.processedSettlementLookup = {}
    self.settlementAcks = {}
    self.settledCancelRemoteIds = {}
    self.completedContractorRemoteIds = {}
    -- Deleted-farm guards (#30): orphaned online remoteIds (persisted) and in-flight actionIds (runtime)
    self.orphanedRemoteIds = {}
    self.orphanedRemoteLookup = {}
    self.orphanedActionIds = {}
    self.orphanedActionOrder = {}
    self.onlineTimerAccumMs = 0
    self.debugForceOnlineContracts = false
end

---Ensures a persistent 16-char hex server identity exists on the authoritative server
---@return string serverInstanceId
function GlobalMarket:ensureServerInstanceId()
    if self.serverInstanceId ~= nil and self.serverInstanceId ~= "" then
        return self.serverInstanceId
    end
    local chars = {}
    for i = 1, 16 do
        chars[i] = string.format("%x", math.random(0, 15))
    end
    self.serverInstanceId = table.concat(chars)
    return self.serverInstanceId
end

---Returns true when serverId matches this savegame's persistent serverInstanceId
---@param serverId string|nil
---@return boolean
function GlobalMarket:isOwnOnlineServer(serverId)
    return serverId ~= nil and serverId ~= "" and self.serverInstanceId ~= nil and serverId == self.serverInstanceId
end

---Returns true when (serverId, farmId) identifies the given farm on this savegame
---@param serverId string|nil
---@param itemFarmId number|nil
---@param checkFarmId number|nil
---@return boolean
function GlobalMarket:isOwnOnlineIdentity(serverId, itemFarmId, checkFarmId)
    if not self:isOwnOnlineServer(serverId) then
        return false
    end
    if itemFarmId == nil or itemFarmId <= 0 then
        return false
    end
    if checkFarmId ~= nil then
        return itemFarmId == checkFarmId
    end
    return true
end

---Formats a sanitized player/server label for outgoing online listings
---@param farmId number
---@return string
function GlobalMarket:formatOnlineIssuerDisplayName(farmId)
    local farmName = self:getContractFarmName(farmId)
    local serverName = nil
    if g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil then
        serverName = g_currentMission.missionDynamicInfo.serverName
    end
    local raw = (serverName ~= nil and serverName ~= "")
        and string.format("%s [%s]", farmName, serverName)
        or farmName
    if GlobalMarketBranding ~= nil and GlobalMarketBranding.sanitizeMarketName ~= nil then
        return GlobalMarketBranding.sanitizeMarketName(raw) or farmName
    end
    return string.sub(raw, 1, 48)
end

---Returns true when the active online Data-Host supports Stage 2 contractData/contractAction
---@return boolean
function GlobalMarket:getAreOnlineContractsSupported()
    return self:getIsMarketOnline()
        and (self.onlineContractsSupported == true or self.debugForceOnlineContracts == true)
end

---Returns true when a farm may publish a new cross-server Supply Contract for fillTypeName
---@param fillTypeName string|nil
---@return boolean
function GlobalMarket:canPublishOnlineContract(fillTypeName)
    if not self:getAreOnlineContractsSupported() then
        return false
    end
    local mode = GlobalMarket.ONLINE_CONTRACTS_MODE or GlobalMarketContracts.ONLINE_MODE_ALL
    if mode ~= GlobalMarketContracts.ONLINE_MODE_ALL and mode ~= GlobalMarketContracts.ONLINE_MODE_CONTRACTS_ONLY then
        return false
    end
    if fillTypeName == nil or fillTypeName == "" then
        return false
    end
    return self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(fillTypeName)
end

---Returns true when a farm may publish a new cross-server +/-10% Direct Offer for fillTypeName
---@param fillTypeName string|nil
---@return boolean
function GlobalMarket:canPublishOnlineOffer(fillTypeName)
    if not self:getAreOnlineContractsSupported() then
        return false
    end
    local mode = GlobalMarket.ONLINE_CONTRACTS_MODE or GlobalMarketContracts.ONLINE_MODE_ALL
    if mode ~= GlobalMarketContracts.ONLINE_MODE_ALL and mode ~= GlobalMarketContracts.ONLINE_MODE_OFFERS_ONLY then
        return false
    end
    if fillTypeName == nil or fillTypeName == "" then
        return false
    end
    return self.getIsFillTypeOnlineApproved ~= nil and self:getIsFillTypeOnlineApproved(fillTypeName)
end

---Returns true when foreign online Supply Contracts may appear on the market board
---@return boolean
function GlobalMarket:isOnlineContractBoardEnabled()
    local mode = GlobalMarket.ONLINE_CONTRACTS_MODE or GlobalMarketContracts.ONLINE_MODE_ALL
    return self:getAreOnlineContractsSupported()
        and (mode == GlobalMarketContracts.ONLINE_MODE_ALL or mode == GlobalMarketContracts.ONLINE_MODE_CONTRACTS_ONLY)
end

---Returns true when foreign online Direct Offers may appear on the market board
---@return boolean
function GlobalMarket:isOnlineOfferBoardEnabled()
    local mode = GlobalMarket.ONLINE_CONTRACTS_MODE or GlobalMarketContracts.ONLINE_MODE_ALL
    return self:getAreOnlineContractsSupported()
        and (mode == GlobalMarketContracts.ONLINE_MODE_ALL or mode == GlobalMarketContracts.ONLINE_MODE_OFFERS_ONLY)
end

---Formats remaining time concisely for local (months) or online (real-time hours/minutes) listings
---@param i18n table
---@param entry table|nil
---@return string
function GlobalMarket:formatContractDurationShort(i18n, entry)
    if entry ~= nil and entry.isOnline == true then
        local sec = math.max(0, math.floor((entry.remainingSeconds or 0) + 0.5))
        if sec >= 3600 then
            local hours = math.max(1, math.ceil(sec / 3600))
            local key = "ui_gm_online_hours_short"
            local fmt = (i18n ~= nil and i18n:hasText(key)) and i18n:getText(key) or "[Online] %dh"
            return string.format(fmt, hours)
        end
        local mins = math.max(1, math.ceil(sec / 60))
        local key = "ui_gm_online_mins_short"
        local fmt = (i18n ~= nil and i18n:hasText(key)) and i18n:getText(key) or "[Online] %dm"
        return string.format(fmt, mins)
    end
    local fmt = (i18n ~= nil) and i18n:getText("ui_gm_months_short") or "%.1f mo."
    return string.format(fmt, (entry and entry.monthsRemaining) or 1.0)
end

---Allocates a unique idempotency actionId for outgoing contractAction packets
---@return string
function GlobalMarket:nextOnlineContractActionId()
    self.onlineActionCounter = (self.onlineActionCounter or 0) + 1
    local sid = self:ensureServerInstanceId()
    return string.format("%s_%d_%d", sid, math.floor(g_time or 0), self.onlineActionCounter)
end

---Dispatches an outgoing contractAction payload locally or via the active remote Data-Host
---@param payload table
---@return boolean
function GlobalMarket:dispatchOnlineContractAction(payload)
    if g_server == nil or payload == nil then
        return false
    end
    if not self:getAreOnlineContractsSupported() then
        return false
    end
    -- Savegame credential (#42): only the server knows it, only the Data-Host receives it
    payload.serverSecret = self:getServerSecret()
    if self.isDataHost then
        return self:exportContractAction(payload)
    elseif self.dataHostConnection ~= nil and type(self.dataHostConnection) == "table" and ContractOnlineBridgeEvent ~= nil then
        self.dataHostConnection:sendEvent(ContractOnlineBridgeEvent.newExportAction(payload))
        return true
    end
    return false
end

---Writes write/contractAction_<date>_<seq>.xml on the active Data-Host for GlobalMarketClient
---@param payload table
---@return boolean
function GlobalMarket:exportContractAction(payload)
    if not self.isDataHost or self.writeFolder == nil or payload == nil then
        return false
    end
    local dateStamp = getDate("%Y%m%d_%H%M%S")
    self.contractActionCounter = (self.contractActionCounter or 0) + 1
    local xmlPath = string.format("%scontractAction_%s_%d.xml", self.writeFolder, dateStamp, self.contractActionCounter)
    local xmlFile = XMLFile.create("gmContractAction", xmlPath, "gmDataSync")
    if xmlFile == nil then
        return false
    end

    xmlFile:setString("gmDataSync#action", "contractAction")
    local key = "gmDataSync.request(0)"
    xmlFile:setString(key .. "#subAction", tostring(payload.subAction or ""))
    xmlFile:setString(key .. "#actionId", tostring(payload.actionId or ""))
    xmlFile:setString(key .. "#serverId", tostring(payload.serverId or ""))
    xmlFile:setString(key .. "#serverSecret", tostring(payload.serverSecret or ""))
    if payload.farmId ~= nil and payload.farmId > 0 then
        xmlFile:setInt(key .. "#farmId", math.floor(payload.farmId))
    end
    if payload.farmName ~= nil and payload.farmName ~= "" then
        xmlFile:setString(key .. "#farmName", payload.farmName)
    end
    if payload.remoteId ~= nil and payload.remoteId ~= "" then
        xmlFile:setString(key .. "#remoteId", payload.remoteId)
    end
    if payload.fillType ~= nil and payload.fillType ~= "" then
        xmlFile:setString(key .. "#fillType", payload.fillType)
    end
    if payload.liters ~= nil and payload.liters > 0 then
        xmlFile:setInt(key .. "#liters", math.floor(payload.liters + 0.5))
    end
    if payload.baseTrendFactor ~= nil then
        xmlFile:setFloat(key .. "#baseTrendFactor", payload.baseTrendFactor)
    end
    if payload.bonusPct ~= nil then
        xmlFile:setInt(key .. "#bonusPct", math.floor(payload.bonusPct + 0.5))
    end
    if payload.priceDeltaPct ~= nil then
        xmlFile:setInt(key .. "#priceDeltaPct", math.floor(payload.priceDeltaPct + 0.5))
    end
    if payload.allowPartial ~= nil then
        xmlFile:setBool(key .. "#allowPartial", payload.allowPartial == true)
    end
    if payload.durationHours ~= nil and payload.durationHours > 0 then
        xmlFile:setInt(key .. "#durationHours", math.floor(payload.durationHours + 0.5))
    end
    if payload.wasBale ~= nil then
        xmlFile:setBool(key .. "#wasBale", payload.wasBale == true)
    end
    if payload.wasPallet ~= nil then
        xmlFile:setBool(key .. "#wasPallet", payload.wasPallet == true)
    end
    if payload.settlementIds ~= nil and payload.settlementIds ~= "" then
        xmlFile:setString(key .. "#settlementIds", payload.settlementIds)
    end

    xmlFile:save()
    xmlFile:delete()
    if self.debugManager ~= nil then
        self.debugManager:info("ContractsOnline: Exported contractAction '%s' (actionId=%s).",
            tostring(payload.subAction), tostring(payload.actionId))
    end
    return true
end

---Server: lets the next tick request a fresh contract board (Data-Host assigned, market switched)
function GlobalMarket:requestOnlineContractsSync()
    self.contractsSyncedHost = nil
end

---Server (1 s step): sends REQUEST_SYNC once per Data-Host and whenever online contracts become available.
---Runs on the server because a remote Data-Host (always on dedicated servers) has no server role (#42).
function GlobalMarket:updateOnlineContractsSync()
    if g_server == nil then
        return
    end
    local host = self:getAreOnlineContractsSupported() and self.dataHostConnection or nil
    if host == nil then
        self.contractsSyncedHost = nil
    elseif host ~= self.contractsSyncedHost and self:dispatchOnlineContractAction({
        subAction = "REQUEST_SYNC",
        actionId = self:nextOnlineContractActionId(),
        serverId = self:ensureServerInstanceId()
    }) then
        self.contractsSyncedHost = host
    end
end

---Clears foreign online board entries (preserving own persisted entries)
function GlobalMarket:pruneForeignOnlineContracts(clearContracts, clearOffers)
    if clearContracts then
        for i = #(self.contracts or {}), 1, -1 do
            local c = self.contracts[i]
            if c.isOnline and not self:isOwnOnlineServer(c.issuerServerId) and not self:isOwnOnlineServer(c.contractorServerId) then
                table.remove(self.contracts, i)
            elseif c.isOnline then
                c.pendingAcceptFarmId = nil
            end
        end
    end
    if clearOffers then
        for i = #(self.directOffers or {}), 1, -1 do
            local o = self.directOffers[i]
            if o.isOnline and not self:isOwnOnlineServer(o.sellerServerId) then
                table.remove(self.directOffers, i)
            end
        end
    end
end

---Handles going offline / Data-Host loss for Stage 2 contracts state
function GlobalMarket:onOnlineContractsDisconnected()
    self.onlineContractsSupported = false
    self.contractsSyncedHost = nil
    -- Purchases and deliveries may still be answered later
    self:releasePendingContractActions(nil)
    self:pruneForeignOnlineContracts(true, true)
    if g_server ~= nil and self.broadcastContractsState ~= nil then
        self:broadcastContractsState()
    end
end

---Handles live market switch (e.g. Official <-> Private Token).
---Contracts/offers live in ONE global backend pool (independent of X-Market-Token), so the board,
---pending actions and anti-resurrection ids stay valid; the next contract snapshot refreshes the board.
function GlobalMarket:onOnlineMarketSwitchedContracts()
    if g_server ~= nil and self.broadcastContractsState ~= nil then
        self:broadcastContractsState()
    end
end

---Reacts immediately when an Admin updates GlobalMarket.ONLINE_CONTRACTS_MODE
function GlobalMarket:onOnlineContractsModeChanged(newMode)
    if g_server == nil then
        return
    end
    local hideContracts = (newMode ~= GlobalMarketContracts.ONLINE_MODE_ALL and newMode ~= GlobalMarketContracts.ONLINE_MODE_CONTRACTS_ONLY)
    local hideOffers = (newMode ~= GlobalMarketContracts.ONLINE_MODE_ALL and newMode ~= GlobalMarketContracts.ONLINE_MODE_OFFERS_ONLY)
    self:pruneForeignOnlineContracts(hideContracts, hideOffers)
    if self.broadcastContractsState ~= nil then
        self:broadcastContractsState()
    end
end

---Counts pending ACCEPT_CONTRACT actions for a farm so the 3-contract cap cannot be bypassed mid-flight
---@param farmId number
---@return number
function GlobalMarket:getPendingAcceptContractCount(farmId)
    local count = 0
    for _, act in pairs(self.pendingContractActions or {}) do
        if act.subAction == "ACCEPT_CONTRACT" and act.farmId == farmId then
            count = count + 1
        end
    end
    return count
end

---Sums cash already committed by in-flight BUY_OFFER actions for a farm
---@param farmId number
---@return number
function GlobalMarket:getPendingBuyOfferCommittedCash(farmId)
    local total = 0
    for _, act in pairs(self.pendingContractActions or {}) do
        if act.subAction == "BUY_OFFER" and act.farmId == farmId then
            total = total + (act.reservedCash or 0)
        end
    end
    return total
end

---Creates an online cross-server Supply Contract (escrow reserved upfront, Pending -> Ack)
function GlobalMarket:createOnlinePlayerContract(farmId, fillTypeName, totalLiters, bonusPct, durationHours)
    if g_server == nil or farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false, nil
    end
    if not self:canPublishOnlineContract(fillTypeName) then
        return false, nil
    end

    local cleanLiters = math.floor(math.max(0, totalLiters or 0) + 0.5)
    if cleanLiters < 1000 then
        return false, nil
    end
    local cleanBonus = math.clamp(
        math.floor((bonusPct or 10) + 0.5),
        GlobalMarketContracts.CONTRACT_PLAYER_BONUS_MIN,
        GlobalMarketContracts.CONTRACT_PLAYER_BONUS_MAX
    )
    local cleanHours = math.clamp(math.floor((durationHours or 48) + 0.5), 1, 168)

    local basePrice = self:getContractReferencePricePer1000(fillTypeName)
    local baseTotal = (cleanLiters / 1000) * basePrice
    local bonusTotal = baseTotal * (cleanBonus / 100)
    local escrowTotal = math.ceil((baseTotal + bonusTotal) - 1e-6)
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.money < escrowTotal then
        return false, nil
    end

    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_BUY
    g_currentMission:addMoney(escrowTotal * -1, farmId, contractMoneyType, true, true)

    local serverId = self:ensureServerInstanceId()
    local actionId = self:nextOnlineContractActionId()
    self.contracts = self.contracts or {}
    self.nextContractId = self.nextContractId or 1
    local id = self.nextContractId
    self.nextContractId = id + 1

    table.insert(self.contracts, {
        id = id,
        remoteId = "",
        isOnline = true,
        origin = "ONLINE",
        issuerServerId = serverId,
        issuerFarmId = farmId,
        issuerName = self:formatOnlineIssuerDisplayName(farmId),
        contractorServerId = "",
        contractorFarmId = 0,
        fillType = fillTypeName,
        totalLiters = cleanLiters,
        deliveredLiters = 0,
        baseTrendFactor = 1.0,
        basePricePer1000 = basePrice,
        bonusPct = cleanBonus,
        escrowRemaining = escrowTotal,
        monthsRemaining = 0,
        remainingSeconds = cleanHours * 3600,
        status = "PENDING_CREATE",
        pendingActionId = actionId,
        pendingSinceMs = g_time or 0
    })

    self:dispatchOnlineContractAction({
        subAction = "CREATE_CONTRACT",
        actionId = actionId,
        serverId = serverId,
        farmId = farmId,
        farmName = self:formatOnlineIssuerDisplayName(farmId),
        fillType = fillTypeName,
        liters = cleanLiters,
        baseTrendFactor = 1.0,
        bonusPct = cleanBonus,
        durationHours = cleanHours
    })

    self:broadcastContractsState()
    return true, id
end

---Cancels an own online Supply Contract (local refund if unconfirmed & timed out/offline; else Pending -> Ack)
function GlobalMarket:cancelOnlineContract(farmId, contract)
    if g_server == nil or contract == nil then
        return false
    end
    if not self:isOwnOnlineIdentity(contract.issuerServerId, contract.issuerFarmId, farmId) then
        return false
    end
    if contract.status == "PENDING_CREATE" and (contract.remoteId == nil or contract.remoteId == "") then
        local timedOut = ((g_time or 0) - (contract.pendingSinceMs or 0)) >= GlobalMarketContracts.PENDING_ACTION_TIMEOUT_MS
        if not self:getAreOnlineContractsSupported() or timedOut then
            local refund = math.max(0, math.floor((contract.escrowRemaining or 0) + 0.5))
            if refund > 0 then
                g_currentMission:addMoney(refund, farmId, MoneyType.GM_CONTRACTS or MoneyType.GM_BUY, true, true)
            end
            local idx = GlobalMarketContracts.findById(self.contracts, contract.id)
            if idx ~= nil then
                table.remove(self.contracts, idx)
            end
            -- The client may still send the create: a late ACCEPTED is cancelled at the backend
            self:markOrphanedOnlineAction(contract.pendingActionId, "CREATE_CONTRACT", farmId)
            self:broadcastContractsState()
            return true
        end
        return false
    end
    if contract.status ~= "OPEN" or contract.remoteId == nil or contract.remoteId == "" then
        return false
    end

    local actionId = self:nextOnlineContractActionId()
    contract.status = "PENDING_CANCEL"
    contract.pendingActionId = actionId
    contract.pendingSinceMs = g_time or 0
    self:dispatchOnlineContractAction({
        subAction = "CANCEL_CONTRACT",
        actionId = actionId,
        serverId = self:ensureServerInstanceId(),
        farmId = farmId,
        remoteId = contract.remoteId
    })
    self:broadcastContractsState()
    return true
end

---Requests acceptance of an open online Supply Contract (Pending -> Ack; binds only on backend confirmation)
function GlobalMarket:requestAcceptOnlineContract(farmId, contract)
    if g_server == nil or contract == nil or farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false
    end
    if not self:isOnlineContractBoardEnabled() or contract.status ~= "OPEN" or contract.pendingAcceptFarmId ~= nil then
        return false
    end
    if contract.remoteId == nil or contract.remoteId == "" then
        return false
    end
    if self:isOwnOnlineIdentity(contract.issuerServerId, contract.issuerFarmId, farmId) then
        return false
    end
    if self:getActiveAcceptedContractCount(farmId) >= GlobalMarketContracts.MAX_ACTIVE_CONTRACTS_PER_FARM then
        return false
    end

    local actionId = self:nextOnlineContractActionId()
    contract.pendingAcceptFarmId = farmId
    self:addPendingContractAction(actionId, {
        subAction = "ACCEPT_CONTRACT",
        farmId = farmId,
        remoteId = contract.remoteId,
        contractId = contract.id
    })

    local sent = self:dispatchOnlineContractAction({
        subAction = "ACCEPT_CONTRACT",
        actionId = actionId,
        serverId = self:ensureServerInstanceId(),
        farmId = farmId,
        farmName = self:formatOnlineIssuerDisplayName(farmId),
        remoteId = contract.remoteId
    })
    if not sent then
        contract.pendingAcceptFarmId = nil
        self.pendingContractActions[actionId] = nil
        return false
    end

    self:broadcastContractsState()
    return true
end

---Delivers goods onto an already-accepted online Supply Contract and exports DELIVER_CONTRACT to backend
function GlobalMarket:deliverToOnlineContract(
    farmId, contract, requestedLiters, targetStorage, isObjectStorage, formatXml
)
    if g_server == nil or contract == nil or contract.status ~= "ACTIVE" then
        return false, 0
    end
    if not self:isOwnOnlineIdentity(contract.contractorServerId, contract.contractorFarmId, farmId) then
        return false, 0
    end
    -- Without the backend nobody would credit the goods
    if not self:getAreOnlineContractsSupported() then
        self:broadcastOnlineNotice(farmId, GlobalMarketServerIdentity.REASON_OFFLINE)
        return false, 0
    end

    local neededLiters = math.max(0, (contract.totalLiters or 0) - (contract.deliveredLiters or 0))
    if neededLiters <= 0.5 then
        return false, 0
    end

    local req = math.min(requestedLiters or neededLiters, neededLiters)
    local ok, actualLiters, _, wasBale, wasPallet = self:withdrawGoodsFromFarmStorage(
        farmId, contract.fillType, req, targetStorage, isObjectStorage, formatXml, true, false
    )
    if not ok or actualLiters <= 0.01 then
        return false, 0
    end

    local creditedLiters = math.min(actualLiters, neededLiters)
    local excessLiters = math.max(0, actualLiters - creditedLiters)
    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_SELL
    local basePayout = math.floor(((creditedLiters / 1000) * (contract.basePricePer1000 or 500)) + 0.5)
    if basePayout > 0 then
        g_currentMission:addMoney(basePayout, farmId, contractMoneyType, true, true)
    end

    if excessLiters > 0.5 then
        local spotPer1000 = self:getCurrentMarketPricePer1000(contract.fillType)
        local excessPayout = math.floor(((excessLiters / 1000) * spotPer1000) + 0.5)
        local fillDesc = g_fillTypeManager:getFillTypeByName(contract.fillType)
        local spotMoneyType = (fillDesc ~= nil and GlobalMarketFinance ~= nil)
            and GlobalMarketFinance.getMoneyType(fillDesc.index, false, wasBale, wasPallet)
            or contractMoneyType
        if excessPayout > 0 then
            g_currentMission:addMoney(excessPayout, farmId, spotMoneyType, true, true)
        end
    end

    -- The backend counts whole liters: rounding the running total keeps both sides equal
    local sentBefore = math.floor((contract.deliveredLiters or 0) + 0.5)
    contract.deliveredLiters = (contract.deliveredLiters or 0) + creditedLiters
    local bonusPayout = 0
    local isCompleted = contract.deliveredLiters >= (contract.totalLiters - 0.5)
    local sentLiters = math.floor((isCompleted and contract.totalLiters or contract.deliveredLiters) + 0.5) - sentBefore
    if isCompleted then
        bonusPayout = math.floor(
            ((contract.totalLiters / 1000) * (contract.basePricePer1000 or 500) * ((contract.bonusPct or 0) / 100)) + 0.5
        )
        if bonusPayout > 0 then
            g_currentMission:addMoney(bonusPayout, farmId, contractMoneyType, true, true)
        end
        if contract.remoteId ~= nil and contract.remoteId ~= "" then
            self.completedContractorRemoteIds = self.completedContractorRemoteIds or {}
            self.completedContractorRemoteIds[contract.remoteId] = true
        end
        local idx = GlobalMarketContracts.findById(self.contracts, contract.id)
        if idx ~= nil then
            table.remove(self.contracts, idx)
        end
    end

    if sentLiters > 0 then
        local actionId = self:nextOnlineContractActionId()
        -- Reversed if the backend does not credit it (applyOnlineDeliveryResult)
        self:addPendingContractAction(actionId, {
            subAction = "DELIVER_CONTRACT",
            farmId = farmId,
            remoteId = contract.remoteId,
            fillType = contract.fillType,
            liters = sentLiters,
            pricePer1000 = contract.basePricePer1000 or 500,
            payout = basePayout,
            bonus = bonusPayout
        })
        if not self:dispatchOnlineContractAction({
            subAction = "DELIVER_CONTRACT",
            actionId = actionId,
            serverId = self:ensureServerInstanceId(),
            farmId = farmId,
            remoteId = contract.remoteId,
            liters = sentLiters
        }) then
            self:applyOnlineDeliveryResult({ actionId = actionId, status = "REJECTED", reason = GlobalMarketServerIdentity.REASON_OFFLINE })
            self:broadcastOnlineNotice(farmId, GlobalMarketServerIdentity.REASON_OFFLINE)
        end
    end

    self:broadcastContractsState()
    return true, creditedLiters
end

---Creates an online cross-server +/-10% Direct Offer (goods escrowed upfront, Pending -> Ack)
function GlobalMarket:createOnlineDirectOffer(
    farmId, fillTypeName, requestedLiters, priceDeltaPct, allowPartial,
    durationHours, targetStorage, isObjectStorage, formatXml
)
    if g_server == nil or farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false, nil
    end
    if not self:canPublishOnlineOffer(fillTypeName) then
        return false, nil
    end

    local ok, actualLiters, _, wasBale, wasPallet = self:withdrawGoodsFromFarmStorage(
        farmId, fillTypeName, requestedLiters, targetStorage, isObjectStorage, formatXml, false, true
    )
    if not ok or actualLiters <= 0.01 then
        return false, nil
    end

    local cleanDelta = math.clamp(math.floor((priceDeltaPct or 0) + 0.5), GlobalMarketContracts.OFFER_DELTA_MIN, GlobalMarketContracts.OFFER_DELTA_MAX)
    local cleanHours = math.clamp(math.floor((durationHours or 48) + 0.5), 1, 72)
    local refPrice = self:getCurrentMarketPricePer1000(fillTypeName)
    local serverId = self:ensureServerInstanceId()
    local actionId = self:nextOnlineContractActionId()

    self.directOffers = self.directOffers or {}
    self.nextOfferId = self.nextOfferId or 1
    local id = self.nextOfferId
    self.nextOfferId = id + 1

    table.insert(self.directOffers, {
        id = id,
        remoteId = "",
        isOnline = true,
        origin = "ONLINE",
        sellerServerId = serverId,
        sellerFarmId = farmId,
        sellerName = self:formatOnlineIssuerDisplayName(farmId),
        fillType = fillTypeName,
        totalLiters = actualLiters,
        remainingLiters = actualLiters,
        refPricePer1000 = refPrice,
        priceDeltaPct = cleanDelta,
        allowPartial = (allowPartial == true),
        monthsRemaining = 0,
        remainingSeconds = cleanHours * 3600,
        wasBale = (wasBale == true),
        wasPallet = (wasPallet == true),
        status = "PENDING_CREATE",
        pendingActionId = actionId,
        pendingSinceMs = g_time or 0
    })

    self:dispatchOnlineContractAction({
        subAction = "CREATE_OFFER",
        actionId = actionId,
        serverId = serverId,
        farmId = farmId,
        farmName = self:formatOnlineIssuerDisplayName(farmId),
        fillType = fillTypeName,
        liters = math.floor(actualLiters + 0.5),
        priceDeltaPct = cleanDelta,
        allowPartial = (allowPartial == true),
        durationHours = cleanHours,
        wasBale = (wasBale == true),
        wasPallet = (wasPallet == true)
    })

    self:broadcastContractsState()
    return true, id
end

---Cancels an own online Direct Offer (moves remainder to Pickup Inbox after backend confirms or local timeout)
function GlobalMarket:cancelOnlineOffer(farmId, offer)
    if g_server == nil or offer == nil then
        return false
    end
    if not self:isOwnOnlineIdentity(offer.sellerServerId, offer.sellerFarmId, farmId) then
        return false
    end
    if offer.status == "PENDING_CREATE" and (offer.remoteId == nil or offer.remoteId == "") then
        local timedOut = ((g_time or 0) - (offer.pendingSinceMs or 0)) >= GlobalMarketContracts.PENDING_ACTION_TIMEOUT_MS
        if not self:getAreOnlineContractsSupported() or timedOut then
            if (offer.remainingLiters or 0) > 0.5 and self.addPickupInboxItem ~= nil then
                self:addPickupInboxItem(farmId, offer.fillType, offer.remainingLiters, "OFFER_CANCELLED", string.format("#%d", offer.id))
            end
            local idx = GlobalMarketContracts.findById(self.directOffers, offer.id)
            if idx ~= nil then
                table.remove(self.directOffers, idx)
            end
            -- The client may still send the create: a late ACCEPTED is cancelled at the backend
            self:markOrphanedOnlineAction(offer.pendingActionId, "CREATE_OFFER", farmId)
            self:broadcastContractsState()
            return true
        end
        return false
    end
    if offer.status == "PENDING_CANCEL" or offer.remoteId == nil or offer.remoteId == "" then
        return false
    end

    local actionId = self:nextOnlineContractActionId()
    offer.status = "PENDING_CANCEL"
    offer.pendingActionId = actionId
    offer.pendingSinceMs = g_time or 0
    self:dispatchOnlineContractAction({
        subAction = "CANCEL_OFFER",
        actionId = actionId,
        serverId = self:ensureServerInstanceId(),
        farmId = farmId,
        remoteId = offer.remoteId
    })
    self:broadcastContractsState()
    return true
end

---Requests purchase of a foreign online Direct Offer (Pending -> Ack; deposits/pays only after backend confirmation)
function GlobalMarket:requestBuyOnlineOffer(
    buyerFarmId, offer, requestedLiters, targetStorage, isObjectStorage, formatXml, capacityPerObject
)
    if g_server == nil or offer == nil or buyerFarmId == nil or buyerFarmId <= 0 or buyerFarmId == FarmManager.SPECTATOR_FARM_ID then
        return false, 0
    end
    if not self:isOnlineOfferBoardEnabled() or (offer.remainingLiters or 0) <= 0.5 or offer.remoteId == nil or offer.remoteId == "" then
        return false, 0
    end
    if self:isOwnOnlineIdentity(offer.sellerServerId, offer.sellerFarmId, buyerFarmId) then
        return false, 0
    end

    local desiredLiters = offer.remainingLiters
    if offer.allowPartial and requestedLiters ~= nil and requestedLiters > 0 then
        desiredLiters = math.min(requestedLiters, offer.remainingLiters)
    end
    if isObjectStorage and capacityPerObject ~= nil and capacityPerObject > 0 then
        local pieces = math.floor((desiredLiters + 0.01) / capacityPerObject)
        if pieces <= 0 then
            return false, 0
        end
        desiredLiters = pieces * capacityPerObject
    end

    local effPer1k = self:getCurrentMarketPricePer1000(offer.fillType) * (1 + ((offer.priceDeltaPct or 0) / 100))
    local estGoodsCost = math.floor(((desiredLiters / 1000) * effPer1k) + 0.5)
    local isGm = (targetStorage ~= nil and targetStorage.isGmMarket == true)
    local estShipping = self:computeContractShippingCost(desiredLiters, isGm)
    local farm = g_farmManager:getFarmById(buyerFarmId)
    local committed = self:getPendingBuyOfferCommittedCash(buyerFarmId)
    if farm == nil or farm.money < (committed + estGoodsCost + estShipping) then
        return false, 0
    end

    local actionId = self:nextOnlineContractActionId()
    self:addPendingContractAction(actionId, {
        subAction = "BUY_OFFER",
        farmId = buyerFarmId,
        remoteId = offer.remoteId,
        offerId = offer.id,
        fillType = offer.fillType,
        priceDeltaPct = offer.priceDeltaPct or 0,
        allowPartial = (offer.allowPartial == true),
        requestedLiters = desiredLiters,
        reservedCash = estGoodsCost + estShipping,
        targetStorage = targetStorage,
        isObjectStorage = (isObjectStorage == true),
        formatXml = formatXml,
        capacityPerObject = capacityPerObject
    })

    local sent = self:dispatchOnlineContractAction({
        subAction = "BUY_OFFER",
        actionId = actionId,
        serverId = self:ensureServerInstanceId(),
        farmId = buyerFarmId,
        remoteId = offer.remoteId,
        liters = math.floor(desiredLiters + 0.5),
        allowPartial = (offer.allowPartial == true)
    })
    if not sent then
        self.pendingContractActions[actionId] = nil
        return false, 0
    end

    return true, desiredLiters
end

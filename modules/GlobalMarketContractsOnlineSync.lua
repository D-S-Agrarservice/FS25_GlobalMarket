-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractsOnlineSync.lua
-- Stage 2: Incoming contractData XML parser, settlement engine, snapshot merge & timers.
-- Author: D-S-Agrarservice
-- =========================================================================================

---Finds an online contract or direct offer entry by pendingActionId or remoteId
---@param list table|nil
---@param pendingActionId string|nil
---@param remoteId string|nil
---@return number|nil index
---@return table|nil entry
function GlobalMarketContracts.findOnlineEntry(list, pendingActionId, remoteId)
    for i, entry in ipairs(list or {}) do
        if entry.isOnline then
            if pendingActionId ~= nil and pendingActionId ~= "" and entry.pendingActionId == pendingActionId then
                return i, entry
            end
            if remoteId ~= nil and remoteId ~= "" and entry.remoteId == remoteId then
                return i, entry
            end
        end
    end
    return nil, nil
end

---Parses incoming <gmDataSync action="contractData"> XML files into pendingContractSyncPackets
---@param action string
---@param xmlFile table
function GlobalMarket:onReadCustomSyncXml(action, xmlFile)
    if action ~= "contractData" or xmlFile == nil then
        return
    end
    local packet = {
        contracts = {},
        directOffers = {},
        actionResults = {},
        settlements = {}
    }

    xmlFile:iterate("gmDataSync.contracts.contract", function(_, key)
        local rid = xmlFile:getString(key .. "#remoteId") or xmlFile:getString(key .. "#id") or ""
        local ft = xmlFile:getString(key .. "#fillType") or ""
        if rid ~= "" and ft ~= "" then
            table.insert(packet.contracts, {
                remoteId = rid,
                origin = xmlFile:getString(key .. "#origin") or "ONLINE",
                isNpc = xmlFile:getBool(key .. "#isNpc", false),
                issuerServerId = xmlFile:getString(key .. "#issuerServerId") or "",
                issuerFarmId = xmlFile:getInt(key .. "#issuerFarmId") or 0,
                issuerName = xmlFile:getString(key .. "#issuerName") or "Online",
                contractorServerId = xmlFile:getString(key .. "#contractorServerId") or "",
                contractorFarmId = xmlFile:getInt(key .. "#contractorFarmId") or 0,
                fillType = string.upper(ft),
                totalLiters = xmlFile:getFloat(key .. "#totalLiters") or 0,
                deliveredLiters = xmlFile:getFloat(key .. "#deliveredLiters") or 0,
                baseTrendFactor = xmlFile:getFloat(key .. "#baseTrendFactor") or 1.0,
                bonusPct = xmlFile:getInt(key .. "#bonusPct") or 10,
                remainingSeconds = xmlFile:getInt(key .. "#remainingSeconds") or 0,
                status = string.upper(xmlFile:getString(key .. "#status") or "OPEN")
            })
        end
    end)

    xmlFile:iterate("gmDataSync.directOffers.offer", function(_, key)
        local rid = xmlFile:getString(key .. "#remoteId") or xmlFile:getString(key .. "#id") or ""
        local ft = xmlFile:getString(key .. "#fillType") or ""
        if rid ~= "" and ft ~= "" then
            table.insert(packet.directOffers, {
                remoteId = rid,
                origin = xmlFile:getString(key .. "#origin") or "ONLINE",
                isNpc = xmlFile:getBool(key .. "#isNpc", false),
                sellerServerId = xmlFile:getString(key .. "#sellerServerId") or "",
                sellerFarmId = xmlFile:getInt(key .. "#sellerFarmId") or 0,
                sellerName = xmlFile:getString(key .. "#sellerName") or "Online",
                fillType = string.upper(ft),
                totalLiters = xmlFile:getFloat(key .. "#totalLiters") or 0,
                remainingLiters = xmlFile:getFloat(key .. "#remainingLiters") or 0,
                priceDeltaPct = xmlFile:getInt(key .. "#priceDeltaPct") or 0,
                allowPartial = xmlFile:getBool(key .. "#allowPartial", true),
                remainingSeconds = xmlFile:getInt(key .. "#remainingSeconds") or 0,
                wasBale = xmlFile:getBool(key .. "#wasBale", false),
                wasPallet = xmlFile:getBool(key .. "#wasPallet", false),
                status = string.upper(xmlFile:getString(key .. "#status") or "OPEN")
            })
        end
    end)

    xmlFile:iterate("gmDataSync.actionResults.result", function(_, key)
        local actionId = xmlFile:getString(key .. "#actionId") or ""
        if actionId ~= "" then
            table.insert(packet.actionResults, {
                actionId = actionId,
                subAction = string.upper(xmlFile:getString(key .. "#subAction") or ""),
                status = string.upper(xmlFile:getString(key .. "#status") or "REJECTED"),
                reason = xmlFile:getString(key .. "#reason") or "",
                remoteId = xmlFile:getString(key .. "#remoteId") or "",
                grantedLiters = xmlFile:getFloat(key .. "#grantedLiters") or 0,
                baseTrendFactor = xmlFile:getFloat(key .. "#baseTrendFactor") or 1.0,
                bonusPct = xmlFile:getInt(key .. "#bonusPct") or 10,
                remainingSeconds = xmlFile:getInt(key .. "#remainingSeconds") or 0
            })
        end
    end)

    xmlFile:iterate("gmDataSync.settlements.settlement", function(_, key)
        local sid = xmlFile:getString(key .. "#settlementId") or xmlFile:getString(key .. "#id") or ""
        if sid ~= "" then
            table.insert(packet.settlements, {
                settlementId = sid,
                type = string.upper(xmlFile:getString(key .. "#type") or ""),
                targetServerId = xmlFile:getString(key .. "#targetServerId") or "",
                targetFarmId = xmlFile:getInt(key .. "#targetFarmId") or 0,
                remoteId = xmlFile:getString(key .. "#remoteId") or "",
                fillType = string.upper(xmlFile:getString(key .. "#fillType") or ""),
                liters = xmlFile:getFloat(key .. "#liters") or 0,
                missingLiters = xmlFile:getFloat(key .. "#missingLiters") or 0,
                baseTrendFactor = xmlFile:getFloat(key .. "#baseTrendFactor") or 1.0,
                priceDeltaPct = xmlFile:getInt(key .. "#priceDeltaPct") or 0,
                sourceLabel = xmlFile:getString(key .. "#sourceLabel") or ""
            })
        end
    end)

    self.pendingContractSyncPackets = self.pendingContractSyncPackets or {}
    table.insert(self.pendingContractSyncPackets, packet)
end

---Routes buffered contractData packets directly on server or relays from remote Data-Host
function GlobalMarket:flushCustomSyncPackets()
    local queue = self.pendingContractSyncPackets
    if queue == nil or #queue == 0 then
        return
    end
    self.pendingContractSyncPackets = {}

    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        for _, packet in ipairs(queue) do
            self:applyOnlineContractSyncPacket(packet)
        end
    elseif ContractOnlineBridgeEvent ~= nil and g_client ~= nil then
        for _, packet in ipairs(queue) do
            g_client:getServerConnection():sendEvent(ContractOnlineBridgeEvent.newSyncPacket(packet))
        end
    end
end

---Records a settlementId into the bounded FIFO deduplication log
---@param settlementId string
function GlobalMarket:markSettlementProcessed(settlementId)
    if settlementId == nil or settlementId == "" then
        return
    end
    self.processedSettlementIds = self.processedSettlementIds or {}
    self.processedSettlementLookup = self.processedSettlementLookup or {}
    if self.processedSettlementLookup[settlementId] then
        return
    end
    table.insert(self.processedSettlementIds, settlementId)
    self.processedSettlementLookup[settlementId] = true
    local cap = GlobalMarketContracts.MAX_PROCESSED_SETTLEMENTS or 256
    while #self.processedSettlementIds > cap do
        local evicted = table.remove(self.processedSettlementIds, 1)
        if evicted ~= nil then
            self.processedSettlementLookup[evicted] = nil
        end
    end
end

---Applies actionResults, idempotent settlements, and board snapshot on the authoritative server
---@param packet table
function GlobalMarket:applyOnlineContractSyncPacket(packet)
    if g_server == nil or packet == nil then
        return
    end
    self.syncPulseTimer = (g_time or 0) + 2000
    self.contracts = self.contracts or {}
    self.directOffers = self.directOffers or {}
    local myServerId = self:ensureServerInstanceId()
    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_BUY
    local penaltyMoneyType = MoneyType.GM_PENALTIES or MoneyType.GM_FEE

    -- Liters of not-yet-processed OFFER_SOLD settlements per offer (used by the CANCEL_OFFER race guard)
    local soldInPacket = {}
    for _, s in ipairs(packet.settlements or {}) do
        if s.type == "OFFER_SOLD" and s.remoteId ~= "" and self:isOwnOnlineServer(s.targetServerId)
            and not (self.processedSettlementLookup or {})[s.settlementId] then
            soldInPacket[s.remoteId] = (soldInPacket[s.remoteId] or 0) + (s.liters or 0)
        end
    end

    -- 1. Process Pending -> Ack results
    for _, res in ipairs(packet.actionResults or {}) do
        local sub = res.subAction
        local accepted = (res.status == "ACCEPTED")
        if self.orphanedActionIds ~= nil and self.orphanedActionIds[res.actionId] ~= nil then
            -- Action of a deleted farm (#30): never bind/refund, cancel accepted creates
            self:handleOrphanedActionResult(res)
        elseif sub == "CREATE_CONTRACT" then
            local idx, c = GlobalMarketContracts.findOnlineEntry(self.contracts, res.actionId, res.remoteId)
            if c ~= nil then
                if accepted and res.remoteId ~= "" then
                    c.remoteId = res.remoteId
                    c.status = "OPEN"
                    c.pendingActionId = nil
                    c.pendingSinceMs = nil
                    if (res.remainingSeconds or 0) > 0 then c.remainingSeconds = res.remainingSeconds end
                else
                    local refund = math.max(0, math.floor((c.escrowRemaining or 0) + 0.5))
                    if refund > 0 and c.issuerFarmId > 0 then
                        g_currentMission:addMoney(refund, c.issuerFarmId, contractMoneyType, true, true)
                    end
                    table.remove(self.contracts, idx)
                end
            end
        elseif sub == "CREATE_OFFER" then
            local idx, o = GlobalMarketContracts.findOnlineEntry(self.directOffers, res.actionId, res.remoteId)
            if o ~= nil then
                if accepted and res.remoteId ~= "" then
                    o.remoteId = res.remoteId
                    o.status = "OPEN"
                    o.pendingActionId = nil
                    o.pendingSinceMs = nil
                    if (res.remainingSeconds or 0) > 0 then o.remainingSeconds = res.remainingSeconds end
                else
                    if (o.remainingLiters or 0) > 0.5 and o.sellerFarmId > 0 and self.addPickupInboxItem ~= nil then
                        self:addPickupInboxItem(o.sellerFarmId, o.fillType, o.remainingLiters, "OFFER_CANCELLED", string.format("#%d", o.id))
                    end
                    table.remove(self.directOffers, idx)
                end
            end
        elseif sub == "CANCEL_CONTRACT" then
            local idx, c = GlobalMarketContracts.findOnlineEntry(self.contracts, res.actionId, res.remoteId)
            if c ~= nil then
                if accepted then
                    local refund = math.max(0, math.floor((c.escrowRemaining or 0) + 0.5))
                    if refund > 0 and c.issuerFarmId > 0 then
                        g_currentMission:addMoney(refund, c.issuerFarmId, contractMoneyType, true, true)
                    end
                    if c.remoteId ~= "" then self.settledCancelRemoteIds[c.remoteId] = true end
                    table.remove(self.contracts, idx)
                else
                    c.status = "OPEN"
                    c.pendingActionId = nil
                    c.pendingSinceMs = nil
                end
            end
        elseif sub == "CANCEL_OFFER" then
            local idx, o = GlobalMarketContracts.findOnlineEntry(self.directOffers, res.actionId, res.remoteId)
            if o ~= nil then
                if accepted then
                    -- Race guard: a partial OFFER_SOLD may be in flight. Prefer the backend's authoritative
                    -- grantedLiters (> 0; the client always writes the attribute, defaulting to 0, and a fully
                    -- sold-out offer is REJECTED); otherwise subtract liters sold in this same packet.
                    local retLiters
                    if (res.grantedLiters or 0) > 0.5 then
                        retLiters = res.grantedLiters
                    else
                        retLiters = math.max(0, (o.remainingLiters or 0) - (soldInPacket[o.remoteId] or 0))
                    end
                    if retLiters > 0.5 and o.sellerFarmId > 0 and self.addPickupInboxItem ~= nil then
                        self:addPickupInboxItem(o.sellerFarmId, o.fillType, retLiters, "OFFER_CANCELLED", string.format("#%d", o.id))
                    end
                    if o.remoteId ~= "" then self.settledCancelRemoteIds[o.remoteId] = true end
                    table.remove(self.directOffers, idx)
                else
                    o.status = "OPEN"
                    o.pendingActionId = nil
                    o.pendingSinceMs = nil
                end
            end
        elseif sub == "ACCEPT_CONTRACT" then
            local pending = self.pendingContractActions[res.actionId]
            self.pendingContractActions[res.actionId] = nil
            if pending ~= nil then
                local _, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, pending.remoteId)
                if c ~= nil then c.pendingAcceptFarmId = nil end
                -- Backend already committed exclusive acceptance; bind unconditionally even if another accept raced
                if accepted and c ~= nil then
                    c.status = "ACTIVE"
                    c.contractorServerId = myServerId
                    c.contractorFarmId = pending.farmId
                    if (res.baseTrendFactor or 0) > 0 then
                        c.baseTrendFactor = res.baseTrendFactor
                        c.basePricePer1000 = self:getContractReferencePricePer1000(c.fillType) * c.baseTrendFactor
                    end
                end
            end
        elseif sub == "BUY_OFFER" then
            local pending = self.pendingContractActions[res.actionId]
            self.pendingContractActions[res.actionId] = nil
            if pending ~= nil and accepted then
                local granted = math.max(0, (res.grantedLiters or 0) > 0 and res.grantedLiters or (pending.requestedLiters or 0))
                if granted > 0.5 then
                    local spotPer1k = self:getCurrentMarketPricePer1000(pending.fillType)
                    local effPer1k = spotPer1k * (1 + ((pending.priceDeltaPct or 0) / 100))
                    local unitCost = effPer1k / 1000
                    local okDep, depositedLiters, _, isBale, isPallet = self:depositGoodsToFarmStorage(
                        pending.farmId, pending.fillType, granted, pending.targetStorage, pending.isObjectStorage,
                        pending.formatXml, pending.capacityPerObject, unitCost, false
                    )
                    local actualDep = (okDep and depositedLiters) or 0
                    local goodsCost = math.floor((granted * unitCost) + 0.5)
                    local fillDesc = g_fillTypeManager:getFillTypeByName(pending.fillType)
                    local buyerMoneyType = (fillDesc ~= nil and GlobalMarketFinance ~= nil)
                        and GlobalMarketFinance.getMoneyType(fillDesc.index, true, isBale, isPallet)
                        or MoneyType.GM_BUY_BULK
                    if goodsCost > 0 then
                        g_currentMission:addMoney(goodsCost * -1, pending.farmId, buyerMoneyType, true, true)
                    end
                    local overflow = math.max(0, granted - actualDep)
                    if overflow > 0.5 and self.addPickupInboxItem ~= nil then
                        self:addPickupInboxItem(
                            pending.farmId, pending.fillType, overflow, "OFFER_PURCHASE", string.format("#%s", tostring(pending.remoteId))
                        )
                    end
                end
            end
        end
    end

    -- 2. Apply idempotent settlements & emit ACK_SETTLEMENT
    local ackIds = {}
    for _, s in ipairs(packet.settlements or {}) do
        if self:isOwnOnlineServer(s.targetServerId) then
            if self.processedSettlementLookup[s.settlementId] then
                table.insert(ackIds, s.settlementId)
            else
                local st = s.type
                local isDupCancel = ((st == "CONTRACT_EXPIRED_OPEN" or st == "OFFER_RETURNED") and self.settledCancelRemoteIds[s.remoteId])
                -- Settlements for a deleted farm (#30) are acknowledged but never booked onto a reused farm ID
                local isOrphan = self.isOrphanedOnlineRemoteId ~= nil and self:isOrphanedOnlineRemoteId(s.remoteId)
                if not isDupCancel and not isOrphan then
                    if st == "CONTRACT_DELIVERY" then
                        local _, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, s.remoteId)
                        if c ~= nil then
                            local baseDeduct = math.floor(((s.liters / 1000) * (c.basePricePer1000 or 500)) + 0.5)
                            c.escrowRemaining = math.max(0, (c.escrowRemaining or 0) - baseDeduct)
                        end
                        if s.targetFarmId > 0 and s.liters > 0.5 and self.addPickupInboxItem ~= nil then
                            local lbl = (s.sourceLabel ~= "") and s.sourceLabel or string.format("#%s", tostring(s.remoteId))
                            self:addPickupInboxItem(s.targetFarmId, s.fillType, s.liters, "CONTRACT_DELIVERY", lbl)
                        end
                    elseif st == "CONTRACT_COMPLETED_ISSUER" then
                        local idx = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, s.remoteId)
                        if idx ~= nil then table.remove(self.contracts, idx) end
                    elseif st == "CONTRACT_EXPIRED_OPEN" then
                        local idx, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, s.remoteId)
                        local refund = (c ~= nil) and math.max(0, math.floor((c.escrowRemaining or 0) + 0.5))
                            or math.floor(((s.liters / 1000) * self:getContractReferencePricePer1000(s.fillType) * (s.baseTrendFactor or 1.0)) + 0.5)
                        if refund > 0 and s.targetFarmId > 0 then
                            g_currentMission:addMoney(refund, s.targetFarmId, contractMoneyType, true, true)
                        end
                        if idx ~= nil then table.remove(self.contracts, idx) end
                    elseif st == "CONTRACT_DEFAULT_REFUND" then
                        local idx, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, s.remoteId)
                        local basePer1k = (c ~= nil and c.basePricePer1000) or (self:getContractReferencePricePer1000(s.fillType) * (s.baseTrendFactor or 1.0))
                        local refund = (c ~= nil) and math.max(0, math.floor((c.escrowRemaining or 0) + 0.5)) or 0
                        if refund > 0 and s.targetFarmId > 0 then
                            g_currentMission:addMoney(refund, s.targetFarmId, contractMoneyType, true, true)
                        end
                        local penalty = math.ceil(((s.missingLiters or 0) / 1000) * basePer1k * GlobalMarketContracts.PENALTY_RATE)
                        if penalty > 0 and s.targetFarmId > 0 then
                            g_currentMission:addMoney(penalty, s.targetFarmId, penaltyMoneyType, true, true)
                        end
                        if idx ~= nil then table.remove(self.contracts, idx) end
                    elseif st == "CONTRACT_PENALTY_DEBIT" then
                        local idx, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, s.remoteId)
                        local basePer1k = (c ~= nil and c.basePricePer1000) or (self:getContractReferencePricePer1000(s.fillType) * (s.baseTrendFactor or 1.0))
                        local penalty = math.ceil(((s.missingLiters or 0) / 1000) * basePer1k * GlobalMarketContracts.PENALTY_RATE)
                        if penalty > 0 and s.targetFarmId > 0 then
                            g_currentMission:addMoney(penalty * -1, s.targetFarmId, penaltyMoneyType, true, true)
                        end
                        if idx ~= nil then table.remove(self.contracts, idx) end
                    elseif st == "OFFER_SOLD" then
                        local idx, o = GlobalMarketContracts.findOnlineEntry(self.directOffers, nil, s.remoteId)
                        local delta = (o ~= nil and o.priceDeltaPct) or s.priceDeltaPct or 0
                        local effPer1k = self:getCurrentMarketPricePer1000(s.fillType) * (1 + (delta / 100))
                        local payout = math.floor(((s.liters / 1000) * effPer1k) + 0.5)
                        if payout > 0 and s.targetFarmId > 0 then
                            local fillDesc = g_fillTypeManager:getFillTypeByName(s.fillType)
                            local sellerMoneyType = (fillDesc ~= nil and GlobalMarketFinance ~= nil)
                                and GlobalMarketFinance.getMoneyType(fillDesc.index, false, o ~= nil and o.wasBale == true, o ~= nil and o.wasPallet == true)
                                or MoneyType.GM_SELL_BULK
                            g_currentMission:addMoney(payout, s.targetFarmId, sellerMoneyType, true, true)
                        end
                        if o ~= nil then
                            o.remainingLiters = math.max(0, (o.remainingLiters or 0) - s.liters)
                            if o.remainingLiters <= 0.5 then table.remove(self.directOffers, idx) end
                        end
                    elseif st == "OFFER_RETURNED" then
                        local idx, o = GlobalMarketContracts.findOnlineEntry(self.directOffers, nil, s.remoteId)
                        local retLiters = (s.liters > 0.5) and s.liters or (o and o.remainingLiters or 0)
                        if retLiters > 0.5 and s.targetFarmId > 0 and self.addPickupInboxItem ~= nil then
                            local lbl = (s.sourceLabel ~= "") and s.sourceLabel or string.format("#%s", tostring(s.remoteId))
                            self:addPickupInboxItem(s.targetFarmId, s.fillType, retLiters, "OFFER_EXPIRED", lbl)
                        end
                        if idx ~= nil then table.remove(self.directOffers, idx) end
                    end
                end
                self:markSettlementProcessed(s.settlementId)
                table.insert(ackIds, s.settlementId)
            end
        end
    end

    if #ackIds > 0 then
        self:dispatchOnlineContractAction({
            subAction = "ACK_SETTLEMENT",
            actionId = self:nextOnlineContractActionId(),
            serverId = myServerId,
            settlementIds = table.concat(ackIds, ",")
        })
    end

    -- 3. Merge authoritative online snapshot while preserving local items, pending creates & stable UI IDs
    self:mergeOnlineContractsSnapshot(packet.contracts or {}, packet.directOffers or {})
    if self.broadcastContractsState ~= nil then
        self:broadcastContractsState()
    end
end

---Merges backend contract & direct offer snapshots into self.contracts / self.directOffers
function GlobalMarket:mergeOnlineContractsSnapshot(remoteContracts, remoteOffers)
    local existingCByRid, keptContracts, seenCRid = {}, {}, {}
    for _, c in ipairs(self.contracts or {}) do
        if not c.isOnline then
            table.insert(keptContracts, c)
        else
            if c.remoteId ~= nil and c.remoteId ~= "" then existingCByRid[c.remoteId] = c end
            if c.status == "PENDING_CREATE" then table.insert(keptContracts, c) end
        end
    end

    local showBoardC = self:isOnlineContractBoardEnabled()
    local completedMap = self.completedContractorRemoteIds or {}
    for _, rc in ipairs(remoteContracts) do
        local ftDesc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(rc.fillType) or nil
        if ftDesc ~= nil and (GlobalMarketAPI == nil or GlobalMarketAPI.getIsFillTypeAllowed(ftDesc)) then
            local isIssuerMine = self:isOwnOnlineServer(rc.issuerServerId)
            local isContractorMine = self:isOwnOnlineServer(rc.contractorServerId)
            local wasCompletedLocally = (completedMap[rc.remoteId] == true)
            local skipResurrect = (wasCompletedLocally and not isIssuerMine) or self:isOrphanedOnlineRemoteId(rc.remoteId)
            if not skipResurrect and (isIssuerMine or isContractorMine or showBoardC) then
                local prev = existingCByRid[rc.remoteId]
                local id = (prev ~= nil and prev.id) or self.nextContractId
                if prev == nil then self.nextContractId = self.nextContractId + 1 end
                local factor = (rc.baseTrendFactor ~= nil and rc.baseTrendFactor > 0) and rc.baseTrendFactor or 1.0
                local basePrice = (prev ~= nil and prev.basePricePer1000) or (self:getContractReferencePricePer1000(rc.fillType) * factor)
                local status = (prev ~= nil and prev.status == "PENDING_CANCEL") and "PENDING_CANCEL" or rc.status
                local contractorSid = rc.contractorServerId
                local contractorFid = rc.contractorFarmId
                local delivered = (prev ~= nil and isContractorMine)
                    and math.max(prev.deliveredLiters or 0, rc.deliveredLiters or 0) or (rc.deliveredLiters or 0)
                if wasCompletedLocally and isIssuerMine then
                    delivered = rc.totalLiters
                    if isContractorMine then
                        contractorSid = ""
                        contractorFid = 0
                    end
                end
                seenCRid[rc.remoteId] = true
                table.insert(keptContracts, {
                    id = id,
                    remoteId = rc.remoteId,
                    isOnline = true,
                    origin = rc.isNpc and "ONLINE_NPC" or "ONLINE",
                    issuerServerId = rc.issuerServerId,
                    issuerFarmId = rc.issuerFarmId,
                    issuerName = rc.issuerName,
                    contractorServerId = contractorSid,
                    contractorFarmId = contractorFid,
                    fillType = rc.fillType,
                    totalLiters = rc.totalLiters,
                    deliveredLiters = delivered,
                    baseTrendFactor = factor,
                    basePricePer1000 = basePrice,
                    bonusPct = rc.bonusPct,
                    escrowRemaining = (prev ~= nil and prev.escrowRemaining) or 0,
                    monthsRemaining = 0,
                    remainingSeconds = rc.remainingSeconds or 0,
                    status = status,
                    pendingAcceptFarmId = prev and prev.pendingAcceptFarmId or nil
                })
            end
        end
    end
    for _, prev in pairs(existingCByRid) do
        if not seenCRid[prev.remoteId] and (prev.status == "PENDING_CANCEL"
            or (prev.status == "ACTIVE" and self:isOwnOnlineServer(prev.contractorServerId))) then
            table.insert(keptContracts, prev)
        end
    end
    self.contracts = keptContracts

    local existingOByRid, keptOffers, seenORid = {}, {}, {}
    for _, o in ipairs(self.directOffers or {}) do
        if not o.isOnline then
            table.insert(keptOffers, o)
        else
            if o.remoteId ~= nil and o.remoteId ~= "" then existingOByRid[o.remoteId] = o end
            if o.status == "PENDING_CREATE" then table.insert(keptOffers, o) end
        end
    end

    local showBoardO = self:isOnlineOfferBoardEnabled()
    for _, ro in ipairs(remoteOffers) do
        local ftDesc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(ro.fillType) or nil
        if ftDesc ~= nil and (GlobalMarketAPI == nil or GlobalMarketAPI.getIsFillTypeAllowed(ftDesc)) then
            local isMine = self:isOwnOnlineServer(ro.sellerServerId)
            if (isMine or showBoardO) and not self:isOrphanedOnlineRemoteId(ro.remoteId) then
                local prev = existingOByRid[ro.remoteId]
                local id = (prev ~= nil and prev.id) or self.nextOfferId
                if prev == nil then self.nextOfferId = self.nextOfferId + 1 end
                local status = (prev ~= nil and prev.status == "PENDING_CANCEL") and "PENDING_CANCEL" or ro.status
                seenORid[ro.remoteId] = true
                table.insert(keptOffers, {
                    id = id,
                    remoteId = ro.remoteId,
                    isOnline = true,
                    origin = ro.isNpc and "ONLINE_NPC" or "ONLINE",
                    sellerServerId = ro.sellerServerId,
                    sellerFarmId = ro.sellerFarmId,
                    sellerName = ro.sellerName,
                    fillType = ro.fillType,
                    totalLiters = ro.totalLiters,
                    remainingLiters = ro.remainingLiters,
                    refPricePer1000 = self:getCurrentMarketPricePer1000(ro.fillType),
                    priceDeltaPct = ro.priceDeltaPct,
                    allowPartial = ro.allowPartial,
                    monthsRemaining = 0,
                    remainingSeconds = ro.remainingSeconds or 0,
                    wasBale = (prev ~= nil and prev.wasBale == true) or (ro.wasBale == true),
                    wasPallet = (prev ~= nil and prev.wasPallet == true) or (ro.wasPallet == true),
                    status = status
                })
            end
        end
    end
    for _, prev in pairs(existingOByRid) do
        if not seenORid[prev.remoteId] and prev.status == "PENDING_CANCEL" then
            table.insert(keptOffers, prev)
        end
    end
    self.directOffers = keptOffers
end

---Gently updates real-time countdown timers (1s step) and clears stale pending requests
---@param dt number
function GlobalMarket:updateOnlineContractsTimers(dt)
    self.onlineTimerAccumMs = (self.onlineTimerAccumMs or 0) + (dt or 0)
    if self.onlineTimerAccumMs < 1000 then
        return
    end
    local elapsedSec = math.floor(self.onlineTimerAccumMs / 1000)
    self.onlineTimerAccumMs = self.onlineTimerAccumMs - (elapsedSec * 1000)

    for _, c in ipairs(self.contracts or {}) do
        if c.isOnline and (c.remainingSeconds or 0) > 0 then
            c.remainingSeconds = math.max(0, c.remainingSeconds - elapsedSec)
        end
    end
    for _, o in ipairs(self.directOffers or {}) do
        if o.isOnline and (o.remainingSeconds or 0) > 0 then
            o.remainingSeconds = math.max(0, o.remainingSeconds - elapsedSec)
        end
    end

    if g_currentMission ~= nil and g_currentMission:getIsServer() and self.pendingContractActions ~= nil then
        local nowMs = g_time or 0
        local timeout = GlobalMarketContracts.PENDING_ACTION_TIMEOUT_MS or 30000
        local clearedAny = false
        for actionId, act in pairs(self.pendingContractActions) do
            if (nowMs - (act.createdAtMs or 0)) >= timeout then
                if act.subAction == "ACCEPT_CONTRACT" and act.remoteId ~= nil then
                    local _, c = GlobalMarketContracts.findOnlineEntry(self.contracts, nil, act.remoteId)
                    if c ~= nil and c.pendingAcceptFarmId == act.farmId then
                        c.pendingAcceptFarmId = nil
                        clearedAny = true
                    end
                end
                self.pendingContractActions[actionId] = nil
            end
        end
        if clearedAny and self.broadcastContractsState ~= nil then
            self:broadcastContractsState()
        end
    end
end

---Developer console command for Stage 2 testing (`gmTestOnlineContracts <on|off|mock>`)
function GlobalMarket:consoleCommandTestOnlineContracts(cmdArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if not g_currentMission:getIsServer() then
        return "Execute gmTestOnlineContracts directly on the server/SP host."
    end
    local arg = string.lower(tostring(cmdArg or "mock"))
    if arg == "on" then
        self.debugForceOnlineContracts = true
        self.onlineContractsSupported = true
        self.isOnline = true
        self:broadcastContractsState()
        return "Stage 2 Online Contracts debug capability forced ON."
    elseif arg == "off" then
        self.debugForceOnlineContracts = false
        self:broadcastContractsState()
        return "Stage 2 Online Contracts debug capability override OFF."
    end

    self.debugForceOnlineContracts = true
    self.onlineContractsSupported = true
    self.isOnline = true
    local results = {}
    for _, c in ipairs(self.contracts or {}) do
        if c.isOnline and c.status == "PENDING_CREATE" and c.pendingActionId ~= nil then
            table.insert(results, { actionId = c.pendingActionId, subAction = "CREATE_CONTRACT", status = "ACCEPTED", remoteId = "mock_c_" .. tostring(c.id), remainingSeconds = c.remainingSeconds })
        end
    end
    for _, o in ipairs(self.directOffers or {}) do
        if o.isOnline and o.status == "PENDING_CREATE" and o.pendingActionId ~= nil then
            table.insert(results, { actionId = o.pendingActionId, subAction = "CREATE_OFFER", status = "ACCEPTED", remoteId = "mock_o_" .. tostring(o.id), remainingSeconds = o.remainingSeconds })
        end
    end
    self:applyOnlineContractSyncPacket({
        actionResults = results,
        contracts = {
            { remoteId = "mock_foreign_c1", origin = "ONLINE", isNpc = false, issuerServerId = "remote_srv_9999", issuerFarmId = 2, issuerName = "Mock Partner [EU]", contractorServerId = "", contractorFarmId = 0, fillType = "WHEAT", totalLiters = 50000, deliveredLiters = 0, baseTrendFactor = 1.0, bonusPct = 14, remainingSeconds = 172800, status = "OPEN" }
        },
        directOffers = {
            { remoteId = "mock_foreign_o1", origin = "ONLINE", isNpc = false, sellerServerId = "remote_srv_9999", sellerFarmId = 2, sellerName = "Mock Trader [EU]", fillType = "BARLEY", totalLiters = 30000, remainingLiters = 30000, priceDeltaPct = -6, allowPartial = true, remainingSeconds = 86400, wasBale = false, wasPallet = false, status = "OPEN" }
        }
    })
    return "Injected mock Stage 2 online contract, direct offer, and accepted pending creates."
end

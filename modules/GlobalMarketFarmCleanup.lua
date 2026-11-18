-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketFarmCleanup.lua
-- Server-side cleanup of all farm-keyed GlobalMarket data on MessageType.FARM_DELETED (#30).
-- The base game reuses the lowest free farm ID, so orphaned data would otherwise be inherited
-- by the next farm created with the same ID.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketFarmCleanup = {}
GlobalMarketFarmCleanup.MAX_ORPHANED_REMOTE_IDS = 256

---Returns true when an online remoteId belonged to a deleted farm of this savegame
---@param remoteId string|nil
---@return boolean
function GlobalMarket:isOrphanedOnlineRemoteId(remoteId)
    return remoteId ~= nil and remoteId ~= "" and self.orphanedRemoteLookup ~= nil and self.orphanedRemoteLookup[remoteId] == true
end

---Records an online remoteId into the bounded, persisted FIFO orphan list
---@param remoteId string|nil
function GlobalMarket:markOrphanedOnlineRemoteId(remoteId)
    if remoteId == nil or remoteId == "" then
        return
    end
    self.orphanedRemoteIds = self.orphanedRemoteIds or {}
    self.orphanedRemoteLookup = self.orphanedRemoteLookup or {}
    if self.orphanedRemoteLookup[remoteId] then
        return
    end
    table.insert(self.orphanedRemoteIds, remoteId)
    self.orphanedRemoteLookup[remoteId] = true
    while #self.orphanedRemoteIds > GlobalMarketFarmCleanup.MAX_ORPHANED_REMOTE_IDS do
        local evicted = table.remove(self.orphanedRemoteIds, 1)
        if evicted ~= nil then
            self.orphanedRemoteLookup[evicted] = nil
        end
    end
end

---Handles a late backend actionResult for an action dispatched by a farm that no longer exists
---(accepted CREATE_* results are cancelled immediately so the listing never stays ownerless)
---@param res table
function GlobalMarket:handleOrphanedActionResult(res)
    local info = self.orphanedActionIds[res.actionId]
    self.orphanedActionIds[res.actionId] = nil
    if info == nil or res.remoteId == nil or res.remoteId == "" then
        return
    end
    self:markOrphanedOnlineRemoteId(res.remoteId)
    if res.status ~= "ACCEPTED" then
        return
    end
    local cancelSub = (info.subAction == "CREATE_CONTRACT" and "CANCEL_CONTRACT")
        or (info.subAction == "CREATE_OFFER" and "CANCEL_OFFER") or nil
    if cancelSub ~= nil then
        self:dispatchOnlineContractAction({
            subAction = cancelSub,
            actionId = self:nextOnlineContractActionId(),
            serverId = self:ensureServerInstanceId(),
            farmId = info.farmId,
            remoteId = res.remoteId
        })
    end
end

---Cleans up local + online contracts, direct offers, pending actions and the Pickup Inbox of a deleted farm
---@param farmId number
---@return boolean changed
function GlobalMarket:cleanupContractsForDeletedFarm(farmId)
    local changed = false
    local myServerId = (self.ensureServerInstanceId ~= nil) and self:ensureServerInstanceId() or ""
    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_SELL
    self.orphanedActionIds = self.orphanedActionIds or {}

    -- 1. Pending online actions (ACCEPT_CONTRACT / BUY_OFFER / CREATE_*) of the farm
    for actionId, act in pairs(self.pendingContractActions or {}) do
        if act.farmId == farmId then
            self.orphanedActionIds[actionId] = { subAction = act.subAction, farmId = farmId }
            self:markOrphanedOnlineRemoteId(act.remoteId)
            self.pendingContractActions[actionId] = nil
        end
    end

    -- 2. Supply contracts
    for i = #(self.contracts or {}), 1, -1 do
        local c = self.contracts[i]
        local isIssuer = (c.issuerFarmId == farmId) and (not c.isOnline or c.issuerServerId == myServerId)
        local isContractor = (c.contractorFarmId == farmId) and (not c.isOnline or c.contractorServerId == myServerId)
        if c.pendingAcceptFarmId == farmId then
            c.pendingAcceptFarmId = nil
            changed = true
        end
        if isIssuer or isContractor then
            if c.isOnline then
                if c.pendingActionId ~= nil and c.pendingActionId ~= "" then
                    self.orphanedActionIds[c.pendingActionId] = { subAction = (c.status == "PENDING_CREATE") and "CREATE_CONTRACT" or "CANCEL_CONTRACT", farmId = farmId }
                end
                if isIssuer and c.status == "OPEN" and c.remoteId ~= nil and c.remoteId ~= "" then
                    self:dispatchOnlineContractAction({
                        subAction = "CANCEL_CONTRACT", actionId = self:nextOnlineContractActionId(),
                        serverId = myServerId, farmId = farmId, remoteId = c.remoteId
                    })
                end
                self:markOrphanedOnlineRemoteId(c.remoteId)
            elseif isContractor and not isIssuer and c.origin ~= "NPC" and (c.issuerFarmId or 0) > 0 then
                -- Local player issuer keeps the delivered goods and gets the unused escrow back
                local refund = math.max(0, math.floor((c.escrowRemaining or 0) + 0.5))
                if refund > 0 and g_farmManager:getFarmById(c.issuerFarmId) ~= nil then
                    g_currentMission:addMoney(refund, c.issuerFarmId, contractMoneyType, true, true)
                end
            end
            table.remove(self.contracts, i)
            changed = true
        end
    end

    -- 3. Direct offers
    for i = #(self.directOffers or {}), 1, -1 do
        local o = self.directOffers[i]
        if o.sellerFarmId == farmId and (not o.isOnline or o.sellerServerId == myServerId) then
            if o.isOnline then
                if o.pendingActionId ~= nil and o.pendingActionId ~= "" then
                    self.orphanedActionIds[o.pendingActionId] = { subAction = (o.status == "PENDING_CREATE") and "CREATE_OFFER" or "CANCEL_OFFER", farmId = farmId }
                end
                if o.status == "OPEN" and o.remoteId ~= nil and o.remoteId ~= "" then
                    self:dispatchOnlineContractAction({
                        subAction = "CANCEL_OFFER", actionId = self:nextOnlineContractActionId(),
                        serverId = myServerId, farmId = farmId, remoteId = o.remoteId
                    })
                end
                self:markOrphanedOnlineRemoteId(o.remoteId)
            end
            table.remove(self.directOffers, i)
            changed = true
        end
    end

    -- 4. Pickup Inbox
    for i = #(self.pickupInbox or {}), 1, -1 do
        if self.pickupInbox[i].farmId == farmId then
            table.remove(self.pickupInbox, i)
            changed = true
        end
    end

    return changed
end

---Removes a deleted farm's share from all GM bulk silos and GM object storages
---@param farmId number
---@return number removedLiters
function GlobalMarket:cleanupGmStorageForDeletedFarm(farmId)
    local removedTotal = 0
    if g_currentMission.placeableSystem == nil or g_currentMission.placeableSystem.placeables == nil then
        return 0
    end

    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.isGmMarket then
            -- Bulk GM silos: shadow array share is physically removed and synced to clients as 0
            if placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                for _, storage in ipairs(placeable.spec_silo.storages) do
                    local farmLevels = storage.gmFarmFillLevels ~= nil and storage.gmFarmFillLevels[farmId] or nil
                    if farmLevels ~= nil then
                        for fillTypeIndex, level in pairs(farmLevels) do
                            if (level or 0) > 0 then
                                local physLevel = storage:getFillLevel(fillTypeIndex)
                                storage.gmTempFarmId = nil
                                storage:setFillLevel(math.max(0, physLevel - level), fillTypeIndex, nil)
                                removedTotal = removedTotal + level
                                if g_server ~= nil and SyncGmSiloEvent ~= nil then
                                    g_server:broadcastEvent(SyncGmSiloEvent.new(storage, farmId, fillTypeIndex, 0))
                                end
                            end
                        end
                        storage.gmFarmFillLevels[farmId] = nil
                    end
                    if storage.gmStorageTracker ~= nil then
                        storage.gmStorageTracker[farmId] = nil
                    end
                end
            end

            -- GM object storages: farm-owned bales/pallets are removed per fill type
            if placeable.spec_objectStorage ~= nil and placeable.spec_objectStorage.storedObjects ~= nil
                and GlobalMarketFinance ~= nil and GlobalMarketFinance.removeExpiredObjectsFromStorage ~= nil then
                local fillTypes = {}
                for _, obj in ipairs(placeable.spec_objectStorage.storedObjects) do
                    local objFillType, objFarmId = nil, nil
                    if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                        objFillType = (obj.baleObject ~= nil and obj.baleObject:getFillType()) or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                        objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId)
                    elseif obj.REFERENCE_CLASS_NAME == "Vehicle" and obj.palletAttributes ~= nil then
                        objFillType = obj.palletAttributes.fillType
                        objFarmId = obj.palletAttributes.ownerFarmId
                    end
                    if objFillType ~= nil and objFarmId == farmId then
                        fillTypes[objFillType] = true
                    end
                end
                for fillTypeIndex, _ in pairs(fillTypes) do
                    removedTotal = removedTotal + GlobalMarketFinance.removeExpiredObjectsFromStorage(placeable, farmId, fillTypeIndex)
                end
                if placeable.gmObjectTracker ~= nil then
                    placeable.gmObjectTracker[farmId] = nil
                end
            end
        end
    end
    return removedTotal
end

---MessageType.FARM_DELETED subscriber (server only)
---@param farmId number
function GlobalMarket:onFarmDeleted(farmId)
    if g_server == nil or farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end

    local contractsChanged = self:cleanupContractsForDeletedFarm(farmId)
    local removedLiters = self:cleanupGmStorageForDeletedFarm(farmId)

    if contractsChanged then
        if self.replenishNpcContractsAndOffers ~= nil then
            self:replenishNpcContractsAndOffers()
        end
        if self.broadcastContractsState ~= nil then
            self:broadcastContractsState()
        end
    end
    if removedLiters > 0 and not g_dedicatedServer and self.ui ~= nil and self.ui.updateContent ~= nil then
        self.ui:updateContent()
    end

    if self.debugManager ~= nil then
        self.debugManager:info("Farm Cleanup: Farm %d deleted. Contracts/offers/inbox cleaned: %s | GM storage removed: %.0f L",
            farmId, tostring(contractsChanged), removedLiters)
    end
end

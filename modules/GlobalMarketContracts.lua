-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContracts.lua
-- Supply contracts (#25 T4xs), +/-10% direct offers (Tensuko), NPC simulation & escrow.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketContracts = {}
GlobalMarketContracts.MAX_ACTIVE_CONTRACTS_PER_FARM = 3
GlobalMarketContracts.CONTRACT_PLAYER_BONUS_MIN = 5
GlobalMarketContracts.CONTRACT_PLAYER_BONUS_MAX = 20
GlobalMarketContracts.CONTRACT_NPC_BONUS_MIN = 8
GlobalMarketContracts.CONTRACT_NPC_BONUS_MAX = 18
GlobalMarketContracts.CONTRACT_DURATION_MIN = 1
GlobalMarketContracts.CONTRACT_DURATION_MAX = 6
GlobalMarketContracts.OFFER_DELTA_MIN = -10
GlobalMarketContracts.OFFER_DELTA_MAX = 10
GlobalMarketContracts.OFFER_DURATION_MIN = 1
GlobalMarketContracts.OFFER_DURATION_MAX = 3
GlobalMarketContracts.PENALTY_RATE = 0.15
GlobalMarketContracts.INBOX_GRACE_MONTHS = 2.0
GlobalMarketContracts.INBOX_LIQUIDATION_FACTOR = 0.85

GlobalMarketContracts.NPC_MODE_ALL = 1
GlobalMarketContracts.NPC_MODE_CONTRACTS_ONLY = 2
GlobalMarketContracts.NPC_MODE_PLAYERS_ONLY = 3

GlobalMarketContracts.TARGET_NPC_CONTRACTS = 5
GlobalMarketContracts.TARGET_NPC_OFFERS = 3

-- Stock-driven NPC seeding (#29): minimum pick weight per good, extra contract weight during Great Demand
GlobalMarketContracts.NPC_WEIGHT_FLOOR = 0.05
GlobalMarketContracts.NPC_GREAT_DEMAND_WEIGHT = 1.0
GlobalMarketContracts.NPC_OFFER_DELTA_MIN = 1
GlobalMarketContracts.NPC_OFFER_DELTA_MAX = 8

GlobalMarketContracts.NPC_CONTRACTORS = {
    "AgroFood Processing",
    "Nordland Mühle",
    "BioEnergie Werk",
    "RegioKartoffel GmbH",
    "SüdZucker Depot"
}

GlobalMarketContracts.NPC_TRADERS = {
    "Landhandel Ost",
    "Hofkontor Mitte",
    "AgrarDepot West"
}

---Initializes runtime tables for contracts, direct offers, and Pickup Inbox
function GlobalMarket:initContractsSystem()
    self.contractsBroadcastFingerprint = nil
    self.contracts = {}
    self.directOffers = {}
    self.nextContractId = 1
    self.nextOfferId = 1
    if self.initPickupInbox ~= nil then
        self:initPickupInbox()
    end
    if self.initOnlineContractsSystem ~= nil then
        self:initOnlineContractsSystem()
    end
end

---Broadcasts full contracts/offers/inbox snapshot to clients and refreshes local UI if visible
function GlobalMarket:broadcastContractsState()
    -- Refresh map station targets (#27) before the snapshot so vanished stations are synced as cleared
    if self.rebuildContractStationIndex ~= nil then
        self:rebuildContractStationIndex()
    end
    if g_server ~= nil and SyncContractsStateEvent ~= nil then
        self.contractsBroadcastFingerprint = SyncContractsStateEvent.getFingerprint(self)
        self.contractsBroadcastMs = g_time or 0
        g_server:broadcastEvent(SyncContractsStateEvent.new())
    end
    self:refreshContractsUi()
end

---Refreshes the local market menu if it is open
function GlobalMarket:refreshContractsUi()
    local ui = self.ui or (g_currentMission ~= nil and g_currentMission.globalMarketUi or nil)
    if ui ~= nil and ui:getIsVisible() and ui.updateContent ~= nil then
        ui:updateContent()
    end
end

---Sends the snapshot only if clients would see a difference (online sync files repeat the whole board,
---e.g. every 30 s while a settlement waits for the next save). A full one follows at the latest after
---CONTRACTS_RESEND_MS, so countdowns stay in step.
function GlobalMarket:broadcastContractsStateIfChanged()
    -- Vanished map stations (#27) are cleared before the comparison
    if self.rebuildContractStationIndex ~= nil then
        self:rebuildContractStationIndex()
    end
    if g_server ~= nil and SyncContractsStateEvent ~= nil and self.contractsBroadcastFingerprint ~= nil
        and (g_time or 0) - (self.contractsBroadcastMs or 0) < GlobalMarketContracts.CONTRACTS_RESEND_MS
        and self.contractsBroadcastFingerprint == SyncContractsStateEvent.getFingerprint(self) then
        self:refreshContractsUi()
        return
    end
    self:broadcastContractsState()
end

---Resolves display name for a farmId
---@param farmId number
---@return string
function GlobalMarket:getContractFarmName(farmId)
    if farmId ~= nil and farmId > 0 and g_farmManager ~= nil then
        local farm = g_farmManager:getFarmById(farmId)
        if farm ~= nil and farm.name ~= nil and farm.name ~= "" then
            return farm.name
        end
        return string.format("Farm %d", farmId)
    end
    return "NPC"
end

---Returns the local map normal baseline price per 1,000 L for contract valuation
---@param fillTypeName string
---@return number pricePer1000
function GlobalMarket:getContractReferencePricePer1000(fillTypeName)
    local activeList = (self:getIsMarketOnline() and self.fillTypes ~= nil and #self.fillTypes > 0)
        and self.fillTypes or (self.offlineMarketFillTypes or {})
    for _, item in pairs(activeList) do
        if item.fillType == fillTypeName then
            return math.max(10, item.normalPrice or item.price or 500)
        end
    end
    if self.offlineMarketFillTypes ~= nil then
        for _, item in pairs(self.offlineMarketFillTypes) do
            if item.fillType == fillTypeName then
                return math.max(10, item.normalPrice or item.price or 500)
            end
        end
    end
    return 500
end

---Returns the active spot market price per 1,000 L used as baseline for +/-10% direct offers
---@param fillTypeName string
---@return number pricePer1000
function GlobalMarket:getCurrentMarketPricePer1000(fillTypeName)
    local activeList = (self:getIsMarketOnline() and self.fillTypes ~= nil and #self.fillTypes > 0)
        and self.fillTypes or (self.offlineMarketFillTypes or {})
    for _, item in pairs(activeList) do
        if item.fillType == fillTypeName then
            local p = (item.price ~= nil and item.price > 0) and item.price or item.normalPrice
            return math.max(10, p or 500)
        end
    end
    return self:getContractReferencePricePer1000(fillTypeName)
end

---Counts active accepted contracts held by a farm (enforces MAX_ACTIVE_CONTRACTS_PER_FARM)
---@param farmId number
---@return number count
function GlobalMarket:getActiveAcceptedContractCount(farmId)
    local count = 0
    for _, c in ipairs(self.contracts or {}) do
        if c.status == "ACTIVE" then
            if c.isOnline then
                if self.isOwnOnlineIdentity ~= nil and self:isOwnOnlineIdentity(c.contractorServerId, c.contractorFarmId, farmId) then
                    count = count + 1
                end
            elseif c.contractorFarmId == farmId then
                count = count + 1
            end
        end
    end
    if self.getPendingAcceptContractCount ~= nil then
        count = count + self:getPendingAcceptContractCount(farmId)
    end
    return count
end

---Finds an index and table entry by id inside a list
---@param list table|nil
---@param targetId number
---@return number|nil index
---@return table|nil entry
function GlobalMarketContracts.findById(list, targetId)
    if list == nil then
        return nil, nil
    end
    for i, entry in ipairs(list) do
        if entry.id == targetId then
            return i, entry
        end
    end
    return nil, nil
end

---Creates a player-issued Supply Contract and reserves 100% escrow (base + bonus) upfront
---@return boolean success
---@return number|nil contractId
function GlobalMarket:createPlayerContract(farmId, fillTypeName, totalLiters, bonusPct, durationMonths, isOnlineScope)
    if isOnlineScope == true and self.createOnlinePlayerContract ~= nil then
        return self:createOnlinePlayerContract(farmId, fillTypeName, totalLiters, bonusPct, durationMonths)
    end
    if g_server == nil or farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false, nil
    end

    local fillTypeDesc = g_fillTypeManager:getFillTypeByName(fillTypeName)
    if fillTypeDesc == nil or (GlobalMarketAPI ~= nil and not GlobalMarketAPI.getIsFillTypeAllowed(fillTypeDesc)) then
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
    local cleanMonths = math.clamp(
        math.floor((durationMonths or 2) + 0.5),
        GlobalMarketContracts.CONTRACT_DURATION_MIN,
        GlobalMarketContracts.CONTRACT_DURATION_MAX
    )

    local basePrice = self:getContractReferencePricePer1000(fillTypeName)
    local baseTotal = (cleanLiters / 1000) * basePrice
    local bonusTotal = baseTotal * (cleanBonus / 100)
    local escrowTotal = math.ceil(baseTotal + bonusTotal)

    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil or farm.money < escrowTotal then
        return false, nil
    end

    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_BUY
    g_currentMission:addMoney(escrowTotal * -1, farmId, contractMoneyType, true, true)

    self.contracts = self.contracts or {}
    self.nextContractId = self.nextContractId or 1
    local id = self.nextContractId
    self.nextContractId = id + 1

    table.insert(self.contracts, {
        id = id,
        origin = "PLAYER",
        issuerFarmId = farmId,
        issuerName = self:getContractFarmName(farmId),
        contractorFarmId = 0,
        fillType = fillTypeName,
        totalLiters = cleanLiters,
        deliveredLiters = 0,
        basePricePer1000 = basePrice,
        bonusPct = cleanBonus,
        escrowRemaining = escrowTotal,
        monthsRemaining = cleanMonths,
        status = "OPEN"
    })

    if self.debugManager ~= nil then
        self.debugManager:info("Contracts: Farm %d posted contract #%d (%d L %s, +%d%% bonus, Escrow=%d EUR).",
            farmId, id, cleanLiters, tostring(fillTypeName), cleanBonus, escrowTotal)
    end
    self:broadcastContractsState()
    return true, id
end

---Cancels an open (unaccepted) player-issued contract and refunds 100% escrow
---@param farmId number
---@param contractId number
---@return boolean success
function GlobalMarket:cancelPlayerContract(farmId, contractId)
    if g_server == nil then
        return false
    end
    local idx, contract = GlobalMarketContracts.findById(self.contracts, contractId)
    if contract ~= nil and contract.isOnline and self.cancelOnlineContract ~= nil then
        return self:cancelOnlineContract(farmId, contract)
    end
    if contract == nil or contract.origin ~= "PLAYER" or contract.issuerFarmId ~= farmId or contract.status ~= "OPEN" then
        return false
    end

    local refund = math.max(0, math.floor((contract.escrowRemaining or 0) + 0.5))
    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_BUY
    if refund > 0 then
        g_currentMission:addMoney(refund, farmId, contractMoneyType, true, true)
    end

    table.remove(self.contracts, idx)
    if self.debugManager ~= nil then
        self.debugManager:info("Contracts: Farm %d cancelled open contract #%d (Refund=%d EUR).", farmId, contractId, refund)
    end
    self:broadcastContractsState()
    return true
end

---Accepts an open supply contract exclusively for a farm (subject to 3-contract farm cap)
---@param farmId number
---@param contractId number
---@return boolean success
function GlobalMarket:acceptContract(farmId, contractId)
    if g_server == nil or farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false
    end
    local _, contract = GlobalMarketContracts.findById(self.contracts, contractId)
    if contract ~= nil and contract.isOnline and self.requestAcceptOnlineContract ~= nil then
        return self:requestAcceptOnlineContract(farmId, contract)
    end
    if contract == nil or contract.status ~= "OPEN" then
        return false
    end
    if contract.origin == "PLAYER" and contract.issuerFarmId == farmId then
        return false
    end
    if self:getActiveAcceptedContractCount(farmId) >= GlobalMarketContracts.MAX_ACTIVE_CONTRACTS_PER_FARM then
        return false
    end

    contract.status = "ACTIVE"
    contract.contractorFarmId = farmId
    if self.debugManager ~= nil then
        self.debugManager:info("Contracts: Farm %d accepted contract #%d (%s).",
            farmId, contractId, tostring(contract.fillType))
    end
    self:broadcastContractsState()
    return true
end

---Delivers partial or full goods from farm storage against an accepted active contract
---@return boolean success
---@return number creditedLiters
function GlobalMarket:deliverToContract(
    farmId, contractId, requestedLiters, targetStorage, isObjectStorage, formatXml
)
    if g_server == nil or farmId == nil or farmId <= 0 then
        return false, 0
    end
    -- Settle pending map station unloads (#27) first so the open amount is up to date
    if self.stationCreditsDirty and self.flushStationContractCredits ~= nil then
        self:flushStationContractCredits()
    end
    local idx, contract = GlobalMarketContracts.findById(self.contracts, contractId)
    if contract ~= nil and contract.isOnline and self.deliverToOnlineContract ~= nil then
        return self:deliverToOnlineContract(farmId, contract, requestedLiters, targetStorage, isObjectStorage, formatXml)
    end
    if contract == nil or contract.status ~= "ACTIVE" or contract.contractorFarmId ~= farmId then
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

    -- Settle any minor rounding excess from full-bale/pallet completion at normal market spot price
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
        local cap = GlobalMarket.MARKET_CAPACITY or 2000000
        for _, ft in pairs(self.offlineMarketFillTypes or {}) do
            if ft.fillType == contract.fillType then
                ft.fillLevel = math.clamp((ft.fillLevel or 0) + excessLiters, 0, cap)
                break
            end
        end
    end

    local completed = self:creditContractLiters(contract, idx, farmId, creditedLiters, true)
    if not completed and self.debugManager ~= nil then
        self.debugManager:info("Contracts: Farm %d delivered %.0f L to contract #%d (%.0f/%.0f L).",
            farmId, creditedLiters, contract.id, contract.deliveredLiters, contract.totalLiters)
    end
    self:broadcastContractsState()
    return true, creditedLiters
end

---Pays the contract base price for credited liters, routes the goods and settles completion bonus.
---Shared by menu deliveries (deliverToContract) and physical map station unloads (#27).
---@param contract table Active local contract
---@param idx number|nil Index of the contract inside self.contracts (resolved if nil)
---@param farmId number Contractor farm receiving the payout
---@param creditedLiters number Liters counted towards the contract (already capped to the open amount)
---@param addToMarketStock boolean True if NPC goods should be added to GM market stock (menu delivery)
---@return boolean completed True if the contract was completed and removed
function GlobalMarket:creditContractLiters(contract, idx, farmId, creditedLiters, addToMarketStock)
    if contract == nil or creditedLiters == nil or creditedLiters <= 0 then
        return false
    end
    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_SELL

    local basePayout = math.floor(((creditedLiters / 1000) * (contract.basePricePer1000 or 500)) + 0.5)
    if basePayout > 0 then
        g_currentMission:addMoney(basePayout, farmId, contractMoneyType, true, true)
    end

    if contract.origin == "PLAYER" then
        contract.escrowRemaining = math.max(0, (contract.escrowRemaining or 0) - basePayout)
        if self.addPickupInboxItem ~= nil then
            local srcLabel = string.format("#%d (%s)", contract.id, self:getContractFarmName(farmId))
            self:addPickupInboxItem(contract.issuerFarmId, contract.fillType, creditedLiters, "CONTRACT_DELIVERY", srcLabel)
        end
    elseif addToMarketStock then
        local cap = GlobalMarket.MARKET_CAPACITY or 2000000
        for _, ft in pairs(self.offlineMarketFillTypes or {}) do
            if ft.fillType == contract.fillType then
                ft.fillLevel = math.clamp((ft.fillLevel or 0) + creditedLiters, 0, cap)
                break
            end
        end
    end

    contract.deliveredLiters = (contract.deliveredLiters or 0) + creditedLiters
    if contract.deliveredLiters >= (contract.totalLiters - 0.5) then
        local bonusPayout
        if contract.origin == "PLAYER" then
            bonusPayout = math.max(0, math.floor((contract.escrowRemaining or 0) + 0.5))
        else
            bonusPayout = math.floor(
                ((contract.totalLiters / 1000) * (contract.basePricePer1000 or 500) * ((contract.bonusPct or 0) / 100)) + 0.5
            )
        end
        if bonusPayout > 0 then
            g_currentMission:addMoney(bonusPayout, farmId, contractMoneyType, true, true)
        end
        if self.debugManager ~= nil then
            self.debugManager:info("Contracts: Contract #%d completed by Farm %d (Bonus=%d EUR).", contract.id, farmId, bonusPayout)
        end
        if idx == nil or self.contracts[idx] ~= contract then
            idx = GlobalMarketContracts.findById(self.contracts, contract.id)
        end
        if idx ~= nil then
            table.remove(self.contracts, idx)
        end
        return true
    end
    return false
end

---Collects allowed fillTypes present in the current market for NPC contract/offer seeding
---@return table candidates
function GlobalMarket:getNpcContractCandidates()
    local candidates = {}
    for _, item in pairs(self.offlineMarketFillTypes or {}) do
        if item ~= nil and item.fillType ~= nil and (item.normalPrice or item.price or 0) > 10 then
            table.insert(candidates, item)
        end
    end
    return candidates
end

---Market stock ratio of a market entry (0 = empty, 1 = saturated). The shared market list
---holds the global online stock for APPROVED goods and the local stock otherwise.
---@param item table
---@return number ratio
function GlobalMarketContracts.getStockRatio(item)
    local cap = GlobalMarket.MARKET_CAPACITY or 2000000
    if cap <= 0 then
        return 0.5
    end
    return math.clamp((item.fillLevel or 0) / cap, 0, 1)
end

---Pick weight for an NPC supply contract: scarce goods and Great Demand are preferred
---@param item table
---@return number weight
function GlobalMarketContracts.getNpcContractWeight(item)
    local scarcity = 1 - GlobalMarketContracts.getStockRatio(item)
    local weight = scarcity * scarcity + GlobalMarketContracts.NPC_WEIGHT_FLOOR
    if item.isGreatDemand == true then
        weight = weight + GlobalMarketContracts.NPC_GREAT_DEMAND_WEIGHT
    end
    return weight
end

---Pick weight for an NPC direct offer: goods in surplus are preferred
---@param item table
---@return number weight
function GlobalMarketContracts.getNpcOfferWeight(item)
    local ratio = GlobalMarketContracts.getStockRatio(item)
    return ratio * ratio + GlobalMarketContracts.NPC_WEIGHT_FLOOR
end

---Picks one candidate with probability proportional to weightFn(candidate)
---@param candidates table
---@param weightFn function
---@return table|nil candidate
function GlobalMarketContracts.pickWeighted(candidates, weightFn)
    local weights = {}
    local total = 0
    for i, item in ipairs(candidates) do
        local w = math.max(0, weightFn(item) or 0)
        weights[i] = w
        total = total + w
    end
    if total <= 0 then
        return candidates[math.random(1, #candidates)]
    end
    local roll = math.random() * total
    for i, item in ipairs(candidates) do
        roll = roll - weights[i]
        if roll <= 0 then
            return item
        end
    end
    return candidates[#candidates]
end

---Integer in [minValue, maxValue] that moves towards maxValue as t goes from 0 to 1,
---with +/-25 % random spread so equal stock levels still vary
---@param minValue number
---@param maxValue number
---@param t number 0..1
---@return number value
function GlobalMarketContracts.scaleByRatio(minValue, maxValue, t)
    local spread = maxValue - minValue
    local value = minValue + spread * math.clamp(t, 0, 1) + (math.random() * 2 - 1) * spread * 0.25
    return math.clamp(math.floor(value + 0.5), minValue, maxValue)
end

---Seeds NPC contracts and NPC direct offers up to target counts according to NPC_ACTIVITY_MODE
---@return boolean changed
function GlobalMarket:replenishNpcContractsAndOffers()
    if g_server == nil then
        return false
    end
    local mode = GlobalMarket.NPC_ACTIVITY_MODE or GlobalMarketContracts.NPC_MODE_ALL
    local changed = false
    self.contracts = self.contracts or {}
    self.directOffers = self.directOffers or {}

    local candidates = self:getNpcContractCandidates()
    if #candidates == 0 then
        return false
    end

    -- 1. NPC Supply Contracts (Modes: ALL and CONTRACTS_ONLY)
    if mode ~= GlobalMarketContracts.NPC_MODE_PLAYERS_ONLY then
        local openNpcContracts = 0
        for _, c in ipairs(self.contracts) do
            if c.origin == "NPC" and c.status == "OPEN" then
                openNpcContracts = openNpcContracts + 1
            end
        end

        while openNpcContracts < GlobalMarketContracts.TARGET_NPC_CONTRACTS do
            -- Scarce goods are picked more often and pay a higher bonus for larger volumes (#29)
            local pick = GlobalMarketContracts.pickWeighted(candidates, GlobalMarketContracts.getNpcContractWeight)
            local scarcity = 1 - GlobalMarketContracts.getStockRatio(pick)
            local liters = GlobalMarketContracts.scaleByRatio(2, 16, scarcity) * 10000
            local bonusPct = GlobalMarketContracts.scaleByRatio(GlobalMarketContracts.CONTRACT_NPC_BONUS_MIN, GlobalMarketContracts.CONTRACT_NPC_BONUS_MAX, scarcity)
            local months = math.random(2, 5)
            local contractor = GlobalMarketContracts.NPC_CONTRACTORS[math.random(1, #GlobalMarketContracts.NPC_CONTRACTORS)]
            local basePrice = self:getContractReferencePricePer1000(pick.fillType)

            self.nextContractId = self.nextContractId or 1
            local id = self.nextContractId
            self.nextContractId = id + 1

            local npcContract = {
                id = id,
                origin = "NPC",
                issuerFarmId = 0,
                issuerName = contractor,
                contractorFarmId = 0,
                fillType = pick.fillType,
                totalLiters = liters,
                deliveredLiters = 0,
                basePricePer1000 = basePrice,
                bonusPct = bonusPct,
                escrowRemaining = 0,
                monthsRemaining = months,
                status = "OPEN"
            }
            -- Prefer a real map selling station / unowned production as buyer (#27); keeps fictional name otherwise
            if self.assignContractStation ~= nil then
                self:assignContractStation(npcContract)
            end
            table.insert(self.contracts, npcContract)
            openNpcContracts = openNpcContracts + 1
            changed = true
        end
    end

    -- 2. NPC Direct Offers (Mode: ALL only)
    if mode == GlobalMarketContracts.NPC_MODE_ALL and self.replenishNpcOffers ~= nil then
        if self:replenishNpcOffers(candidates) then
            changed = true
        end
    end

    return changed
end

---Ensures initial NPC board entries exist on a fresh savegame once prices are initialized
function GlobalMarket:ensureInitialNpcBoard()
    if g_server == nil then
        return
    end
    if self:replenishNpcContractsAndOffers() then
        self:broadcastContractsState()
    end
end

---Reacts immediately when an Admin updates GlobalMarket.NPC_ACTIVITY_MODE
---@param newMode number
function GlobalMarket:onNpcActivityModeChanged(newMode)
    if g_server == nil then
        return
    end
    local changed = false
    if newMode == GlobalMarketContracts.NPC_MODE_PLAYERS_ONLY then
        for i = #(self.contracts or {}), 1, -1 do
            if self.contracts[i].origin == "NPC" and self.contracts[i].status == "OPEN" then
                table.remove(self.contracts, i)
                changed = true
            end
        end
    end
    if newMode ~= GlobalMarketContracts.NPC_MODE_ALL then
        for i = #(self.directOffers or {}), 1, -1 do
            if self.directOffers[i].origin == "NPC" then
                table.remove(self.directOffers, i)
                changed = true
            end
        end
    end
    if self:replenishNpcContractsAndOffers() then
        changed = true
    end
    if changed then
        self:broadcastContractsState()
    end
end

---Reacts immediately when an Admin changes the contract board limits (#26).
---Trims surplus unaccepted OPEN NPC contracts and NPC offers (newest first) when lowered, replenishes when raised.
---Accepted (ACTIVE) contracts and player/online entries are never touched; the per-farm cap only blocks new accepts.
function GlobalMarket:onContractLimitsChanged()
    if g_server == nil then
        return
    end
    local changed = false
    local keepContracts = math.max(0, GlobalMarketContracts.TARGET_NPC_CONTRACTS or 0)
    local openNpcContracts = 0
    for _, c in ipairs(self.contracts or {}) do
        if c.origin == "NPC" and c.status == "OPEN" then
            openNpcContracts = openNpcContracts + 1
        end
    end
    for i = #(self.contracts or {}), 1, -1 do
        local c = self.contracts[i]
        if openNpcContracts > keepContracts and c.origin == "NPC" and c.status == "OPEN" then
            table.remove(self.contracts, i)
            openNpcContracts = openNpcContracts - 1
            changed = true
        end
    end

    local keepOffers = math.max(0, GlobalMarketContracts.TARGET_NPC_OFFERS or 0)
    local npcOffers = 0
    for _, o in ipairs(self.directOffers or {}) do
        if o.origin == "NPC" then
            npcOffers = npcOffers + 1
        end
    end
    for i = #(self.directOffers or {}), 1, -1 do
        if npcOffers > keepOffers and self.directOffers[i].origin == "NPC" then
            table.remove(self.directOffers, i)
            npcOffers = npcOffers - 1
            changed = true
        end
    end

    if self:replenishNpcContractsAndOffers() then
        changed = true
    end
    if changed then
        self:broadcastContractsState()
    end
end

---Evaluates contract deadlines, direct offer expirations, Pickup Inbox liquidation & NPC cycles hourly
---@param customMonthDelta number|nil
---@return boolean changed
function GlobalMarket:updateContractsAndOffersHourly(customMonthDelta)
    if g_server == nil then
        return false
    end

    -- Settle pending map station unloads (#27) before deadlines and penalties are evaluated
    if self.stationCreditsDirty and self.flushStationContractCredits ~= nil then
        self:flushStationContractCredits()
    end

    local daysPerPeriod = (g_currentMission ~= nil and g_currentMission.environment ~= nil
        and g_currentMission.environment.daysPerPeriod) or 1
    daysPerPeriod = math.max(1, daysPerPeriod)
    local monthDelta = customMonthDelta or (1.0 / (24.0 * daysPerPeriod))
    local changed = false

    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_SELL
    local penaltyMoneyType = MoneyType.GM_PENALTIES or MoneyType.GM_FEE

    -- 1. Tick Contracts & enforce deadlines / escrow refunds / 15% penalty
    for i = #(self.contracts or {}), 1, -1 do
        local c = self.contracts[i]
        if not c.isOnline then
            c.monthsRemaining = (c.monthsRemaining or 1.0) - monthDelta
            if c.monthsRemaining <= 0 then
                if c.status == "OPEN" then
                    if c.origin == "PLAYER" and (c.escrowRemaining or 0) > 0 and c.issuerFarmId > 0 then
                        g_currentMission:addMoney(c.escrowRemaining, c.issuerFarmId, contractMoneyType, true, true)
                    end
                elseif c.status == "ACTIVE" then
                    local missing = math.max(0, (c.totalLiters or 0) - (c.deliveredLiters or 0))
                    local missingBase = (missing / 1000) * (c.basePricePer1000 or 500)
                    local penalty = math.ceil(missingBase * GlobalMarketContracts.PENALTY_RATE)

                    if penalty > 0 and c.contractorFarmId ~= nil and c.contractorFarmId > 0 then
                        g_currentMission:addMoney(penalty * -1, c.contractorFarmId, penaltyMoneyType, true, true)
                    end

                    if c.origin == "PLAYER" and c.issuerFarmId ~= nil and c.issuerFarmId > 0 then
                        local escrowRefund = math.max(0, math.floor((c.escrowRemaining or 0) + 0.5))
                        if escrowRefund > 0 then
                            g_currentMission:addMoney(escrowRefund, c.issuerFarmId, contractMoneyType, true, true)
                        end
                        if penalty > 0 then
                            g_currentMission:addMoney(penalty, c.issuerFarmId, penaltyMoneyType, true, true)
                        end
                    end

                    if self.debugManager ~= nil then
                        self.debugManager:info(
                            "Contracts: Contract #%d expired incomplete (Missing %.0f L, Penalty=%d EUR on Farm %d).",
                            c.id, missing, penalty, c.contractorFarmId or 0
                        )
                    end
                end
                table.remove(self.contracts, i)
                changed = true
            end
        end
    end

    -- 2. Tick Direct Offers & move expired unsold player lots to Pickup Inbox
    for i = #(self.directOffers or {}), 1, -1 do
        local o = self.directOffers[i]
        if not o.isOnline then
            o.monthsRemaining = (o.monthsRemaining or 1.0) - monthDelta
            if o.monthsRemaining <= 0 then
                if o.origin == "PLAYER" and (o.remainingLiters or 0) > 0.5 and o.sellerFarmId ~= nil and o.sellerFarmId > 0 then
                    if self.addPickupInboxItem ~= nil then
                        self:addPickupInboxItem(o.sellerFarmId, o.fillType, o.remainingLiters, "OFFER_EXPIRED", string.format("#%d", o.id))
                    end
                end
                table.remove(self.directOffers, i)
                changed = true
            end
        end
    end

    -- 3. Tick Pickup Inbox (2-month grace -> -15% liquidation)
    if self.tickPickupInbox ~= nil and self:tickPickupInbox(monthDelta) then
        changed = true
    end

    -- 4. NPC buyer activity & replenishment
    if self.processNpcDirectOfferBuying ~= nil and self:processNpcDirectOfferBuying() then
        changed = true
    end
    if self:replenishNpcContractsAndOffers() then
        changed = true
    end

    if changed then
        self:broadcastContractsState()
    end
    return changed
end

---Developer console command to advance contract, direct offer, and inbox timers (`gmAdvanceContracts [months]`)
---@param monthsArg string|nil
---@return string
function GlobalMarket:consoleCommandAdvanceContracts(monthsArg)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if not g_currentMission:getIsServer() and not g_currentMission.isMasterUser then
        return "Permission denied: Only Server or MasterUser can advance contract timers."
    end
    if not g_currentMission:getIsServer() then
        return "Execute gmAdvanceContracts directly on the server/SP host."
    end

    local delta = tonumber(monthsArg) or 1.0
    if delta <= 0 then
        delta = 1.0
    end
    self:updateContractsAndOffersHourly(delta)
    return string.format("Advanced contracts, direct offers, and Pickup Inbox by +%.2f month(s).", delta)
end

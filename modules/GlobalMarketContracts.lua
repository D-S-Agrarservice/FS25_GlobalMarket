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
    self.contracts = {}
    self.directOffers = {}
    self.nextContractId = 1
    self.nextOfferId = 1
    if self.initPickupInbox ~= nil then
        self:initPickupInbox()
    end
end

---Broadcasts full contracts/offers/inbox snapshot to clients and refreshes local UI if visible
function GlobalMarket:broadcastContractsState()
    if g_server ~= nil and SyncContractsStateEvent ~= nil then
        g_server:broadcastEvent(SyncContractsStateEvent.new())
    end
    local ui = self.ui or (g_currentMission ~= nil and g_currentMission.globalMarketUi or nil)
    if ui ~= nil and ui:getIsVisible() and ui.updateContent ~= nil then
        ui:updateContent()
    end
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
        if c.status == "ACTIVE" and c.contractorFarmId == farmId then
            count = count + 1
        end
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
function GlobalMarket:createPlayerContract(farmId, fillTypeName, totalLiters, bonusPct, durationMonths)
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
    local idx, contract = GlobalMarketContracts.findById(self.contracts, contractId)
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

    local basePayout = math.floor(((creditedLiters / 1000) * (contract.basePricePer1000 or 500)) + 0.5)
    local contractMoneyType = MoneyType.GM_CONTRACTS or MoneyType.GM_SELL
    if basePayout > 0 then
        g_currentMission:addMoney(basePayout, farmId, contractMoneyType, true, true)
    end

    if contract.origin == "PLAYER" then
        contract.escrowRemaining = math.max(0, (contract.escrowRemaining or 0) - basePayout)
        if self.addPickupInboxItem ~= nil then
            local srcLabel = string.format("#%d (%s)", contract.id, self:getContractFarmName(farmId))
            self:addPickupInboxItem(contract.issuerFarmId, contract.fillType, creditedLiters, "CONTRACT_DELIVERY", srcLabel)
        end
    else
        local cap = GlobalMarket.MARKET_CAPACITY or 2000000
        for _, ft in pairs(self.offlineMarketFillTypes or {}) do
            if ft.fillType == contract.fillType then
                ft.fillLevel = math.clamp((ft.fillLevel or 0) + creditedLiters, 0, cap)
                break
            end
        end
    end

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
        table.remove(self.contracts, idx)
    elseif self.debugManager ~= nil then
        self.debugManager:info("Contracts: Farm %d delivered %.0f L to contract #%d (%.0f/%.0f L).",
            farmId, creditedLiters, contract.id, contract.deliveredLiters, contract.totalLiters)
    end

    self:broadcastContractsState()
    return true, creditedLiters
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
            local pick = candidates[math.random(1, #candidates)]
            local liters = math.random(2, 16) * 10000
            local bonusPct = math.random(GlobalMarketContracts.CONTRACT_NPC_BONUS_MIN, GlobalMarketContracts.CONTRACT_NPC_BONUS_MAX)
            local months = math.random(2, 5)
            local contractor = GlobalMarketContracts.NPC_CONTRACTORS[math.random(1, #GlobalMarketContracts.NPC_CONTRACTORS)]
            local basePrice = self:getContractReferencePricePer1000(pick.fillType)

            self.nextContractId = self.nextContractId or 1
            local id = self.nextContractId
            self.nextContractId = id + 1

            table.insert(self.contracts, {
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
            })
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

---Evaluates contract deadlines, direct offer expirations, Pickup Inbox liquidation & NPC cycles hourly
---@param customMonthDelta number|nil
---@return boolean changed
function GlobalMarket:updateContractsAndOffersHourly(customMonthDelta)
    if g_server == nil then
        return false
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

    -- 2. Tick Direct Offers & move expired unsold player lots to Pickup Inbox
    for i = #(self.directOffers or {}), 1, -1 do
        local o = self.directOffers[i]
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

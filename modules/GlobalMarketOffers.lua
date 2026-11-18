-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketOffers.lua
-- +/-10% direct offers (Tensuko), NPC buying simulation & savegame XML persistence.
-- Author: D-S-Agrarservice
-- =========================================================================================

---Creates a +/-10% direct offer listing by withdrawing goods into marketplace escrow
---@return boolean success
---@return number|nil offerId
function GlobalMarket:createDirectOffer(
    farmId, fillTypeName, requestedLiters, priceDeltaPct, allowPartial,
    durationMonths, targetStorage, isObjectStorage, formatXml, isOnlineScope
)
    if isOnlineScope == true and self.createOnlineDirectOffer ~= nil then
        return self:createOnlineDirectOffer(
            farmId, fillTypeName, requestedLiters, priceDeltaPct, allowPartial,
            durationMonths, targetStorage, isObjectStorage, formatXml
        )
    end
    if g_server == nil or farmId == nil or farmId <= 0 or farmId == FarmManager.SPECTATOR_FARM_ID then
        return false, nil
    end

    local ok, actualLiters, _, wasBale, wasPallet = self:withdrawGoodsFromFarmStorage(
        farmId, fillTypeName, requestedLiters, targetStorage, isObjectStorage, formatXml, false, true
    )
    if not ok or actualLiters <= 0.01 then
        return false, nil
    end

    local cleanDelta = math.clamp(
        math.floor((priceDeltaPct or 0) + 0.5),
        GlobalMarketContracts.OFFER_DELTA_MIN,
        GlobalMarketContracts.OFFER_DELTA_MAX
    )
    local cleanMonths = math.clamp(
        math.floor((durationMonths or 2) + 0.5),
        GlobalMarketContracts.OFFER_DURATION_MIN,
        GlobalMarketContracts.OFFER_DURATION_MAX
    )

    local refPrice = self:getCurrentMarketPricePer1000(fillTypeName)
    self.directOffers = self.directOffers or {}
    self.nextOfferId = self.nextOfferId or 1
    local id = self.nextOfferId
    self.nextOfferId = id + 1

    table.insert(self.directOffers, {
        id = id,
        origin = "PLAYER",
        sellerFarmId = farmId,
        sellerName = self:getContractFarmName(farmId),
        fillType = fillTypeName,
        totalLiters = actualLiters,
        remainingLiters = actualLiters,
        refPricePer1000 = refPrice,
        priceDeltaPct = cleanDelta,
        allowPartial = (allowPartial == true),
        monthsRemaining = cleanMonths,
        wasBale = (wasBale == true),
        wasPallet = (wasPallet == true)
    })

    if self.debugManager ~= nil then
        self.debugManager:info("DirectOffers: Farm %d listed %.0f L %s at %+d%% (Partial=%s, ID=#%d).",
            farmId, actualLiters, tostring(fillTypeName), cleanDelta, tostring(allowPartial == true), id)
    end
    self:broadcastContractsState()
    return true, id
end

---Buys full or partial goods from a direct offer without system dealer markup
---@return boolean success
---@return number actualLiters
function GlobalMarket:buyDirectOffer(
    buyerFarmId, offerId, requestedLiters, targetStorage, isObjectStorage, formatXml, capacityPerObject
)
    if g_server == nil or buyerFarmId == nil or buyerFarmId <= 0 or buyerFarmId == FarmManager.SPECTATOR_FARM_ID then
        return false, 0
    end
    local idx, offer = GlobalMarketContracts.findById(self.directOffers, offerId)
    if offer ~= nil and offer.isOnline and self.requestBuyOnlineOffer ~= nil then
        return self:requestBuyOnlineOffer(
            buyerFarmId, offer, requestedLiters, targetStorage, isObjectStorage, formatXml, capacityPerObject
        )
    end
    if offer == nil or (offer.remainingLiters or 0) <= 0.01 then
        return false, 0
    end
    if offer.origin == "PLAYER" and offer.sellerFarmId == buyerFarmId then
        return false, 0
    end

    local desiredLiters = offer.remainingLiters
    local requireFull = (not offer.allowPartial)
    if offer.allowPartial and requestedLiters ~= nil and requestedLiters > 0 then
        desiredLiters = math.min(requestedLiters, offer.remainingLiters)
    end

    local effectivePricePer1000 = (offer.refPricePer1000 or 500) * (1 + ((offer.priceDeltaPct or 0) / 100))
    local unitCostPerLiter = effectivePricePer1000 / 1000

    local ok, actualLiters, _, isBale, isPallet = self:depositGoodsToFarmStorage(
        buyerFarmId, offer.fillType, desiredLiters, targetStorage, isObjectStorage,
        formatXml, capacityPerObject, unitCostPerLiter, requireFull
    )
    if not ok or actualLiters <= 0.01 then
        return false, 0
    end

    local goodsCost = math.floor((actualLiters * unitCostPerLiter) + 0.5)
    local fillDesc = g_fillTypeManager:getFillTypeByName(offer.fillType)
    local buyerMoneyType = (fillDesc ~= nil and GlobalMarketFinance ~= nil)
        and GlobalMarketFinance.getMoneyType(fillDesc.index, true, isBale, isPallet)
        or MoneyType.GM_BUY_BULK
    if goodsCost > 0 then
        g_currentMission:addMoney(goodsCost * -1, buyerFarmId, buyerMoneyType, true, true)
    end

    if offer.origin == "PLAYER" and offer.sellerFarmId ~= nil and offer.sellerFarmId > 0 then
        local sellerMoneyType = (fillDesc ~= nil and GlobalMarketFinance ~= nil)
            and GlobalMarketFinance.getMoneyType(fillDesc.index, false, offer.wasBale == true, offer.wasPallet == true)
            or MoneyType.GM_SELL_BULK
        if goodsCost > 0 then
            g_currentMission:addMoney(goodsCost, offer.sellerFarmId, sellerMoneyType, true, true)
        end
    end

    offer.remainingLiters = math.max(0, (offer.remainingLiters or 0) - actualLiters)
    if offer.remainingLiters <= 0.5 then
        table.remove(self.directOffers, idx)
    end

    if self.debugManager ~= nil then
        self.debugManager:info("DirectOffers: Farm %d bought %.0f L from offer #%d for %d EUR.",
            buyerFarmId, actualLiters, offerId, goodsCost)
    end
    self:broadcastContractsState()
    return true, actualLiters
end

---Cancels an active player direct offer and moves unsold stock into the seller's Pickup Inbox
---@param farmId number
---@param offerId number
---@return boolean success
function GlobalMarket:cancelDirectOffer(farmId, offerId)
    if g_server == nil then
        return false
    end
    local idx, offer = GlobalMarketContracts.findById(self.directOffers, offerId)
    if offer ~= nil and offer.isOnline and self.cancelOnlineOffer ~= nil then
        return self:cancelOnlineOffer(farmId, offer)
    end
    if offer == nil or offer.origin ~= "PLAYER" or offer.sellerFarmId ~= farmId then
        return false
    end

    if (offer.remainingLiters or 0) > 0.5 and self.addPickupInboxItem ~= nil then
        self:addPickupInboxItem(farmId, offer.fillType, offer.remainingLiters, "OFFER_CANCELLED", string.format("#%d", offer.id))
    end
    table.remove(self.directOffers, idx)

    if self.debugManager ~= nil then
        self.debugManager:info("DirectOffers: Farm %d cancelled offer #%d; remainder moved to Pickup Inbox.", farmId, offerId)
    end
    self:broadcastContractsState()
    return true
end

---Seeds NPC direct offers up to TARGET_NPC_OFFERS when NPC_ACTIVITY_MODE == ALL
---@param candidates table
---@return boolean changed
function GlobalMarket:replenishNpcOffers(candidates)
    if g_server == nil or candidates == nil or #candidates == 0 then
        return false
    end
    if (GlobalMarket.NPC_ACTIVITY_MODE or GlobalMarketContracts.NPC_MODE_ALL) ~= GlobalMarketContracts.NPC_MODE_ALL then
        return false
    end

    self.directOffers = self.directOffers or {}
    local openNpcOffers = 0
    for _, o in ipairs(self.directOffers) do
        if o.origin == "NPC" then
            openNpcOffers = openNpcOffers + 1
        end
    end

    local changed = false
    while openNpcOffers < GlobalMarketContracts.TARGET_NPC_OFFERS do
        local pick = candidates[math.random(1, #candidates)]
        local liters = math.random(2, 10) * 5000
        local deltaPct = math.random(-8, -1)
        local trader = GlobalMarketContracts.NPC_TRADERS[math.random(1, #GlobalMarketContracts.NPC_TRADERS)]
        local refPrice = self:getCurrentMarketPricePer1000(pick.fillType)

        self.nextOfferId = self.nextOfferId or 1
        local id = self.nextOfferId
        self.nextOfferId = id + 1

        table.insert(self.directOffers, {
            id = id,
            origin = "NPC",
            sellerFarmId = 0,
            sellerName = trader,
            fillType = pick.fillType,
            totalLiters = liters,
            remainingLiters = liters,
            refPricePer1000 = refPrice,
            priceDeltaPct = deltaPct,
            allowPartial = true,
            monthsRemaining = math.random(1, 3),
            wasBale = false,
            wasPallet = false
        })
        openNpcOffers = openNpcOffers + 1
        changed = true
    end

    return changed
end

---Simulates NPC purchases of attractive player direct offers when NPC Mode == ALL
---@return boolean changed
function GlobalMarket:processNpcDirectOfferBuying()
    if g_server == nil or (GlobalMarket.NPC_ACTIVITY_MODE or 1) ~= GlobalMarketContracts.NPC_MODE_ALL then
        return false
    end

    local changed = false
    local marketCap = GlobalMarket.MARKET_CAPACITY or 2000000

    for i = #(self.directOffers or {}), 1, -1 do
        local offer = self.directOffers[i]
        if not offer.isOnline and offer.origin == "PLAYER" and (offer.remainingLiters or 0) > 0.5 then
            -- Base hourly probability scales inversely with seller markup (-10% ~18%/h, 0% ~7%/h, +10% ~1.5%/h)
            local delta = offer.priceDeltaPct or 0
            local prob = math.clamp(0.07 - (delta * 0.008), 0.015, 0.22)
            for _, ft in pairs(self.offlineMarketFillTypes or {}) do
                if ft.fillType == offer.fillType and marketCap > 0 then
                    local scarcityBoost = 1.0 + (0.5 * math.max(0, 1 - ((ft.fillLevel or 0) / marketCap)))
                    prob = prob * scarcityBoost
                    break
                end
            end

            if math.random() <= prob then
                local buyLiters = offer.remainingLiters
                if offer.allowPartial and buyLiters > 10000 then
                    local frac = math.random(35, 100) / 100
                    buyLiters = math.min(offer.remainingLiters, math.max(5000, math.floor(offer.remainingLiters * frac)))
                end

                local pricePer1000 = (offer.refPricePer1000 or 500) * (1 + (delta / 100))
                local payout = math.floor(((buyLiters / 1000) * pricePer1000) + 0.5)
                if payout > 0 and offer.sellerFarmId ~= nil and offer.sellerFarmId > 0 then
                    local fillDesc = g_fillTypeManager:getFillTypeByName(offer.fillType)
                    local mType = (fillDesc ~= nil and GlobalMarketFinance ~= nil)
                        and GlobalMarketFinance.getMoneyType(fillDesc.index, false, offer.wasBale == true, offer.wasPallet == true)
                        or MoneyType.GM_SELL_BULK
                    g_currentMission:addMoney(payout, offer.sellerFarmId, mType, true, true)
                end

                offer.remainingLiters = math.max(0, offer.remainingLiters - buyLiters)
                if offer.remainingLiters <= 0.5 then
                    table.remove(self.directOffers, i)
                end
                changed = true
            end
        end
    end

    return changed
end

---Persists contracts, direct offers, and Pickup Inbox into savegame globalMarket.xml
---@param xmlFile table
function GlobalMarket:saveContractsSystemToXml(xmlFile)
    if xmlFile == nil then
        return
    end
    -- Settle pending map station unloads (#27) so no liters are lost across save/load
    if self.stationCreditsDirty and self.flushStationContractCredits ~= nil then
        self:flushStationContractCredits()
    end

    local rootKey = "globalMarket.contractsSystem"
    local serverId = (self.ensureServerInstanceId ~= nil) and self:ensureServerInstanceId() or (self.serverInstanceId or "")
    xmlFile:setString(rootKey .. "#serverInstanceId", serverId)
    xmlFile:setInt(rootKey .. "#nextContractId", self.nextContractId or 1)
    xmlFile:setInt(rootKey .. "#nextOfferId", self.nextOfferId or 1)
    xmlFile:setInt(rootKey .. "#nextInboxId", self.nextInboxId or 1)

    local cSaveIdx = 0
    for _, c in ipairs(self.contracts or {}) do
        local shouldPersist = (not c.isOnline)
            or (self.isOwnOnlineServer ~= nil and (self:isOwnOnlineServer(c.issuerServerId) or self:isOwnOnlineServer(c.contractorServerId)))
        if shouldPersist then
            local key = string.format("%s.contracts.contract(%d)", rootKey, cSaveIdx)
            cSaveIdx = cSaveIdx + 1
            xmlFile:setInt(key .. "#id", c.id)
            xmlFile:setString(key .. "#origin", c.origin or "NPC")
            xmlFile:setInt(key .. "#issuerFarmId", c.issuerFarmId or 0)
            xmlFile:setString(key .. "#issuerName", c.issuerName or "NPC")
            xmlFile:setInt(key .. "#contractorFarmId", c.contractorFarmId or 0)
            xmlFile:setString(key .. "#fillType", c.fillType or "")
            xmlFile:setFloat(key .. "#totalLiters", c.totalLiters or 0)
            xmlFile:setFloat(key .. "#deliveredLiters", c.deliveredLiters or 0)
            xmlFile:setFloat(key .. "#basePricePer1000", c.basePricePer1000 or 500)
            xmlFile:setInt(key .. "#bonusPct", c.bonusPct or 10)
            xmlFile:setFloat(key .. "#escrowRemaining", c.escrowRemaining or 0)
            xmlFile:setFloat(key .. "#monthsRemaining", c.monthsRemaining or 1)
            xmlFile:setString(key .. "#status", c.status or "OPEN")
            if c.stationPlaceableId ~= nil and c.stationPlaceableId ~= "" then
                xmlFile:setString(key .. "#stationPlaceableId", c.stationPlaceableId)
                xmlFile:setInt(key .. "#stationIndex", c.stationIndex or 1)
                xmlFile:setFloat(key .. "#stationPosX", c.stationPosX or 0)
                xmlFile:setFloat(key .. "#stationPosZ", c.stationPosZ or 0)
            end
            if c.isOnline then
                xmlFile:setBool(key .. "#isOnline", true)
                xmlFile:setString(key .. "#remoteId", c.remoteId or "")
                xmlFile:setString(key .. "#issuerServerId", c.issuerServerId or "")
                xmlFile:setString(key .. "#contractorServerId", c.contractorServerId or "")
                xmlFile:setFloat(key .. "#baseTrendFactor", c.baseTrendFactor or 1.0)
                xmlFile:setInt(key .. "#remainingSeconds", math.floor((c.remainingSeconds or 0) + 0.5))
                if c.pendingActionId ~= nil and c.pendingActionId ~= "" then
                    xmlFile:setString(key .. "#pendingActionId", c.pendingActionId)
                end
            end
        end
    end

    local oSaveIdx = 0
    for _, o in ipairs(self.directOffers or {}) do
        local shouldPersist = (not o.isOnline)
            or (self.isOwnOnlineServer ~= nil and self:isOwnOnlineServer(o.sellerServerId))
        if shouldPersist then
            local key = string.format("%s.directOffers.offer(%d)", rootKey, oSaveIdx)
            oSaveIdx = oSaveIdx + 1
            xmlFile:setInt(key .. "#id", o.id)
            xmlFile:setString(key .. "#origin", o.origin or "NPC")
            xmlFile:setInt(key .. "#sellerFarmId", o.sellerFarmId or 0)
            xmlFile:setString(key .. "#sellerName", o.sellerName or "NPC")
            xmlFile:setString(key .. "#fillType", o.fillType or "")
            xmlFile:setFloat(key .. "#totalLiters", o.totalLiters or 0)
            xmlFile:setFloat(key .. "#remainingLiters", o.remainingLiters or 0)
            xmlFile:setFloat(key .. "#refPricePer1000", o.refPricePer1000 or 500)
            xmlFile:setInt(key .. "#priceDeltaPct", o.priceDeltaPct or 0)
            xmlFile:setBool(key .. "#allowPartial", o.allowPartial == true)
            xmlFile:setFloat(key .. "#monthsRemaining", o.monthsRemaining or 1)
            xmlFile:setBool(key .. "#wasBale", o.wasBale == true)
            xmlFile:setBool(key .. "#wasPallet", o.wasPallet == true)
            if o.isOnline then
                xmlFile:setBool(key .. "#isOnline", true)
                xmlFile:setString(key .. "#remoteId", o.remoteId or "")
                xmlFile:setString(key .. "#sellerServerId", o.sellerServerId or "")
                xmlFile:setInt(key .. "#remainingSeconds", math.floor((o.remainingSeconds or 0) + 0.5))
                xmlFile:setString(key .. "#status", o.status or "OPEN")
                if o.pendingActionId ~= nil and o.pendingActionId ~= "" then
                    xmlFile:setString(key .. "#pendingActionId", o.pendingActionId)
                end
            end
        end
    end

    for i, sid in ipairs(self.processedSettlementIds or {}) do
        local key = string.format("%s.processedSettlements.settlement(%d)", rootKey, i - 1)
        xmlFile:setString(key .. "#id", sid)
    end

    for i, rid in ipairs(self.orphanedRemoteIds or {}) do
        local key = string.format("%s.orphanedRemoteIds.remote(%d)", rootKey, i - 1)
        xmlFile:setString(key .. "#id", rid)
    end

    for i, p in ipairs(self.pickupInbox or {}) do
        local key = string.format("%s.pickupInbox.item(%d)", rootKey, i - 1)
        xmlFile:setInt(key .. "#id", p.id)
        xmlFile:setInt(key .. "#farmId", p.farmId or 0)
        xmlFile:setString(key .. "#fillType", p.fillType or "")
        xmlFile:setFloat(key .. "#liters", p.liters or 0)
        xmlFile:setString(key .. "#sourceType", p.sourceType or "EXPIRED")
        xmlFile:setString(key .. "#sourceLabel", p.sourceLabel or "")
        xmlFile:setFloat(key .. "#monthsRemaining", p.monthsRemaining or 2)
    end
end

---Loads contracts, direct offers, and Pickup Inbox from savegame globalMarket.xml
---@param xmlFile table
function GlobalMarket:loadContractsSystemFromXml(xmlFile)
    if xmlFile == nil then
        return
    end
    self:initContractsSystem()

    local rootKey = "globalMarket.contractsSystem"
    local savedSid = xmlFile:getString(rootKey .. "#serverInstanceId")
    if savedSid ~= nil and savedSid ~= "" then
        self.serverInstanceId = savedSid
    elseif self.ensureServerInstanceId ~= nil then
        self:ensureServerInstanceId()
    end
    local maxCId, maxOId, maxIId = 0, 0, 0

    xmlFile:iterate(rootKey .. ".contracts.contract", function(_, key)
        local id = xmlFile:getInt(key .. "#id") or 0
        local ft = xmlFile:getString(key .. "#fillType")
        if id > 0 and ft ~= nil and ft ~= "" then
            local pendAid = xmlFile:getString(key .. "#pendingActionId")
            local stationId = xmlFile:getString(key .. "#stationPlaceableId")
            local hasStation = (stationId ~= nil and stationId ~= "")
            table.insert(self.contracts, {
                id = id,
                stationPlaceableId = hasStation and stationId or nil,
                stationIndex = hasStation and (xmlFile:getInt(key .. "#stationIndex") or 1) or nil,
                stationPosX = hasStation and (xmlFile:getFloat(key .. "#stationPosX") or 0) or nil,
                stationPosZ = hasStation and (xmlFile:getFloat(key .. "#stationPosZ") or 0) or nil,
                isOnline = xmlFile:getBool(key .. "#isOnline", false),
                remoteId = xmlFile:getString(key .. "#remoteId") or "",
                origin = xmlFile:getString(key .. "#origin") or "NPC",
                issuerServerId = xmlFile:getString(key .. "#issuerServerId") or "",
                issuerFarmId = xmlFile:getInt(key .. "#issuerFarmId") or 0,
                issuerName = xmlFile:getString(key .. "#issuerName") or "NPC",
                contractorServerId = xmlFile:getString(key .. "#contractorServerId") or "",
                contractorFarmId = xmlFile:getInt(key .. "#contractorFarmId") or 0,
                fillType = ft,
                totalLiters = xmlFile:getFloat(key .. "#totalLiters") or 0,
                deliveredLiters = xmlFile:getFloat(key .. "#deliveredLiters") or 0,
                baseTrendFactor = xmlFile:getFloat(key .. "#baseTrendFactor") or 1.0,
                basePricePer1000 = xmlFile:getFloat(key .. "#basePricePer1000") or 500,
                bonusPct = xmlFile:getInt(key .. "#bonusPct") or 10,
                escrowRemaining = xmlFile:getFloat(key .. "#escrowRemaining") or 0,
                monthsRemaining = xmlFile:getFloat(key .. "#monthsRemaining") or 1,
                remainingSeconds = xmlFile:getInt(key .. "#remainingSeconds") or 0,
                status = xmlFile:getString(key .. "#status") or "OPEN",
                pendingActionId = (pendAid ~= nil and pendAid ~= "") and pendAid or nil,
                pendingSinceMs = (pendAid ~= nil and pendAid ~= "") and (g_time or 0) or nil
            })
            if id > maxCId then maxCId = id end
        end
    end)

    xmlFile:iterate(rootKey .. ".directOffers.offer", function(_, key)
        local id = xmlFile:getInt(key .. "#id") or 0
        local ft = xmlFile:getString(key .. "#fillType")
        if id > 0 and ft ~= nil and ft ~= "" then
            local pendAid = xmlFile:getString(key .. "#pendingActionId")
            table.insert(self.directOffers, {
                id = id,
                isOnline = xmlFile:getBool(key .. "#isOnline", false),
                remoteId = xmlFile:getString(key .. "#remoteId") or "",
                origin = xmlFile:getString(key .. "#origin") or "NPC",
                sellerServerId = xmlFile:getString(key .. "#sellerServerId") or "",
                sellerFarmId = xmlFile:getInt(key .. "#sellerFarmId") or 0,
                sellerName = xmlFile:getString(key .. "#sellerName") or "NPC",
                fillType = ft,
                totalLiters = xmlFile:getFloat(key .. "#totalLiters") or 0,
                remainingLiters = xmlFile:getFloat(key .. "#remainingLiters") or 0,
                refPricePer1000 = xmlFile:getFloat(key .. "#refPricePer1000") or 500,
                priceDeltaPct = xmlFile:getInt(key .. "#priceDeltaPct") or 0,
                allowPartial = xmlFile:getBool(key .. "#allowPartial", false),
                monthsRemaining = xmlFile:getFloat(key .. "#monthsRemaining") or 1,
                remainingSeconds = xmlFile:getInt(key .. "#remainingSeconds") or 0,
                wasBale = xmlFile:getBool(key .. "#wasBale", false),
                wasPallet = xmlFile:getBool(key .. "#wasPallet", false),
                status = xmlFile:getString(key .. "#status") or "OPEN",
                pendingActionId = (pendAid ~= nil and pendAid ~= "") and pendAid or nil,
                pendingSinceMs = (pendAid ~= nil and pendAid ~= "") and (g_time or 0) or nil
            })
            if id > maxOId then maxOId = id end
        end
    end)

    xmlFile:iterate(rootKey .. ".processedSettlements.settlement", function(_, key)
        local sid = xmlFile:getString(key .. "#id") or ""
        if sid ~= "" and self.markSettlementProcessed ~= nil then
            self:markSettlementProcessed(sid)
        end
    end)

    xmlFile:iterate(rootKey .. ".orphanedRemoteIds.remote", function(_, key)
        local rid = xmlFile:getString(key .. "#id") or ""
        if rid ~= "" and self.markOrphanedOnlineRemoteId ~= nil then
            self:markOrphanedOnlineRemoteId(rid)
        end
    end)

    xmlFile:iterate(rootKey .. ".pickupInbox.item", function(_, key)
        local id = xmlFile:getInt(key .. "#id") or 0
        local ft = xmlFile:getString(key .. "#fillType")
        if id > 0 and ft ~= nil and ft ~= "" then
            table.insert(self.pickupInbox, {
                id = id,
                farmId = xmlFile:getInt(key .. "#farmId") or 0,
                fillType = ft,
                liters = xmlFile:getFloat(key .. "#liters") or 0,
                sourceType = xmlFile:getString(key .. "#sourceType") or "EXPIRED",
                sourceLabel = xmlFile:getString(key .. "#sourceLabel") or "",
                monthsRemaining = xmlFile:getFloat(key .. "#monthsRemaining") or 2
            })
            if id > maxIId then maxIId = id end
        end
    end)

    self.nextContractId = math.max(xmlFile:getInt(rootKey .. "#nextContractId") or 1, maxCId + 1)
    self.nextOfferId = math.max(xmlFile:getInt(rootKey .. "#nextOfferId") or 1, maxOId + 1)
    self.nextInboxId = math.max(xmlFile:getInt(rootKey .. "#nextInboxId") or 1, maxIId + 1)

    -- Resolve map station targets (#27) now that all placeables exist, and restore local map hotspots
    if self.rebuildContractStationIndex ~= nil then
        self:rebuildContractStationIndex()
    end
    if self.refreshContractHotspots ~= nil then
        self:refreshContractHotspots()
    end
end

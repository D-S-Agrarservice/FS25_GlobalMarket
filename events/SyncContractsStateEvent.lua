-- =========================================================================================
-- FS25_GlobalMarket - SyncContractsStateEvent.lua
-- Server-to-client snapshot sync for Supply Contracts, Direct Offers, and Pickup Inbox.
-- Author: D-S-Agrarservice
-- =========================================================================================

SyncContractsStateEvent = {}
local SyncContractsStateEvent_mt = Class(SyncContractsStateEvent, Event)
InitEventClass(SyncContractsStateEvent, "SyncContractsStateEvent")

function SyncContractsStateEvent.emptyNew()
    return Event.new(SyncContractsStateEvent_mt)
end

function SyncContractsStateEvent.new()
    local self = SyncContractsStateEvent.emptyNew()
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    self.serverInstanceId = (gm ~= nil and gm.serverInstanceId) or ""
    self.onlineContractsSupported = (gm ~= nil and (gm.onlineContractsSupported == true or gm.debugForceOnlineContracts == true))
    self.contracts = {}
    self.directOffers = {}
    self.pickupInbox = {}

    if gm ~= nil then
        for _, c in ipairs(gm.contracts or {}) do
            table.insert(self.contracts, c)
        end
        for _, o in ipairs(gm.directOffers or {}) do
            table.insert(self.directOffers, o)
        end
        for _, p in ipairs(gm.pickupInbox or {}) do
            table.insert(self.pickupInbox, p)
        end
    end
    return self
end

function SyncContractsStateEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.serverInstanceId or "")
    streamWriteBool(streamId, self.onlineContractsSupported == true)

    local contracts = self.contracts or {}
    streamWriteInt16(streamId, #contracts)
    for _, c in ipairs(contracts) do
        streamWriteInt32(streamId, c.id or 0)
        streamWriteString(streamId, c.origin or "NPC")
        streamWriteInt16(streamId, c.issuerFarmId or 0)
        streamWriteString(streamId, c.issuerName or "NPC")
        streamWriteInt16(streamId, c.contractorFarmId or 0)
        streamWriteString(streamId, c.fillType or "")
        streamWriteFloat32(streamId, c.totalLiters or 0)
        streamWriteFloat32(streamId, c.deliveredLiters or 0)
        streamWriteFloat32(streamId, c.basePricePer1000 or 0)
        streamWriteInt16(streamId, c.bonusPct or 0)
        streamWriteFloat32(streamId, c.escrowRemaining or 0)
        streamWriteFloat32(streamId, c.monthsRemaining or 0)
        streamWriteString(streamId, c.status or "OPEN")
        streamWriteBool(streamId, c.isOnline == true)
        streamWriteString(streamId, c.remoteId or "")
        streamWriteString(streamId, c.issuerServerId or "")
        streamWriteString(streamId, c.contractorServerId or "")
        streamWriteFloat32(streamId, c.baseTrendFactor or 1.0)
        streamWriteInt32(streamId, math.floor((c.remainingSeconds or 0) + 0.5))
        streamWriteInt16(streamId, c.pendingAcceptFarmId or 0)
        -- Map station delivery target (#27): uniqueId ("" = none) + hotspot world position
        streamWriteString(streamId, c.stationPlaceableId or "")
        streamWriteFloat32(streamId, c.stationPosX or 0)
        streamWriteFloat32(streamId, c.stationPosZ or 0)
    end

    local offers = self.directOffers or {}
    streamWriteInt16(streamId, #offers)
    for _, o in ipairs(offers) do
        streamWriteInt32(streamId, o.id or 0)
        streamWriteString(streamId, o.origin or "NPC")
        streamWriteInt16(streamId, o.sellerFarmId or 0)
        streamWriteString(streamId, o.sellerName or "NPC")
        streamWriteString(streamId, o.fillType or "")
        streamWriteFloat32(streamId, o.totalLiters or 0)
        streamWriteFloat32(streamId, o.remainingLiters or 0)
        streamWriteFloat32(streamId, o.refPricePer1000 or 0)
        streamWriteInt8(streamId, o.priceDeltaPct or 0)
        streamWriteBool(streamId, o.allowPartial == true)
        streamWriteFloat32(streamId, o.monthsRemaining or 0)
        streamWriteBool(streamId, o.wasBale == true)
        streamWriteBool(streamId, o.wasPallet == true)
        streamWriteBool(streamId, o.isOnline == true)
        streamWriteString(streamId, o.remoteId or "")
        streamWriteString(streamId, o.sellerServerId or "")
        streamWriteInt32(streamId, math.floor((o.remainingSeconds or 0) + 0.5))
        streamWriteString(streamId, o.status or "OPEN")
    end

    local inbox = self.pickupInbox or {}
    streamWriteInt16(streamId, #inbox)
    for _, p in ipairs(inbox) do
        streamWriteInt32(streamId, p.id or 0)
        streamWriteInt16(streamId, p.farmId or 0)
        streamWriteString(streamId, p.fillType or "")
        streamWriteFloat32(streamId, p.liters or 0)
        streamWriteString(streamId, p.sourceType or "EXPIRED")
        streamWriteString(streamId, p.sourceLabel or "")
        streamWriteFloat32(streamId, p.monthsRemaining or 0)
    end
end

function SyncContractsStateEvent:readStream(streamId, connection)
    self.serverInstanceId = streamReadString(streamId)
    self.onlineContractsSupported = streamReadBool(streamId)

    local numContracts = streamReadInt16(streamId)
    self.contracts = {}
    for _ = 1, numContracts do
        local c = {
            id = streamReadInt32(streamId),
            origin = streamReadString(streamId),
            issuerFarmId = streamReadInt16(streamId),
            issuerName = streamReadString(streamId),
            contractorFarmId = streamReadInt16(streamId),
            fillType = streamReadString(streamId),
            totalLiters = streamReadFloat32(streamId),
            deliveredLiters = streamReadFloat32(streamId),
            basePricePer1000 = streamReadFloat32(streamId),
            bonusPct = streamReadInt16(streamId),
            escrowRemaining = streamReadFloat32(streamId),
            monthsRemaining = streamReadFloat32(streamId),
            status = streamReadString(streamId),
            isOnline = streamReadBool(streamId),
            remoteId = streamReadString(streamId),
            issuerServerId = streamReadString(streamId),
            contractorServerId = streamReadString(streamId),
            baseTrendFactor = streamReadFloat32(streamId),
            remainingSeconds = streamReadInt32(streamId)
        }
        local pendFarm = streamReadInt16(streamId)
        c.pendingAcceptFarmId = (pendFarm > 0) and pendFarm or nil
        local stationId = streamReadString(streamId)
        local stationPosX = streamReadFloat32(streamId)
        local stationPosZ = streamReadFloat32(streamId)
        if stationId ~= nil and stationId ~= "" then
            c.stationPlaceableId = stationId
            c.stationPosX = stationPosX
            c.stationPosZ = stationPosZ
        end
        table.insert(self.contracts, c)
    end

    local numOffers = streamReadInt16(streamId)
    self.directOffers = {}
    for _ = 1, numOffers do
        table.insert(self.directOffers, {
            id = streamReadInt32(streamId),
            origin = streamReadString(streamId),
            sellerFarmId = streamReadInt16(streamId),
            sellerName = streamReadString(streamId),
            fillType = streamReadString(streamId),
            totalLiters = streamReadFloat32(streamId),
            remainingLiters = streamReadFloat32(streamId),
            refPricePer1000 = streamReadFloat32(streamId),
            priceDeltaPct = streamReadInt8(streamId),
            allowPartial = streamReadBool(streamId),
            monthsRemaining = streamReadFloat32(streamId),
            wasBale = streamReadBool(streamId),
            wasPallet = streamReadBool(streamId),
            isOnline = streamReadBool(streamId),
            remoteId = streamReadString(streamId),
            sellerServerId = streamReadString(streamId),
            remainingSeconds = streamReadInt32(streamId),
            status = streamReadString(streamId)
        })
    end

    local numInbox = streamReadInt16(streamId)
    self.pickupInbox = {}
    for _ = 1, numInbox do
        table.insert(self.pickupInbox, {
            id = streamReadInt32(streamId),
            farmId = streamReadInt16(streamId),
            fillType = streamReadString(streamId),
            liters = streamReadFloat32(streamId),
            sourceType = streamReadString(streamId),
            sourceLabel = streamReadString(streamId),
            monthsRemaining = streamReadFloat32(streamId)
        })
    end

    self:run(connection)
end

function SyncContractsStateEvent:run(connection)
    if connection:getIsServer() and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil then
        local gm = g_currentMission.globalMarket
        if self.serverInstanceId ~= nil and self.serverInstanceId ~= "" then
            gm.serverInstanceId = self.serverInstanceId
        end
        gm.onlineContractsSupported = (self.onlineContractsSupported == true)
        gm.contracts = self.contracts or {}
        gm.directOffers = self.directOffers or {}
        gm.pickupInbox = self.pickupInbox or {}

        local maxC, maxO, maxI = 0, 0, 0
        for _, c in ipairs(gm.contracts) do
            if (c.id or 0) > maxC then maxC = c.id end
        end
        for _, o in ipairs(gm.directOffers) do
            if (o.id or 0) > maxO then maxO = o.id end
        end
        for _, p in ipairs(gm.pickupInbox) do
            if (p.id or 0) > maxI then maxI = p.id end
        end
        gm.nextContractId = math.max(gm.nextContractId or 1, maxC + 1)
        gm.nextOfferId = math.max(gm.nextOfferId or 1, maxO + 1)
        gm.nextInboxId = math.max(gm.nextInboxId or 1, maxI + 1)

        -- Show/hide map hotspots of this farm's active station contracts (#27)
        if gm.refreshContractHotspots ~= nil then
            gm:refreshContractHotspots()
        end

        local ui = gm.ui or g_currentMission.globalMarketUi
        if ui ~= nil and ui:getIsVisible() and ui.updateContent ~= nil then
            ui:updateContent()
        end
    end
end

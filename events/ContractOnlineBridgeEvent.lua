-- =========================================================================================
-- FS25_GlobalMarket - ContractOnlineBridgeEvent.lua
-- Bidirectional relay between authoritative Server and remote Data-Host for Etappe 2 XMLs.
-- Author: D-S-Agrarservice
-- =========================================================================================

ContractOnlineBridgeEvent = {}
local ContractOnlineBridgeEvent_mt = Class(ContractOnlineBridgeEvent, Event)
InitEventClass(ContractOnlineBridgeEvent, "ContractOnlineBridgeEvent")

ContractOnlineBridgeEvent.MODE_EXPORT_ACTION = 1
ContractOnlineBridgeEvent.MODE_SYNC_PACKET = 2

function ContractOnlineBridgeEvent.emptyNew()
    return Event.new(ContractOnlineBridgeEvent_mt)
end

function ContractOnlineBridgeEvent.newExportAction(payload)
    local self = ContractOnlineBridgeEvent.emptyNew()
    self.mode = ContractOnlineBridgeEvent.MODE_EXPORT_ACTION
    self.payload = payload or {}
    return self
end

function ContractOnlineBridgeEvent.newSyncPacket(packet)
    local self = ContractOnlineBridgeEvent.emptyNew()
    self.mode = ContractOnlineBridgeEvent.MODE_SYNC_PACKET
    self.packet = packet or {}
    return self
end

function ContractOnlineBridgeEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.mode or 1)
    if self.mode == ContractOnlineBridgeEvent.MODE_EXPORT_ACTION then
        local p = self.payload or {}
        streamWriteString(streamId, p.subAction or "")
        streamWriteString(streamId, p.actionId or "")
        streamWriteString(streamId, p.serverId or "")
        streamWriteInt16(streamId, p.farmId or 0)
        streamWriteString(streamId, p.farmName or "")
        streamWriteString(streamId, p.remoteId or "")
        streamWriteString(streamId, p.fillType or "")
        streamWriteInt32(streamId, math.floor((p.liters or 0) + 0.5))
        streamWriteFloat32(streamId, p.baseTrendFactor or 1.0)
        streamWriteInt16(streamId, p.bonusPct or 0)
        streamWriteInt8(streamId, p.priceDeltaPct or 0)
        streamWriteBool(streamId, p.allowPartial == true)
        streamWriteInt16(streamId, p.durationHours or 0)
        streamWriteBool(streamId, p.wasBale == true)
        streamWriteBool(streamId, p.wasPallet == true)
        streamWriteString(streamId, p.settlementIds or "")
        return
    end

    local pkt = self.packet or {}
    local contracts = pkt.contracts or {}
    streamWriteInt16(streamId, #contracts)
    for _, c in ipairs(contracts) do
        streamWriteString(streamId, c.remoteId or "")
        streamWriteString(streamId, c.origin or "ONLINE")
        streamWriteBool(streamId, c.isNpc == true)
        streamWriteString(streamId, c.issuerServerId or "")
        streamWriteInt16(streamId, c.issuerFarmId or 0)
        streamWriteString(streamId, c.issuerName or "")
        streamWriteString(streamId, c.contractorServerId or "")
        streamWriteInt16(streamId, c.contractorFarmId or 0)
        streamWriteString(streamId, c.fillType or "")
        streamWriteFloat32(streamId, c.totalLiters or 0)
        streamWriteFloat32(streamId, c.deliveredLiters or 0)
        streamWriteFloat32(streamId, c.baseTrendFactor or 1.0)
        streamWriteInt16(streamId, c.bonusPct or 10)
        streamWriteInt32(streamId, c.remainingSeconds or 0)
        streamWriteString(streamId, c.status or "OPEN")
    end

    local offers = pkt.directOffers or {}
    streamWriteInt16(streamId, #offers)
    for _, o in ipairs(offers) do
        streamWriteString(streamId, o.remoteId or "")
        streamWriteString(streamId, o.origin or "ONLINE")
        streamWriteBool(streamId, o.isNpc == true)
        streamWriteString(streamId, o.sellerServerId or "")
        streamWriteInt16(streamId, o.sellerFarmId or 0)
        streamWriteString(streamId, o.sellerName or "")
        streamWriteString(streamId, o.fillType or "")
        streamWriteFloat32(streamId, o.totalLiters or 0)
        streamWriteFloat32(streamId, o.remainingLiters or 0)
        streamWriteInt8(streamId, o.priceDeltaPct or 0)
        streamWriteBool(streamId, o.allowPartial == true)
        streamWriteInt32(streamId, o.remainingSeconds or 0)
        streamWriteBool(streamId, o.wasBale == true)
        streamWriteBool(streamId, o.wasPallet == true)
        streamWriteString(streamId, o.status or "OPEN")
    end

    local results = pkt.actionResults or {}
    streamWriteInt16(streamId, #results)
    for _, r in ipairs(results) do
        streamWriteString(streamId, r.actionId or "")
        streamWriteString(streamId, r.subAction or "")
        streamWriteString(streamId, r.status or "REJECTED")
        streamWriteString(streamId, r.reason or "")
        streamWriteString(streamId, r.remoteId or "")
        streamWriteFloat32(streamId, r.grantedLiters or 0)
        streamWriteFloat32(streamId, r.baseTrendFactor or 1.0)
        streamWriteInt16(streamId, r.bonusPct or 10)
        streamWriteInt32(streamId, r.remainingSeconds or 0)
    end

    local settlements = pkt.settlements or {}
    streamWriteInt16(streamId, #settlements)
    for _, s in ipairs(settlements) do
        streamWriteString(streamId, s.settlementId or "")
        streamWriteString(streamId, s.type or "")
        streamWriteString(streamId, s.targetServerId or "")
        streamWriteInt16(streamId, s.targetFarmId or 0)
        streamWriteString(streamId, s.remoteId or "")
        streamWriteString(streamId, s.fillType or "")
        streamWriteFloat32(streamId, s.liters or 0)
        streamWriteFloat32(streamId, s.missingLiters or 0)
        streamWriteFloat32(streamId, s.baseTrendFactor or 1.0)
        streamWriteInt8(streamId, s.priceDeltaPct or 0)
        streamWriteString(streamId, s.sourceLabel or "")
    end
end

function ContractOnlineBridgeEvent:readStream(streamId, connection)
    self.mode = streamReadInt8(streamId)
    if self.mode == ContractOnlineBridgeEvent.MODE_EXPORT_ACTION then
        self.payload = {
            subAction = streamReadString(streamId),
            actionId = streamReadString(streamId),
            serverId = streamReadString(streamId),
            farmId = streamReadInt16(streamId),
            farmName = streamReadString(streamId),
            remoteId = streamReadString(streamId),
            fillType = streamReadString(streamId),
            liters = streamReadInt32(streamId),
            baseTrendFactor = streamReadFloat32(streamId),
            bonusPct = streamReadInt16(streamId),
            priceDeltaPct = streamReadInt8(streamId),
            allowPartial = streamReadBool(streamId),
            durationHours = streamReadInt16(streamId),
            wasBale = streamReadBool(streamId),
            wasPallet = streamReadBool(streamId),
            settlementIds = streamReadString(streamId)
        }
        self:run(connection)
        return
    end

    local pkt = { contracts = {}, directOffers = {}, actionResults = {}, settlements = {} }
    local nC = streamReadInt16(streamId)
    for _ = 1, nC do
        table.insert(pkt.contracts, {
            remoteId = streamReadString(streamId),
            origin = streamReadString(streamId),
            isNpc = streamReadBool(streamId),
            issuerServerId = streamReadString(streamId),
            issuerFarmId = streamReadInt16(streamId),
            issuerName = streamReadString(streamId),
            contractorServerId = streamReadString(streamId),
            contractorFarmId = streamReadInt16(streamId),
            fillType = streamReadString(streamId),
            totalLiters = streamReadFloat32(streamId),
            deliveredLiters = streamReadFloat32(streamId),
            baseTrendFactor = streamReadFloat32(streamId),
            bonusPct = streamReadInt16(streamId),
            remainingSeconds = streamReadInt32(streamId),
            status = streamReadString(streamId)
        })
    end

    local nO = streamReadInt16(streamId)
    for _ = 1, nO do
        table.insert(pkt.directOffers, {
            remoteId = streamReadString(streamId),
            origin = streamReadString(streamId),
            isNpc = streamReadBool(streamId),
            sellerServerId = streamReadString(streamId),
            sellerFarmId = streamReadInt16(streamId),
            sellerName = streamReadString(streamId),
            fillType = streamReadString(streamId),
            totalLiters = streamReadFloat32(streamId),
            remainingLiters = streamReadFloat32(streamId),
            priceDeltaPct = streamReadInt8(streamId),
            allowPartial = streamReadBool(streamId),
            remainingSeconds = streamReadInt32(streamId),
            wasBale = streamReadBool(streamId),
            wasPallet = streamReadBool(streamId),
            status = streamReadString(streamId)
        })
    end

    local nR = streamReadInt16(streamId)
    for _ = 1, nR do
        table.insert(pkt.actionResults, {
            actionId = streamReadString(streamId),
            subAction = streamReadString(streamId),
            status = streamReadString(streamId),
            reason = streamReadString(streamId),
            remoteId = streamReadString(streamId),
            grantedLiters = streamReadFloat32(streamId),
            baseTrendFactor = streamReadFloat32(streamId),
            bonusPct = streamReadInt16(streamId),
            remainingSeconds = streamReadInt32(streamId)
        })
    end

    local nS = streamReadInt16(streamId)
    for _ = 1, nS do
        table.insert(pkt.settlements, {
            settlementId = streamReadString(streamId),
            type = streamReadString(streamId),
            targetServerId = streamReadString(streamId),
            targetFarmId = streamReadInt16(streamId),
            remoteId = streamReadString(streamId),
            fillType = streamReadString(streamId),
            liters = streamReadFloat32(streamId),
            missingLiters = streamReadFloat32(streamId),
            baseTrendFactor = streamReadFloat32(streamId),
            priceDeltaPct = streamReadInt8(streamId),
            sourceLabel = streamReadString(streamId)
        })
    end

    self.packet = pkt
    self:run(connection)
end

function ContractOnlineBridgeEvent:run(connection)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return
    end
    if self.mode == ContractOnlineBridgeEvent.MODE_EXPORT_ACTION then
        if connection:getIsServer() and gm.isDataHost and gm.exportContractAction ~= nil then
            gm:exportContractAction(self.payload)
        end
    elseif self.mode == ContractOnlineBridgeEvent.MODE_SYNC_PACKET then
        if not connection:getIsServer() and g_currentMission:getIsServer() and gm.dataHostConnection == connection then
            if gm.applyOnlineContractSyncPacket ~= nil then
                gm:applyOnlineContractSyncPacket(self.packet)
            end
        elseif not connection:getIsServer() and GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:warning("ContractsOnline: Ignored unauthorized contractData relay from non-Data-Host client.")
        end
    end
end

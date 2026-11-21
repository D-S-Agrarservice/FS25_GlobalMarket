-- =========================================================================================
-- FS25_GlobalMarket - ContractActionEvent.lua
-- Client-to-server event for creating, accepting, fulfilling, buying & claiming contracts/offers.
-- Author: D-S-Agrarservice
-- =========================================================================================

ContractActionEvent = {}
local ContractActionEvent_mt = Class(ContractActionEvent, Event)
InitEventClass(ContractActionEvent, "ContractActionEvent")

ContractActionEvent.ACTION_CREATE_CONTRACT = 1
ContractActionEvent.ACTION_CANCEL_CONTRACT = 2
ContractActionEvent.ACTION_ACCEPT_CONTRACT = 3
ContractActionEvent.ACTION_DELIVER_CONTRACT = 4
ContractActionEvent.ACTION_CREATE_OFFER = 5
ContractActionEvent.ACTION_BUY_OFFER = 6
ContractActionEvent.ACTION_CANCEL_OFFER = 7
ContractActionEvent.ACTION_CLAIM_INBOX = 8

function ContractActionEvent.emptyNew()
    return Event.new(ContractActionEvent_mt)
end

function ContractActionEvent.new(
    actionType, farmId, targetId, fillTypeName, liters, pctParam, durationMonths,
    flagParam, storageObject, isObjectStorage, formatXml, capacityPerObject, isOnlineScope
)
    local self = ContractActionEvent.emptyNew()
    self.actionType = actionType or 1
    self.farmId = farmId or 0
    self.targetId = targetId or 0
    self.fillTypeName = fillTypeName or ""
    self.liters = liters or 0
    self.pctParam = pctParam or 0
    self.durationMonths = durationMonths or 1
    self.flagParam = (flagParam == true)
    self.isOnlineScope = (isOnlineScope == true)

    self.storageObject = storageObject
    self.isObjectStorage = (isObjectStorage == true)
    self.formatXml = formatXml
    self.capacityPerObject = capacityPerObject or 0
    self.targetPlaceable = nil
    self.storageIndex = 1

    if storageObject ~= nil then
        if self.isObjectStorage then
            self.targetPlaceable = storageObject
        elseif g_currentMission ~= nil and g_currentMission.globalMarket ~= nil
            and g_currentMission.globalMarket.resolveBulkStorageOwner ~= nil then
            local ownerPlaceable, _, _, resolvedIndex =
                g_currentMission.globalMarket:resolveBulkStorageOwner(storageObject)
            self.targetPlaceable = ownerPlaceable
            self.storageIndex = resolvedIndex or 1
        end
    end

    return self
end

function ContractActionEvent:writeStream(streamId, connection)
    streamWriteInt8(streamId, self.actionType)
    streamWriteInt16(streamId, self.farmId)
    streamWriteInt32(streamId, self.targetId)
    streamWriteString(streamId, self.fillTypeName)
    streamWriteFloat32(streamId, self.liters)
    streamWriteInt8(streamId, self.pctParam)
    streamWriteInt16(streamId, self.durationMonths)
    streamWriteBool(streamId, self.flagParam)
    streamWriteBool(streamId, self.isOnlineScope == true)

    local hasDirect = (self.storageObject ~= nil and self.storageObject.isRegistered == true)
    streamWriteBool(streamId, hasDirect)
    if hasDirect then
        NetworkUtil.writeNodeObject(streamId, self.storageObject)
    end

    local hasPlaceable = (self.targetPlaceable ~= nil and self.targetPlaceable.isRegistered == true)
    streamWriteBool(streamId, hasPlaceable)
    if hasPlaceable then
        NetworkUtil.writeNodeObject(streamId, self.targetPlaceable)
    end
    streamWriteInt8(streamId, self.storageIndex or 1)
    streamWriteBool(streamId, self.isObjectStorage)

    local isBaleIndex = type(self.formatXml) == "number"
    streamWriteBool(streamId, isBaleIndex)
    if isBaleIndex then
        streamWriteInt32(streamId, self.formatXml)
    else
        local safeStr = (type(self.formatXml) == "string") and self.formatXml or ""
        streamWriteString(streamId, safeStr)
    end
    streamWriteInt32(streamId, self.capacityPerObject)
end

function ContractActionEvent:readStream(streamId, connection)
    self.actionType = streamReadInt8(streamId)
    self.farmId = streamReadInt16(streamId)
    self.targetId = streamReadInt32(streamId)
    self.fillTypeName = streamReadString(streamId)
    self.liters = streamReadFloat32(streamId)
    self.pctParam = streamReadInt8(streamId)
    self.durationMonths = streamReadInt16(streamId)
    self.flagParam = streamReadBool(streamId)
    self.isOnlineScope = streamReadBool(streamId)

    local hasDirect = streamReadBool(streamId)
    local directObj = nil
    if hasDirect then
        directObj = NetworkUtil.readNodeObject(streamId)
    end

    local hasPlaceable = streamReadBool(streamId)
    self.targetPlaceable = nil
    if hasPlaceable then
        self.targetPlaceable = NetworkUtil.readNodeObject(streamId)
    end
    self.storageIndex = streamReadInt8(streamId)
    self.isObjectStorage = streamReadBool(streamId)

    local isBaleIndex = streamReadBool(streamId)
    if isBaleIndex then
        self.formatXml = streamReadInt32(streamId)
    else
        self.formatXml = streamReadString(streamId)
    end
    self.capacityPerObject = streamReadInt32(streamId)

    self.storageObject = directObj
    if self.storageObject == nil and self.targetPlaceable ~= nil then
        local tp = self.targetPlaceable
        if self.isObjectStorage then
            self.storageObject = tp
        elseif tp.spec_silo ~= nil and tp.spec_silo.storages ~= nil then
            self.storageObject = tp.spec_silo.storages[self.storageIndex]
        elseif tp.spec_siloExtension ~= nil and tp.spec_siloExtension.storage ~= nil then
            self.storageObject = tp.spec_siloExtension.storage
        elseif tp.spec_husbandry ~= nil and tp.spec_husbandry.storage ~= nil then
            self.storageObject = tp.spec_husbandry.storage
        elseif tp.spec_manureHeap ~= nil and tp.spec_manureHeap.manureHeap ~= nil then
            self.storageObject = tp.spec_manureHeap.manureHeap
        elseif tp.spec_productionPoint ~= nil and tp.spec_productionPoint.productionPoint ~= nil then
            self.storageObject = tp.spec_productionPoint.productionPoint.storage
        end
    end

    self:run(connection)
end

---Routes action either directly on the server or over network from MP client with format encoding
function ContractActionEvent.dispatch(
    actionType, farmId, targetId, fillTypeName, liters, pctParam, durationMonths,
    flagParam, storageObject, isObjectStorage, formatXml, capacityPerObject, isOnlineScope
)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return false
    end

    if g_server ~= nil then
        local cleanFmt = (formatXml ~= "" and formatXml ~= 0) and formatXml or nil
        local cleanCap = (capacityPerObject ~= nil and capacityPerObject > 0) and capacityPerObject or nil
        return ContractActionEvent.executeOnServer(
            gm, actionType, farmId, targetId, fillTypeName, liters,
            pctParam, durationMonths, flagParam, storageObject, isObjectStorage, cleanFmt, cleanCap, isOnlineScope
        )
    end

    if g_client ~= nil then
        local payloadFormat = formatXml
        if type(formatXml) == "string" and formatXml ~= "" then
            if g_baleManager ~= nil and g_baleManager.getBaleTypeIndexByXMLFilename ~= nil then
                local baleIdx = g_baleManager:getBaleTypeIndexByXMLFilename(formatXml)
                if baleIdx ~= nil then
                    payloadFormat = baleIdx
                end
            end
            if type(payloadFormat) == "string" and NetworkUtil ~= nil and NetworkUtil.convertToNetworkFilename ~= nil then
                payloadFormat = NetworkUtil.convertToNetworkFilename(payloadFormat)
            end
        end
        g_client:getServerConnection():sendEvent(ContractActionEvent.new(
            actionType, farmId, targetId, fillTypeName, liters, pctParam,
            durationMonths, flagParam, storageObject, isObjectStorage, payloadFormat, capacityPerObject, isOnlineScope
        ))
        return true
    end

    return false
end

---Executes a validated contract/offer action on the authoritative server
function ContractActionEvent.executeOnServer(
    gm, actionType, farmId, targetId, fillTypeName, liters,
    pctParam, durationMonths, flagParam, storageObject, isObjectStorage, formatXml, capacityPerObject, isOnlineScope
)
    if actionType == ContractActionEvent.ACTION_CREATE_CONTRACT then
        return gm:createPlayerContract(farmId, fillTypeName, liters, pctParam, durationMonths, isOnlineScope)
    elseif actionType == ContractActionEvent.ACTION_CANCEL_CONTRACT then
        return gm:cancelPlayerContract(farmId, targetId)
    elseif actionType == ContractActionEvent.ACTION_ACCEPT_CONTRACT then
        return gm:acceptContract(farmId, targetId)
    elseif actionType == ContractActionEvent.ACTION_DELIVER_CONTRACT then
        return gm:deliverToContract(farmId, targetId, liters, storageObject, isObjectStorage, formatXml)
    elseif actionType == ContractActionEvent.ACTION_CREATE_OFFER then
        return gm:createDirectOffer(
            farmId, fillTypeName, liters, pctParam, flagParam,
            durationMonths, storageObject, isObjectStorage, formatXml, isOnlineScope
        )
    elseif actionType == ContractActionEvent.ACTION_BUY_OFFER then
        return gm:buyDirectOffer(
            farmId, targetId, liters, storageObject, isObjectStorage, formatXml, capacityPerObject
        )
    elseif actionType == ContractActionEvent.ACTION_CANCEL_OFFER then
        return gm:cancelDirectOffer(farmId, targetId)
    elseif actionType == ContractActionEvent.ACTION_CLAIM_INBOX then
        return gm:claimPickupInboxItem(
            farmId, targetId, liters, storageObject, isObjectStorage, formatXml, capacityPerObject
        )
    end
    return false
end

function ContractActionEvent:run(connection)
    if connection:getIsServer() then
        return
    end
    if self.farmId == nil or self.farmId <= 0 or self.farmId == FarmManager.SPECTATOR_FARM_ID then
        return
    end

    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil then
        return
    end

    -- Verify sender connection belongs to the claimed farmId on MP servers
    if g_currentMission.userManager ~= nil and g_farmManager ~= nil then
        local user = g_currentMission.userManager:getUserByConnection(connection)
        if user == nil then
            return
        end
        if g_farmManager.getFarmByUserId ~= nil then
            local senderFarm = g_farmManager:getFarmByUserId(user:getId())
            if senderFarm == nil or senderFarm.farmId ~= self.farmId then
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:warning("Contracts (Server): Blocked spoofed farmId %d from user %s.",
                        self.farmId, tostring(user:getNickname()))
                end
                return
            end
        end
    end

    -- Basegame farm rights: admins and farm managers always, other members need "manage contracts"
    if not g_currentMission:getHasPlayerPermission(Farm.PERMISSION.MANAGE_CONTRACTS, connection, self.farmId) then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:warning("Contracts (Server): Blocked action %d of farm %d without permission.",
                self.actionType or 0, self.farmId)
        end
        return
    end

    local cleanFmt = (self.formatXml ~= "" and self.formatXml ~= 0) and self.formatXml or nil
    local cleanCap = (self.capacityPerObject ~= nil and self.capacityPerObject > 0) and self.capacityPerObject or nil
    ContractActionEvent.executeOnServer(
        gm, self.actionType, self.farmId, self.targetId, self.fillTypeName, self.liters,
        self.pctParam, self.durationMonths, self.flagParam,
        self.storageObject, self.isObjectStorage, cleanFmt, cleanCap, self.isOnlineScope
    )
end

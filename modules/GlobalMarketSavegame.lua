--
-- FS25 - GlobalMarket (Savegame Module)
--

-- Saves the current offline market fill levels and silo shadow arrays to the active savegame directory.
function GlobalMarket:saveToXmlFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then
        if self.debugManager ~= nil then
            self.debugManager:error("Savegame directory not found! Market data cannot be saved.")
        end
        return
    end

    local fullPath = savegamePath .. "/globalMarket.xml"
    if self.debugManager ~= nil then
        self.debugManager:info("Saving market data to: %s", fullPath)
    end

    local xmlFile = XMLFile.create("globalMarket", fullPath, "globalMarket")
    if xmlFile ~= nil then
        -- Save Offline Market stock levels
        xmlFile:setTable("globalMarket.offlineMarket.fillTypes.fillType", self.offlineMarketFillTypes, function (key, info, _)
            xmlFile:setString(key .. "#fillType", info.fillType)
            xmlFile:setFloat(key .. "#level", info.fillLevel)
            if info.greatDemandBonus ~= nil and info.greatDemandBonus > 0 then
                xmlFile:setFloat(key .. "#greatDemandBonus", info.greatDemandBonus)
            end
            if info.greatDemandHours ~= nil and info.greatDemandHours > 0 then
                xmlFile:setInt(key .. "#greatDemandHours", info.greatDemandHours)
            end
        end)

        -- Note: Future online save data hooks (e.g., server IP, credentials) go here.

        -- Save siloStorages (Shadow Array for multi-farm logic) using Giants' native uniqueId
        local siloIndex = 0
        for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
            if placeable.isGmMarket and placeable.spec_silo ~= nil and placeable.spec_silo.storages ~= nil then
                local uid = placeable.uniqueId

                if uid ~= nil then
                    local siloKey = string.format("globalMarket.siloStorages.silo(%d)", siloIndex)
                    xmlFile:setString(siloKey .. "#uniqueId", uid)

                    for sIndex, storage in ipairs(placeable.spec_silo.storages) do
                        if storage.gmFarmFillLevels ~= nil then
                            local storageKey = string.format("%s.storage(%d)", siloKey, sIndex - 1)
                            local fIndex = 0

                            for farmId, fillLevels in pairs(storage.gmFarmFillLevels) do
                                local farmKey = string.format("%s.farm(%d)", storageKey, fIndex)
                                local ftIndex = 0

                                for fillTypeIndex, level in pairs(fillLevels) do
                                    if level > 0.01 then
                                        local ftKey = string.format("%s.fillType(%d)", farmKey, ftIndex)
                                        local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
                                        if fillTypeName ~= nil then
                                            xmlFile:setString(ftKey .. "#name", fillTypeName)
                                            xmlFile:setFloat(ftKey .. "#level", level)
                                            ftIndex = ftIndex + 1
                                        end
                                    end
                                end

                                if ftIndex > 0 then
                                    xmlFile:setInt(farmKey .. "#farmId", farmId)
                                    fIndex = fIndex + 1
                                end
                            end
                        end
                    end

                    siloIndex = siloIndex + 1
                end
            end
        end

        xmlFile:save()
        xmlFile:delete()

        if self.debugManager ~= nil then
            self.debugManager:info("Savegame successfully written. Saved %d GM Silos.", siloIndex)
        end
    end
end

-- Loads the market data from the active savegame and overrides the randomized start levels.
function GlobalMarket:loadFromXMLFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then return end

    local fullPath = savegamePath .. "/globalMarket.xml"
    if self.debugManager ~= nil then
        self.debugManager:info("Loading market data from: %s", fullPath)
    end

    if fileExists(fullPath) then
        local xmlFile = XMLFile.load("globalMarket", fullPath)
        if xmlFile ~= nil then
            -- Iterates through saved fillTypes and applies the loaded stock levels
            xmlFile:iterate("globalMarket.offlineMarket.fillTypes.fillType", function (_, baseKey)
                local fillType = xmlFile:getString(baseKey .. "#fillType")
                local level = xmlFile:getFloat(baseKey .. "#level")

                for _, ft in pairs(self.offlineMarketFillTypes) do
                    if ft.fillType == fillType then
                        ft.fillLevel = level
                        ft.greatDemandBonus = xmlFile:getFloat(baseKey .. "#greatDemandBonus") or 0
                        ft.greatDemandHours = xmlFile:getInt(baseKey .. "#greatDemandHours") or 0
                        -- Logged as TRACE to prevent massive log spam when loading 100+ fillTypes
                        if self.debugManager ~= nil then
                            self.debugManager:trace("Loaded %s: Level=%.2f", fillType, level)
                        end
                        break
                    end
                end
            end)

            -- Load siloStorages (Shadow Array for multi-farm logic) via uniqueId
            local loadedSilos = 0
            xmlFile:iterate("globalMarket.siloStorages.silo", function(_, siloKey)
                local uid = xmlFile:getString(siloKey .. "#uniqueId")

                if uid ~= nil then
                    local targetPlaceable = nil
                    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                        if placeable.uniqueId == uid then
                            targetPlaceable = placeable
                            break
                        end
                    end

                    if targetPlaceable ~= nil and targetPlaceable.spec_silo ~= nil and targetPlaceable.spec_silo.storages ~= nil then
                        xmlFile:iterate(siloKey .. ".storage", function(sIndex, storageKey)
                            local storage = targetPlaceable.spec_silo.storages[sIndex]
                            if storage ~= nil then
                                storage.gmFarmFillLevels = storage.gmFarmFillLevels or {}

                                xmlFile:iterate(storageKey .. ".farm", function(_, farmKey)
                                    local farmId = xmlFile:getInt(farmKey .. "#farmId")
                                    if farmId ~= nil then
                                        storage.gmFarmFillLevels[farmId] = storage.gmFarmFillLevels[farmId] or {}

                                        xmlFile:iterate(farmKey .. ".fillType", function(_, ftKey)
                                            local ftName = xmlFile:getString(ftKey .. "#name")
                                            local level = xmlFile:getFloat(ftKey .. "#level")
                                            if ftName ~= nil and level ~= nil then
                                                local fillTypeDesc = g_fillTypeManager:getFillTypeByName(ftName)
                                                if fillTypeDesc ~= nil then
                                                    storage.gmFarmFillLevels[farmId][fillTypeDesc.index] = level
                                                end
                                            end
                                        end)
                                    end
                                end)
                            end
                        end)
                        loadedSilos = loadedSilos + 1
                    else
                        if self.debugManager ~= nil then
                            self.debugManager:warning("Failed to map saved GM Silo with uniqueId '%s' to a physical placeable. It might have been removed.", uid)
                        end
                    end
                end
            end)

            xmlFile:delete()

            -- Recalculate all prices once after all levels are loaded
            if self.updateOfflinePrices ~= nil then
                self:refreshMarketPrices()
            end

            if self.debugManager ~= nil then
                self.debugManager:info("Savegame loading completed. Reconstructed arrays for %d GM Silos.", loadedSilos)
            end
        end
    else
        if self.debugManager ~= nil then
            self.debugManager:info("No savegame file found. Using randomized start levels and empty storages.")
        end
    end
end

-- Appends to the native engine save routine to ensure our data is written simultaneously.
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
    if g_currentMission.globalMarket ~= nil then
        g_currentMission.globalMarket:saveToXmlFile()
    end
end)

-- Syncs the initial state to players joining the multiplayer server.
function GlobalMarket:sendInitialClientState(connection, user, farm)
    if self.debugManager ~= nil then
        self.debugManager:debug("Syncing initial state to joining client: %s", tostring(user:getNickname()))
    end
    connection:sendEvent(SynchOfflineMarketEvent.new())
end

FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, function(mission, connection, user, farm)
    if mission.globalMarket ~= nil then
        mission.globalMarket:sendInitialClientState(connection, user, farm)
    end
end)
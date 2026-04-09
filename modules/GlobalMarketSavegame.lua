--
-- FS25 - GlobalMarket (Savegame Module)
--

-- Saves the current offline market fill levels to the active savegame directory.
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
        end)

        -- Note: Future online save data hooks (e.g., server IP, credentials) go here.

        xmlFile:save()
        xmlFile:delete()

        if self.debugManager ~= nil then
            self.debugManager:info("Savegame successfully written.")
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
                        -- Logged as TRACE to prevent massive log spam when loading 100+ fillTypes
                        if self.debugManager ~= nil then
                            self.debugManager:trace("Loaded %s: Level=%.2f", fillType, level)
                        end
                        break
                    end
                end
            end)
            xmlFile:delete()

            -- Recalculate all prices once after all levels are loaded
            if self.updateOfflinePrices ~= nil then
                self:updateOfflinePrices()
            end

            if self.debugManager ~= nil then
                self.debugManager:info("Savegame loading completed.")
            end
        end
    else
        if self.debugManager ~= nil then
            self.debugManager:info("No savegame file found. Using randomized start levels.")
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
--
-- FS25 - GlobalMarket (Savegame Module)
--

function GlobalMarket:saveToXmlFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then
        GlobalMarket.debugLog("Error: Savegame directory not found!")
        return
    end

    local fullPath = savegamePath .. "/globalMarket.xml"
    GlobalMarket.debugLog("Saving market data to: %s", fullPath)

    local xmlFile = XMLFile.create("globalMarket", fullPath, "globalMarket")
    if xmlFile ~= nil then
        -- Save Offline Market
        xmlFile:setTable("globalMarket.offlineMarket.fillTypes.fillType", self.offlineMarketFillTypes, function (key, info, _)
            xmlFile:setString(key .. "#fillType", info.fillType)
            xmlFile:setFloat(key .. "#level", info.fillLevel)
        end)

        -- If you had online save data hooks here previously, they would go here.
        -- (e.g. Last known server IP, user credentials, etc.)

        xmlFile:save()
        xmlFile:delete()
        GlobalMarket.debugLog("  -> Savegame successfully written.")
    end
end

function GlobalMarket:loadFromXMLFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then return end

    local fullPath = savegamePath .. "/globalMarket.xml"
    GlobalMarket.debugLog("Loading market data from: %s", fullPath)

    if fileExists(fullPath) then
        local xmlFile = XMLFile.load("globalMarket", fullPath)
        if xmlFile ~= nil then
            xmlFile:iterate("globalMarket.offlineMarket.fillTypes.fillType", function (_, baseKey)
                local fillType = xmlFile:getString(baseKey .. "#fillType")
                local level = xmlFile:getFloat(baseKey .. "#level")

                for _, ft in pairs(self.offlineMarketFillTypes) do
                    if ft.fillType == fillType then
                        ft.fillLevel = level
                        -- Removed old calcOfflinePrice call here because pricing is now centralized
                        GlobalMarket.debugLog("  -> Loaded %s: Level=%f", fillType, level)
                        break
                    end
                end
            end)
            xmlFile:delete()

            -- Recalculate all prices once after all levels are loaded
            if self.updateOfflinePrices ~= nil then
                self:updateOfflinePrices()
            end

            GlobalMarket.debugLog("  -> Savegame loading completed.")
        end
    else
        GlobalMarket.debugLog("  -> No savegame file found. Using randomized start levels.")
    end
end

-- Hook into the game's save process
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
    if g_currentMission.globalMarket ~= nil then
        g_currentMission.globalMarket:saveToXmlFile()
    end
end)

-- Initial Sync for joining clients
function GlobalMarket:sendInitialClientState(connection, user, farm)
    GlobalMarket.debugLog("Syncing initial state to joining client: %s", tostring(user:getNickname()))
    connection:sendEvent(SynchOfflineMarketEvent.new())
end

FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, function(mission, connection, user, farm)
    if mission.globalMarket ~= nil then
        mission.globalMarket:sendInitialClientState(connection, user, farm)
    end
end)
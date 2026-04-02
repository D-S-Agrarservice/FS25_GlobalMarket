--
-- FS25 - GlobalMarket (Savegame Module)
--

function GlobalMarket:saveToXmlFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then
        self:debugLog("Error: Savegame directory not found!")
        return
    end

    local fullPath = savegamePath .. "/globalMarket.xml"
    self:debugLog("Saving market data to: %s", fullPath)

    local xmlFile = XMLFile.create("globalMarket", fullPath, "globalMarket")
    if xmlFile ~= nil then
        xmlFile:setTable("globalMarket.offlineMarket.fillTypes.fillType", self.offlineMarketFillTypes, function (key, info, _)
            xmlFile:setString(key .. "#fillType", info.fillType)
            xmlFile:setInt(key .. "#level", info.fillLevel)
        end)

        xmlFile:save()
        xmlFile:delete()
        self:debugLog("  -> Savegame successfully written.")
    end
end

function GlobalMarket:loadFromXMLFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then return end

    local fullPath = savegamePath .. "/globalMarket.xml"
    self:debugLog("Loading market data from: %s", fullPath)

    if fileExists(fullPath) then
        local xmlFile = XMLFile.load("globalMarket", fullPath)
        if xmlFile ~= nil then
            xmlFile:iterate("globalMarket.offlineMarket.fillTypes.fillType", function (_, baseKey)
                local fillType = xmlFile:getString(baseKey .. "#fillType")
                local level = xmlFile:getInt(baseKey .. "#level")

                for _, ft in pairs(self.offlineMarketFillTypes) do
                    if ft.fillType == fillType then
                        ft.fillLevel = level
                        ft.price = GlobalMarket.calcOfflinePrice(ft.normalPrice, ft.fillLevel)
                        self:debugLog("  -> Loaded %s: Level=%d, Price=%f", fillType, level, ft.price)
                        break
                    end
                end
            end)
            xmlFile:delete()
            self:debugLog("  -> Savegame loading completed.")
        end
    else
        self:debugLog("  -> No savegame file found. Using randomized start levels.")
    end
end

-- Hook into save process
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
    if g_currentMission.globalMarket ~= nil then
        g_currentMission.globalMarket:saveToXmlFile()
    end
end)

-- Initial Sync for joining clients
function GlobalMarket:sendInitialClientState(connection, user, farm)
    self:debugLog("Syncing initial state to joining client: %s", tostring(user:getNickname()))
    connection:sendEvent(SynchOfflineMarketEvent.new())
end

FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, function(mission, connection, user, farm)
    if mission.globalMarket ~= nil then
        mission.globalMarket:sendInitialClientState(connection, user, farm)
    end
end)
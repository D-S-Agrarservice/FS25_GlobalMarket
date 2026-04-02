--
-- FS25 - GlobalMarket (Savegame Module)
-- Responsible for persisting offline market data
--

-- Save data to the globalMarket.xml within the current savegame folder
function GlobalMarket:saveToXmlFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then
        -- Fallback for safety, though missionInfo is standard in FS25
        return
    end

    local fullPath = savegamePath .. "/globalMarket.xml"
    local xmlFile = XMLFile.create("globalMarket", fullPath, "globalMarket")

    if xmlFile ~= nil then
        -- Save the offline fill levels and types
        xmlFile:setTable("globalMarket.offlineMarket.fillTypes.fillType", self.offlineMarketFillTypes, function (key, info, _)
            xmlFile:setString(key .. "#fillType", info.fillType)
            xmlFile:setInt(key .. "#level", info.fillLevel)
        end)

        xmlFile:save()
        xmlFile:delete()

        -- Logging for debug purposes in dev environment
        -- print("GlobalMarket: Savegame data written to " .. fullPath)
    end
end

-- Load data from the globalMarket.xml
function GlobalMarket:loadFromXMLFile()
    if not g_currentMission:getIsServer() then
        return
    end

    local savegamePath = g_currentMission.missionInfo.savegameDirectory
    if savegamePath == nil then
        return
    end

    local fullPath = savegamePath .. "/globalMarket.xml"
    if fileExists(fullPath) then
        local xmlFile = XMLFile.load("globalMarket", fullPath)

        if xmlFile ~= nil then
            xmlFile:iterate("globalMarket.offlineMarket.fillTypes.fillType", function (_, baseKey)
                local fillType = xmlFile:getString(baseKey .. "#fillType")
                local level = xmlFile:getInt(baseKey .. "#level")

                -- Match loaded data with initialized offline market table
                for _, ft in pairs(self.offlineMarketFillTypes) do
                    if ft.fillType == fillType then
                        ft.fillLevel = level
                        -- Recalculate price based on loaded level
                        ft.price = GlobalMarket.calcOfflinePrice(ft.normalPrice, ft.fillLevel)
                        break
                    end
                end
            end)

            xmlFile:delete()
        end
    end
end

-- Hook into the engine's saving process and initial client sync
FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, function()
    if g_currentMission.globalMarket ~= nil then
        g_currentMission.globalMarket:saveToXmlFile()
    end
end)

-- Ensure clients receive the current offline market state when joining
function GlobalMarket:sendInitialClientState(connection, user, farm)
    connection:sendEvent(SynchOfflineMarketEvent.new())
end

FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, function(mission, connection, user, farm)
    if mission.globalMarket ~= nil then
        mission.globalMarket:sendInitialClientState(connection, user, farm)
    end
end)
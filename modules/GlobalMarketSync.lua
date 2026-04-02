--
-- FS25 - GlobalMarket (Sync Module)
--

function GlobalMarket:initSync()
    self:debugLog("Initializing Sync Module (Online Communication)...")
    self.fillTypes = {}
    self.siloLevels = {}
    self.objectLevels = {}
    self.lastConnection = false
    self.timer2sec = 2000

    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.readFolder = getUserProfileAppPath() .. "modSettings/FS25_GlobalMarket/read/"
    self.writeFolder = getUserProfileAppPath() .. "modSettings/FS25_GlobalMarket/write/"

    if not entityExists(self.readFolder) then createFolder(self.readFolder) end
    if not entityExists(self.writeFolder) then createFolder(self.writeFolder) end
    self:debugLog("Sync paths set up. Read: %s", self.readFolder)
end

function GlobalMarket:updateSync(dt)
    self.timer2sec = self.timer2sec + dt

    if self:getIsMarketOnline() then
        if self.timer2sec >= 1000 then
            self.timer2sec = self.timer2sec - 1000

            local files = Files.new(self.readFolder)
            local updateUi = false

            for _, file in pairs(files.files) do
                local fullPath = self.readFolder .. "/" .. file.filename
                local xmlFile = XMLFile.load("gmDataSync", fullPath)

                if xmlFile ~= nil then
                    local action = xmlFile:getString("gmDataSync#action", "")
                    self:debugLog("Sync: Processing action '%s' from external EXE.", action)

                    if action == "marketData" then
                        self:parseMarketData(xmlFile)
                    elseif action == "buy" or action == "sell" then
                        -- Silo sync logic
                    elseif action == "buyObject" or action == "sellObject" then
                        -- Object sync logic
                    end

                    xmlFile:delete()
                    deleteFile(fullPath)
                    updateUi = true
                end
            end

            if updateUi and g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
            self.lastConnection = true
        end
    elseif self.lastConnection then
        self:debugLog("Sync: Connection to external EXE lost.")
        self.lastConnection = false
    end
end

function GlobalMarket:getIsMarketOnline()
    if fileExists(self.isOnlineFile) then
        local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
        local version = xmlFile:getInt("globalMarketOnline.version")
        xmlFile:delete()
        return version ~= nil and version >= self.needExeVersion
    end
    return false
end

function GlobalMarket:parseMarketData(xmlFile)
    self:debugLog("Sync: Updating online market data...")
    self.fillTypes = {}
    xmlFile:iterate("gmDataSync.fillTypes.fillType", function (_, baseKey)
        table.insert(self.fillTypes, {
            fillType = xmlFile:getString(baseKey .. "#fillType"),
            fillLevel = xmlFile:getInt(baseKey .. "#fillLevel"),
            price = xmlFile:getFloat(baseKey .. "#price"),
            isSilo = xmlFile:getBool(baseKey .. "#isSilo"),
            isObject = xmlFile:getBool(baseKey .. "#isObject"),
        })
    end)
end
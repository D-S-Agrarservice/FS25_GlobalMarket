--
-- FS25 - GlobalMarket (Sync Module)
--

function GlobalMarket:initSync()
    GlobalMarket.debugLog("Sync: Setting up optimized background listener...")

    self.isOnline = false
    self.lastConnectionState = false

    self.timerData = 0
    self.timerStatus = 0

    -- Dynamic intervals (in milliseconds)
    self.intervalData = 1000      -- Check for data files every 1s
    self.intervalStatusOff = 2000 -- Check if EXE started every 2s
    self.intervalStatusOn = 10000 -- Heartbeat check every 10s when online

    self.needExeVersion = 1

    local settingsPath = getUserProfileAppPath() .. "modSettings/FS25_GlobalMarket/"
    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.readFolder = settingsPath .. "read/"
    self.writeFolder = settingsPath .. "write/"

    createFolder(settingsPath)
    createFolder(self.readFolder)
    createFolder(self.writeFolder)
end

function GlobalMarket:runSyncUpdateLogic(dt)
    self.timerData = self.timerData + dt
    self.timerStatus = self.timerStatus + dt

    -- 1. HEARTBEAT / STATUS CHECK (Optimized Frequency)
    local currentStatusInterval = self.isOnline and self.intervalStatusOn or self.intervalStatusOff

    if self.timerStatus >= currentStatusInterval then
        self.timerStatus = 0
        local currentlyOnline = false

        if fileExists(self.isOnlineFile) then
            local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
            if xmlFile ~= nil then
                local version = xmlFile:getInt("globalMarketOnline.version")
                xmlFile:delete()
                currentlyOnline = (version ~= nil and version >= self.needExeVersion)
            end
        end

        -- Handle state change
        if currentlyOnline ~= self.isOnline then
            self.isOnline = currentlyOnline
            if self.isOnline then
                GlobalMarket.debugLog("Sync: EXE detected. Online mode active (Heartbeat slowed to %ds).", self.intervalStatusOn / 1000)
                self.lastConnectionState = true
            else
                GlobalMarket.debugLog("Sync: EXE lost. Reverting to Offline mode.")
                self.lastConnectionState = false
            end

            -- Force UI update on state change
            if g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        end
    end

    -- 2. DATA PROCESSING (Only if Online)
    if self.isOnline and self.timerData >= self.intervalData then
        self.timerData = 0

        local files = getFiles(self.readFolder)
        if files ~= nil then
            local updateUi = false
            for _, filename in pairs(files) do
                local fullPath = self.readFolder .. filename
                local xmlFile = XMLFile.load("gmDataSync", fullPath)
                if xmlFile ~= nil then
                    local action = xmlFile:getString("gmDataSync#action", "")
                    if action == "marketData" then
                        self:parseMarketData(xmlFile)
                        updateUi = true
                    end
                    xmlFile:delete()
                    deleteFile(fullPath)
                end
            end
            if updateUi and g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        end
    end
end

function GlobalMarket:parseMarketData(xmlFile)
    self.fillTypes = {}
    xmlFile:iterate("gmDataSync.fillTypes.fillType", function (_, baseKey)
        table.insert(self.fillTypes, {
            fillType = xmlFile:getString(baseKey .. "#fillType"),
            fillLevel = xmlFile:getInt(baseKey .. "#fillLevel") or 0,
            price = xmlFile:getFloat(baseKey .. "#price") or 0,
            isSilo = xmlFile:getBool(baseKey .. "#isSilo") or false,
            isObject = xmlFile:getBool(baseKey .. "#isObject") or false,
        })
    end)
end
--
-- FS25 - GlobalMarket (Sync Module)
--

function GlobalMarket:initSync()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Setting up optimized background listener...")
    end

    self.isOnline = false
    self.lastConnectionState = false

    self.timerData = 0
    self.timerStatus = 0

    -- Dynamic intervals (in milliseconds)
    self.intervalData = 1000      -- Check for data files every 1s
    self.intervalStatusOff = 2000 -- Check if EXE started every 2s
    self.intervalStatusOn = 10000 -- Heartbeat check every 10s when online

    self.needExeVersion = 1

    local settingsPath = getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/"
    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.readFolder = settingsPath .. "read/"
    self.writeFolder = settingsPath .. "write/"

    createFolder(settingsPath)
    createFolder(self.readFolder)
    createFolder(self.writeFolder)

    if self.debugManager ~= nil then
        self.debugManager:trace("Sync Folders verified. Read: %s | Write: %s", self.readFolder, self.writeFolder)
    end
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
                if self.debugManager ~= nil then
                    self.debugManager:info("Sync: EXE detected. Online mode active (Heartbeat slowed to %ds).", self.intervalStatusOn / 1000)
                end
                self.lastConnectionState = true
            else
                if self.debugManager ~= nil then
                    self.debugManager:warning("Sync: EXE connection lost or version mismatch. Reverting to Offline mode.")
                end
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
        if files ~= nil and #files > 0 then
            local updateUi = false
            for _, filename in pairs(files) do
                local fullPath = self.readFolder .. filename
                local xmlFile = XMLFile.load("gmDataSync", fullPath)

                if xmlFile ~= nil then
                    local action = xmlFile:getString("gmDataSync#action", "")

                    if self.debugManager ~= nil then
                        self.debugManager:trace("Sync: Found and processing file '%s' with action: '%s'", filename, action)
                    end

                    if action == "marketData" then
                        self:parseMarketData(xmlFile)
                        updateUi = true
                    end

                    xmlFile:delete()
                    local deleted = deleteFile(fullPath)

                    if not deleted and self.debugManager ~= nil then
                        self.debugManager:error("Sync: Failed to delete processed file '%s'. Possible OS file lock.", fullPath)
                    end
                end
            end

            if updateUi and g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        end
    end
end

-- Parses the incoming XML data from the EXE into the local Lua table
function GlobalMarket:parseMarketData(xmlFile)
    local updatedCount = 0

    xmlFile:iterate("gmDataSync.fillTypes.fillType", function (_, baseKey)
        local incomingFillTypeName = xmlFile:getString(baseKey .. "#fillType")
        local incomingFillLevel = xmlFile:getInt(baseKey .. "#fillLevel") or 0
        local incomingPrice = xmlFile:getFloat(baseKey .. "#price") or 0

        -- Find the existing entry in our single-source-of-truth table and update it
        if self.offlineMarketFillTypes ~= nil then
            for _, ft in pairs(self.offlineMarketFillTypes) do
                if ft.fillType == incomingFillTypeName then
                    ft.fillLevel = incomingFillLevel
                    ft.price = incomingPrice
                    -- ft.isSilo = isSilo 
                    -- ft.isObject = isObject
                    updatedCount = updatedCount + 1
                    break
                end
            end
        end
    end)

    if self.debugManager ~= nil then
        self.debugManager:debug("Sync: Successfully merged online market data. Updated %d items.", updatedCount)
        self.debugManager:traceTable("Sync: Dump of merged market data", self.offlineMarketFillTypes)
    end
end
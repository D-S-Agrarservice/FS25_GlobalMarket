--
-- FS25 - GlobalMarket (Sync Module)
-- Description: Handles dynamic token assignment for external EXE synchronization.
-- Implements semantic version checking and local pricing strategies.
-- Corrected: Segregated FileSystem initialization to prevent Nil-Pointer access during early boot.
--

-- Initializing path variables at module level to ensure visibility
function GlobalMarket:initFileSystem()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing FileSystem Paths & Directories...")
    end

    -- Base path for all modSettings
    local settingsPath = getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/"

    -- Absolute path definitions
    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.serverWhitelistFile = settingsPath .. "server_whitelist.xml"
    self.readFolder = settingsPath .. "read/"
    self.writeFolder = settingsPath .. "write/"

    -- Ensure physical directories exist
    createFolder(settingsPath)
    createFolder(self.readFolder)
    createFolder(self.writeFolder)
end

function GlobalMarket:initSync()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing Dynamic Token System...")
    end

    -- Ensure initFileSystem was called; fallback if load order is still incorrect
    if self.serverWhitelistFile == nil then
        self:initFileSystem()
    end

    -- State tracking for network authority
    self.isExeRunningLocal = false
    self.isDataHost = false
    self.dataHostConnection = nil
    self.serverWhitelist = {}

    self.timerData = 0
    self.timerStatus = 0

    -- Dynamic intervals (in milliseconds)
    self.intervalData = 1000
    self.intervalStatus = 2000

    -- Semantic versioning requirement
    self.minExeVersion = "1.0.0.0"
    self.hasShownVersionWarning = false
end

-- =========================================================================
-- HELPER: SEMANTIC VERSION COMPARISON
-- =========================================================================

local function isVersionSufficient(currentVersion, minVersion)
    if currentVersion == nil or currentVersion == "" then return false end

    local currentParts = {}
    for p in string.gmatch(currentVersion, "%d+") do table.insert(currentParts, tonumber(p)) end

    local minParts = {}
    for p in string.gmatch(minVersion, "%d+") do table.insert(minParts, tonumber(p)) end

    for i = 1, 4 do
        local cVal = currentParts[i] or 0
        local mVal = minParts[i] or 0

        if cVal > mVal then return true end
        if cVal < mVal then return false end
    end

    return true
end

-- =========================================================================
-- SERVER PERSISTENCE: ENRICHED WHITELIST GENERATION
-- =========================================================================

function GlobalMarket:initServerWhitelist()
    if not g_currentMission:getIsServer() then return end

    -- Critical Safety: Prevent XML engine crash if paths are not initialized
    if self.serverWhitelistFile == nil then
        if self.debugManager ~= nil then
            self.debugManager:error("Sync (Server): Cannot generate Whitelist. FileSystem not initialized!")
        end
        return
    end

    self.serverWhitelist = {}

    if self.offlineMarketFillTypes ~= nil then
        for _, data in pairs(self.offlineMarketFillTypes) do
            if data.fillType ~= nil then
                local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)
                local title = fillTypeDesc ~= nil and fillTypeDesc.title or data.fillType

                table.insert(self.serverWhitelist, {
                    name = data.fillType,
                    title = title,
                    basePrice = data.basePrice or 0
                })
            end
        end
    end

    if self.debugManager ~= nil then
        self.debugManager:info("Sync (Server): Generated enriched whitelist with %d items. Saving to %s", #self.serverWhitelist, self.serverWhitelistFile)
    end

    local xmlFile = XMLFile.create("gmServerWhitelist", self.serverWhitelistFile, "gmServerWhitelist")
    if xmlFile ~= nil then
        for i, item in ipairs(self.serverWhitelist) do
            local key = string.format("gmServerWhitelist.item(%d)", i - 1)
            xmlFile:setString(key .. "#name", item.name)
            xmlFile:setString(key .. "#title", item.title)
            xmlFile:setFloat(key .. "#basePrice", item.basePrice)
        end
        xmlFile:save()
        xmlFile:delete()
    end
end

-- =========================================================================
-- UPDATE LOOP (Client Polling & Data Host I/O)
-- =========================================================================

function GlobalMarket:runSyncUpdateLogic(dt)
    self.timerData = self.timerData + dt
    self.timerStatus = self.timerStatus + dt

    if not g_currentMission:getIsServer() and self.timerStatus >= self.intervalStatus then
        self.timerStatus = 0
        local exeRunningNow = false

        if fileExists(self.isOnlineFile) then
            local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
            if xmlFile ~= nil then
                local exeVersion = xmlFile:getString("globalMarketOnline.version")
                xmlFile:delete()

                exeRunningNow = isVersionSufficient(exeVersion, self.minExeVersion)

                if not exeRunningNow and exeVersion ~= nil then
                    if not self.hasShownVersionWarning and g_currentMission ~= nil then
                        local msg = g_i18n:getText("ui_gm_warning_exe_outdated")
                        if msg == nil or msg == "ui_gm_warning_exe_outdated" then
                            msg = string.format("GlobalMarket: External .exe is outdated! Minimum required version is %s.", self.minExeVersion)
                        end
                        g_currentMission:showBlinkingWarning(msg, 8000)
                        self.hasShownVersionWarning = true
                    end
                elseif exeRunningNow then
                    self.hasShownVersionWarning = false
                end
            end
        end

        if exeRunningNow ~= self.isExeRunningLocal then
            self.isExeRunningLocal = exeRunningNow
            if ExeStatusEvent ~= nil then
                g_client:getServerConnection():sendEvent(ExeStatusEvent.new(self.isExeRunningLocal))
            end
        end
    end

    if self.isDataHost and self.timerData >= self.intervalData then
        self.timerData = 0

        local files = getFiles(self.readFolder)
        if files ~= nil and #files > 0 then
            local newMarketData = {}

            for _, filename in pairs(files) do
                local fullPath = self.readFolder .. filename
                local xmlFile = XMLFile.load("gmDataSync", fullPath)

                if xmlFile ~= nil then
                    local action = xmlFile:getString("gmDataSync#action", "")
                    if action == "marketData" then
                        xmlFile:iterate("gmDataSync.fillTypes.fillType", function (_, baseKey)
                            local ftName = xmlFile:getString(baseKey .. "#fillType")
                            local ftLevel = xmlFile:getInt(baseKey .. "#fillLevel") or 0

                            table.insert(newMarketData, {
                                fillType = ftName,
                                fillLevel = ftLevel
                            })
                        end)
                    end
                    xmlFile:delete()
                    deleteFile(fullPath)
                end
            end

            if #newMarketData > 0 and MarketDataSyncEvent ~= nil then
                g_client:getServerConnection():sendEvent(MarketDataSyncEvent.new(newMarketData))
            end
        end
    end
end

-- =========================================================================
-- SERVER AUTHORITY FUNCTIONS
-- =========================================================================

function GlobalMarket:handleClientExeStatus(connection, isExeRunning)
    if not g_currentMission:getIsServer() then return end

    if isExeRunning then
        if self.dataHostConnection == nil then
            self.dataHostConnection = connection
            if SyncMarketWhitelistEvent ~= nil then
                connection:sendEvent(SyncMarketWhitelistEvent.new(self.serverWhitelist))
            end
            self.isOnline = true
            if g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        end
    else
        if self.dataHostConnection == connection then
            self.dataHostConnection = nil
            self.isOnline = false
            if g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        end
    end
end

function GlobalMarket:onClientDisconnected(connection)
    if g_currentMission:getIsServer() and self.dataHostConnection == connection then
        self.dataHostConnection = nil
        self.isOnline = false
        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
    end
end

-- =========================================================================
-- DATA-HOST FUNCTIONS
-- =========================================================================

function GlobalMarket:receiveDataHostToken(whitelist)
    self.isDataHost = true
    self.isOnline = true

    if self.writeFolder == nil then return end

    local xmlPath = self.writeFolder .. "whitelist_" .. tostring(math.floor(g_time)) .. ".xml"
    local xmlFile = XMLFile.create("gmWhitelist", xmlPath, "gmDataSync")

    if xmlFile ~= nil then
        xmlFile:setString("gmDataSync#action", "updateWhitelist")
        for i, item in ipairs(whitelist) do
            local key = string.format("gmDataSync.whitelist.item(%d)", i - 1)
            xmlFile:setString(key .. "#name", item.name)
            xmlFile:setString(key .. "#title", item.title)
            xmlFile:setFloat(key .. "#basePrice", item.basePrice)
        end
        xmlFile:save()
        xmlFile:delete()
    end
end

-- =========================================================================
-- SHARED SYNC FUNCTIONS
-- =========================================================================

function GlobalMarket:applySyncedMarketData(marketData)
    local updatedCount = 0
    if self.offlineMarketFillTypes ~= nil then
        for _, incomingItem in ipairs(marketData) do
            for _, localItem in pairs(self.offlineMarketFillTypes) do
                if localItem.fillType == incomingItem.fillType then
                    localItem.fillLevel = incomingItem.fillLevel
                    updatedCount = updatedCount + 1
                    break
                end
            end
        end
    end

    if self.updateOfflinePrices ~= nil then
        self:updateOfflinePrices()
    end

    if g_currentMission.globalMarketUi ~= nil then
        g_currentMission.globalMarketUi:updateContent()
    end
end
--
-- FS25 - GlobalMarket (Sync Module)
-- Description: Handles dynamic token assignment for external EXE synchronization.
-- Only ONE client (the Data-Host) polls the file system to prevent network collapse.
-- Implements semantic version checking, enriched whitelist data for the backend,
-- and local pricing strategies (preventing arbitrage).
--

function GlobalMarket:initSync()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing Dynamic Token System & File I/O...")
    end

    -- State tracking for network authority
    self.isExeRunningLocal = false
    self.isDataHost = false
    self.dataHostConnection = nil -- Server only: Tracks which client holds the token
    self.serverWhitelist = {}     -- Server only: Cached enriched whitelist for the current map

    self.timerData = 0
    self.timerStatus = 0

    -- Dynamic intervals (in milliseconds)
    self.intervalData = 1000      -- Data-Host checks read folder every 1s
    self.intervalStatus = 2000    -- All clients check local EXE status every 2s

    -- Semantic versioning requirement (Major.Minor.Patch.Build)
    self.minExeVersion = "1.0.0.0"
    self.hasShownVersionWarning = false -- Prevents UI warning spam

    -- Path definitions
    local settingsPath = getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/"
    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.serverWhitelistFile = settingsPath .. "server_whitelist.xml"
    self.readFolder = settingsPath .. "read/"
    self.writeFolder = settingsPath .. "write/"

    createFolder(settingsPath)
    createFolder(self.readFolder)
    createFolder(self.writeFolder)
end

-- =========================================================================
-- HELPER: SEMANTIC VERSION COMPARISON
-- =========================================================================

-- Compares two semantic version strings (e.g. "1.2.0.0" >= "1.0.5.0")
-- Returns true if currentVersion is greater than or equal to minVersion
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

    return true -- Exact match
end

-- =========================================================================
-- SERVER PERSISTENCE: ENRICHED WHITELIST GENERATION
-- =========================================================================

-- Generates the persistent server whitelist based on the initialized offline market.
-- Includes localized titles and base prices for backend registration.
function GlobalMarket:initServerWhitelist()
    if not g_currentMission:getIsServer() then return end

    self.serverWhitelist = {}

    -- Generate fresh from validated offlineMarketFillTypes to ensure map/mod changes are caught
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
        self.debugManager:info("Sync (Server): Generated enriched whitelist with %d items. Saving to modSettings...", #self.serverWhitelist)
    end

    -- Persist for external reference/debugging
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

    -- 1. LOCAL EXE STATUS POLLING (Executed by ALL Clients, NOT the Server)
    if not g_currentMission:getIsServer() and self.timerStatus >= self.intervalStatus then
        self.timerStatus = 0
        local exeRunningNow = false

        if fileExists(self.isOnlineFile) then
            local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
            if xmlFile ~= nil then
                -- Parse semantic version string
                local exeVersion = xmlFile:getString("globalMarketOnline.version")
                xmlFile:delete()

                exeRunningNow = isVersionSufficient(exeVersion, self.minExeVersion)

                if not exeRunningNow and exeVersion ~= nil then
                    if self.debugManager ~= nil then
                        self.debugManager:warning("Sync: Local EXE version %s is outdated. Required: %s", exeVersion, self.minExeVersion)
                    end

                    -- Trigger In-Game UI Warning once per outdated session
                    if not self.hasShownVersionWarning and g_currentMission ~= nil then
                        local msg = g_i18n:getText("ui_gm_warning_exe_outdated")
                        if msg == nil or msg == "ui_gm_warning_exe_outdated" then
                            -- Fallback if localization is missing
                            msg = string.format("GlobalMarket: External .exe is outdated! Minimum required version is %s.", self.minExeVersion)
                        end
                        -- Display for 8 seconds
                        g_currentMission:showBlinkingWarning(msg, 8000)
                        self.hasShownVersionWarning = true
                    end
                elseif exeRunningNow then
                    -- Reset the warning flag if the player successfully starts a valid EXE version
                    self.hasShownVersionWarning = false
                end
            end
        end

        -- Notify server on state change
        if exeRunningNow ~= self.isExeRunningLocal then
            self.isExeRunningLocal = exeRunningNow

            if self.debugManager ~= nil then
                self.debugManager:info("Sync: Local EXE status changed to %s. Notifying server...", tostring(exeRunningNow))
            end

            if ExeStatusEvent ~= nil then
                g_client:getServerConnection():sendEvent(ExeStatusEvent.new(self.isExeRunningLocal))
            end
        end
    end

    -- 2. DATA PROCESSING (Executed ONLY by the elected Data-Host Client)
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
                        -- Parse data into a temporary table to be sent via network event
                        -- NOTE: Price is intentionally omitted to allow local economic calculation
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

            -- Dispatch to server if data was found
            if #newMarketData > 0 then
                if self.debugManager ~= nil then
                    self.debugManager:trace("Sync (Data-Host): Parsed %d items. Dispatching MarketDataSyncEvent.", #newMarketData)
                end

                if MarketDataSyncEvent ~= nil then
                    g_client:getServerConnection():sendEvent(MarketDataSyncEvent.new(newMarketData))
                end
            end
        end
    end
end

-- =========================================================================
-- SERVER AUTHORITY FUNCTIONS
-- =========================================================================

-- Called by ExeStatusEvent when a client reports their EXE status
function GlobalMarket:handleClientExeStatus(connection, isExeRunning)
    if not g_currentMission:getIsServer() then return end

    if isExeRunning then
        -- Assign token if no host exists
        if self.dataHostConnection == nil then
            self.dataHostConnection = connection

            if self.debugManager ~= nil then
                self.debugManager:info("Sync (Server): Assigning Data-Host token to client.")
            end

            -- Hand over token and enriched map whitelist
            if SyncMarketWhitelistEvent ~= nil then
                connection:sendEvent(SyncMarketWhitelistEvent.new(self.serverWhitelist))
            end

            -- Force UI update & set global state
            self.isOnline = true
            if g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        end
    else
        -- Revoke token if the current host stopped their EXE
        if self.dataHostConnection == connection then
            self.dataHostConnection = nil
            self.isOnline = false

            if self.debugManager ~= nil then
                self.debugManager:warning("Sync (Server): Data-Host stopped their EXE. Token revoked. Falling back to offline mode.")
            end

            if g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
        end
    end
end

-- Called on client disconnect to prevent token deadlocks
function GlobalMarket:onClientDisconnected(connection)
    if g_currentMission:getIsServer() and self.dataHostConnection == connection then
        self.dataHostConnection = nil
        self.isOnline = false

        if self.debugManager ~= nil then
            self.debugManager:warning("Sync (Server): Data-Host disconnected. Token revoked.")
        end

        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
    end
end

-- =========================================================================
-- DATA-HOST FUNCTIONS
-- =========================================================================

-- Called by SyncMarketWhitelistEvent on the client receiving the token
function GlobalMarket:receiveDataHostToken(whitelist)
    self.isDataHost = true
    self.isOnline = true

    if self.debugManager ~= nil then
        self.debugManager:info("Sync (Client): Received Data-Host Token. Initializing Enriched Whitelist XML for EXE...")
    end

    -- Write enriched whitelist to XML so the EXE limits its API requests and discovers new fillTypes
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
-- SHARED SYNC FUNCTIONS (Server & All Clients)
-- =========================================================================

-- Called by MarketDataSyncEvent. Injects global stock levels and triggers local price calculation.
function GlobalMarket:applySyncedMarketData(marketData)
    local updatedCount = 0

    if self.offlineMarketFillTypes ~= nil then
        for _, incomingItem in ipairs(marketData) do
            for _, localItem in pairs(self.offlineMarketFillTypes) do
                if localItem.fillType == incomingItem.fillType then
                    -- Overwrite local fill level with global fill level from backend
                    localItem.fillLevel = incomingItem.fillLevel
                    updatedCount = updatedCount + 1
                    break
                end
            end
        end
    end

    if self.debugManager ~= nil then
        self.debugManager:debug("Sync: Applied %d synced global stock levels.", updatedCount)
    end

    -- Trigger local price calculation based on the new global supply metrics
    if self.updateOfflinePrices ~= nil then
        self:updateOfflinePrices()
    end

    if g_currentMission.globalMarketUi ~= nil then
        g_currentMission.globalMarketUi:updateContent()
    end
end
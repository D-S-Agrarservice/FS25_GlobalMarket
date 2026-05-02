--
-- FS25 - GlobalMarket (Sync Module)
-- Description: Handles dynamic token assignment for external EXE synchronization.
-- Implements semantic version checking, enriched whitelist generation, and HUD status integration.
-- Enhanced: High-performance polling and event-driven HUD updates for dedicated servers.
--

function GlobalMarket:initFileSystem()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing FileSystem Paths & Directories...")
    end

    -- Base directory for mod configuration
    local settingsPath = getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/"

    -- Absolute path definitions
    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.serverWhitelistFile = settingsPath .. "server_whitelist.xml"
    self.readFolder = settingsPath .. "read/"
    self.writeFolder = settingsPath .. "write/"

    -- Ensure physical folder structure exists on local drive
    createFolder(settingsPath)
    createFolder(self.readFolder)
    createFolder(self.writeFolder)

    if self.debugManager ~= nil then
        self.debugManager:trace("Sync: FileSystem initialized. Paths: Read=%s, Write=%s", self.readFolder, self.writeFolder)
    end
end

function GlobalMarket:initSync()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing Dynamic Token System...")
    end

    -- Safety check: Warn if filesystem was not initialized during loadMap
    if self.serverWhitelistFile == nil then
        if self.debugManager ~= nil then
            self.debugManager:warning("Sync: FileSystem not ready during initSync! Forcing late initialization...")
        end
        self:initFileSystem()
    end

    -- Synchronization and authority states
    self.isExeRunningLocal = false
    self.isDataHost = false
    self.dataHostConnection = nil
    self.serverWhitelist = {}

    -- Cycle management
    self.timerData = 0
    self.timerStatus = 0
    self.intervalData = 1000      -- Polling backend data every 1s
    self.intervalStatus = 2000    -- Checking EXE heartbeat every 2s

    -- API Requirements
    self.minExeVersion = "1.0.0.0"
    self.hasShownVersionWarning = false

    -- HUD Integration: Only for clients (non-Dedi)
    if g_dedicatedServerInfo == nil then
        self:initStatusHudHooks()
    end

    -- Console Debug API
    addConsoleCommand("gmTestStatus", "Toggle GM Status Icon testing (0=Off, 1=EXE, 2=Host)", "consoleCommandTestStatus", self)
end

-- =========================================================================
-- HUD STATUS INTEGRATION (GameInfoDisplay Hooks)
-- =========================================================================

function GlobalMarket:initStatusHudHooks()
    -- Hook 1: Constructor - Prepare Overlay using guiProfiles.xml definition
    GameInfoDisplay.new = Utils.appendedFunction(GameInfoDisplay.new, function(display)
        -- Profile "gui.icon_sync" must exist in guiProfiles.xml
        display.gmStatusIcon = g_overlayManager:createOverlay("gui.icon_sync", 0, 0, 0, 0)
        display.gmStatusIcon:setColor(0.5, 0.5, 0.5, 0.5) -- Initial offline color
    end)

    -- Hook 2: Cleanup - prevent memory leaks
    GameInfoDisplay.delete = Utils.appendedFunction(GameInfoDisplay.delete, function(display)
        if display.gmStatusIcon ~= nil then
            display.gmStatusIcon:delete()
            display.gmStatusIcon = nil
        end
    end)

    -- Hook 3: Scaling - Maintain FS25 48px standard
    GameInfoDisplay.storeScaledValues = Utils.appendedFunction(GameInfoDisplay.storeScaledValues, function(display)
        display.gmIconWidth, display.gmIconHeight = display:scalePixelValuesToScreenVector(48, 48)
        if display.gmStatusIcon ~= nil then
            display.gmStatusIcon:setDimension(display.gmIconWidth, display.gmIconHeight)
        end
    end)

    -- Hook 4: Rendering - Optimized draw with minimal logic
    GameInfoDisplay.draw = Utils.overwrittenFunction(GameInfoDisplay.draw, function(display, superFunc)
        if not display.isVisible or display.gmStatusIcon == nil then
            return superFunc(display)
        end

        -- Run vanilla rendering (draws background and weather elements)
        superFunc(display)

        -- Position icon left of weather using info bar anchors
        local posY = display.y - display.moneyBgRight.height
        local posX = display.infoBgLeft.x + display.spacing

        display.gmStatusIcon:setPosition(posX, posY + display.weatherIconOffsetY)
        display.gmStatusIcon:render()
    end)
end

-- =========================================================================
-- UPDATE LOGIC: CONSOLIDATED POLLING
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

function GlobalMarket:runSyncUpdateLogic(dt)
    self.timerData = self.timerData + dt
    self.timerStatus = self.timerStatus + dt

    -- Phase 1: Heartbeat - Update local EXE status (Clients only)
    if not g_currentMission:getIsServer() and self.timerStatus >= self.intervalStatus then
        self.timerStatus = 0
        local exeRunningNow = false

        if fileExists(self.isOnlineFile) then
            local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
            if xmlFile ~= nil then
                local exeVersion = xmlFile:getString("globalMarketOnline.version")
                xmlFile:delete()
                exeRunningNow = isVersionSufficient(exeVersion, self.minExeVersion)

                if not exeRunningNow and not self.hasShownVersionWarning then
                    g_currentMission:showBlinkingWarning(g_i18n:getText("ui_gm_warning_exe_outdated"), 8000)
                    self.hasShownVersionWarning = true
                elseif exeRunningNow then
                    self.hasShownVersionWarning = false
                end
            end
        end

        if exeRunningNow ~= self.isExeRunningLocal then
            self.isExeRunningLocal = exeRunningNow
            self:updateHudIconState() -- Trigger optimized HUD color change
            if ExeStatusEvent ~= nil then
                g_client:getServerConnection():sendEvent(ExeStatusEvent.new(self.isExeRunningLocal))
            end
        end
    end

    -- Phase 2: Processing - File Polling (Data-Host only)
    if self.isDataHost and self.timerData >= self.intervalData then
        self.timerData = 0
        -- Guarded directory check to minimize IO overhead
        if fileExists(self.readFolder) then
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
                                table.insert(newMarketData, { fillType = ftName, fillLevel = ftLevel })
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
end

-- =========================================================================
-- OPTIMIZED HUD COLOR MANAGEMENT
-- =========================================================================

function GlobalMarket:updateHudIconState()
    if g_dedicatedServerInfo ~= nil or g_currentMission.hud.display.gmStatusIcon == nil then return end

    local icon = g_currentMission.hud.display.gmStatusIcon
    if self.isDataHost then
        icon:setColor(0.3, 0.8, 0, 1.0) -- Green: Hosting
    elseif self.isExeRunningLocal then
        icon:setColor(1.0, 0.5, 0, 1.0) -- Orange: Heartbeat Active
    else
        icon:setColor(0.5, 0.5, 0.5, 0.5) -- Gray: Offline
    end
end

-- =========================================================================
-- NETWORKING & WHITELIST GENERATION
-- =========================================================================

function GlobalMarket:initServerWhitelist()
    if not g_currentMission:getIsServer() or self.serverWhitelistFile == nil then return end

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
        self.debugManager:info("Sync (Server): Discovery whitelist generated (%d items).", #self.serverWhitelist)
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

function GlobalMarket:handleClientExeStatus(connection, isExeRunning)
    if not g_currentMission:getIsServer() then return end
    if isExeRunning then
        if self.dataHostConnection == nil then
            self.dataHostConnection = connection
            if self.debugManager ~= nil then
                self.debugManager:info("Sync (Server): Connection %s elected as Data-Host.", tostring(connection:getContext()))
            end
            if SyncMarketWhitelistEvent ~= nil then
                connection:sendEvent(SyncMarketWhitelistEvent.new(self.serverWhitelist))
            end
            self.isOnline = true
            if g_currentMission.globalMarketUi ~= nil then g_currentMission.globalMarketUi:updateContent() end
        end
    else
        if self.dataHostConnection == connection then
            self.dataHostConnection = nil
            self.isOnline = false
            if g_currentMission.globalMarketUi ~= nil then g_currentMission.globalMarketUi:updateContent() end
        end
    end
end

function GlobalMarket:onClientDisconnected(connection)
    if g_currentMission:getIsServer() and self.dataHostConnection == connection then
        self.dataHostConnection = nil
        self.isOnline = false
        if g_currentMission.globalMarketUi ~= nil then g_currentMission.globalMarketUi:updateContent() end
    end
end

function GlobalMarket:receiveDataHostToken(whitelist)
    self.isDataHost = true
    self.isOnline = true
    self:updateHudIconState() -- Transition to Green

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
    if self.updateOfflinePrices ~= nil then self:updateOfflinePrices() end
    if g_currentMission.globalMarketUi ~= nil then g_currentMission.globalMarketUi:updateContent() end
end

-- =========================================================================
-- DEV TOOLS
-- =========================================================================

function GlobalMarket:consoleCommandTestStatus(val)
    local state = tonumber(val)
    if state == 0 then
        self.isExeRunningLocal = false
        self.isDataHost = false
    elseif state == 1 then
        self.isExeRunningLocal = true
        self.isDataHost = false
    elseif state == 2 then
        self.isExeRunningLocal = true
        self.isDataHost = true
    end
    self:updateHudIconState()
    return string.format("GM Status Test Mode: %d", state)
end
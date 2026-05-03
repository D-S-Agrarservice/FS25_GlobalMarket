--
-- FS25 - GlobalMarket (Sync Module)
-- Description: Handles dynamic token assignment for external EXE synchronization.
-- Implements semantic version checking, enriched whitelist generation, and HUD status integration.
-- Enhanced: Instance-Injection method to safely bypass FS25 HUD initialization timing issues.
--

function GlobalMarket:initFileSystem()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing FileSystem Paths & Directories...")
    end

    -- Base path for mod settings
    local settingsPath = getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/"

    -- File definitions
    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.serverWhitelistFile = settingsPath .. "server_whitelist.xml"
    self.readFolder = settingsPath .. "read/"
    self.writeFolder = settingsPath .. "write/"

    -- Physical directory creation
    createFolder(settingsPath)
    createFolder(self.readFolder)
    createFolder(self.writeFolder)
end

function GlobalMarket:initSync()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing Dynamic Token System...")
    end

    if self.serverWhitelistFile == nil then
        self:initFileSystem()
    end

    -- Network and EXE state tracking
    self.isExeRunningLocal = false
    self.hasBackendConnection = false -- Tracks connection state to external backend
    self.isDataHost = false
    self.dataHostConnection = nil
    self.serverWhitelist = {}

    -- Polling management
    self.timerData = 0
    self.timerStatus = 0
    self.intervalData = 1000
    self.intervalStatus = 2000

    -- Versioning
    self.minExeVersion = "1.0.0.0"
    self.hasShownVersionWarning = false

    -- Note: HUD injection (self:initStatusHudHooks()) has been moved to onFinishedLoading in gm.lua
    -- to ensure g_currentMission.hud.gameInfoDisplay is fully initialized before access.

    addConsoleCommand("gmTestStatus", "Toggle GM Status Icon testing (0=Off, 1=EXE, 2=Host)", "consoleCommandTestStatus", self)
end

-- =========================================================================
-- HUD STATUS INTEGRATION (Instance Injection Method)
-- =========================================================================

function GlobalMarket:initStatusHudHooks()
    local display = g_currentMission.hud.gameInfoDisplay

    -- Abort if the instance does not exist
    if display == nil then
        if self.debugManager ~= nil then
            self.debugManager:error("HUD Injection failed: gameInfoDisplay instance not found!")
        end
        return
    end

    -- Prevent double injection on script reload
    if display.hasGlobalMarketIcon then
        return
    end
    display.hasGlobalMarketIcon = true

    -- Local reference for the hook
    local syncModule = self
    -- Default color values (Gray)
    syncModule.iconColorR, syncModule.iconColorG, syncModule.iconColorB = 0.5, 0.5, 0.5

    -- Hook into the draw method of GameInfoDisplay
    display.draw = Utils.appendedFunction(display.draw, function(self)
        -- Only render if the HUD is actually visible
        if not self.getVisible or not self:getVisible() then
            return
        end

        -- Initialize the GlobalMarket overlays if they do not exist yet
        if self.gmStatusBg == nil then
            -- Create background overlay using the vanilla white circle slice
            self.gmStatusBg = g_overlayManager:createOverlay("gui.whiteCircleFilled", 0, 0, 0, 0)

            -- Create icon overlay from local mod file
            local iconPath = Utils.getFilename("images/menuIcon.png", GlobalMarket.dir)
            self.gmStatusIcon = Overlay.new(iconPath, 0, 0, 0, 0)
        end

        -- Calculate dynamic scaling based on UI scale settings
        local bgSizeX, bgSizeY = self:scalePixelValuesToScreenVector(42, 42)
        local iconSizeX, iconSizeY = self:scalePixelValuesToScreenVector(28, 28)

        self.gmStatusBg:setDimension(bgSizeX, bgSizeY)
        self.gmStatusIcon:setDimension(iconSizeX, iconSizeY)

        -- Set background color to native HUD background color (semi-transparent black)
        local bgColor = HUD.COLOR.BACKGROUND
        if bgColor ~= nil then
            self.gmStatusBg:setColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
        else
            self.gmStatusBg:setColor(0, 0, 0, 0.8) -- Fallback
        end

        -- Calculate dynamic position relative to the leftmost part of the GameInfoDisplay
        local paddingX = self:scalePixelToScreenWidth(15)
        local targetBgX = self.infoBgLeft.x - bgSizeX - paddingX

        -- Center vertically relative to the base posY of the GameInfoDisplay
        local _, posY = self:getPosition()
        posY = posY - self.moneyBgRight.height -- Adjust for the HUD box height
        local targetBgY = posY + (self.infoBgLeft.height * 0.5) - (bgSizeY * 0.5)

        self.gmStatusBg:setPosition(targetBgX, targetBgY)

        -- Center the icon inside the background circle
        local targetIconX = targetBgX + (bgSizeX * 0.5) - (iconSizeX * 0.5)
        local targetIconY = targetBgY + (bgSizeY * 0.5) - (iconSizeY * 0.5)

        self.gmStatusIcon:setPosition(targetIconX, targetIconY)

        -- Determine alpha for pulsing effect
        local alpha = 1.0
        if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil and GlobalMarketSettings.current.isIconPulseActive then
            if syncModule.syncPulseTimer ~= nil and syncModule.syncPulseTimer > g_time then
                -- Calculate fading effect using sine wave between 0.2 and 1.0
                alpha = 0.2 + 0.8 * math.abs(math.sin(g_time / 150))
            end
        end

        -- Apply color state and alpha
        self.gmStatusIcon:setColor(syncModule.iconColorR, syncModule.iconColorG, syncModule.iconColorB, alpha)

        -- Render the overlays (background first, then icon)
        self.gmStatusBg:render()
        self.gmStatusIcon:render()
    end)

    -- Hook into the delete method to prevent memory leaks
    display.delete = Utils.prependedFunction(display.delete, function(self)
        if self.gmStatusBg ~= nil then
            self.gmStatusBg:delete()
            self.gmStatusBg = nil
        end
        if self.gmStatusIcon ~= nil then
            self.gmStatusIcon:delete()
            self.gmStatusIcon = nil
        end
        self.hasGlobalMarketIcon = false
    end)

    -- Force initial status update to color the icon immediately
    self:updateHudIconState()
end

-- =========================================================================
-- UPDATE LOGIC: PERFORMANCE CONSOLIDATED
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

    -- Phase 1: Heartbeat - Update local EXE status
    if not g_currentMission:getIsServer() and self.timerStatus >= self.intervalStatus then
        self.timerStatus = 0
        local exeRunningNow = false
        local backendConnectedNow = false

        if fileExists(self.isOnlineFile) then
            local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
            if xmlFile ~= nil then
                local exeVersion = xmlFile:getString("globalMarketOnline.version")

                -- Read backend connection state (default to true for legacy support)
                backendConnectedNow = xmlFile:getBool("globalMarketOnline#isConnected", true)

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

        -- Check if either EXE status or backend connection state changed
        if exeRunningNow ~= self.isExeRunningLocal or backendConnectedNow ~= self.hasBackendConnection then
            self.isExeRunningLocal = exeRunningNow
            self.hasBackendConnection = backendConnectedNow

            self:updateHudIconState()

            if ExeStatusEvent ~= nil then
                -- Note: ExeStatusEvent must be updated to support the second parameter (self.hasBackendConnection)
                g_client:getServerConnection():sendEvent(ExeStatusEvent.new(self.isExeRunningLocal, self.hasBackendConnection))
            end
        end
    end

    -- Phase 2: Processing - backend IO (Data-Host only)
    if self.isDataHost and self.timerData >= self.intervalData then
        self.timerData = 0
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
-- HUD STATE MANAGEMENT (Event Driven)
-- =========================================================================

function GlobalMarket:updateHudIconState()
    if self.isDataHost then
        self.iconColorR, self.iconColorG, self.iconColorB = 0.3, 0.8, 0.0 -- Green (All OK, Master)
    elseif self.isExeRunningLocal then
        if self.hasBackendConnection == false then
            self.iconColorR, self.iconColorG, self.iconColorB = 1.0, 0.0, 0.0 -- Red (EXE running, but no backend connection)
        else
            self.iconColorR, self.iconColorG, self.iconColorB = 1.0, 0.5, 0.0 -- Orange (EXE running, connected, not host)
        end
    else
        self.iconColorR, self.iconColorG, self.iconColorB = 0.5, 0.5, 0.5 -- Gray (No local EXE)
    end
end

-- =========================================================================
-- NETWORKING & DATA HANDLING
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

    -- Write whitelist for external EXE discovery
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

function GlobalMarket:handleClientExeStatus(connection, isExeRunning, hasBackendConnection)
    if not g_currentMission:getIsServer() then return end

    -- Verify the connection parameters depending on the actual client state
    if isExeRunning and hasBackendConnection ~= false then
        if self.dataHostConnection == nil then
            self.dataHostConnection = connection
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
    self:updateHudIconState()

    if self.writeFolder == nil then return end

    -- Notify backend about becoming the host
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
    -- Trigger UI pulse effect for 2000 milliseconds
    self.syncPulseTimer = g_time + 2000

    if self.offlineMarketFillTypes ~= nil then
        for _, incomingItem in ipairs(marketData) do
            for _, localItem in pairs(self.offlineMarketFillTypes) do
                if localItem.fillType == incomingItem.fillType then
                    localItem.fillLevel = incomingItem.fillLevel
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
        self.hasBackendConnection = false
    elseif state == 1 then
        self.isExeRunningLocal = true
        self.isDataHost = false
        self.hasBackendConnection = true
    elseif state == 2 then
        self.isExeRunningLocal = true
        self.isDataHost = true
        self.hasBackendConnection = true
    elseif state == 3 then
        self.isExeRunningLocal = true
        self.isDataHost = false
        self.hasBackendConnection = false
    end
    self:updateHudIconState()
    return string.format("GM Status Test Mode: %d", state)
end
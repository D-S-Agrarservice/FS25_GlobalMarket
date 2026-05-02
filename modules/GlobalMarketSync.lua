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
    if display.gmStatusIcon ~= nil then
        return
    end

    -- Resolve the absolute path to the custom status icon image
    local iconPath = Utils.getFilename("images/menuIcon.png", GlobalMarket.dir)

    -- Use the native Overlay class instead of g_overlayManager to load raw files
    -- Overlay.new(overlayFilename, x, y, width, height) uses the engine's createImageOverlay
    display.gmStatusIcon = Overlay.new(iconPath, 0, 0, 0, 0)

    if display.gmStatusIcon == nil or display.gmStatusIcon.overlayId == 0 then
        if self.debugManager ~= nil then
            self.debugManager:error("HUD Injection failed: Could not create Overlay from path '%s'!", iconPath)
        end
        return
    end

    -- Set default color state (Inactive/Grey)
    display.gmStatusIcon:setColor(0.5, 0.5, 0.5, 0.5)

    -- Force initial scaling based on FS25 UI standard size (48px)
    display.gmIconWidth, display.gmIconHeight = display:scalePixelValuesToScreenVector(48, 48)
    display.gmStatusIcon:setDimension(display.gmIconWidth, display.gmIconHeight)

    -- Hook scaling method to react to user changing the UI scale in the game settings
    display.storeScaledValues = Utils.appendedFunction(display.storeScaledValues, function(target)
        target.gmIconWidth, target.gmIconHeight = target:scalePixelValuesToScreenVector(48, 48)
        if target.gmStatusIcon ~= nil then
            target.gmStatusIcon:setDimension(target.gmIconWidth, target.gmIconHeight)
        end
    end)

    -- Inject direct draw method
    local originalDraw = display.draw
    display.draw = function(target)
        -- Execute original draw to let the engine calculate dynamic anchor positions
        originalDraw(target)

        if target.isVisible and target.gmStatusIcon ~= nil then
            -- Position dynamically based on the left background edge and weather icon Y-axis
            local posX = target.infoBgLeft.x - target.gmIconWidth - target.spacing
            local posY = target.y + target.weatherIconOffsetY

            target.gmStatusIcon:setPosition(posX, posY)
            target.gmStatusIcon:render()
        end
    end

    -- Prevent memory leaks upon UI destruction
    display.delete = Utils.prependedFunction(display.delete, function(target)
        if target.gmStatusIcon ~= nil then
            target.gmStatusIcon:delete()
            target.gmStatusIcon = nil
        end
    end)
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
            self:updateHudIconState()
            if ExeStatusEvent ~= nil then
                g_client:getServerConnection():sendEvent(ExeStatusEvent.new(self.isExeRunningLocal))
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
    -- Validating HUD instance before access
    if g_currentMission == nil or g_currentMission.hud == nil or g_currentMission.hud.gameInfoDisplay == nil then
        return
    end

    local icon = g_currentMission.hud.gameInfoDisplay.gmStatusIcon
    if icon == nil then return end

    -- Color assignment based on sync state
    if self.isDataHost then
        icon:setColor(0.3, 0.8, 0, 1.0) -- Green: Primary Data Source
    elseif self.isExeRunningLocal then
        icon:setColor(1.0, 0.5, 0, 1.0) -- Orange: Local Link Active
    else
        icon:setColor(0.5, 0.5, 0.5, 0.5) -- Gray: Link Lost
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

function GlobalMarket:handleClientExeStatus(connection, isExeRunning)
    if not g_currentMission:getIsServer() then return end
    if isExeRunning then
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
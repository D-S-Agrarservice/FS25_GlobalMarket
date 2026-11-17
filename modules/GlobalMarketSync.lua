-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketSync.lua
-- External companion client synchronization, Data-Host failover, and HUD status indicator.
-- Author: D-S-Agrarservice
-- =========================================================================================

function GlobalMarket:initFileSystem()
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Initializing FileSystem Paths & Directories...")
    end

    -- Base path for mod settings
    local settingsPath = getUserProfileAppPath() .. "modSettings/" .. GlobalMarket.modName .. "/"

    -- File definitions (all consolidated inside modSettings/FS25_GlobalMarket/)
    self.settingsFolder = settingsPath
    self.isOnlineFile = settingsPath .. "globalMarketOnline.xml"
    self.clientVersionStateFile = settingsPath .. "clientVersionState.xml"
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
    self.clientExeStates = {}
    self.serverWhitelist = {}

    -- Sandbox-safe Heartbeat / Anti-Zombie tracking (os.time() is nil in FS25 Lua sandbox)
    self.lastSeenExeTimestamp = nil
    self.exeHeartbeatVerified = false
    self.exeStaleMs = 0
    self.hasCheckedOnlineFileOnce = false
    self.pendingReadFiles = {}

    -- Transaction Management (g_time in milliseconds)
    self.lastTransactionTime = -999999 -- Engine timestamp (g_time in ms) of the last executed online transaction
    self.transactionCooldown = 15000 -- 15,000 ms (15 seconds) rate limit for online market actions
    self.txCounter = 0
    self.wlCounter = 0

    -- Polling management
    self.timerData = 0
    self.timerStatus = 0
    self.intervalData = 1000
    self.intervalStatus = 2000
    self.exeSwitchGraceMs = 0

    -- Versioning & Market Branding state
    self.minExeVersion = GlobalMarket.DEFAULT_MIN_EXE_VERSION or "0.9.10"
    self.hasShownVersionWarning = false
    self.hasShownOptionalUpdateHint = false
    self.shownOptionalUpdateVersions = {}
    if self.loadPersistedMinExeVersion ~= nil then self:loadPersistedMinExeVersion() end
    if self.initBrandingState ~= nil then self:initBrandingState() end

    -- Note: HUD injection (self:initStatusHudHooks()) is executed during onFinishedLoading in GlobalMarket.lua
    -- to ensure g_currentMission.hud.gameInfoDisplay is fully initialized before access.
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
        -- Only render while mission and HUD status integration are active and visible
        if g_currentMission == nil or not self.hasGlobalMarketIcon or not self.getVisible or not self:getVisible() then
            return
        end

        -- Initialize the GlobalMarket overlays if they do not exist yet
        if self.gmStatusBg == nil then
            -- Create background overlay using the vanilla white circle slice
            self.gmStatusBg = g_overlayManager:createOverlay("gui.whiteCircleFilled", 0, 0, 0, 0)

            -- Create icon overlay from local mod file
            local iconPath = Utils.getFilename("images/menuIcon.dds", GlobalMarket.dir)
            self.gmStatusIcon = Overlay.new(iconPath, 0, 0, 0, 0)
        end

        -- Calculate dynamic scaling based on UI scale settings
        local bgSizeX, bgSizeY = self:scalePixelValuesToScreenVector(50, 50)
        local iconSizeX, iconSizeY = self:scalePixelValuesToScreenVector(35, 35)

        self.gmStatusBg:setDimension(bgSizeX, bgSizeY)
        self.gmStatusIcon:setDimension(iconSizeX, iconSizeY)

        -- Set background color to native HUD background color (semi-transparent black)
        local bgColor = HUD.COLOR.BACKGROUND
        if bgColor ~= nil then
            self.gmStatusBg:setColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4])
        else
            self.gmStatusBg:setColor(0, 0, 0, 0.8) -- Fallback
        end

        -- Anchor strictly to the left edge of the HUD background box (infoBgLeft), including mod offsets (e.g. eGID)
        local anchorX = 0
        if self.infoBgLeft ~= nil then
            anchorX = (self.infoBgLeft.x or 0) + (self.infoBgLeft.offsetX or 0)
        elseif self.weatherIcon ~= nil then
            anchorX = (self.weatherIcon.x or 0) + (self.weatherIcon.offsetX or 0)
        end

        local paddingX = self:scalePixelToScreenWidth(15)
        local targetBgX = anchorX - bgSizeX - paddingX

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

        -- Live HUD icon visibility toggle from Mod Settings (defaults to true)
        local isVisible = true
        if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil and type(GlobalMarketSettings.current.showStatusIcon) == "boolean" then
            isVisible = GlobalMarketSettings.current.showStatusIcon
        end

        -- Render the overlays (background first, then icon) only if permitted
        if isVisible then
            self.gmStatusBg:render()
            self.gmStatusIcon:render()
        end
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
    if GlobalMarket.isExeVersionSufficient ~= nil then
        return GlobalMarket.isExeVersionSufficient(currentVersion, minVersion)
    end
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

-- Callback for native GIANTS getFiles(folderPath, callbackName, target) directory enumeration.
-- Collects bare *.xml filenames inside modSettings/FS25_GlobalMarket/read/ without per-tick wrapper allocations.
function GlobalMarket:onReadFolderFileFound(filename, isDirectory)
    if not isDirectory and filename ~= nil and string.find(string.lower(filename), "%.xml$") ~= nil then
        table.insert(self.pendingReadFiles, filename)
    end
end

function GlobalMarket:runSyncUpdateLogic(dt)
    -- Master switch guard, Dedicated Server exclusion & Mission-Ready check (wait until onFinishedLoading + onStartMission completed)
    if not GlobalMarket.ENABLE_ONLINE_SYNC or g_dedicatedServer ~= nil or g_currentMission == nil or not g_currentMission.isMissionStarted then
        return
    end

    self.timerData = self.timerData + dt
    self.timerStatus = self.timerStatus + dt

    -- Phase 1: Heartbeat - Update local EXE status (SP, local MP-Host, and MP-Clients)
    if self.timerStatus >= self.intervalStatus then
        local statusElapsedMs = self.timerStatus
        self.timerStatus = 0
        local exeRunningNow = false
        local backendConnectedNow = false
        local brandingChanged = false
        local isHardVersionLock = false

        if fileExists(self.isOnlineFile) then
            local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
            if xmlFile ~= nil then
                local exeVersion = xmlFile:getString("globalMarketOnline.version")
                local rawMinVer = xmlFile:getString("globalMarketOnline.minVersion") or xmlFile:getString("globalMarketOnline#minVersion")
                local rawLatestVer = xmlFile:getString("globalMarketOnline.latestVersion") or xmlFile:getString("globalMarketOnline#latestVersion")
                local backendMinVersion = (GlobalMarket.sanitizeExeVersion ~= nil) and GlobalMarket.sanitizeExeVersion(rawMinVer) or rawMinVer
                local backendLatestVersion = (GlobalMarket.sanitizeExeVersion ~= nil) and GlobalMarket.sanitizeExeVersion(rawLatestVer) or rawLatestVer
                local exeTimestamp = xmlFile:getInt("globalMarketOnline#timestamp") or 0

                -- Read backend connection state (default to true for legacy support)
                backendConnectedNow = xmlFile:getBool("globalMarketOnline#isConnected", true)

                -- Sandbox-safe Anti-Zombie Check (os.time() is unavailable in the FS25 Lua sandbox):
                -- Verify that globalMarketOnline#timestamp advances within 10,000 ms.
                local isTimestampActive = false
                if exeTimestamp <= 0 then
                    -- Clean EXE shutdown signal (timestamp="0") -> immediately offline
                    self.lastSeenExeTimestamp = nil
                    self.exeHeartbeatVerified = false
                    self.exeStaleMs = 0
                elseif self.lastSeenExeTimestamp == nil then
                    self.lastSeenExeTimestamp = exeTimestamp
                    self.exeStaleMs = 0
                    if self.hasCheckedOnlineFileOnce then
                        -- File newly appeared during an active polling session -> immediately active
                        self.exeHeartbeatVerified = true
                        isTimestampActive = true
                    else
                        -- File already existed before initial poll -> wait for first timestamp advance to rule out a leftover crash file
                        self.exeHeartbeatVerified = false
                        isTimestampActive = false
                    end
                elseif exeTimestamp ~= self.lastSeenExeTimestamp then
                    self.lastSeenExeTimestamp = exeTimestamp
                    self.exeStaleMs = 0
                    self.exeHeartbeatVerified = true
                    isTimestampActive = true
                else
                    self.exeStaleMs = (self.exeStaleMs or 0) + statusElapsedMs
                    isTimestampActive = (self.exeHeartbeatVerified == true and self.exeStaleMs <= 10000)
                end

                self.hasCheckedOnlineFileOnce = true

                -- Tier 1 (Mandatory): Reconcile dynamic minimum version floor (raises immediately; allows rollback when isConnected="true")
                if self.reconcileMinExeVersion ~= nil then
                    self:reconcileMinExeVersion(backendMinVersion, isTimestampActive, backendConnectedNow)
                elseif isTimestampActive and backendMinVersion ~= nil and backendMinVersion ~= "" and not isVersionSufficient(self.minExeVersion, backendMinVersion) then
                    self.minExeVersion = backendMinVersion
                end

                local isVersionValid = isVersionSufficient(exeVersion, self.minExeVersion)

                if not isTimestampActive then
                    exeRunningNow = false
                    backendConnectedNow = false
                else
                    exeRunningNow = isVersionValid
                end

                if exeRunningNow and backendConnectedNow and self.readHeartbeatBranding ~= nil then
                    brandingChanged = self:readHeartbeatBranding(xmlFile)
                end
                xmlFile:delete()

                -- Tier 1 (Mandatory): Show outdated warning if the EXE is actively running (fresh timestamp) but fails minExeVersion
                if isTimestampActive and not isVersionValid then
                    isHardVersionLock = true
                    if not self.hasShownVersionWarning then
                        g_currentMission:showBlinkingWarning(g_i18n:getText("ui_gm_warning_exe_outdated"), 8000)
                        self.hasShownVersionWarning = true
                    end
                elseif isVersionValid then
                    self.hasShownVersionWarning = false
                    -- Tier 2 (Optional): Non-blocking once-per-session hint when a newer recommended client version is available
                    if isTimestampActive and backendLatestVersion ~= nil and self.notifyOptionalExeUpdate ~= nil then
                        self:notifyOptionalExeUpdate(exeVersion, backendLatestVersion)
                    end
                end
            else
                -- XML temporarily unreadable (e.g. mid-rename on Windows); tolerate up to 10s if previously verified
                self.exeStaleMs = (self.exeStaleMs or 0) + statusElapsedMs
                if self.exeHeartbeatVerified and self.exeStaleMs <= 10000 then
                    exeRunningNow = self.isExeRunningLocal
                    backendConnectedNow = self.hasBackendConnection
                else
                    self.lastSeenExeTimestamp = nil
                    self.exeHeartbeatVerified = false
                end
                self.hasCheckedOnlineFileOnce = true
            end
        else
            -- Heartbeat file absent (clean EXE shutdown, token switch restart, or EXE not running)
            self.lastSeenExeTimestamp = nil
            self.exeHeartbeatVerified = false
            self.exeStaleMs = 0
            self.hasCheckedOnlineFileOnce = true
        end

        -- Token-switch & transient reconnect grace window (~4.5s / 2 polls): prevents premature Data-Host failover while switching profiles
        if exeRunningNow and backendConnectedNow then
            self.exeSwitchGraceMs = 0
        elseif not isHardVersionLock and self.isExeRunningLocal and self.hasBackendConnection then
            self.exeSwitchGraceMs = (self.exeSwitchGraceMs or 0) + statusElapsedMs
            if self.exeSwitchGraceMs <= (GlobalMarket.EXE_SWITCH_GRACE_MS or 4500) then
                exeRunningNow = true
                backendConnectedNow = true
                brandingChanged = false
            else
                self.exeSwitchGraceMs = 0
            end
        else
            self.exeSwitchGraceMs = 0
        end

        local wasDataHost = (self.isDataHost == true)
        if not exeRunningNow or not backendConnectedNow then
            if not g_currentMission:getIsServer() then self.isDataHost = false end
            brandingChanged = (self.clearLocalBranding ~= nil and self:clearLocalBranding()) or brandingChanged
        end

        -- Check if EXE status, backend connection, Data-Host state, or token market branding changed
        if exeRunningNow ~= self.isExeRunningLocal or backendConnectedNow ~= self.hasBackendConnection or (self.isDataHost ~= wasDataHost) or brandingChanged then
            self.isExeRunningLocal = exeRunningNow
            self.hasBackendConnection = backendConnectedNow

            self:updateHudIconState()
            if self.refreshBrandingUiIfOpen ~= nil then self:refreshBrandingUiIfOpen() end

            if g_currentMission:getIsServer() then
                -- SP / MP-Host / Dedicated Server running local EXE directly
                self:handleClientExeStatus("LOCAL_HOST", self.isExeRunningLocal, self.hasBackendConnection, self.localExeMarketName, self.localExeIsPrivateMarket, self.localExeContractsSupported)
            elseif ExeStatusEvent ~= nil and g_client ~= nil then
                -- Remote MP-Client notifies the authoritative server
                g_client:getServerConnection():sendEvent(ExeStatusEvent.new(self.isExeRunningLocal, self.hasBackendConnection, self.localExeMarketName, self.localExeIsPrivateMarket, self.localExeContractsSupported))
            end
        end
    end

    -- Phase 2: Processing - backend IO (Data-Host only)
    -- Note: fileExists() returns false on directory paths in GIANTS Engine, and getFiles() uses a callback (see dataS/scripts/Files.lua).
    if self.isDataHost and self.timerData >= self.intervalData then
        self.timerData = 0
        if self.readFolder ~= nil then
            local files = self.pendingReadFiles
            if files == nil then
                files = {}
                self.pendingReadFiles = files
            else
                for i = #files, 1, -1 do
                    files[i] = nil
                end
            end

            getFiles(self.readFolder, "onReadFolderFileFound", self)

            if #files > 0 then
                if #files > 1 then
                    table.sort(files)
                end

                local newMarketData = {}
                local marketDataIndexByName = {}
                local hasMarketDataPacket = false

                for _, filename in ipairs(files) do
                    local fullPath = self.readFolder .. filename
                    local xmlFile = XMLFile.load("gmDataSync", fullPath)
                    if xmlFile ~= nil then
                        local action = xmlFile:getString("gmDataSync#action", "")
                        if action == "marketData" then
                            hasMarketDataPacket = true
                            if self.readMarketSyncBranding ~= nil then self:readMarketSyncBranding(xmlFile) end
                            xmlFile:iterate("gmDataSync.fillTypes.fillType", function (_, baseKey)
                                local ftName = xmlFile:getString(baseKey .. "#fillType")
                                if ftName ~= nil and ftName ~= "" then
                                    ftName = string.upper(ftName)
                                    local ftLevel = xmlFile:getInt(baseKey .. "#fillLevel") or 0
                                    local ftTrend = xmlFile:getFloat(baseKey .. "#trend")
                                    local ftGreatDemand = xmlFile:getBool(baseKey .. "#greatDemand", false)
                                    local ftGdBonus = xmlFile:getFloat(baseKey .. "#greatDemandBonus")
                                    local ftGdRemaining = xmlFile:getInt(baseKey .. "#greatDemandRemaining")

                                    local rawStatus = xmlFile:getString(baseKey .. "#status")
                                    local ftStatus = "APPROVED"
                                    if rawStatus ~= nil and rawStatus ~= "" then
                                        local upperStatus = string.upper(rawStatus)
                                        if upperStatus == "PENDING" or upperStatus == "NEED_REVIEW" then
                                            ftStatus = "PENDING"
                                        elseif upperStatus == "REJECTED" then
                                            ftStatus = "REJECTED"
                                        else
                                            ftStatus = "APPROVED"
                                        end
                                    end

                                    local entry = {
                                        fillType = ftName,
                                        status = ftStatus,
                                        fillLevel = ftLevel,
                                        trend = ftTrend,
                                        isGreatDemand = ftGreatDemand,
                                        greatDemandBonus = ftGdBonus,
                                        greatDemandRemainingLiters = ftGdRemaining
                                    }

                                    local existingIdx = marketDataIndexByName[ftName]
                                    if existingIdx ~= nil then
                                        newMarketData[existingIdx] = entry
                                    else
                                        table.insert(newMarketData, entry)
                                        marketDataIndexByName[ftName] = #newMarketData
                                    end
                                end
                            end)
                        elseif self.onReadCustomSyncXml ~= nil then
                            self:onReadCustomSyncXml(action, xmlFile)
                        end
                        xmlFile:delete()
                        deleteFile(fullPath)
                    end
                end
                if hasMarketDataPacket then
                    if g_currentMission:getIsServer() then
                        -- Local Host / Server validates session market lock before applying and broadcasting
                        if self.applyAndBroadcastServerMarketPacket ~= nil then
                            self:applyAndBroadcastServerMarketPacket(
                                "LOCAL_HOST", newMarketData, self.localExeMarketName, self.localExeIsPrivateMarket)
                        end
                    elseif MarketDataSyncEvent ~= nil and g_client ~= nil then
                        -- Remote Data-Host Client sends payload to Server (Server broadcasts back to all clients)
                        g_client:getServerConnection():sendEvent(MarketDataSyncEvent.new(newMarketData, self.localExeMarketName, self.localExeIsPrivateMarket))
                    end
                end
                if self.flushCustomSyncPackets ~= nil then self:flushCustomSyncPackets() end
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

    local sourceMap, activeModPrefixes = nil, nil
    if GlobalMarketAPI ~= nil and GlobalMarketAPI.buildFillTypeSourceMap ~= nil then
        sourceMap, activeModPrefixes = GlobalMarketAPI.buildFillTypeSourceMap()
    end
    local lang = (g_languageShort ~= nil and g_languageShort ~= "") and string.lower(g_languageShort) or "en"

    self.serverWhitelist = {}
    if self.offlineMarketFillTypes ~= nil then
        for _, data in pairs(self.offlineMarketFillTypes) do
            if data.fillType ~= nil then
                local fillTypeDesc = g_fillTypeManager:getFillTypeByName(data.fillType)
                local title = fillTypeDesc ~= nil and fillTypeDesc.title or data.fillType
                local category, itemType, source = "PRODUCTS_PALLETS", "BULK", "BASEGAME"
                if GlobalMarketAPI ~= nil and GlobalMarketAPI.resolveWhitelistMetadata ~= nil then
                    category, itemType, source = GlobalMarketAPI.resolveWhitelistMetadata(fillTypeDesc, sourceMap, activeModPrefixes)
                end

                table.insert(self.serverWhitelist, {
                    name = data.fillType,
                    title = title,
                    category = category,
                    type = itemType,
                    basePrice = data.basePrice or 0,
                    source = source
                })
            end
        end
    end

    -- Write static reference whitelist for external companion client discovery
    local xmlFile = XMLFile.create("gmServerWhitelist", self.serverWhitelistFile, "gmServerWhitelist")
    if xmlFile ~= nil then
        xmlFile:setString("gmServerWhitelist#lang", lang)
        for i, item in ipairs(self.serverWhitelist) do
            local key = string.format("gmServerWhitelist.item(%d)", i - 1)
            xmlFile:setString(key .. "#name", item.name)
            xmlFile:setString(key .. "#title", item.title)
            xmlFile:setString(key .. "#category", item.category)
            xmlFile:setString(key .. "#type", item.type)
            xmlFile:setFloat(key .. "#basePrice", item.basePrice)
            xmlFile:setString(key .. "#source", item.source)
        end
        xmlFile:save()
        xmlFile:delete()
    end
end

-- Promotes the next available EXE-capable connection (or falls back to Offline mode)
function GlobalMarket:assignNextDataHost()
    if not g_currentMission:getIsServer() then return end

    self.clientExeStates = self.clientExeStates or {}
    local nextConn = (self.selectNextDataHostConnection ~= nil) and self:selectNextDataHostConnection() or nil

    local prevConn = self.dataHostConnection
    if prevConn ~= nil and prevConn ~= "LOCAL_HOST" and prevConn ~= nextConn then
        if SyncMarketWhitelistEvent ~= nil and type(prevConn) == "table" and prevConn.sendEvent ~= nil then
            prevConn:sendEvent(SyncMarketWhitelistEvent.new(nil, false))
        end
    end

    if nextConn ~= nil then
        local prevWasOnline = (self.isOnline == true)
        self.dataHostConnection = nextConn
        self.isOnline = true
        if self.onDataHostSelectedBranding ~= nil then
            self:onDataHostSelectedBranding(self.clientExeStates[nextConn], prevWasOnline)
        elseif self.applyDataHostBranding ~= nil then
            self:applyDataHostBranding(self.clientExeStates[nextConn])
        end

        -- Hybrid Mode initialization: Treat all local fillTypes as PENDING until the backend confirms APPROVED/REJECTED
        if self.offlineMarketFillTypes ~= nil then
            for _, item in pairs(self.offlineMarketFillTypes) do
                if item.onlineStatus == nil then
                    item.onlineStatus = "PENDING"
                end
            end
        end

        if nextConn == "LOCAL_HOST" then
            self:receiveDataHostToken(self.serverWhitelist)
        else
            self.isDataHost = false
            self:updateHudIconState()
            if self.debugManager ~= nil then
                self.debugManager:info("Sync: Assigned Data-Host token to client connection (%d whitelist items).", #(self.serverWhitelist or {}))
            end
            if SyncMarketWhitelistEvent ~= nil and type(nextConn) == "table" and nextConn.sendEvent ~= nil then
                nextConn:sendEvent(SyncMarketWhitelistEvent.new(self.serverWhitelist, true))
            end
        end

        if self.refreshMarketPrices ~= nil then self:refreshMarketPrices() end
        if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    else
        -- No eligible EXE connection remaining -> seamless fallback to Offline Market
        local wasOnline = (self.isOnline == true)
        self.dataHostConnection = nil
        self.isOnline = false
        self.isDataHost = false
        self.onlineContractsSupported = false
        self:updateHudIconState()
        self:restoreOfflineMarketState()
        if self.onOnlineContractsDisconnected ~= nil then self:onOnlineContractsDisconnected() end
        if wasOnline and self.debugManager ~= nil then
            self.debugManager:info("Sync: No active companion client available. Restored Offline Market state.")
        end

        if self.refreshMarketPrices ~= nil then self:refreshMarketPrices() end
        if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
            g_server:broadcastEvent(SynchOfflineMarketEvent.new())
        end
    end
end

function GlobalMarket:handleClientExeStatus(connection, isExeRunning, hasBackendConnection, marketName, isPrivateMarket, contractsSupported)
    if not g_currentMission:getIsServer() or connection == nil then return end

    self.clientExeStates = self.clientExeStates or {}
    local prevState = self.clientExeStates[connection]
    local state = {
        isExeRunning = (isExeRunning == true),
        hasBackendConnection = (hasBackendConnection ~= false),
        marketName = marketName,
        isPrivateMarket = (isPrivateMarket == true),
        contractsSupported = (contractsSupported == true),
        readySeq = (prevState ~= nil) and prevState.readySeq or nil
    }
    local eligible = (self.isClientEligibleForSessionMarket == nil) or self:isClientEligibleForSessionMarket(state)
    if eligible then
        if state.readySeq == nil then
            self.nextExeReadySeq = (self.nextExeReadySeq or 0) + 1
            state.readySeq = self.nextExeReadySeq
        end
    else
        state.readySeq = nil
    end
    self.clientExeStates[connection] = state

    if eligible then
        if self.dataHostConnection == nil then
            self:assignNextDataHost()
        elseif self.dataHostConnection == connection and self.updateActiveDataHostBranding ~= nil then
            self:updateActiveDataHostBranding(connection)
        end
    elseif self.dataHostConnection == connection then
        self:assignNextDataHost()
    end
end

-- Safety hook called by GlobalMarket.lua when a client disconnects from the server
function GlobalMarket:onClientDisconnected(connection)
    if not g_currentMission:getIsServer() or connection == nil then return end

    if self.clientExeStates ~= nil then
        self.clientExeStates[connection] = nil
    end

    if self.dataHostConnection == connection then
        if self.debugManager ~= nil then
            self.debugManager:info("Sync: Active Data-Host disconnected. Reassigning token or falling back to Offline mode...")
        end
        self.dataHostConnection = nil
        self:assignNextDataHost()
    end
end

function GlobalMarket:receiveDataHostToken(whitelist)
    self.isDataHost = true
    self.isOnline = true
    self.timerData = self.intervalData or 1000
    self:updateHudIconState()
    if self.refreshBrandingUiIfOpen ~= nil then self:refreshBrandingUiIfOpen() end
    if self.onBecomeContractsDataHost ~= nil then self:onBecomeContractsDataHost() end
    if self.debugManager ~= nil then
        self.debugManager:info("Sync: Data-Host token active (%d whitelist items). Exporting whitelist to companion client.", #(whitelist or {}))
    end

    if self.writeFolder == nil then return end

    local lang = (g_languageShort ~= nil and g_languageShort ~= "") and string.lower(g_languageShort) or "en"

    -- Notify backend about becoming the Data-Host using GIANTS getDate() (sandbox-safe)
    local dateStamp = getDate("%Y%m%d_%H%M%S")
    self.wlCounter = (self.wlCounter or 0) + 1
    local xmlPath = string.format("%swhitelist_%s_%d.xml", self.writeFolder, dateStamp, self.wlCounter)
    local xmlFile = XMLFile.create("gmWhitelist", xmlPath, "gmDataSync")
    if xmlFile ~= nil then
        xmlFile:setString("gmDataSync#action", "updateWhitelist")
        xmlFile:setString("gmDataSync#lang", lang)
        for i, item in ipairs(whitelist or {}) do
            local key = string.format("gmDataSync.whitelist.item(%d)", i - 1)
            local ftDesc = (g_fillTypeManager ~= nil and item.name ~= nil) and g_fillTypeManager:getFillTypeByName(item.name) or nil
            local localizedTitle = (ftDesc ~= nil and ftDesc.title ~= nil and ftDesc.title ~= "") and ftDesc.title or item.title or item.name or ""

            xmlFile:setString(key .. "#name", item.name or "")
            xmlFile:setString(key .. "#title", localizedTitle)
            xmlFile:setString(key .. "#category", item.category or "PRODUCTS_PALLETS")
            xmlFile:setString(key .. "#type", item.type or "BULK")
            xmlFile:setFloat(key .. "#basePrice", item.basePrice or 0)
            xmlFile:setString(key .. "#source", item.source or "BASEGAME")
        end
        xmlFile:save()
        xmlFile:delete()
    end
end

function GlobalMarket:applySyncedMarketData(marketData)
    -- Trigger UI pulse effect for 2000 milliseconds
    self.syncPulseTimer = g_time + 2000
    self.isOnline = true

    local incomingByFillType = {}
    if marketData ~= nil then
        for _, incomingItem in ipairs(marketData) do
            if incomingItem.fillType ~= nil then
                incomingByFillType[incomingItem.fillType] = incomingItem
            end
        end
    end

    -- MP Clients apply authoritative server-computed prices and Hybrid states directly without local recalculation
    if not g_currentMission:getIsServer() and GlobalMarketOnline ~= nil and GlobalMarketOnline.applyAuthoritativeClientSync ~= nil then
        GlobalMarketOnline.applyAuthoritativeClientSync(self, incomingByFillType)
        return
    end

    local currentLimit = GlobalMarket.MARKET_CAPACITY or 2000000
    if self.offlineMarketFillTypes ~= nil then
        for _, localItem in pairs(self.offlineMarketFillTypes) do
            local incomingItem = incomingByFillType[localItem.fillType]
            if incomingItem ~= nil then
                local status = incomingItem.status or "APPROVED"
                localItem.onlineStatus = status

                if status == "APPROVED" then
                    -- Snapshot pre-online Offline stock & Great Demand state before overwriting with global backend data
                    if localItem.savedOfflineFillLevel == nil then
                        localItem.savedOfflineFillLevel = math.clamp(localItem.fillLevel or 0, 0, currentLimit)
                        localItem.savedOfflineGdBonus = localItem.greatDemandBonus or 0
                        localItem.savedOfflineGdHours = localItem.greatDemandHours or 0
                        localItem.savedOfflineGdRemainingMinutes = localItem.greatDemandRemainingMinutes or 0
                        localItem.savedOfflineGdRemainingLiters = localItem.greatDemandRemainingLiters or 0
                        localItem.savedOfflineGdOriginMode = localItem.greatDemandOriginMode or 0
                    end

                    localItem.fillLevel = incomingItem.fillLevel or 0
                    localItem.trend = incomingItem.trend
                    localItem.greatDemandFromServer = (incomingItem.isGreatDemand == true)
                    localItem.onlineGreatDemandBonus = incomingItem.greatDemandBonus
                    if incomingItem.greatDemandRemainingLiters ~= nil then
                        localItem.greatDemandRemainingLiters = incomingItem.greatDemandRemainingLiters
                    end
                    -- Clear any local offline Great Demand state while authoritative APPROVED online trading is active
                    localItem.greatDemandBonus = 0
                    localItem.greatDemandHours = 0
                    localItem.greatDemandRemainingMinutes = 0
                    localItem.greatDemandOriginMode = 0
                else
                    -- Hybrid Mode (PENDING / REJECTED): Restore local offline state if previously APPROVED, otherwise preserve it
                    if localItem.savedOfflineFillLevel ~= nil then
                        self:restoreItemOfflineState(localItem, currentLimit)
                        localItem.onlineStatus = status
                    else
                        localItem.trend = nil
                        localItem.greatDemandFromServer = nil
                        localItem.onlineGreatDemandBonus = nil
                    end
                end
            else
                -- Local FillType missing from incoming online packet -> automatically treat as PENDING
                if localItem.savedOfflineFillLevel ~= nil then
                    self:restoreItemOfflineState(localItem, currentLimit)
                end
                localItem.onlineStatus = "PENDING"
                localItem.trend = nil
                localItem.greatDemandFromServer = nil
                localItem.onlineGreatDemandBonus = nil
            end
        end
    end

    if self.refreshMarketPrices ~= nil then self:refreshMarketPrices() end
    if g_currentMission.globalMarketUi ~= nil and g_currentMission.globalMarketUi:getIsVisible() then
        g_currentMission.globalMarketUi:updateContent()
    end
end

-- Returns the online moderation status ("APPROVED", "PENDING", "REJECTED") for a fillType while Online, or nil when Offline.
function GlobalMarket:getFillTypeOnlineStatus(fillTypeName)
    if not self:getIsMarketOnline() or fillTypeName == nil then
        return nil
    end

    if self.offlineMarketFillTypes ~= nil then
        for _, item in pairs(self.offlineMarketFillTypes) do
            if item.fillType == fillTypeName then
                return item.onlineStatus or "PENDING"
            end
        end
    end

    return "PENDING"
end

-- Returns true strictly when the market is Online AND the fillType is approved for global backend trading.
function GlobalMarket:getIsFillTypeOnlineApproved(fillTypeName)
    return self:getFillTypeOnlineStatus(fillTypeName) == "APPROVED"
end

-- =========================================================================
-- EXPORT FUNCTIONS (Lua -> EXE)
-- =========================================================================

-- Server-side rate-limit check: blocks any player from buying/selling APPROVED online goods
-- within 15 seconds after the previous online transaction. Hybrid (PENDING/REJECTED) goods bypass this cooldown.
function GlobalMarket:checkOnlineTransactionCooldown(fillType)
    if not self:getIsMarketOnline() then
        return true
    end

    if fillType ~= nil and not self:getIsFillTypeOnlineApproved(fillType) then
        return true
    end

    local currentTimeMs = g_time or 0
    local lastTxMs = self.lastTransactionTime or -999999
    local cooldownMs = self.transactionCooldown or 15000
    if lastTxMs >= 0 and currentTimeMs >= lastTxMs and (currentTimeMs - lastTxMs) < cooldownMs then
        if self.debugManager ~= nil then
            self.debugManager:warning("Sync: Online transaction blocked (15s global cooldown active). Please wait.")
        end
        return false
    end

    return true
end

-- Server-side router: locks the 15s cooldown and exports the transaction locally (SP/MP-Host)
-- or relays it to the active remote Data-Host client (Dedicated Server).
function GlobalMarket:dispatchOnlineTransaction(fillType, amountLiters, transactionType)
    if not GlobalMarket.ENABLE_ONLINE_SYNC or not self:getIsMarketOnline() then
        return false
    end

    local cleanAmount = math.floor((amountLiters or 0) + 0.5)
    if cleanAmount <= 0 or fillType == nil then
        return false
    end

    -- Hybrid Mode guard: PENDING and REJECTED goods remain purely local and never generate transaction_*.xml or trigger the 15s cooldown
    if not self:getIsFillTypeOnlineApproved(fillType) then
        if self.debugManager ~= nil then
            self.debugManager:trace("Sync: Skipped online transaction export for '%s' (Hybrid status: %s).",
                tostring(fillType), tostring(self:getFillTypeOnlineStatus(fillType)))
        end
        return false
    end

    -- Lock global 15-second (15,000 ms) cooldown on the authoritative server for all players
    self.lastTransactionTime = g_time or 0

    if self.isDataHost then
        return self:exportTransaction(fillType, cleanAmount, transactionType)
    elseif self.dataHostConnection ~= nil and type(self.dataHostConnection) == "table" and SellBuyMarketGlobalMarketEvent ~= nil then
        local txCode = (transactionType == "BUY") and SellBuyMarketGlobalMarketEvent.ACTION_BUY or SellBuyMarketGlobalMarketEvent.ACTION_SELL
        self.dataHostConnection:sendEvent(
            SellBuyMarketGlobalMarketEvent.new(SellBuyMarketGlobalMarketEvent.ACTION_EXPORT_TX, txCode, 0, cleanAmount, fillType)
        )
        return true
    end

    return false
end

-- Exports a server-validated transaction to the write folder on the Data-Host for the EXE to process
function GlobalMarket:exportTransaction(fillType, amount, transactionType)
    if not self.isDataHost or self.writeFolder == nil then return false end

    local dateStamp = getDate("%Y%m%d_%H%M%S")
    self.txCounter = (self.txCounter or 0) + 1
    local xmlPath = string.format("%stransaction_%s_%d.xml", self.writeFolder, dateStamp, self.txCounter)
    local xmlFile = XMLFile.create("gmTransaction", xmlPath, "gmDataSync")

    if xmlFile ~= nil then
        xmlFile:setString("gmDataSync#action", "transaction")
        xmlFile:setString("gmDataSync.entry(0)#fillType", fillType)
        xmlFile:setInt("gmDataSync.entry(0)#amount", math.floor(amount))
        xmlFile:setString("gmDataSync.entry(0)#type", transactionType)

        xmlFile:save()
        xmlFile:delete()

        self.lastTransactionTime = g_time or 0

        if self.debugManager ~= nil then
            self.debugManager:info(string.format("Sync: Exported transaction (%s %s %s)", transactionType, tostring(amount), fillType))
        end
        return true
    end

    return false
end

-- =========================================================================
-- DEV TOOLS
-- =========================================================================

function GlobalMarket:consoleCommandTestStatus(val)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end

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

function GlobalMarket:consoleCommandToggleOnlineSync(val)
    if GlobalMarketSettings == nil or GlobalMarketSettings.current == nil or not GlobalMarketSettings.current.isDebugActive then
        return "GM Debug Mode is disabled."
    end
    if g_currentMission ~= nil and not (g_currentMission:getIsServer() or g_currentMission.isMasterUser) then
        return "Permission denied (Server/Admin required)."
    end

    if val ~= nil and val ~= "" then
        GlobalMarket.ENABLE_ONLINE_SYNC = (val == "true" or val == "1")
    else
        GlobalMarket.ENABLE_ONLINE_SYNC = not GlobalMarket.ENABLE_ONLINE_SYNC
    end

    self.lastSeenExeTimestamp = nil
    self.exeHeartbeatVerified = false
    self.exeStaleMs = 0
    self.hasCheckedOnlineFileOnce = false

    if GlobalMarket.ENABLE_ONLINE_SYNC then
        -- Trigger immediate status poll on the next update tick
        self.timerStatus = self.intervalStatus or 2000
    else
        self.isExeRunningLocal = false
        self.hasBackendConnection = false
        self.isDataHost = false
        self.isOnline = false
        self.dataHostConnection = nil
        self.clientExeStates = {}
        self.nextExeReadySeq = 0
        if self.clearLocalBranding ~= nil then self:clearLocalBranding() end
        self:restoreOfflineMarketState()
        self:updateHudIconState()
        if g_currentMission:getIsServer() then
            if self.refreshMarketPrices ~= nil then
                self:refreshMarketPrices()
            end
            if g_server ~= nil and SynchOfflineMarketEvent ~= nil then
                g_server:broadcastEvent(SynchOfflineMarketEvent.new())
            end
        end
    end

    return string.format("GlobalMarket.ENABLE_ONLINE_SYNC = %s", tostring(GlobalMarket.ENABLE_ONLINE_SYNC))
end
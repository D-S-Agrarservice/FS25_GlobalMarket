--
-- FS25 - GlobalMarket (Core)
-- Description: Main module registry and initialization hub.
--

GlobalMarket = {}
GlobalMarket.dir = g_currentModDirectory
GlobalMarket.modName = g_currentModName

-- =========================================================================
-- SYSTEM VARIABLES
-- =========================================================================
-- Delivery costs are dynamically managed by GlobalMarketSettings.lua based on environment.
-- We initialize them as 0 here to catch loading errors.
GlobalMarket.DELIVER_COST = 0
GlobalMarket.DELIVER_COST_PERLITER = 0

-- =========================================================================
-- DEBUG MANAGER INITIALIZATION (Highest Priority)
-- =========================================================================

-- Source Core Debug Module first so it is available globally BEFORE any other code runs
source(GlobalMarket.dir .. "modules/GlobalMarketDebug.lua")

-- Instantiating the Debug Manager immediately so it's ready for boot sequence errors
if GlobalMarketDebug ~= nil then
    GlobalMarket.debugManager = GlobalMarketDebug.new(GlobalMarket.modName, GlobalMarket.dir)
    GlobalMarket.debugManager:info("=== GlobalMarket Boot Sequence Started ===")
end

-- =========================================================================
-- ENGINE FIX: GUI $moddir$ PATH RESOLVER
-- =========================================================================
-- The native UI engine cannot resolve $moddir$ paths for external UI images.
-- This global hook intercepts the path resolution and fixes it for all mods.

local originalResolveFilename = GuiOverlay.resolveFilename

GuiOverlay.resolveFilename = function(filename)
    if filename ~= nil and type(filename) == "string" then
        -- Check if the filename uses the standard Giants mod directory placeholder
        -- Format: "$moddir$MOD_NAME/path/to/image.dds"
        if string.startsWith(filename, "$moddir$") then
            -- Find the first slash after $moddir$ to extract the mod name
            local modNameEndPos = string.find(filename, "/", 9) -- 9 is the length of "$moddir$" + 1

            if modNameEndPos ~= nil then
                local extractedModName = string.sub(filename, 9, modNameEndPos - 1)
                local remainingPath = string.sub(filename, modNameEndPos + 1)

                -- Ask the mod manager for the physical directory of this specific mod
                local modItem = g_modManager:getModByName(extractedModName)

                if modItem ~= nil and modItem.modDir ~= nil then
                    filename = modItem.modDir .. remainingPath

                    if GlobalMarket.debugManager ~= nil then
                        GlobalMarket.debugManager:trace("UI Engine Fix: Successfully resolved $moddir$ path to -> %s", filename)
                    end
                else
                    if GlobalMarket.debugManager ~= nil then
                        GlobalMarket.debugManager:error("UI Engine Fix Failed: Could not resolve $moddir$ path. Mod '%s' is not loaded or missing!", extractedModName)
                    end
                end
            end
        end
    end

    -- Pass the (potentially fixed) filename back to the original engine function
    return originalResolveFilename(filename)
end

-- =========================================================================
-- MODULE INJECTIONS
-- =========================================================================
-- ALL modules are now loaded unconditionally to ensure maximum stability.

-- Load the central API first so it is available to all other modules
source(GlobalMarket.dir .. "modules/GlobalMarketAPI.lua")

-- UI Modules
source(GlobalMarket.dir .. "gui/GlobalMarketDialog.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketUI.lua")

-- Economy & Savegame Modules
source(GlobalMarket.dir .. "modules/GlobalMarketOffline.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSavegame.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSettings.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketFinance.lua")

-- Storage & Access Modules
source(GlobalMarket.dir .. "modules/GlobalMarketStorage.lua")

-- Load Access Module to inject terminal permissions
source(GlobalMarket.dir .. "modules/GlobalMarketAccess.lua")

-- Compatibility Management
source(GlobalMarket.dir .. "modules/GlobalMarketCompatibilityManager.lua")

-- Events
source(GlobalMarket.dir .. "events/InitOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/InitGlobalMarketSettingsEvent.lua")
source(GlobalMarket.dir .. "events/SynchOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SyncGlobalMarketSettingsEvent.lua")
source(GlobalMarket.dir .. "events/SyncGmSiloEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuySiloGlobalMarketEvent.lua")
-- Online Events
source(GlobalMarket.dir .. "events/ExeStatusEvent.lua")
source(GlobalMarket.dir .. "events/SyncMarketWhitelistEvent.lua")
source(GlobalMarket.dir .. "events/MarketDataSyncEvent.lua")

-- Compatibility Sync Events
source(GlobalMarket.dir .. "events/SyncGlobalMarketCompatibilityEvent.lua")

--Collect storeData Module
source(GlobalMarket.dir .. "modules/GlobalMarketStoreCache.lua")

-- External Sync Module
source(GlobalMarket.dir .. "modules/GlobalMarketSync.lua")


-- =========================================================================
-- ENGINE HOOKS & LIFECYCLE
-- =========================================================================

---Triggered when the player successfully loads into a map (SP or MP Server)
---@param name string The name of the map being loaded
function GlobalMarket:loadMap(name)
    if self.debugManager ~= nil then
        self.debugManager:info("Map loading detected. Initializing GlobalMarket core systems...")
    end

    -- Initial state setup
    self.fillTypes = {}
    self.offlineMarketFillTypes = {}
    self.isOnline = false
    self.closeSelectLevelUi = 0
    self.syncModule = self

    -- Register global reference
    g_currentMission.globalMarket = self

    -- 1. MANDATORY: Initialize FileSystem Infrastructure first
    -- This ensures all path variables (read/write/whitelist) are defined before logic modules access them.
    if self.initFileSystem ~= nil then
        self:initFileSystem()
    end

    -- Load GUI profiles and inject UI
    if g_gui ~= nil then
        g_gui:loadProfiles(GlobalMarket.dir .. "gui/guiProfiles.xml")

        -- =========================================================
        -- UI INJECTION (Moved to early map load to prevent FocusManager corruption)
        -- =========================================================
        if GlobalMarketUI ~= nil then
            if self.debugManager ~= nil then
                self.debugManager:info("Injecting GlobalMarket UI during map load...")
            end

            -- 1. Load Transaction Dialog
            local dialogController = GlobalMarketDialog.new()
            g_gui:loadGui(GlobalMarket.dir .. "gui/GlobalMarketDialog.xml", "GlobalMarketDialog", dialogController)
            self.dialog = dialogController

            -- 2. Load Main Market UI
            local uiController = GlobalMarketUI.new()
            local xmlFilename = GlobalMarket.dir .. "gui/GlobalMarketUI.xml"

            g_gui:loadGui(xmlFilename, "GlobalMarketUI", uiController, true)
            self.ui = uiController

            -- Inject Tab into InGameMenu
            self:fixInGameMenu(uiController, "GlobalMarketUI")
        else
            if self.debugManager ~= nil then
                self.debugManager:error("UI Injection failed! GlobalMarketUI class is nil.")
            end
        end
    end

    -- =========================================================
    -- CORE MODULES
    -- =========================================================

    -- 2. Initialize the Central API (Single Source of Truth)
    if GlobalMarketAPI ~= nil and GlobalMarketAPI.init ~= nil then
        GlobalMarketAPI.init()
    end

    -- 3. Load settings so global states and costs are available
    if GlobalMarketSettings ~= nil and GlobalMarketSettings.loadFromXML ~= nil then
        GlobalMarketSettings:loadFromXML()
    end

    -- 4. Initialize Compatibility Manager and load local/server XML
    if GMCompatibilityManager ~= nil then
        self.compatibilityManager = GMCompatibilityManager.new()
        self.compatibilityManager:loadFromXML()
    end

    -- 5. Initialize Finance system with loaded settings
    if GlobalMarketFinance ~= nil then
        GlobalMarketFinance.init()
    end

    -- 6. Initialize Access & Permission Hooks
    if GlobalMarketAccess ~= nil and GlobalMarketAccess.init ~= nil then
        GlobalMarketAccess.init()
    end

    -- =========================================================
    -- OFFLINE MARKET (Local simulation logic)
    -- =========================================================

    -- Now safe to initialize as initFileSystem has provided the required paths
    if self.initOfflineMarket ~= nil then
        self:initOfflineMarket()

        -- Build the Server Whitelist based on the fully evaluated offline market
        -- Requirement: getIsServer must be true to generate the external sync file
        if g_currentMission:getIsServer() and self.initServerWhitelist ~= nil then
            self:initServerWhitelist()
        end

        -- Subscribe to hourly simulation
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.runOfflineSimulation, self)
    end

    -- =========================================================
    -- ONLINE MARKET (External sync via .exe)
    -- =========================================================

    -- Initialize the network and polling logic
    if self.initSync ~= nil then
        self:initSync()
    end

   -- self:dumpFillTypeData()
end

-- Used by the UI to check if the external EXE is currently connected
function GlobalMarket:getIsMarketOnline()
    return self.isOnline == true
end

-- Global frame update loop (Be careful with heavy operations here)
function GlobalMarket:update(dt)
    -- Hook for internal debug timers
    if self.debugManager ~= nil then
        self.debugManager:update(dt)
    end

    if self.runSyncUpdateLogic ~= nil then
        self:runSyncUpdateLogic(dt)
    end
end

-- Triggered right after the map finishes loading, before the player can move.
-- Used to safely inject our custom UI into the native Game Menu without crashes.
local function onFinishedLoading(mission)
    if g_currentMission ~= nil and g_currentMission.globalMarket ~= nil then

        -- Run dynamic compatibility check before UI initialization to set mitigation flags
        if g_currentMission.globalMarket.compatibilityManager ~= nil then
            g_currentMission.globalMarket.compatibilityManager:checkActiveMods()
        end

        -- Inject HUD Icon Status safely after engine UI is fully initialized
        if g_currentMission.globalMarket.initStatusHudHooks ~= nil then
            g_currentMission.globalMarket:initStatusHudHooks()
        end

        -- Init store cache for global available buy/sell list
        if GlobalMarketStoreCache ~= nil and GlobalMarketStoreCache.init ~= nil then
            GlobalMarketStoreCache.init()
        end

        -- LOAD SAVEGAME DATA HERE: At this point, the entire map and all placeables are fully spawned.
        if g_currentMission:getIsServer() and g_currentMission.globalMarket.loadFromXMLFile ~= nil then
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:info("Map fully loaded. Injecting GM Savegame data into placeables...")
            end
            g_currentMission.globalMarket:loadFromXMLFile()
        end
    end
    -- GlobalMarket.dumpShopItems()
end
FSBaseMission.onFinishedLoading = Utils.appendedFunction(FSBaseMission.onFinishedLoading, onFinishedLoading)

-- Helper for the menu registry
function GlobalMarket:isMarketEnabled()
    return true
end

-- =========================================================================
-- UI MENU HACKS (FS25 Compatibility)
-- =========================================================================

-- Manual Tab Injection to prevent InGameMenu crashes and fix Tab-Jumping
function GlobalMarket:fixInGameMenu(frame, pageName)
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:error("UI Injection aborted: InGameMenu or pagingElement is missing.")
        end
        return
    end

    local targetPos = 2
    for i, element in ipairs(inGameMenu.pagingElement.elements) do
        if element == inGameMenu["pageStatistics"] then
            targetPos = i
            break
        end
    end

    inGameMenu.controlIDs[pageName] = nil
    inGameMenu[pageName] = frame

    inGameMenu.pagingElement:addElement(frame)
    inGameMenu:exposeControlsAsFields(pageName)

    -- 1. Shift the visual elements
    for i, element in ipairs(inGameMenu.pagingElement.elements) do
        if element == frame then
            table.remove(inGameMenu.pagingElement.elements, i)
            table.insert(inGameMenu.pagingElement.elements, targetPos, element)
            break
        end
    end

    -- 2. Shift the internal pages mapping
    for i, page in ipairs(inGameMenu.pagingElement.pages) do
        if page.element == frame then
            table.remove(inGameMenu.pagingElement.pages, i)
            table.insert(inGameMenu.pagingElement.pages, targetPos, page)
            break
        end
    end

    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()

    -- Register the page using the predicate function
    inGameMenu:registerPage(frame, targetPos, function() return self:isMarketEnabled() end)

    -- Create Tab cleanly using direct file path and UVs (No XML profile or post-injection needed)
    local iconFileName = Utils.getFilename("images/menuIcon.dds", GlobalMarket.dir)
    inGameMenu:addPageTab(frame, iconFileName, {0, 0, 0, 1, 1, 0, 1, 1})

    -- 3. Shift the pageFrames table
    for i, pFrame in ipairs(inGameMenu.pageFrames) do
        if pFrame == frame then
            table.remove(inGameMenu.pageFrames, i)
            table.insert(inGameMenu.pageFrames, targetPos, pFrame)
            break
        end
    end

    inGameMenu:rebuildTabList()

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:debug("GlobalMarket GUI registered natively as '%s' at position %d.", pageName, targetPos)
    end
end

-- =========================================================================
-- INPUT BINDINGS (Reverted to original working state)
-- =========================================================================

-- Triggered via the custom input binding to open/close the market
function GlobalMarket:onToggleMarket(actionName, inputValue, callbackState, isAnalog, isMouse, deviceCategory, binding)
    if inputValue > 0 then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:trace("Hotkey pressed: Toggling GlobalMarket Menu.")
        end

        local inGameMenu = g_gui.screenControllers[InGameMenu]
        if inGameMenu ~= nil then
            if g_gui.currentGuiName == "InGameMenu" and inGameMenu.currentPage == self.ui then
                inGameMenu:onButtonBack()
            else
                g_gui:showGui("InGameMenu")
                inGameMenu:goToPage(self.ui)
            end
        end
    end
end

local function registerGlobalPlayerActionEvents(playerInputComponent, contextName)
    if playerInputComponent.player ~= nil and playerInputComponent.player.isOwner then
        local currentContextName = g_inputBinding:getContextName()
        local newContextName = contextName or currentContextName

        if currentContextName ~= newContextName then
            g_inputBinding:beginActionEventsModification(newContextName)
        end

        g_inputBinding:removeActionEventsByTarget(GlobalMarket)
        local _, eventId = g_inputBinding:registerActionEvent(InputAction.GLOBAL_MARKET_OPEN, GlobalMarket, GlobalMarket.onToggleMarket, false, true, false, true)

        if eventId ~= nil then
            g_inputBinding:setActionEventTextVisibility(eventId, true)
            g_inputBinding:setActionEventActive(eventId, true)
        end

        if currentContextName ~= newContextName then
            g_inputBinding:beginActionEventsModification(currentContextName)
        end
    end
end
PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(PlayerInputComponent.registerGlobalPlayerActionEvents, registerGlobalPlayerActionEvents)

-- =========================================================================
-- TEMPORARY DEBUG: FillType & Manager Dump (ALL FillTypes)
-- =========================================================================
function GlobalMarket:dumpFillTypeData()
    if g_fillTypeManager == nil or g_fillTypeManager.fillTypes == nil then
        print("[GM Debug] WARNING: g_fillTypeManager is not available yet!")
        return
    end

    print("==============================================================")
    print("[GM Debug] INITIATING MASSIVE FILLTYPE DUMP")
    print("==============================================================")

    for _, fillType in pairs(g_fillTypeManager.fillTypes) do
        if fillType ~= nil and fillType.name ~= nil then
            print("--------------------------------------------------------------")
            print("[GM Debug] DUMPING FILLTYPE FROM MANAGER: " .. tostring(fillType.name))
            print("--------------------------------------------------------------")

            -- Dump the fillType table directly (depth 5 to prevent infinite loops)
            DebugUtil.printTableRecursively(fillType, "--> ", 0, 5)

            -- Check the BaleManager for references to this fillType
            if g_baleManager ~= nil then
                print("--------------------------------------------------------------")
                print("[GM Debug] BALE MANAGER DATA FOR: " .. tostring(fillType.name))
                print("--------------------------------------------------------------")

                -- Check if the basic support boolean function exists and returns true
                if g_baleManager.getIsFillTypeSupported ~= nil then
                    local isSupported = g_baleManager:getIsFillTypeSupported(fillType.index)
                    print("--> getIsFillTypeSupported: " .. tostring(isSupported))
                end

                -- Dump the specific registered bale array for this fillType if it exists
                if g_baleManager.fillTypes ~= nil and g_baleManager.fillTypes[fillType.index] ~= nil then
                    print("--> Registered Bales for this FillType:")
                    DebugUtil.printTableRecursively(g_baleManager.fillTypes[fillType.index], "----> ", 0, 5)
                else
                    print("--> No specific bale arrays found in g_baleManager.fillTypes for this index.")
                end
            end
        end
    end
    print("==============================================================")
    print("[GM Debug] MASSIVE FILLTYPE DUMP COMPLETE!")
    print("==============================================================")
end

-- ============================================================================
-- DEV-TOOL: Analyze Shop Items (BigBags & Pallets)
-- ============================================================================
function GlobalMarket.dumpShopItems()
    if g_storeManager ~= nil and g_storeManager.items ~= nil then
        print("================== START GM MEGA DUMP (PALLETS & BIGBAGS) ==================")

        local count = 0
        for _, item in ipairs(g_storeManager:getItems()) do
            local cat = item.categoryName and string.lower(item.categoryName) or ""
            local xmlLower = item.xmlFilename and string.lower(item.xmlFilename) or ""

            -- Catch everything in relevant categories OR containing "bag"/"pallet" in the xml path
            if cat == "bigbags" or cat == "pallets" or cat == "bigbagpallets" or string.find(xmlLower, "bag") or string.find(xmlLower, "pallet") then
                count = count + 1
                print("--------------------------------------------------")
                print("Item Name:      " .. tostring(item.name))
                print("XML Path:       " .. tostring(item.xmlFilename))
                print("Category:       " .. tostring(item.categoryName))
                print("showInStore:    " .. tostring(item.showInStore))

                -- Ruthlessly dig through all specs
                if item.specs ~= nil then
                    print("SPECS found:")
                    for specName, specValue in pairs(item.specs) do
                        print("  -> " .. tostring(specName) .. ": " .. tostring(specValue))
                    end
                else
                    print("No specs found in item table.")
                end

                -- Output functions (sometimes hidden info is stored here)
                if item.functions ~= nil and #item.functions > 0 then
                    print("FUNCTIONS found:")
                    for i, func in ipairs(item.functions) do
                        print("  -> F" .. i .. ": " .. tostring(func))
                    end
                else
                    print("No functions found.")
                end
            end
        end
        print("--- DUMP END --- (Total items analyzed: " .. count .. ")")
        print("============================================================================")
    else
        print("[GM-DUMP] Error: g_storeManager is not initialized!")
    end
end

-- =========================================================================
-- SAFE NETWORK INITIALIZATION
-- =========================================================================

-- This hook is called when the player is actually in the game
-- and the network synchronization is guaranteed to be finished.
local function onStartMission(mission)
    -- 1. Network events for Multiplayer Clients
    if g_client ~= nil and not g_currentMission:getIsServer() then
        if InitOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(InitOfflineMarketEvent.new())
        end
        if InitGlobalMarketSettingsEvent ~= nil then
            g_client:getServerConnection():sendEvent(InitGlobalMarketSettingsEvent.new())
        end

        -- Sync compatibility XML if the joining client is an Admin/MasterUser
        if g_currentMission.isMasterUser and g_currentMission.globalMarket ~= nil then
            local compMgr = g_currentMission.globalMarket.compatibilityManager
            if compMgr ~= nil then
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:info("Admin login detected. Synchronizing Compatibility XML version %s with Server...", compMgr.version)
                end
                g_client:getServerConnection():sendEvent(SyncGlobalMarketCompatibilityEvent.new(compMgr.version, compMgr.conflicts))
            end
        end
    end

    -- 2. FIREWALL START (For ALL players: SP, MP-Host and MP-Clients)
    -- At this exact point, all placeables are 100% loaded and synchronized!
    if g_currentMission ~= nil and g_currentMission.globalMarket ~= nil then
        if g_currentMission.globalMarket.compatibilityManager ~= nil then
            g_currentMission.globalMarket.compatibilityManager:checkActiveMods()
        end
    end
end

-- Appending to onStartMission ensures the 'Invalid event id' error is avoided
FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, onStartMission)

-- =========================================================================
-- SAFETY HOOK: Free Token on Client Disconnect
-- =========================================================================
local function onConnectionClosed(mission, connection)
    if g_currentMission ~= nil and g_currentMission.globalMarket ~= nil then
        if g_currentMission.globalMarket.onClientDisconnected ~= nil then
            g_currentMission.globalMarket:onClientDisconnected(connection)
        end
    end
end
FSBaseMission.onConnectionClosed = Utils.appendedFunction(FSBaseMission.onConnectionClosed, onConnectionClosed)

-- Register the mod with the engine
addModEventListener(GlobalMarket)
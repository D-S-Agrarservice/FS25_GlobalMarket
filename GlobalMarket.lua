--
-- FS25 - GlobalMarket (Core)
-- Description: Main module registry and initialization hub.
--

GlobalMarket = {}
GlobalMarket.dir = g_currentModDirectory
GlobalMarket.modName = g_currentModName

-- Feature toggles (Restart required if changed)
GlobalMarket.config = {
    useUI      = true,
    useEconomy = true,
    useStorage = true,
    useSync    = false
}

-- Static delivery costs for logistics calculation
GlobalMarket.DELIVER_COST = 50
GlobalMarket.DELIVER_COST_PERLITER = 0.05

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
-- MODULE INJECTIONS
-- =========================================================================

if GlobalMarket.config.useUI then
    source(GlobalMarket.dir .. "gui/GlobalMarketDialog.lua")
    source(GlobalMarket.dir .. "gui/GlobalMarketUI.lua")
end

if GlobalMarket.config.useEconomy then
    source(GlobalMarket.dir .. "modules/GlobalMarketOffline.lua")
    -- Savegame module must be loaded here to ensure offline data is saved/loaded!
    source(GlobalMarket.dir .. "modules/GlobalMarketSavegame.lua")
    source(GlobalMarket.dir .. "modules/GlobalMarketSettings.lua")
    source(GlobalMarket.dir .. "modules/GlobalMarketFinance.lua")
end

if GlobalMarket.config.useStorage then
    source(GlobalMarket.dir .. "modules/GlobalMarketStorage.lua")
end

-- Events must be loaded unconditionally to ensure MP compatibility and internal transactions work
source(GlobalMarket.dir .. "events/SynchOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/InitOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuySiloGlobalMarketEvent.lua")

-- Only load the external .exe sync module if the config allows it
if GlobalMarket.config.useSync then
    source(GlobalMarket.dir .. "modules/GlobalMarketSync.lua")
end

-- =========================================================================
-- ENGINE HOOKS & LIFECYCLE
-- =========================================================================

-- Triggered when the player successfully loads into a map (SP or MP Server)
function GlobalMarket:loadMap(name)
    if self.debugManager ~= nil then
        self.debugManager:info("Map loading detected. Initializing GlobalMarket core systems...")
    end

    self.fillTypes = {}
    self.offlineMarketFillTypes = {}
    self.isOnline = false
    self.closeSelectLevelUi = 0
    self.syncModule = self

    g_currentMission.globalMarket = self

    if g_gui ~= nil then
        g_gui:loadProfiles(GlobalMarket.dir .. "gui/guiProfiles.xml")
    end

    -- =========================================================
    -- CORE MODULES (Always load, regardless of Offline or Sync)
    -- =========================================================
    -- 1. Load settings first so states are available!
    if GlobalMarketSettings ~= nil and GlobalMarketSettings.loadFromXML ~= nil then
        GlobalMarketSettings:loadFromXML()
    end

    -- 2. Initialize Finance system with loaded settings
    if GlobalMarketFinance ~= nil then
        GlobalMarketFinance.init()
    end

    -- =========================================================
    -- OFFLINE MARKET (Local simulation logic)
    -- =========================================================
    if GlobalMarket.config.useEconomy and self.initOfflineMarket ~= nil then
        self:initOfflineMarket()

        -- Subscribe to hourly simulation
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.runOfflineSimulation, self)

        if g_currentMission:getIsServer() and self.loadFromXMLFile ~= nil then
            self:loadFromXMLFile()
        end
    end

    -- =========================================================
    -- ONLINE MARKET (External sync via .exe)
    -- =========================================================
    if GlobalMarket.config.useSync and self.initSync ~= nil then
        self:initSync()
        -- Request initial data if the current instance is a client
        if g_client ~= nil and not g_currentMission:getIsServer() and InitOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(InitOfflineMarketEvent.new())
        end
    end
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

    if GlobalMarket.config.useSync and self.runSyncUpdateLogic ~= nil then
        self:runSyncUpdateLogic(dt)
    end
end

-- Triggered right after the map finishes loading, before the player can move.
-- Used to safely inject our custom UI into the native Game Menu without crashes.
local function onFinishedLoading(mission)
    if GlobalMarket.config.useUI and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil then
        if GlobalMarketUI ~= nil then
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:info("Injecting GlobalMarket UI into native game menu...")
            end

            -- 1. Load Transaction Dialog
            local dialogController = GlobalMarketDialog.new()
            g_gui:loadGui(GlobalMarket.dir .. "gui/GlobalMarketDialog.xml", "GlobalMarketDialog", dialogController)
            g_currentMission.globalMarket.dialog = dialogController

            -- 2. Load Main Market UI
            local uiController = GlobalMarketUI.new()
            local xmlFilename = GlobalMarket.dir .. "gui/GlobalMarketUI.xml"

            g_gui:loadGui(xmlFilename, "GlobalMarketUI", uiController, true)
            g_currentMission.globalMarket.ui = uiController

            -- Inject Tab into InGameMenu
            g_currentMission.globalMarket:fixInGameMenu(uiController, "GlobalMarketUI")
        else
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:error("UI Injection failed! GlobalMarketUI class is nil.")
            end
        end
    end
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
-- INPUT BINDINGS
-- =========================================================================

-- Triggered via the custom input binding to open/close the market
function GlobalMarket:onToggleMarket(actionName, inputValue, callbackState, isAnalog, isMouse, deviceCategory, binding)
    if inputValue > 0 and GlobalMarket.config.useUI then
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
    if GlobalMarket.config.useUI and playerInputComponent.player ~= nil and playerInputComponent.player.isOwner then
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

-- Register the mod with the engine
addModEventListener(GlobalMarket)
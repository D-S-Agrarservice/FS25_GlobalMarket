--
-- FS25 - GlobalMarket (Core)
--

GlobalMarket = {}
GlobalMarket.dir = g_currentModDirectory
GlobalMarket.modName = g_currentModName
GlobalMarket.debug = true


GlobalMarket.config = {
    useUI      = true,
    useEconomy = true, 
    useStorage = true,
    useSync    = false
}

-- Static delivery costs for logistics calculation
GlobalMarket.DELIVER_COST = 50
GlobalMarket.DELIVER_COST_PERLITER = 0.05

function GlobalMarket.debugLog(text, ...)
    if GlobalMarket.debug then
        local content = tostring(text)
        local arg = {...}
        if #arg > 0 then
            for i = 1, #arg do arg[i] = tostring(arg[i]) end
            local success, result = pcall(string.format, content, table.unpack(arg))
            content = success and result or (content .. " [Format Error]")
        end
        print(string.format("[%s - Debug]: %s", GlobalMarket.modName, content))
    end
end

-- Source includes
if GlobalMarket.config.useUI then
    source(GlobalMarket.dir .. "gui/GlobalMarketDialog.lua")
    source(GlobalMarket.dir .. "gui/GlobalMarketUI.lua")
end
if GlobalMarket.config.useEconomy then
    source(GlobalMarket.dir .. "modules/GlobalMarketOffline.lua")
end
if GlobalMarket.config.useStorage then
    source(GlobalMarket.dir .. "modules/GlobalMarketStorage.lua")
end
if GlobalMarket.config.useSync then
    source(GlobalMarket.dir .. "modules/GlobalMarketSavegame.lua")
    source(GlobalMarket.dir .. "modules/GlobalMarketSync.lua")
    source(GlobalMarket.dir .. "events/SynchOfflineMarketEvent.lua")
    source(GlobalMarket.dir .. "events/InitOfflineMarketEvent.lua")
    source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
    source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
    source(GlobalMarket.dir .. "events/SellBuySiloGlobalMarketEvent.lua")
end

function GlobalMarket:loadMap(name)
    GlobalMarket.debugLog("GlobalMarket core loading...")

    self.fillTypes = {}
    self.offlineMarketFillTypes = {}
    self.isOnline = false
    self.closeSelectLevelUi = 0
    self.syncModule = self

    g_currentMission.globalMarket = self

    if g_gui ~= nil then
        g_gui:loadProfiles(GlobalMarket.dir .. "gui/guiProfiles.xml")
    end

    -- Initialize Offline Market if economy is enabled
    if GlobalMarket.config.useEconomy and self.initOfflineMarket ~= nil then
        self:initOfflineMarket()

        -- Subscribe to hourly simulation
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.runOfflineSimulation, self)

        if g_currentMission:getIsServer() and self.loadFromXMLFile ~= nil then
            self:loadFromXMLFile()
        end
    end

    if GlobalMarket.config.useSync and self.initSync ~= nil then
        self:initSync()
        if g_client ~= nil and not g_currentMission:getIsServer() and InitOfflineMarketEvent ~= nil then
            g_client:getServerConnection():sendEvent(InitOfflineMarketEvent.new())
        end
    end
end

function GlobalMarket:getIsMarketOnline()
    return self.isOnline == true
end

function GlobalMarket:update(dt)
    if GlobalMarket.config.useSync and self.runSyncUpdateLogic ~= nil then
        self:runSyncUpdateLogic(dt)
    end
end

local function onFinishedLoading(mission)
    if GlobalMarket.config.useUI and g_currentMission ~= nil and g_currentMission.globalMarket ~= nil then
        if GlobalMarketUI ~= nil then
            -- 1. Load Transaction Dialog
            local dialogController = GlobalMarketDialog.new()
            g_gui:loadGui(GlobalMarket.dir .. "gui/GlobalMarketDialog.xml", "GlobalMarketDialog", dialogController)
            g_currentMission.globalMarket.dialog = dialogController

            -- 2. Load Main Market UI (Updated Path and Name)
            local uiController = GlobalMarketUI.new()
            local xmlFilename = GlobalMarket.dir .. "gui/GlobalMarketUI.xml"

            g_gui:loadGui(xmlFilename, "GlobalMarketUI", uiController, true)
            g_currentMission.globalMarket.ui = uiController

            -- Inject Tab into InGameMenu
            g_currentMission.globalMarket:fixInGameMenu(uiController, "GlobalMarketUI")
        else
            GlobalMarket.debugLog("ERROR: GlobalMarketUI class is nil.")
        end
    end
end
FSBaseMission.onFinishedLoading = Utils.appendedFunction(FSBaseMission.onFinishedLoading, onFinishedLoading)

function GlobalMarket:isMarketEnabled()
    return true
end

-- Manual Tab Injection to prevent InGameMenu crashes and fix Tab-Jumping
function GlobalMarket:fixInGameMenu(frame, pageName)
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
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

    -- Create Tab
    local tab = inGameMenu:addPageTab(frame, nil, nil, "gui.icon_ingameMenu_prices")

    -- Custom Icon Injection
    if tab ~= nil and type(tab) == "table" then
        if tab.icon ~= nil then
            local iconFileName = Utils.getFilename('images/menuIcon.dds', GlobalMarket.dir)
            tab.icon:setImageFilename(iconFileName)
            tab.icon:setImageUVs(nil, {0, 0, 0, 1, 1, 0, 1, 1})
        end
    end

    -- 3. Shift the pageFrames table
    for i, pFrame in ipairs(inGameMenu.pageFrames) do
        if pFrame == frame then
            table.remove(inGameMenu.pageFrames, i)
            table.insert(inGameMenu.pageFrames, targetPos, pFrame)
            break
        end
    end

    inGameMenu:rebuildTabList()
    GlobalMarket.debugLog("GlobalMarket GUI registered as %s and mapping fixed.", pageName)
end

function GlobalMarket:onToggleMarket(actionName, inputValue, callbackState, isAnalog, isMouse, deviceCategory, binding)
    if inputValue > 0 and GlobalMarket.config.useUI then
        GlobalMarket.debugLog("Hotkey pressed! Toggling Menu...")
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

addModEventListener(GlobalMarket)
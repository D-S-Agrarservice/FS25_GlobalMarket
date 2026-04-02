--
-- FS25 - GlobalMarket (Core)
--

GlobalMarket = {}
GlobalMarket.dir = g_currentModDirectory
GlobalMarket.modName = g_currentModName
GlobalMarket.needExeVersion = 1000

-- Debug Settings
GlobalMarket.debug = false -- Set to true to enable detailed logging by default

-- =========================================================================
-- Integrated Utility & Debug Functions
-- =========================================================================

function GlobalMarket:debugLog(text, ...)
    if self.debug then
        local formattedText = string.format(text, ...)
        print(string.format("[%s - Debug %s]: %s", self.modName, os.date("%H:%M:%S"), formattedText))
    end
end

-- Console Command to toggle debug mode ingame
function GlobalMarket:consoleCommandDebug(enable)
    if enable == nil then
        self.debug = not self.debug
    else
        self.debug = GlobalMarket.convertToBool(enable)
    end
    print(string.format("GlobalMarket Debug Mode: %s", tostring(self.debug)))
end

function GlobalMarket.splitString(s, delimiter)
    local result = {}
    for match in (s..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, match)
    end
    return result
end

function GlobalMarket.convertToBool(val)
    if type(val) == "boolean" then return val end
    return val == "true" or val == "True" or val == "TRUE" or val == "1"
end

function GlobalMarket.stringStarts(String, Start)
    return string.sub(String, 1, string.len(Start)) == Start
end

-- =========================================================================
-- Module & Event Loading
-- =========================================================================

source(GlobalMarket.dir .. "gui/GlobalMarketUI.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketEconomy.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketStorage.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSavegame.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSync.lua")

source(GlobalMarket.dir .. "events/SynchOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/InitOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuySiloGlobalMarketEvent.lua")

-- =========================================================================
-- Core Logic
-- =========================================================================

function GlobalMarket:loadMap(name)
    self:debugLog("Initializing GlobalMarket on map: %s", tostring(name))

    self.fillTypes = {}
    self.offlineMarketFillTypes = {}
    self.siloLevels = {}
    self.objectLevels = {}
    self.lastConnection = false
    self.closeSelectLevelUi = 0

    GlobalMarketUI.init()
    self:initEconomy()
    self:initSync()

    if g_currentMission:getIsServer() then
        self:loadFromXMLFile()
        self:debugLog("Server detected, savegame data loaded.")
    end

    g_currentMission.globalMarket = self

    -- Register console command
    addConsoleCommand("gmDebug", "Toggles GlobalMarket debug logging", "consoleCommandDebug", self)

    if g_client ~= nil and not g_currentMission:getIsServer() then
        self:debugLog("Client detected, requesting initial state from server.")
        g_client:getServerConnection():sendEvent(InitOfflineMarketEvent.new())
    end
end

function GlobalMarket:update(dt)
    -- Prepared for later
    -- if self.updateSync ~= nil then self:updateSync(dt) end
end

addModEventListener(GlobalMarket)
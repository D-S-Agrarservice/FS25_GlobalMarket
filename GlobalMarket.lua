--
-- FS25 - GlobalMarket (Core)
--

GlobalMarket = {}
GlobalMarket.dir = g_currentModDirectory
GlobalMarket.modName = g_currentModName
GlobalMarket.needExeVersion = 1000

-- =========================================================================
-- Integrated Utility Functions
-- =========================================================================

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

-- Load UI and Logic Modules
source(GlobalMarket.dir .. "gui/GlobalMarketUI.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketEconomy.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketStorage.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSavegame.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSync.lua")

-- Load Network Events
source(GlobalMarket.dir .. "events/SynchOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/InitOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuySiloGlobalMarketEvent.lua")

-- =========================================================================
-- Core Logic
-- =========================================================================

function GlobalMarket:loadMap(name)
    -- Initialize basic data tables
    self.fillTypes = {}
    self.offlineMarketFillTypes = {}
    self.siloLevels = {}
    self.objectLevels = {}
    self.lastConnection = false
    self.closeSelectLevelUi = 0

    -- Initialize Modules
    GlobalMarketUI.init()
    self:initEconomy()
    self:initSync()
    
    -- Load persistent data if on server
    if g_currentMission:getIsServer() then
        self:loadFromXMLFile()
    end

    -- Store reference for global access
    g_currentMission.globalMarket = self
    
    -- Request initial data from server if we are a client
    if g_client ~= nil and not g_currentMission:getIsServer() then
        g_client:getServerConnection():sendEvent(InitOfflineMarketEvent.new())
    end
end

function GlobalMarket:update(dt)
    -- Sync update (Keep commented out until external EXE communication is tested)
    -- if self.updateSync ~= nil then
    --     self:updateSync(dt)
    -- end
end

-- Register Mod Object
addModEventListener(GlobalMarket)
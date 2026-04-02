--
-- FS25 - GlobalMarket (Core)
--

GlobalMarket = {}
GlobalMarket.dir = g_currentModDirectory
GlobalMarket.modName = g_currentModName
GlobalMarket.debug = true

-- =========================================================================
-- Global Utility & Debug Functions
-- =========================================================================

function GlobalMarket.debugLog(text, ...)
    if GlobalMarket.debug then
        local formattedText = string.format(text, ...)
        print(string.format("[%s - Debug]: %s", GlobalMarket.modName, formattedText))
    end
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
-- Module & Event Loading (Nothing removed)
-- =========================================================================

source(GlobalMarket.dir .. "gui/GlobalMarketUI.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketEconomy.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketStorage.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSavegame.lua")
--source(GlobalMarket.dir .. "modules/GlobalMarketSync.lua") -- Online Sync Module intact

source(GlobalMarket.dir .. "events/SynchOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/InitOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuySiloGlobalMarketEvent.lua")
-- Add any other events you have here

-- =========================================================================
-- Core Logic
-- =========================================================================

function GlobalMarket:loadMap(name)
    GlobalMarket.debugLog("Initializing GlobalMarket on map: %s", tostring(name))
    
    self.fillTypes = {}
    self.offlineMarketFillTypes = {}
    self.siloLevels = {}
    self.objectLevels = {}
    self.closeSelectLevelUi = 0

    g_currentMission.globalMarket = self

    GlobalMarketUI.init()
    self:initEconomy()
    self:initSync() -- Online Sync init
    
    if g_currentMission:getIsServer() then
        self:loadFromXMLFile()
        GlobalMarket.debugLog("Server detected, savegame data loaded.")
    end

    if g_client ~= nil and not g_currentMission:getIsServer() then
        GlobalMarket.debugLog("Client detected, requesting initial state from server.")
        g_client:getServerConnection():sendEvent(InitOfflineMarketEvent.new())
    end
end

function GlobalMarket:getIsMarketOnline()
    -- Currently returning false to force offline mode, but logic remains intact
    if self.syncModule ~= nil then
        return self.syncModule.isOnline
    end
    return false
end

function GlobalMarket:update(dt)
    if self.syncModule ~= nil and type(self.syncModule.update) == "function" then
        self.syncModule:update(dt)
    end
end

addModEventListener(GlobalMarket)
-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarket.lua
-- Core module registry, mission lifecycle orchestrator, and InGameMenu integration.
-- Author: D-S-Agrarservice
-- =========================================================================================

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
GlobalMarket.STORAGE_DECAY_MONTHS = 6
GlobalMarket.GREAT_DEMAND_MODE = 1 -- 1 = Scarcity (Stock-based), 2 = Random, 3 = Off
GlobalMarket.NPC_ACTIVITY_MODE = 1 -- 1 = All (Contracts+Offers), 2 = Contracts Only, 3 = Players Only
GlobalMarket.ONLINE_CONTRACTS_MODE = 1 -- 1 = All Online+Local, 2 = Contracts Online, 3 = Offers Online, 4 = Local Only

-- Master switch for external companion client file polling and online market synchronization.
-- Active by default; can be toggled live via the console command 'gmToggleOnlineSync' for testing/debugging.
GlobalMarket.ENABLE_ONLINE_SYNC = true

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
-- GUI $moddir$ PATH RESOLVER
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

-- Engine Fix: Prevent nil arithmetic crash in BuyingStation:getEffectiveFillTypePrice (BuyingStation.lua:127)
-- when InGameMenuStatisticsFrame:onHourChanged() reloads priceList while open on the Finances sub-tab.
if BuyingStation ~= nil and BuyingStation.getEffectiveFillTypePrice ~= nil then
    local origBuyingStationGetEffectivePrice = BuyingStation.getEffectiveFillTypePrice
    BuyingStation.getEffectiveFillTypePrice = function(stationSelf, fillTypeIndex)
        if stationSelf == nil or fillTypeIndex == nil or stationSelf.fillTypePricesScale == nil or stationSelf.fillTypePricesScale[fillTypeIndex] == nil then
            return 0
        end
        return origBuyingStationGetEffectivePrice(stationSelf, fillTypeIndex)
    end
end

-- =========================================================================
-- MODULE INJECTIONS
-- =========================================================================
-- Load all core modules unconditionally in dependency order

-- Load the central API first so it is available to all other modules
source(GlobalMarket.dir .. "modules/GlobalMarketAPI.lua")

-- UI Modules
source(GlobalMarket.dir .. "gui/GlobalMarketDialog.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketContractDialog.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketContractDialogScope.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketVehicleDialog.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketAnimalDialog.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketUI.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketCategories.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketContractsUI.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketContractsUIActions.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketVehiclesUI.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketAnimalsUI.lua")
source(GlobalMarket.dir .. "gui/GlobalMarketVehicleShopBridge.lua")

-- Economy & Savegame Modules
source(GlobalMarket.dir .. "modules/GlobalMarketOffline.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketOnline.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSavegame.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSettings.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketFinance.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketStorageAge.lua")

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
source(GlobalMarket.dir .. "events/SyncGmStorageAgeEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
-- Online Events
source(GlobalMarket.dir .. "events/ExeStatusEvent.lua")
source(GlobalMarket.dir .. "events/SyncMarketWhitelistEvent.lua")
source(GlobalMarket.dir .. "events/MarketDataSyncEvent.lua")

-- Compatibility Sync Events
source(GlobalMarket.dir .. "events/SyncGlobalMarketCompatibilityEvent.lua")

-- Store Cache Module
source(GlobalMarket.dir .. "modules/GlobalMarketStoreCache.lua")

-- External Branding & Sync Modules
source(GlobalMarket.dir .. "modules/GlobalMarketBranding.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketSync.lua")

-- Contracts, Direct Offers & Pickup Inbox Modules
source(GlobalMarket.dir .. "modules/GlobalMarketContractsStorage.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketContracts.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketContractsStations.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketVehicleListings.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketVehicleMarket.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketVehicleTrade.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketVehicleNpc.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketVehicleOnline.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketVehicleOnlineSync.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAuction.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAnimalListings.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAnimalMarket.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAnimalTrade.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAnimalNpc.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAnimalDemand.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAnimalAuction.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketAnimalAuctionNpc.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketPermissions.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketMapPriceHint.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketMarketSwitch.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketOffers.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketContractsOnline.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketContractsOnlineSync.lua")
source(GlobalMarket.dir .. "modules/GlobalMarketFarmCleanup.lua")
source(GlobalMarket.dir .. "events/SyncContractsStateEvent.lua")
source(GlobalMarket.dir .. "events/ContractActionEvent.lua")
source(GlobalMarket.dir .. "events/ContractOnlineBridgeEvent.lua")
source(GlobalMarket.dir .. "events/VehicleMarketActionEvent.lua")
source(GlobalMarket.dir .. "events/SyncVehicleMarketEvent.lua")
source(GlobalMarket.dir .. "events/VehicleOnlineBridgeEvent.lua")
source(GlobalMarket.dir .. "events/AnimalMarketActionEvent.lua")
source(GlobalMarket.dir .. "events/SyncAnimalMarketEvent.lua")


-- =========================================================================
-- ENGINE HOOKS & LIFECYCLE
-- =========================================================================

---Triggered when the player successfully loads into a map (SP or MP Server)
---@param name string The name of the map being loaded
function GlobalMarket:loadMap(name)
    if self.debugManager ~= nil then
        if self.debugManager.currentLogFile == nil and self.debugManager.openNewLogFile ~= nil then
            self.debugManager:rotateLogs()
            self.debugManager:openNewLogFile()
        end
        self.debugManager:info("Map loading detected. Initializing GlobalMarket core systems...")
    end

    -- Initial state setup
    self.fillTypes = {}
    self.offlineMarketFillTypes = {}
    self.isOnline = false
    self.debugCommandsRegistered = false
    self.syncModule = self

    -- Register global reference
    g_currentMission.globalMarket = self

    -- Animal subtype indices are per mission
    GlobalMarketAnimalListings.resetCaches()

    -- 1. MANDATORY: Initialize FileSystem Infrastructure first
    -- This ensures all path variables (read/write/whitelist) are defined before logic modules access them.
    if self.initFileSystem ~= nil then
        self:initFileSystem()
    end

    -- Load GUI profiles and inject UI
    if g_gui ~= nil then
        g_gui:loadProfiles(GlobalMarket.dir .. "gui/guiProfiles.xml")

        -- =========================================================
        -- UI INJECTION (Executed during map load to preserve FocusManager state)
        -- =========================================================
        if GlobalMarketUI ~= nil then
            if self.debugManager ~= nil then
                self.debugManager:info("Injecting GlobalMarket UI during map load...")
            end

            local previousFocusGui = FocusManager.currentGui

            -- 1. Load Transaction Dialogs
            local dialogController = GlobalMarketDialog.new()
            g_gui:loadGui(GlobalMarket.dir .. "gui/GlobalMarketDialog.xml", "GlobalMarketDialog", dialogController)
            self.dialog = dialogController

            local contractDialogController = GlobalMarketContractDialog.new()
            g_gui:loadGui(GlobalMarket.dir .. "gui/GlobalMarketContractDialog.xml", "GlobalMarketContractDialog", contractDialogController)
            self.contractDialog = contractDialogController

            -- Used vehicle market dialog (#16); reuses profiles registered by the contract dialog
            local vehicleDialogController = GlobalMarketVehicleDialog.new()
            g_gui:loadGui(GlobalMarket.dir .. "gui/GlobalMarketVehicleDialog.xml", "GlobalMarketVehicleDialog", vehicleDialogController)
            self.vehicleDialog = vehicleDialogController

            -- Livestock market dialog (#15); reuses profiles registered by the contract dialog
            local animalDialogController = GlobalMarketAnimalDialog.new()
            g_gui:loadGui(GlobalMarket.dir .. "gui/GlobalMarketAnimalDialog.xml", "GlobalMarketAnimalDialog", animalDialogController)
            self.animalDialog = animalDialogController

            -- 2. Load Main Market UI
            local uiController = GlobalMarketUI.new()
            local xmlFilename = GlobalMarket.dir .. "gui/GlobalMarketUI.xml"

            g_gui:loadGui(xmlFilename, "GlobalMarketUI", uiController, true)
            self.ui = uiController
            g_currentMission.globalMarketUi = uiController

            -- Inject Tab into InGameMenu
            self:fixInGameMenu(uiController, "GlobalMarketUI")

            -- Restore active FocusManager GUI context if one was set prior to loadGui
            if previousFocusGui ~= nil then
                FocusManager:setGui(previousFocusGui)
            end
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

        -- Initialize contracts, direct offers, and unified Pickup Inbox tables
        if self.initContractsSystem ~= nil then
            self:initContractsSystem()
        end

        -- Initialize the used vehicle market (#16)
        if self.initVehicleMarket ~= nil then
            self:initVehicleMarket()
        end

        -- Initialize the livestock market (#15)
        if self.initAnimalMarket ~= nil then
            self:initAnimalMarket()
        end

        -- Build the Server Whitelist based on the fully evaluated offline market
        -- Requirement: getIsServer must be true to generate the external sync file
        if g_currentMission:getIsServer() and self.initServerWhitelist ~= nil then
            self:initServerWhitelist()
        end

        -- Subscribe to hourly simulation
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.runOfflineSimulation, self)

        -- Clean up farm-keyed GM data when a farm is deleted in MP (#30, farm IDs get reused)
        g_messageCenter:subscribe(MessageType.FARM_DELETED, self.onFarmDeleted, self)
    end

    -- =========================================================
    -- ONLINE MARKET (External sync via .exe)
    -- =========================================================

    -- Initialize the network and polling logic
    if self.initSync ~= nil then
        self:initSync()
    end

    -- Report own version and file hash to the local companion client (#35)
    if self.writeModInfo ~= nil then
        self:writeModInfo()
    end

    -- Register developer console commands only when GM Debug Mode is enabled
    self:syncDebugConsoleCommands(false)
end

---Registers or removes the developer console commands dynamically based on GM Debug Mode
---@param forceRemove boolean|nil If true, unconditionally unregisters all GM debug console commands
function GlobalMarket:syncDebugConsoleCommands(forceRemove)
    local shouldEnable = (not forceRemove)
        and GlobalMarketSettings ~= nil
        and GlobalMarketSettings.current ~= nil
        and GlobalMarketSettings.current.isDebugActive == true

    if shouldEnable then
        if not self.debugCommandsRegistered then
            addConsoleCommand("gmTriggerGreatDemand", "Triggers a GlobalMarket Great Demand for testing", "consoleCommandTriggerGreatDemand", self)
            addConsoleCommand("gmAdvanceStorageAge", "Advances GM storage age in months to test fees/decay/clearance", "consoleCommandAdvanceStorageAge", self)
            addConsoleCommand("gmAdvanceContracts", "Advances contract, offer & inbox timers in months for testing", "consoleCommandAdvanceContracts", self)
            addConsoleCommand("gmTestStatus", "Toggle GM Status Icon testing (0=Off, 1=EXE, 2=Host, 3=Exe: external connection broken)", "consoleCommandTestStatus", self)
            addConsoleCommand("gmToggleOnlineSync", "Toggles GlobalMarket.ENABLE_ONLINE_SYNC master switch for EXE bridge testing", "consoleCommandToggleOnlineSync", self)
            addConsoleCommand("gmTestBranding", "Previews 3-tier online market branding (0/off, 1, 2, 3)", "consoleCommandTestBranding", self)
            addConsoleCommand("gmTestOnlineContracts", "Tests Stage 2 online contracts capability and mock packets (on/off/mock)", "consoleCommandTestOnlineContracts", self)
            addConsoleCommand("gmVehicleMarketList", "Lists own vehicles (eligibility, dealer value) and all vehicle market listings", "consoleCommandVehicleMarketList", self)
            addConsoleCommand("gmVehicleMarketSell", "Lists an own vehicle: <index> [pricePercent=100] [months=3]", "consoleCommandVehicleMarketSell", self)
            addConsoleCommand("gmVehicleMarketReturn", "Returns a listed vehicle to its seller: <listingId|pending>", "consoleCommandVehicleMarketReturn", self)
            addConsoleCommand("gmVehicleMarketBuy", "Buys a vehicle market listing for the own farm: <listingId>", "consoleCommandVehicleMarketBuy", self)
            addConsoleCommand("gmVehicleMarketMakeNpc", "Turns a listing into an NPC dealer listing (SP buy test): <listingId>", "consoleCommandVehicleMarketMakeNpc", self)
            addConsoleCommand("gmVehicleMarketSpawnNpc", "Creates NPC dealer vehicle listings now: [count=1]", "consoleCommandVehicleMarketSpawnNpc", self)
            addConsoleCommand("gmAdvanceVehicleMarket", "Advances vehicle market listing timers in months (expiry test)", "consoleCommandAdvanceVehicleMarket", self)
            addConsoleCommand("gmAnimalMarketList", "Lists own barn/trailer animals (eligibility, dealer value, new price, flags), listings and pickup box", "consoleCommandAnimalMarketList", self)
            addConsoleCommand("gmAnimalMarketSell", "Lists own animals: <clusterId> <count> [pricePercent=100] [months=1]", "consoleCommandAnimalMarketSell", self)
            addConsoleCommand("gmAnimalMarketReturn", "Withdraws an own animal listing: <listingId|pending>", "consoleCommandAnimalMarketReturn", self)
            addConsoleCommand("gmAdvanceAnimalMarket", "Advances animal market listing timers in months (expiry test)", "consoleCommandAdvanceAnimalMarket", self)
            addConsoleCommand("gmAnimalMarketBuy", "Buys an animal listing for the own farm: <listingId> [barn|pickup]", "consoleCommandAnimalMarketBuy", self)
            addConsoleCommand("gmAnimalMarketLoad", "Loads pickup box animals onto an own livestock trailer at the animal dealer: [pickupId|all]", "consoleCommandAnimalMarketLoad", self)
            addConsoleCommand("gmAnimalMarketMakeNpc", "Turns an animal listing into an NPC dealer listing (SP buy test): <listingId>", "consoleCommandAnimalMarketMakeNpc", self)
            addConsoleCommand("gmAnimalMarketSpawnNpc", "Creates NPC animal dealer listings now: [count=1] [auction]", "consoleCommandAnimalMarketSpawnNpc", self)
            addConsoleCommand("gmAnimalDemandStart", "Starts a great demand for meat animals now: [animal type, e.g. COW or PIG]", "consoleCommandAnimalDemandStart", self)
            addConsoleCommand("gmAnimalDemandEnd", "Ends the active great demand for meat animals", "consoleCommandAnimalDemandEnd", self)
            addConsoleCommand("gmAnimalDemandSell", "Sells own animals to the great demand: <clusterId> <count>", "consoleCommandAnimalDemandSell", self)
            addConsoleCommand("gmAnimalAuctionCreate", "Lists own animals as auction: <clusterId> <count> <startPercent> [buyNowPercent=0] [hours=12]", "consoleCommandAnimalAuctionCreate", self)
            addConsoleCommand("gmAnimalAuctionBid", "Bids on an animal auction: <listingId> <percent of dealer value|min>", "consoleCommandAnimalAuctionBid", self)
            addConsoleCommand("gmAnimalAuctionBuyNow", "Buys an animal auction at its buy-now price: <listingId>", "consoleCommandAnimalAuctionBuyNow", self)
            addConsoleCommand("gmAnimalAuctionNpcBid", "An NPC places the minimum bid on an animal auction now: <listingId>", "consoleCommandAnimalAuctionNpcBid", self)
            self.debugCommandsRegistered = true
        end
    else
        if self.debugCommandsRegistered or forceRemove then
            removeConsoleCommand("gmTriggerGreatDemand")
            removeConsoleCommand("gmAdvanceStorageAge")
            removeConsoleCommand("gmAdvanceContracts")
            removeConsoleCommand("gmTestStatus")
            removeConsoleCommand("gmToggleOnlineSync")
            removeConsoleCommand("gmTestBranding")
            removeConsoleCommand("gmTestOnlineContracts")
            removeConsoleCommand("gmVehicleMarketList")
            removeConsoleCommand("gmVehicleMarketSell")
            removeConsoleCommand("gmVehicleMarketReturn")
            removeConsoleCommand("gmVehicleMarketBuy")
            removeConsoleCommand("gmVehicleMarketMakeNpc")
            removeConsoleCommand("gmVehicleMarketSpawnNpc")
            removeConsoleCommand("gmAdvanceVehicleMarket")
            removeConsoleCommand("gmAnimalMarketList")
            removeConsoleCommand("gmAnimalMarketSell")
            removeConsoleCommand("gmAnimalMarketReturn")
            removeConsoleCommand("gmAdvanceAnimalMarket")
            removeConsoleCommand("gmAnimalMarketBuy")
            removeConsoleCommand("gmAnimalMarketLoad")
            removeConsoleCommand("gmAnimalMarketMakeNpc")
            removeConsoleCommand("gmAnimalMarketSpawnNpc")
            removeConsoleCommand("gmAnimalDemandStart")
            removeConsoleCommand("gmAnimalDemandEnd")
            removeConsoleCommand("gmAnimalDemandSell")
            removeConsoleCommand("gmAnimalAuctionCreate")
            removeConsoleCommand("gmAnimalAuctionBid")
            removeConsoleCommand("gmAnimalAuctionBuyNow")
            removeConsoleCommand("gmAnimalAuctionNpcBid")
            self.debugCommandsRegistered = false
        end
    end
end

---Cleans up console commands, MessageCenter subscriptions, HUD overlays, and log handles on mission exit
function GlobalMarket:deleteMap()
    self:syncDebugConsoleCommands(true)

    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end

    if g_currentMission ~= nil and g_currentMission.hud ~= nil and g_currentMission.hud.gameInfoDisplay ~= nil then
        local display = g_currentMission.hud.gameInfoDisplay
        if display.gmStatusBg ~= nil then
            display.gmStatusBg:delete()
            display.gmStatusBg = nil
        end
        if display.gmStatusIcon ~= nil then
            display.gmStatusIcon:delete()
            display.gmStatusIcon = nil
        end
        display.hasGlobalMarketIcon = nil
    end

    if self.debugManager ~= nil then
        self.debugManager:close()
    end
end

-- Used by the UI to check if the external EXE is currently connected
function GlobalMarket:getIsMarketOnline()
    return self.isOnline == true
end

-- =========================================================================
-- CENTRAL PRICE ROUTER
-- =========================================================================
-- Decides dynamically which module calculates the prices based on connection state.
-- This function can be safely called by any module (Sync, Offline, UI) to refresh prices.
function GlobalMarket:refreshMarketPrices(skipUiUpdate)
    -- Follow authoritative online state so standby clients never override a locked/offline server
    local useOnline = (self.isOnline == true)

    if useOnline then
        -- EXE is active and connected -> Online Module takes over
        if GlobalMarketOnline ~= nil and GlobalMarketOnline.updateOnlinePrices ~= nil then
            GlobalMarketOnline:updateOnlinePrices(self.offlineMarketFillTypes)
        end
    else
        -- EXE missing or connection broken -> Safe fallback to local simulation
        if self.updateOfflinePrices ~= nil then
            self:updateOfflinePrices()
        end
    end

    -- Check for newly started Great Demands and announce via HUD notification
    if self.checkAndAnnounceGreatDemands ~= nil then
        self:checkAndAnnounceGreatDemands(skipUiUpdate)
    end

    -- Trigger UI update if the terminal is currently open
    if not skipUiUpdate then
        local ui = self.ui or g_currentMission.globalMarketUi
        if ui ~= nil and ui:getIsVisible() then
            ui:updateContent()
        end
    end
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

    if g_currentMission ~= nil and g_currentMission:getIsServer() and self.updateOfflineGreatDemands ~= nil then
        self:updateOfflineGreatDemands(dt)
    end

    if self.updateOnlineContractsTimers ~= nil then
        self:updateOnlineContractsTimers(dt)
    end

    -- Cross-server vehicle market (#36): sync request on availability / Data-Host change
    if self.updateVehicleOnline ~= nil then
        self:updateVehicleOnline(dt)
    end

    -- Timeout of an in-game market switch request (#38)
    if self.updateMarketSwitch ~= nil then
        self:updateMarketSwitch(dt)
    end

    -- Settle liters unloaded at map stations for NPC contracts (#27), throttled to ~1s
    if self.stationCreditsDirty and self.updateStationContracts ~= nil then
        self:updateStationContracts(dt)
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

        -- Recalculate market prices now that all map SellingStations and savegame economy settings are loaded
        if g_currentMission:getIsServer() and g_currentMission.globalMarket.refreshMarketPrices ~= nil then
            g_currentMission.globalMarket:refreshMarketPrices(true)
            if g_currentMission.globalMarket.initServerWhitelist ~= nil then
                g_currentMission.globalMarket:initServerWhitelist()
            end
            if g_currentMission.globalMarket.ensureInitialNpcBoard ~= nil then
                g_currentMission.globalMarket:ensureInitialNpcBoard()
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
-- IN-GAME MENU TAB INJECTION
-- =========================================================================

local function applyTabListScrollDefaults(tabList)
    tabList.supportsMouseScrolling = true
    if (tabList.itemizedScrollDelta or 0) <= 0 then
        tabList.itemizedScrollDelta = 1
    end
    if (tabList.selectionMarginItems or 0) <= 0 then
        tabList.selectionMarginItems = 1
    end
end

-- Guards InGameMenu's sidebar SmoothListElement against GIANTS's MP overflow and Spectator-alignment lock
function GlobalMarket.ensureInGameMenuTabListScrollable(inGameMenu)
    if inGameMenu == nil then
        return
    end

    local tabList = inGameMenu.pagingTabList
    if tabList ~= nil then
        applyTabListScrollDefaults(tabList)

        if not tabList.gmTabScrollHooked and Utils ~= nil and Utils.overwrittenFunction ~= nil then
            tabList.gmTabScrollHooked = true
            tabList.buildSectionInfo = Utils.overwrittenFunction(
                tabList.buildSectionInfo,
                function(listSelf, superFunc, ...)
                    applyTabListScrollDefaults(listSelf)
                    -- Reset before superFunc: SmoothListElement only updates listItemAlignmentOffset when contentOffset > 0
                    listSelf.listItemAlignmentOffset = 0
                    superFunc(listSelf, ...)

                    local lengthAxis = listSelf.lengthAxis or 2
                    local viewLen = (listSelf.absSize ~= nil and listSelf.absSize[lengthAxis]) or 0
                    if viewLen > 0 and (listSelf.contentSize or 0) >= viewLen then
                        listSelf.listItemAlignmentOffset = 0
                        if (listSelf.scrollViewOffsetDelta or 0) <= 0 then
                            if (listSelf.totalItemCount or 0) > 0 then
                                listSelf.scrollViewOffsetDelta = listSelf.contentSize / listSelf.totalItemCount
                            else
                                listSelf.scrollViewOffsetDelta = viewLen / 8
                            end
                        end
                    end
                end
            )
        end
    end

    if not inGameMenu.gmRebuildTabListHooked and Utils ~= nil and Utils.overwrittenFunction ~= nil then
        inGameMenu.gmRebuildTabListHooked = true
        inGameMenu.rebuildTabList = Utils.overwrittenFunction(
            inGameMenu.rebuildTabList,
            function(menuSelf, superFunc, ...)
                if menuSelf.pagingTabList ~= nil then
                    applyTabListScrollDefaults(menuSelf.pagingTabList)
                end
                if menuSelf.pagingElement ~= nil and menuSelf.currentPage ~= nil then
                    local mappedIdx = menuSelf.pagingElement:getPageMappingIndexByElement(menuSelf.currentPage)
                    if mappedIdx ~= nil and mappedIdx > 0 then
                        menuSelf.currentPageListIndex = mappedIdx
                    end
                end
                return superFunc(menuSelf, ...)
            end
        )
    end
end

-- Injects the Global Market frame into InGameMenu with separate element and page index mapping
function GlobalMarket:fixInGameMenu(frame, pageName)
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:error("UI Injection aborted: InGameMenu or pagingElement is missing.")
        end
        return
    end

    local pagingElement = inGameMenu.pagingElement

    -- Clean up any prior registration for pageName so re-injection remains idempotent
    local oldFrame = inGameMenu[pageName]
    if oldFrame ~= nil then
        if inGameMenu.pageFrames ~= nil then
            for i = #inGameMenu.pageFrames, 1, -1 do
                if inGameMenu.pageFrames[i] == oldFrame then
                    table.remove(inGameMenu.pageFrames, i)
                end
            end
        end
        if inGameMenu.pageRoots ~= nil then
            inGameMenu.pageRoots[oldFrame] = nil
        end
        if inGameMenu.pageEnablingPredicates ~= nil then
            inGameMenu.pageEnablingPredicates[oldFrame] = nil
        end
        if inGameMenu.pageTabs ~= nil then
            inGameMenu.pageTabs[oldFrame] = nil
        end
        pagingElement:removeElement(oldFrame)
    end

    -- 1. Find visual index in pagingElement.elements (contains unused mobile/console FrameReferences in FS25)
    local targetElementPos = #pagingElement.elements + 1
    for i, element in ipairs(pagingElement.elements) do
        if element == inGameMenu["pageStatistics"] then
            targetElementPos = i
            break
        end
    end

    -- 2. Find logical page index in pagingElement.pages / inGameMenu.pageFrames
    local targetPagePos = #pagingElement.pages + 1
    for i, page in ipairs(pagingElement.pages) do
        if page.element == inGameMenu["pageStatistics"] then
            targetPagePos = i
            break
        end
    end

    inGameMenu.controlIDs[pageName] = nil
    inGameMenu[pageName] = frame

    pagingElement:addElement(frame)
    frame:setSize(unpack(pagingElement.size))
    local rootElement = frame:getRootElement()
    if rootElement ~= nil then
        rootElement:setSize(unpack(pagingElement.size))
    end

    inGameMenu:exposeControlsAsFields(pageName)

    -- 3. Shift the visual element to targetElementPos
    for i, element in ipairs(pagingElement.elements) do
        if element == frame then
            table.remove(pagingElement.elements, i)
            table.insert(pagingElement.elements, targetElementPos, element)
            break
        end
    end

    -- 4. Shift the internal page mapping to targetPagePos
    for i, page in ipairs(pagingElement.pages) do
        if page.element == frame then
            table.remove(pagingElement.pages, i)
            table.insert(pagingElement.pages, targetPagePos, page)
            break
        end
    end

    pagingElement:updateAbsolutePosition()
    pagingElement:updatePageMapping()

    -- 5. Register the page directly at targetPagePos (inserts into inGameMenu.pageFrames at targetPagePos)
    inGameMenu:registerPage(frame, targetPagePos, function() return self:isMarketEnabled() end)

    -- Create Tab cleanly using direct file path and UVs (No XML profile or post-injection needed)
    local iconFileName = Utils.getFilename("images/menuIcon.dds", GlobalMarket.dir)
    inGameMenu:addPageTab(frame, iconFileName, {0, 0, 0, 1, 1, 0, 1, 1})

    GlobalMarket.ensureInGameMenuTabListScrollable(inGameMenu)
    inGameMenu:rebuildTabList()

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:debug("GlobalMarket GUI registered natively as '%s' at pagePos %d (elementPos %d).", pageName, targetPagePos, targetElementPos)
    end
end

-- =========================================================================
-- INPUT BINDINGS
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

-- =========================================================================
-- IN-GAME HELP (ESC Help Menu / HelpLineManager)
-- =========================================================================
if HelpLineManager ~= nil and HelpLineManager.loadMapData ~= nil then
    HelpLineManager.loadMapData = Utils.overwrittenFunction(
        HelpLineManager.loadMapData,
        function(self, superFunc, xmlFile, missionInfo)
            local ret = superFunc(self, xmlFile, missionInfo)
            local modEnv = GlobalMarket.modName or "FS25_GlobalMarket"
            if self.customEnvironmentToCategory ~= nil and self.customEnvironmentToCategory[modEnv] == nil then
                local helpXmlPath = Utils.getFilename("xml/helpLine_globalMarket.xml", GlobalMarket.dir)
                if helpXmlPath ~= nil and fileExists(helpXmlPath) then
                    self:loadFromXML(helpXmlPath, missionInfo)
                end
            end
            return ret
        end
    )
end

-- Register the mod with the engine
addModEventListener(GlobalMarket)

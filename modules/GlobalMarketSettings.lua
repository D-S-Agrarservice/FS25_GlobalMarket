--
-- FS25 - GlobalMarketSettings
-- Handles admin settings, XML storage in modSettings, and UI injection
--

GlobalMarketSettings = {}
GlobalMarketSettings.MOD_NAME = g_currentModName
GlobalMarketSettings.isMenuInjected = false
GlobalMarketSettings.CONTROLS = {}

-- Define the available steps for the multi-options
GlobalMarketSettings.OPTIONS = {
    DELIVERY_BASE = {0, 10, 25, 50, 75, 100, 150, 200},
    DELIVERY_LITER = {0.0, 0.01, 0.02, 0.05, 0.10, 0.20},
    -- Dealer Markup in percent (e.g., 5 = 5% price increase when buying)
    DEALER_MARKUP = {0, 2, 5, 10, 15, 20, 25}, 
    -- Market Capacity in Liters (500k, 1M, 2M, 5M, 10M, 20M)
    MARKET_CAPACITY = {500000, 1000000, 2000000, 5000000, 10000000, 20000000},
    STORAGE_DECAY = {0, 3, 6, 9, 12},
    -- Reordered array: Starts with Info on the far left
    DEBUG_LEVEL = {"Info", "Warning", "Error", "Debug", "Trace"},
    DEBUG_DURATION = {"1 Hour", "3 Hours"},
    -- 1=Ignore, 2=Warn Only, 3=Smart (Default), 4=Paranoia
    COMPAT_MODE = {"1: Ignore", "2: Warn Only", "3: Smart (Default*)", "4: Paranoia*"}
}

-- Default values
GlobalMarketSettings.current = {
    deliveryBaseIndex = 4,   -- Default: 50
    deliveryLiterIndex = 4,  -- Default: 0.05
    dealerMarkupIndex = 3,   -- Default: 5%
    capacityIndex = 3,       -- Default 2M Liters
    storageDecayIndex = 3,   -- Default: 6 Months (Index 3)
    isDebugActive = false,   -- Default: Off (Boolean for BinaryOption)
    debugLevelIndex = 1,     -- Default: Info
    debugDurationIndex = 1,  -- Default: 1 Hour
    isDetailedFinance = false, -- Default: Off (Simple Finance)
    compatModeIndex = 3,     -- Default: Strict (Auto-resolve known conflicts)
    isIconPulseActive = true,  -- Default: On
    showStatusIcon = true    -- Default: On (Controls HUD icon visibility)
}

-- Gets default indices based on the game's economic difficulty
-- 1 = Easy, 2 = Normal, 3 = Hard
-- Returns: deliveryBaseIndex, deliveryLiterIndex, dealerMarkupIndex, capacityIndex
function GlobalMarketSettings:getDefaultIndices()
    local diff = 2
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        diff = g_currentMission.missionInfo.economicDifficulty
    end

    if diff == 1 then
        return 2, 2, 2, 4 -- Easy: Base=10, Liter=0.01, Markup=2%, Capacity=5M (Index 4)
    elseif diff == 3 then
        return 6, 5, 5, 2 -- Hard: Base=100, Liter=0.10, Markup=15%, Capacity=1M (Index 2)
    else
        return 4, 4, 3, 3 -- Normal: Base=50, Liter=0.05, Markup=5%, Capacity=2M (Index 3)
    end
end

-- ============================================================================
-- Debug Module Synchronization
-- ============================================================================

-- Syncs the UI settings with the actual Debug Module logic
function GlobalMarketSettings:applyDebugSettings()
    -- Only proceed if the debug manager has been initialized by the core script
    if GlobalMarket.debugManager == nil then return end

    -- Toggle master switch
    GlobalMarket.debugManager.isActive = self.current.isDebugActive

    -- If disabled, ensure deep logging is turned off
    if not GlobalMarket.debugManager.isActive then
        GlobalMarket.debugManager.deepLogActive = false
        return
    end

    -- Handle Deep Logging activation based on Level (4 = Debug, 5 = Trace)
    if self.current.debugLevelIndex >= 4 then
        local durationHours = (self.current.debugDurationIndex == 1) and 1 or 3
        GlobalMarket.debugManager:enableDeepLogging(durationHours)
    else
        GlobalMarket.debugManager.deepLogActive = false
    end
end

-- ============================================================================
-- XML Storage Manager (Multi-Profile Edition)
-- ============================================================================

-- Ensure the settings directory exists, fallback to standard modSettings folder
local settingsDirectory = g_currentModSettingsDirectory
if settingsDirectory == nil or settingsDirectory == "" then
    settingsDirectory = string.format("%smodSettings/%s/", getUserProfileAppPath(), GlobalMarketSettings.MOD_NAME)
end

-- Helper: Determines the correct XML Node prefix based on the environment.
function GlobalMarketSettings:getEnvPrefix()
    local isDedi = (g_dedicatedServer ~= nil)
    if not isDedi and StartParams ~= nil and type(StartParams.getIsSet) == "function" then
        isDedi = StartParams.getIsSet("server") or StartParams.getIsSet("serverWithGui")
    end

    if not isDedi and g_currentMission ~= nil then
        isDedi = g_currentMission.connectedToDedicatedServer
    end

    if isDedi then
        return "globalMarketSettings.profiles.dedi"
    elseif g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer then
        return "globalMarketSettings.profiles.mp"
    else
        return "globalMarketSettings.profiles.sp"
    end
end

function GlobalMarketSettings:loadFromXML()
    local savePath = settingsDirectory .. "settings.xml"
    local prefix = self:getEnvPrefix()

    -- Fetch dynamic defaults based on game difficulty
    local defaultBase, defaultLiter, defaultMarkup, defaultCapacity = self:getDefaultIndices()

    if not fileExists(savePath) then
        self.current.deliveryBaseIndex = defaultBase
        self.current.deliveryLiterIndex = defaultLiter
        self.current.dealerMarkupIndex = defaultMarkup
        self.current.capacityIndex = defaultCapacity
        self.current.storageDecayIndex = 3
        self.current.isDetailedFinance = false
        self.current.isDebugActive = false
        self.current.debugLevelIndex = 1
        self.current.debugDurationIndex = 1
        self.current.compatModeIndex = 3
        self.current.isIconPulseActive = true
        self.current.showStatusIcon = true 

        self:saveToXML()
        self:applyDebugSettings()

        GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[self.current.deliveryBaseIndex]
        GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[self.current.deliveryLiterIndex]
        GlobalMarket.DEALER_MARKUP = self.OPTIONS.DEALER_MARKUP[self.current.dealerMarkupIndex]
        GlobalMarket.MARKET_CAPACITY = self.OPTIONS.MARKET_CAPACITY[self.current.capacityIndex]
        GlobalMarket.STORAGE_DECAY_MONTHS = self.OPTIONS.STORAGE_DECAY[self.current.storageDecayIndex] or 6
        if GlobalMarketFinance ~= nil then
            GlobalMarketFinance.isDetailedCached = false
        end
        return
    end

    local xmlFile = XMLFile.load("GlobalMarketSettingsXML", savePath)
    local profileExisted = (xmlFile ~= nil) and xmlFile:hasProperty(prefix) or false
    if xmlFile ~= nil then
        -- Load Delivery & Markup Costs
        self.current.deliveryBaseIndex = xmlFile:getInt(prefix .. "#deliveryBaseIndex", defaultBase)
        self.current.deliveryLiterIndex = xmlFile:getInt(prefix .. "#deliveryLiterIndex", defaultLiter)
        self.current.dealerMarkupIndex = xmlFile:getInt(prefix .. "#dealerMarkupIndex", defaultMarkup)
        self.current.capacityIndex = xmlFile:getInt(prefix .. "#capacityIndex", defaultCapacity)
        self.current.storageDecayIndex = xmlFile:getInt(prefix .. "#storageDecayIndex", 3)

        -- Load Detailed Finance Setting
        -- Load Detailed Finance Setting
        self.current.isDetailedFinance = xmlFile:getBool(prefix .. "#isDetailedFinance", false)
        if GlobalMarketFinance ~= nil then
            GlobalMarketFinance.isDetailedCached = (self.current.isDetailedFinance == true)
        end

        -- Load Debug Settings
        self.current.isDebugActive = xmlFile:getBool(prefix .. ".debug#isActive", false)
        self.current.debugLevelIndex = xmlFile:getInt(prefix .. ".debug#levelIndex", 1)
        self.current.debugDurationIndex = xmlFile:getInt(prefix .. ".debug#durationIndex", 1)

        -- Load Compatibility Setting
        self.current.compatModeIndex = xmlFile:getInt(prefix .. ".compatibility#modeIndex", 3)
        self.current.isIconPulseActive = xmlFile:getBool(prefix .. "#isIconPulseActive", true)
        self.current.showStatusIcon = xmlFile:getBool(prefix .. "#showStatusIcon", true)

        -- Apply loaded values to active global variables
        GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[self.current.deliveryBaseIndex]
        GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[self.current.deliveryLiterIndex]
        GlobalMarket.DEALER_MARKUP = self.OPTIONS.DEALER_MARKUP[self.current.dealerMarkupIndex]
        GlobalMarket.MARKET_CAPACITY = self.OPTIONS.MARKET_CAPACITY[self.current.capacityIndex]
        GlobalMarket.STORAGE_DECAY_MONTHS = self.OPTIONS.STORAGE_DECAY[self.current.storageDecayIndex] or 6

        self:applyDebugSettings()
        xmlFile:delete()

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("Settings: Loaded profile '%s' from XML.", prefix)
        end

        -- Persist the environment profile (sp/mp/dedi) if it did not exist in settings.xml yet
        if not profileExisted then
            self:saveToXML()
        end
    end
end

function GlobalMarketSettings:saveToXML()
    createFolder(settingsDirectory)
    local savePath = settingsDirectory .. "settings.xml"
    local prefix = self:getEnvPrefix()

    local xmlFile
    if fileExists(savePath) then
        xmlFile = XMLFile.load("GlobalMarketSettingsXML", savePath)
    else
        xmlFile = XMLFile.create("GlobalMarketSettingsXML", savePath, "globalMarketSettings")
    end

    if xmlFile ~= nil then
        xmlFile:setInt(prefix .. "#deliveryBaseIndex", self.current.deliveryBaseIndex)
        xmlFile:setInt(prefix .. "#deliveryLiterIndex", self.current.deliveryLiterIndex)
        xmlFile:setInt(prefix .. "#dealerMarkupIndex", self.current.dealerMarkupIndex)
        xmlFile:setInt(prefix .. "#capacityIndex", self.current.capacityIndex)
        xmlFile:setInt(prefix .. "#storageDecayIndex", self.current.storageDecayIndex or 3)

        xmlFile:setBool(prefix .. "#isDetailedFinance", self.current.isDetailedFinance)

        xmlFile:setBool(prefix .. ".debug#isActive", self.current.isDebugActive)
        xmlFile:setInt(prefix .. ".debug#levelIndex", self.current.debugLevelIndex)
        xmlFile:setInt(prefix .. ".debug#durationIndex", self.current.debugDurationIndex)

        xmlFile:setInt(prefix .. ".compatibility#modeIndex", self.current.compatModeIndex)
        xmlFile:setBool(prefix .. "#isIconPulseActive", self.current.isIconPulseActive)
        xmlFile:setBool(prefix .. "#showStatusIcon", self.current.showStatusIcon)

        xmlFile:save()
        xmlFile:delete()

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("Settings: Saved profile '%s' to XML.", prefix)
        end
    end
end

-- ============================================================================
-- UI Menu Injection (Dynamic Element Instantiation)
-- ============================================================================

function GlobalMarketSettings:addSectionHeader(settingsFrame, titleKey)
    local textElement = TextElement.new()
    local textElementProfile = g_gui:getProfile("fs25_settingsSectionHeader")

    textElement.name = "sectionHeader"
    textElement:loadProfile(textElementProfile, true)
    textElement:setText(g_i18n:getText(titleKey) or titleKey)

    settingsFrame.gameSettingsLayout:addElement(textElement)
    textElement:onGuiSetupFinished()
end

function GlobalMarketSettings:addMultiOption(settingsFrame, controlId, titleKey, tooltipKey, texts, callbackName)
    local bitMap = BitmapElement.new()
    local bitMapProfile = g_gui:getProfile("fs25_multiTextOptionContainer")
    bitMap:loadProfile(bitMapProfile, true)

    local multiTextOption = MultiTextOptionElement.new()
    local multiTextOptionProfile = g_gui:getProfile("fs25_settingsMultiTextOption")
    multiTextOption:loadProfile(multiTextOptionProfile, true)
    multiTextOption.target = GlobalMarketSettings
    multiTextOption:setCallback("onClickCallback", callbackName)
    multiTextOption:setTexts(texts)

    local multiTextOptionTitle = TextElement.new()
    local multiTextOptionTitleProfile = g_gui:getProfile("fs25_settingsMultiTextOptionTitle")
    multiTextOptionTitle:loadProfile(multiTextOptionTitleProfile, true)
    multiTextOptionTitle:setText(g_i18n:getText(titleKey))

    local multiTextOptionTooltip = TextElement.new()
    local multiTextOptionTooltipProfile = g_gui:getProfile("fs25_multiTextOptionTooltip")
    multiTextOptionTooltip.name = "ignore"
    multiTextOptionTooltip:loadProfile(multiTextOptionTooltipProfile, true)
    multiTextOptionTooltip:setText(g_i18n:getText(tooltipKey))

    multiTextOption:addElement(multiTextOptionTooltip)
    bitMap:addElement(multiTextOption)
    bitMap:addElement(multiTextOptionTitle)

    multiTextOption:onGuiSetupFinished()
    multiTextOptionTitle:onGuiSetupFinished()
    multiTextOptionTooltip:onGuiSetupFinished()

    settingsFrame.gameSettingsLayout:addElement(bitMap)
    bitMap:onGuiSetupFinished()

    GlobalMarketSettings.CONTROLS[controlId] = multiTextOption
    return multiTextOption, bitMap
end

function GlobalMarketSettings:addBinaryOption(settingsFrame, controlId, titleKey, tooltipKey, callbackName)
    local bitMap = BitmapElement.new()
    local bitMapProfile = g_gui:getProfile("fs25_multiTextOptionContainer")
    bitMap:loadProfile(bitMapProfile, true)

    local binaryOption = BinaryOptionElement.new()
    local binaryOptionProfile = g_gui:getProfile("fs25_settingsBinaryOption")
    binaryOption:loadProfile(binaryOptionProfile, true)
    binaryOption.target = GlobalMarketSettings
    binaryOption:setCallback("onClickCallback", callbackName)

    local binaryOptionTitle = TextElement.new()
    local binaryOptionTitleProfile = g_gui:getProfile("fs25_settingsMultiTextOptionTitle")
    binaryOptionTitle:loadProfile(binaryOptionTitleProfile, true)
    binaryOptionTitle:setText(g_i18n:getText(titleKey))

    local binaryOptionTooltip = TextElement.new()
    local binaryOptionTooltipProfile = g_gui:getProfile("fs25_multiTextOptionTooltip")
    binaryOptionTooltip.name = "ignore"
    binaryOptionTooltip:loadProfile(binaryOptionTooltipProfile, true)
    binaryOptionTooltip:setText(g_i18n:getText(tooltipKey))

    binaryOption:addElement(binaryOptionTooltip)
    bitMap:addElement(binaryOption)
    bitMap:addElement(binaryOptionTitle)

    binaryOption:onGuiSetupFinished()
    binaryOptionTitle:onGuiSetupFinished()
    binaryOptionTooltip:onGuiSetupFinished()

    settingsFrame.gameSettingsLayout:addElement(bitMap)
    bitMap:onGuiSetupFinished()

    GlobalMarketSettings.CONTROLS[controlId] = binaryOption
    return binaryOption, bitMap
end

function GlobalMarketSettings.onFrameOpen(settingsFrame)
    if not GlobalMarketSettings.isMenuInjected then
        GlobalMarketSettings:addSectionHeader(settingsFrame, "ui_gm_settings_header")

        -- Format texts for UI display
        local baseTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_BASE) do table.insert(baseTexts, tostring(val) .. " €") end

        local literTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_LITER) do table.insert(literTexts, tostring(val) .. " € / L") end

        local markupTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.DEALER_MARKUP) do table.insert(markupTexts, tostring(val) .. " %") end

        local capacityTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.MARKET_CAPACITY) do 
            -- Convert to Millions for cleaner UI (e.g., "2.0 M")
            table.insert(capacityTexts, string.format("%.1f M", val / 1000000)) 
        end

        -- 1. DELIVERY COSTS & DEALER MARKUP
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsBaseCost", "ui_gm_settings_baseCost", "ui_gm_settings_baseCost_desc", baseTexts, "onBaseCostChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsLiterCost", "ui_gm_settings_literCost", "ui_gm_settings_literCost_desc", literTexts, "onLiterCostChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsDealerMarkup", "ui_gm_settings_markup", "ui_gm_settings_markup_desc", markupTexts, "onDealerMarkupChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsCapacity", "ui_gm_settings_capacity", "ui_gm_settings_capacity_desc", capacityTexts, "onCapacityChanged")

        local decayTexts = {}
        local offText = g_i18n:getText("ui_gm_settings_decay_off")
        if offText == nil or offText == "ui_gm_settings_decay_off" then offText = "Off" end
        local monthsPattern = g_i18n:getText("ui_gm_settings_decay_months")
        if monthsPattern == nil or monthsPattern == "ui_gm_settings_decay_months" then monthsPattern = "%d Months" end
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.STORAGE_DECAY) do
            if val <= 0 then
                table.insert(decayTexts, offText)
            else
                table.insert(decayTexts, string.format(monthsPattern, val))
            end
        end
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsStorageDecay", "ui_gm_settings_storageDecay", "ui_gm_settings_storageDecay_desc", decayTexts, "onStorageDecayChanged")

        -- 2. FINANCE SETTINGS
        GlobalMarketSettings:addBinaryOption(settingsFrame, "gmSettingsDetailedFinance", "ui_gm_settings_detailedFinance", "ui_gm_settings_detailedFinance_desc", "onDetailedFinanceChanged")

        -- 3. COMPATIBILITY SETTINGS
        GlobalMarketSettings:addSectionHeader(settingsFrame, "ui_gm_settings_system_header")
        GlobalMarketSettings:addBinaryOption(settingsFrame, "gmSettingsShowIcon", "ui_gm_settings_showIcon", "ui_gm_settings_showIcon_desc", "onShowIconChanged")
        GlobalMarketSettings:addBinaryOption(settingsFrame, "gmSettingsIconPulse", "ui_gm_settings_iconPulse", "ui_gm_settings_iconPulse_desc", "onIconPulseChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsCompatMode", "ui_gm_settings_compatMode", "ui_gm_settings_compatMode_desc", GlobalMarketSettings.OPTIONS.COMPAT_MODE, "onCompatModeChanged")

        -- 4. DEBUG MODE
        GlobalMarketSettings:addBinaryOption(settingsFrame, "gmSettingsDebugMode", "ui_gm_settings_debugMode", "ui_gm_settings_debugMode_desc", "onDebugModeChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsDebugLevel", "ui_gm_settings_debugLevel", "ui_gm_settings_debugLevel_desc", GlobalMarketSettings.OPTIONS.DEBUG_LEVEL, "onDebugLevelChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsDebugDuration", "ui_gm_settings_debugDuration", "ui_gm_settings_debugDuration_desc", GlobalMarketSettings.OPTIONS.DEBUG_DURATION, "onDebugDurationChanged")

        settingsFrame.gameSettingsLayout:invalidateLayout()

        -- Update alternating row background colors
        if type(settingsFrame.updateAlternatingElements) == "function" then
            settingsFrame:updateAlternatingElements(settingsFrame.gameSettingsLayout)
        end

        GlobalMarketSettings.isMenuInjected = true
    end

    GlobalMarketSettings.refreshMenuState()
end

function GlobalMarketSettings.refreshMenuState()
    if not GlobalMarketSettings.isMenuInjected then return end

    -- Safe Admin/SP check
    local isAdmin = false
    if g_currentMission ~= nil then
        isAdmin = g_currentMission:getIsServer() or g_currentMission.isMasterUser
    end

    -- Delivery Controls
    local baseControl = GlobalMarketSettings.CONTROLS["gmSettingsBaseCost"]
    if baseControl ~= nil then
        baseControl:setState(GlobalMarketSettings.current.deliveryBaseIndex)
        baseControl:setDisabled(not isAdmin)
    end

    local literControl = GlobalMarketSettings.CONTROLS["gmSettingsLiterCost"]
    if literControl ~= nil then
        literControl:setState(GlobalMarketSettings.current.deliveryLiterIndex)
        literControl:setDisabled(not isAdmin)
    end

    local markupControl = GlobalMarketSettings.CONTROLS["gmSettingsDealerMarkup"]
    if markupControl ~= nil then
        markupControl:setState(GlobalMarketSettings.current.dealerMarkupIndex)
        markupControl:setDisabled(not isAdmin)
    end

    local capacityControl = GlobalMarketSettings.CONTROLS["gmSettingsCapacity"]
    local storageDecayControl = GlobalMarketSettings.CONTROLS["gmSettingsStorageDecay"]
    if storageDecayControl ~= nil then
        storageDecayControl:setState(GlobalMarketSettings.current.storageDecayIndex or 3)
        storageDecayControl:setDisabled(not isAdmin)
    end
    if capacityControl ~= nil then
        capacityControl:setState(GlobalMarketSettings.current.capacityIndex)
        capacityControl:setDisabled(not isAdmin)
    end

    -- Finance Controls
    local financeControl = GlobalMarketSettings.CONTROLS["gmSettingsDetailedFinance"]
    if financeControl ~= nil then
        financeControl:setState(GlobalMarketSettings.current.isDetailedFinance and 2 or 1)
        financeControl:setDisabled(false)
    end

    -- System Controls
    local isStatusIconOn = GlobalMarketSettings.current.showStatusIcon

    local showIconControl = GlobalMarketSettings.CONTROLS["gmSettingsShowIcon"]
    if showIconControl ~= nil then
        showIconControl:setState(isStatusIconOn and 2 or 1)
        showIconControl:setDisabled(false)
    end

    local iconPulseControl = GlobalMarketSettings.CONTROLS["gmSettingsIconPulse"]
    if iconPulseControl ~= nil then
        iconPulseControl:setState(GlobalMarketSettings.current.isIconPulseActive and 2 or 1)
        iconPulseControl:setDisabled(not isStatusIconOn)
    end

    -- Compatibility Controls
    local compatControl = GlobalMarketSettings.CONTROLS["gmSettingsCompatMode"]
    if compatControl ~= nil then
        compatControl:setState(GlobalMarketSettings.current.compatModeIndex)
        compatControl:setDisabled(not isAdmin)
    end

    -- Debug Controls
    local isDebugOn = GlobalMarketSettings.current.isDebugActive
    local isDeepLoggingLevel = (GlobalMarketSettings.current.debugLevelIndex >= 4)

    local modeControl = GlobalMarketSettings.CONTROLS["gmSettingsDebugMode"]
    if modeControl ~= nil then
        modeControl:setState(isDebugOn and 2 or 1)
        modeControl:setDisabled(not isAdmin)
    end

    local levelControl = GlobalMarketSettings.CONTROLS["gmSettingsDebugLevel"]
    if levelControl ~= nil then
        levelControl:setState(GlobalMarketSettings.current.debugLevelIndex)
        levelControl:setDisabled(not isAdmin or not isDebugOn)
    end

    local durationControl = GlobalMarketSettings.CONTROLS["gmSettingsDebugDuration"]
    if durationControl ~= nil then
        durationControl:setState(GlobalMarketSettings.current.debugDurationIndex)
        durationControl:setDisabled(not isAdmin or not isDebugOn or not isDeepLoggingLevel)
    end
end

function GlobalMarketSettings:broadcastChanges()
    if SyncGlobalMarketSettingsEvent == nil then return end

    local c = self.current

    -- FIX: Force local save immediately for everyone (SP, Dedi, or MP Client).
    -- This ensures the client admin saves their own changes before the network sync,
    -- bypassing the issue where the sender is ignored by the server's broadcast echo.
    if self.saveToXML ~= nil then
        self:saveToXML()
    end

    -- Network Synchronization (skip for purely local client comfort settings)
    if self.isLocalChange then
        self.isLocalChange = false
        return
    end
    if g_server ~= nil then
        -- Server broadcasts the changes to all connected clients
        g_server:broadcastEvent(SyncGlobalMarketSettingsEvent.new(c.deliveryBaseIndex, c.deliveryLiterIndex, c.isDetailedFinance, c.isDebugActive, c.debugLevelIndex, c.debugDurationIndex, c.compatModeIndex, c.isIconPulseActive, c.showStatusIcon, c.dealerMarkupIndex, c.capacityIndex, c.storageDecayIndex))
    else
        -- Client admin sends the changes to the dedicated server
        g_client:getServerConnection():sendEvent(SyncGlobalMarketSettingsEvent.new(c.deliveryBaseIndex, c.deliveryLiterIndex, c.isDetailedFinance, c.isDebugActive, c.debugLevelIndex, c.debugDurationIndex, c.compatModeIndex, c.isIconPulseActive, c.showStatusIcon, c.dealerMarkupIndex, c.capacityIndex, c.storageDecayIndex))
    end
end

-- ============================================================================
-- Callbacks
-- ============================================================================

function GlobalMarketSettings:onBaseCostChanged(state)
    self.current.deliveryBaseIndex = state
    GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[state]
    self:broadcastChanges()
end

function GlobalMarketSettings:onLiterCostChanged(state)
    self.current.deliveryLiterIndex = state
    GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[state]
    self:broadcastChanges()
end

function GlobalMarketSettings:onDealerMarkupChanged(state)
    self.current.dealerMarkupIndex = state
    GlobalMarket.DEALER_MARKUP = self.OPTIONS.DEALER_MARKUP[state]
    self:broadcastChanges()
end

function GlobalMarketSettings:onCapacityChanged(state)
    self.current.capacityIndex = state
    GlobalMarket.MARKET_CAPACITY = self.OPTIONS.MARKET_CAPACITY[state]
    self:broadcastChanges()
end

function GlobalMarketSettings:onStorageDecayChanged(state)
    self.current.storageDecayIndex = state
    GlobalMarket.STORAGE_DECAY_MONTHS = self.OPTIONS.STORAGE_DECAY[state] or 6
    self:broadcastChanges()
end

function GlobalMarketSettings:onCapacityChanged_unused(state)
    self.current.capacityIndex = state
    GlobalMarket.MARKET_CAPACITY = self.OPTIONS.MARKET_CAPACITY[state]
    self:broadcastChanges()
end

function GlobalMarketSettings:onDetailedFinanceChanged(state)
    self.current.isDetailedFinance = (state == 2)
    if GlobalMarketFinance ~= nil then
        GlobalMarketFinance.isDetailedCached = self.current.isDetailedFinance
    end
    self.isLocalChange = true
    self:broadcastChanges()
    self.refreshMenuState()
end

function GlobalMarketSettings:onShowIconChanged(state)
    self.current.showStatusIcon = (state == 2)
    self.isLocalChange = true
    self:broadcastChanges()
    if GlobalMarketSettings.refreshMenuState ~= nil then
        GlobalMarketSettings.refreshMenuState()
    end
end

function GlobalMarketSettings:onIconPulseChanged(state)
    self.current.isIconPulseActive = (state == 2)
    self.isLocalChange = true
    self:broadcastChanges()
end

function GlobalMarketSettings:onCompatModeChanged(state)
    self.current.compatModeIndex = state
    self:broadcastChanges()
    if g_currentMission ~= nil and g_currentMission.globalMarket ~= nil and g_currentMission.globalMarket.compatibilityManager ~= nil then
        g_currentMission.globalMarket.compatibilityManager:checkActiveMods()
    end
end

function GlobalMarketSettings:onDebugModeChanged(state)
    self.current.isDebugActive = (state == 2)
    self:applyDebugSettings()
    self:broadcastChanges()
    self.refreshMenuState()
end

function GlobalMarketSettings:onDebugLevelChanged(state)
    self.current.debugLevelIndex = state
    self:applyDebugSettings()
    self:broadcastChanges()
    self.refreshMenuState()
end

function GlobalMarketSettings:onDebugDurationChanged(state)
    self.current.debugDurationIndex = state
    self:applyDebugSettings()
    self:broadcastChanges()
end

-- ============================================================================
-- Core Engine Hooks
-- ============================================================================

local function initHooks()
    local InGameMenuSettingsFrame = _G.InGameMenuSettingsFrame
    if InGameMenuSettingsFrame ~= nil then
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, GlobalMarketSettings.onFrameOpen)
        InGameMenuSettingsFrame.updateGameSettings = Utils.appendedFunction(InGameMenuSettingsFrame.updateGameSettings, GlobalMarketSettings.refreshMenuState)
    end
end

initHooks()
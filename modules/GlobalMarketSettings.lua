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
    -- Reordered array: Starts with Info on the far left
    DEBUG_LEVEL = {"Info", "Warning", "Error", "Debug", "Trace"},
    DEBUG_DURATION = {"1 Hour", "3 Hours"}
}

-- Default values
GlobalMarketSettings.current = {
    deliveryBaseIndex = 4, -- Default: 50
    deliveryLiterIndex = 4, -- Default: 0.05
    isDebugActive = false, -- Default: Off (Boolean for BinaryOption)
    debugLevelIndex = 1,   -- Default: Info
    debugDurationIndex = 1 -- Default: 1 Hour
}

-- Gets default indices based on the game's economic difficulty
-- 1 = Easy, 2 = Normal, 3 = Hard
function GlobalMarketSettings:getDefaultIndices()
    local diff = 2
    if g_currentMission ~= nil and g_currentMission.missionInfo ~= nil then
        diff = g_currentMission.missionInfo.economicDifficulty
    end

    if diff == 1 then
        return 2, 2 -- Easy: Base=10, Liter=0.01
    elseif diff == 3 then
        return 6, 5 -- Hard: Base=100, Liter=0.10
    else
        return 4, 4 -- Normal: Base=50, Liter=0.05
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
-- XML Storage Manager
-- ============================================================================

local settingsDirectory = g_currentModSettingsDirectory
if settingsDirectory == nil or settingsDirectory == "" then
    settingsDirectory = string.format("%smodSettings/%s/", getUserProfileAppPath(), GlobalMarketSettings.MOD_NAME)
end

function GlobalMarketSettings:loadFromXML()
    local savePath = settingsDirectory .. "settings.xml"

    -- Fetch dynamic defaults based on game difficulty
    local defaultBase, defaultLiter = self:getDefaultIndices()

    if not fileExists(savePath) then
        self.current.deliveryBaseIndex = defaultBase
        self.current.deliveryLiterIndex = defaultLiter
        self.current.isDebugActive = false
        self.current.debugLevelIndex = 1
        self.current.debugDurationIndex = 1

        self:saveToXML()
        self:applyDebugSettings()

        GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[self.current.deliveryBaseIndex]
        GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[self.current.deliveryLiterIndex]
        return
    end

    local xmlFile = XMLFile.load("GlobalMarketSettingsXML", savePath)
    if xmlFile ~= nil then
        self.current.deliveryBaseIndex = xmlFile:getInt("globalMarketSettings#deliveryBaseIndex", defaultBase)
        self.current.deliveryLiterIndex = xmlFile:getInt("globalMarketSettings#deliveryLiterIndex", defaultLiter)

        -- Load Debug Settings
        self.current.isDebugActive = xmlFile:getBool("globalMarketSettings.debug#isActive", false)
        self.current.debugLevelIndex = xmlFile:getInt("globalMarketSettings.debug#levelIndex", 1)
        self.current.debugDurationIndex = xmlFile:getInt("globalMarketSettings.debug#durationIndex", 1)

        -- Apply to active global variables and modules
        GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[self.current.deliveryBaseIndex]
        GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[self.current.deliveryLiterIndex]

        self:applyDebugSettings()

        xmlFile:delete()
        GlobalMarket.debugLog("GlobalMarketSettings: Loaded from XML.")
    end
end

function GlobalMarketSettings:saveToXML()
    createFolder(settingsDirectory)
    local savePath = settingsDirectory .. "settings.xml"

    local xmlFile = XMLFile.create("GlobalMarketSettingsXML", savePath, "globalMarketSettings")
    if xmlFile ~= nil then
        xmlFile:setInt("globalMarketSettings#deliveryBaseIndex", self.current.deliveryBaseIndex)
        xmlFile:setInt("globalMarketSettings#deliveryLiterIndex", self.current.deliveryLiterIndex)

        -- Save Debug Settings
        xmlFile:setBool("globalMarketSettings.debug#isActive", self.current.isDebugActive)
        xmlFile:setInt("globalMarketSettings.debug#levelIndex", self.current.debugLevelIndex)
        xmlFile:setInt("globalMarketSettings.debug#durationIndex", self.current.debugDurationIndex)

        xmlFile:save()
        xmlFile:delete()

        GlobalMarket.debugLog("GlobalMarketSettings: Saved to XML.")
    end
end

-- ============================================================================
-- UI Menu Injection (Dynamic Element Instantiation)
-- ============================================================================

function GlobalMarketSettings:addSectionHeader(settingsFrame)
    local textElement = TextElement.new()
    local textElementProfile = g_gui:getProfile("fs25_settingsSectionHeader")

    textElement.name = "sectionHeader"
    textElement:loadProfile(textElementProfile, true)
    textElement:setText(g_i18n:getText("ui_gm_settings_header") or "GLOBAL MARKET SETTINGS")

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

-- Re-engineered function for the native FS25 Binary Option (Yes/No | On/Off toggle)
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
        GlobalMarketSettings:addSectionHeader(settingsFrame)

        -- Format texts for UI display
        local baseTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_BASE) do table.insert(baseTexts, tostring(val) .. " €") end

        local literTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_LITER) do table.insert(literTexts, tostring(val) .. " € / L") end

        -- Inject Existing Options
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsBaseCost", "ui_gm_settings_baseCost", "ui_gm_settings_baseCost_desc", baseTexts, "onBaseCostChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsLiterCost", "ui_gm_settings_literCost", "ui_gm_settings_literCost_desc", literTexts, "onLiterCostChanged")

        -- Inject New Debug Options (Using the accurate FS25 binary option for master switch)
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

    -- Debug Controls and Dependency Logic (Method A: Disabled States)
    local isDebugOn = GlobalMarketSettings.current.isDebugActive
    local isDeepLoggingLevel = (GlobalMarketSettings.current.debugLevelIndex >= 4)

    local modeControl = GlobalMarketSettings.CONTROLS["gmSettingsDebugMode"]
    if modeControl ~= nil then
        -- BinaryOptions in FS25 use states (1 = Off, 2 = On) instead of setIsChecked
        modeControl:setState(isDebugOn and 2 or 1)
        modeControl:setDisabled(not isAdmin)
    end

    local levelControl = GlobalMarketSettings.CONTROLS["gmSettingsDebugLevel"]
    if levelControl ~= nil then
        levelControl:setState(GlobalMarketSettings.current.debugLevelIndex)
        -- Disable if not admin or master switch is OFF
        levelControl:setDisabled(not isAdmin or not isDebugOn)
    end

    local durationControl = GlobalMarketSettings.CONTROLS["gmSettingsDebugDuration"]
    if durationControl ~= nil then
        durationControl:setState(GlobalMarketSettings.current.debugDurationIndex)
        -- Disable if not admin, master switch is OFF, or level is below 'Debug'
        durationControl:setDisabled(not isAdmin or not isDebugOn or not isDeepLoggingLevel)
    end
end

-- ============================================================================
-- Callbacks
-- ============================================================================

function GlobalMarketSettings:onBaseCostChanged(state)
    self.current.deliveryBaseIndex = state
    GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[state]
    self:saveToXML()
end

function GlobalMarketSettings:onLiterCostChanged(state)
    self.current.deliveryLiterIndex = state
    GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[state]
    self:saveToXML()
end

function GlobalMarketSettings:onDebugModeChanged(state)
    -- The callback returns an integer (1 = Off, 2 = On). We convert it to a boolean.
    self.current.isDebugActive = (state == 2) 
    self:applyDebugSettings()
    self:saveToXML()
    self.refreshMenuState() -- Force UI refresh to update disabled states dynamically
end

function GlobalMarketSettings:onDebugLevelChanged(state)
    self.current.debugLevelIndex = state
    self:applyDebugSettings()
    self:saveToXML()
    self.refreshMenuState() -- Force UI refresh to update disabled states dynamically
end

function GlobalMarketSettings:onDebugDurationChanged(state)
    self.current.debugDurationIndex = state
    self:applyDebugSettings()
    self:saveToXML()
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
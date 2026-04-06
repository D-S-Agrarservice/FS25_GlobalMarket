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
    DELIVERY_LITER = {0.0, 0.01, 0.02, 0.05, 0.10, 0.20}
}

-- Default values
GlobalMarketSettings.current = {
    deliveryBaseIndex = 4, -- Default: 50
    deliveryLiterIndex = 4 -- Default: 0.05
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
        self:saveToXML()

        GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[self.current.deliveryBaseIndex]
        GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[self.current.deliveryLiterIndex]
        return
    end

    local xmlFile = XMLFile.load("GlobalMarketSettingsXML", savePath)
    if xmlFile ~= nil then
        self.current.deliveryBaseIndex = xmlFile:getInt("globalMarketSettings#deliveryBaseIndex", defaultBase)
        self.current.deliveryLiterIndex = xmlFile:getInt("globalMarketSettings#deliveryLiterIndex", defaultLiter)

        -- Apply to active global variables
        GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[self.current.deliveryBaseIndex]
        GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[self.current.deliveryLiterIndex]

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

    textElement.name = "sectionHeader" -- WICHTIG: Verhindert, dass die Engine es als normale Zeile markiert
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
    multiTextOptionTooltip.name = "ignore" -- WICHTIG: Verhindert Fokus-Bugs im Unter-Element
    multiTextOptionTooltip:loadProfile(multiTextOptionTooltipProfile, true)
    multiTextOptionTooltip:setText(g_i18n:getText(tooltipKey))

    -- Assemble elements
    multiTextOption:addElement(multiTextOptionTooltip)
    bitMap:addElement(multiTextOption)
    bitMap:addElement(multiTextOptionTitle)

    -- Finalize UI setup
    multiTextOption:onGuiSetupFinished()
    multiTextOptionTitle:onGuiSetupFinished()
    multiTextOptionTooltip:onGuiSetupFinished()

    settingsFrame.gameSettingsLayout:addElement(bitMap)
    bitMap:onGuiSetupFinished()

    -- Store reference for state updates
    GlobalMarketSettings.CONTROLS[controlId] = multiTextOption

    return multiTextOption, bitMap
end

function GlobalMarketSettings.onFrameOpen(settingsFrame)
    if not GlobalMarketSettings.isMenuInjected then
        GlobalMarketSettings:addSectionHeader(settingsFrame)

        -- Format options for UI display
        local baseTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_BASE) do table.insert(baseTexts, tostring(val) .. " €") end

        local literTexts = {}
        for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_LITER) do table.insert(literTexts, tostring(val) .. " € / L") end

        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsBaseCost", "ui_gm_settings_baseCost", "ui_gm_settings_baseCost_desc", baseTexts, "onBaseCostChanged")
        GlobalMarketSettings:addMultiOption(settingsFrame, "gmSettingsLiterCost", "ui_gm_settings_literCost", "ui_gm_settings_literCost_desc", literTexts, "onLiterCostChanged")

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
end

-- ============================================================================
-- Callbacks
-- ============================================================================

function GlobalMarketSettings:onBaseCostChanged(state)
    self.current.deliveryBaseIndex = state
    GlobalMarket.DELIVER_COST = self.OPTIONS.DELIVERY_BASE[state]
    self:saveToXML()
    -- Note: Sync Event to clients will be triggered here later
end

function GlobalMarketSettings:onLiterCostChanged(state)
    self.current.deliveryLiterIndex = state
    GlobalMarket.DELIVER_COST_PERLITER = self.OPTIONS.DELIVERY_LITER[state]
    self:saveToXML()
    -- Note: Sync Event to clients will be triggered here later
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
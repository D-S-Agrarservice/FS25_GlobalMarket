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
-- UI Menu Injection
-- ============================================================================

function GlobalMarketSettings.updateFocusIds(element)
    if element == nil then return end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        GlobalMarketSettings.updateFocusIds(child)
    end
end

function GlobalMarketSettings.getSettingsPage()
    local inGameMenu = g_gui ~= nil and g_gui.screenControllers[InGameMenu] or nil
    if inGameMenu == nil then return nil, nil end
    local settingsPage = inGameMenu.pageSettings
    return settingsPage, settingsPage and settingsPage.generalSettingsLayout or nil
end

function GlobalMarketSettings.addSectionHeader(settingsPage, settingsLayout)
    local sectionTitle = nil
    for _, elem in ipairs(settingsLayout.elements) do
        if elem.name == "sectionHeader" then
            sectionTitle = elem:clone(settingsLayout)
            break
        end
    end

    if sectionTitle ~= nil then
        sectionTitle.id = "gmSettingsSectionHeader"
        -- Use l10n for the section title
        sectionTitle:setText(g_i18n:getText("ui_gm_settings_header") or "GLOBAL MARKET SETTINGS")
        sectionTitle.focusId = FocusManager:serveAutoFocusId()
        table.insert(settingsPage.controlsList, sectionTitle)
        GlobalMarketSettings.CONTROLS[sectionTitle.id] = sectionTitle
    end
end

-- Clones a multi-state option dynamically by finding a suitable template
-- Clones a multi-state option dynamically by finding a suitable template
function GlobalMarketSettings.addMultiOption(settingsPage, settingsLayout, controlId, titleKey, tooltipKey, texts, callbackName)
    -- Find a valid Multi-Option template dynamically
    local original = nil
    for _, elem in ipairs(settingsLayout.elements) do
        -- We specifically look for a true MultiTextOptionElement (like the volume slider)
        if elem.elements ~= nil and elem.elements[1] ~= nil then
            if elem.elements[1]:isa(MultiTextOptionElement) then
                original = elem
                break
            end
        end
    end

    if original == nil then 
        GlobalMarket.debugLog("ERROR: Could not find a suitable MultiTextOptionElement template to clone!")
        return nil 
    end

    local menuOptionBox = original:clone(settingsLayout)
    menuOptionBox.id = controlId .. "Box"

    local menuOption = menuOptionBox.elements[1]
    menuOption.target = GlobalMarketSettings
    menuOption.id = controlId
    menuOption:setTexts(texts)
    menuOption:setCallback("onClickCallback", callbackName)

    -- Safe Admin/SP check (Host or MasterUser)
    local isAdmin = false
    if g_currentMission ~= nil then
        isAdmin = g_currentMission:getIsServer() or g_currentMission.isMasterUser
    end
    menuOption:setDisabled(not isAdmin)

    local toolTip = menuOption.elements[1]
    if toolTip ~= nil and type(toolTip.setText) == "function" then
        toolTip:setText(g_i18n:getText(tooltipKey))
    end

    local settingTitle = menuOptionBox.elements[2]
    if settingTitle ~= nil and type(settingTitle.setText) == "function" then
        settingTitle:setText(g_i18n:getText(titleKey))
    end

    GlobalMarketSettings.updateFocusIds(menuOptionBox)
    table.insert(settingsPage.controlsList, menuOptionBox)
    GlobalMarketSettings.CONTROLS[controlId] = menuOption

    return menuOption
end

function GlobalMarketSettings.ensureMenuInjected()
    if GlobalMarketSettings.isMenuInjected then return end

    local settingsPage, settingsLayout = GlobalMarketSettings.getSettingsPage()
    if settingsPage == nil or settingsLayout == nil then return end

    GlobalMarketSettings.addSectionHeader(settingsPage, settingsLayout)

    -- Format options for UI display
    local baseTexts = {}
    for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_BASE) do table.insert(baseTexts, tostring(val) .. " €") end
    
    local literTexts = {}
    for _, val in ipairs(GlobalMarketSettings.OPTIONS.DELIVERY_LITER) do table.insert(literTexts, tostring(val) .. " € / L") end

    GlobalMarketSettings.addMultiOption(settingsPage, settingsLayout, "gmSettingsBaseCost", "ui_gm_settings_baseCost", "ui_gm_settings_baseCost_desc", baseTexts, "onBaseCostChanged")
    GlobalMarketSettings.addMultiOption(settingsPage, settingsLayout, "gmSettingsLiterCost", "ui_gm_settings_literCost", "ui_gm_settings_literCost_desc", literTexts, "onLiterCostChanged")

    settingsLayout:invalidateLayout()
    GlobalMarketSettings.isMenuInjected = true
end

function GlobalMarketSettings.refreshMenuState()
    GlobalMarketSettings.ensureMenuInjected()

    local baseControl = GlobalMarketSettings.CONTROLS["gmSettingsBaseCost"]
    if baseControl ~= nil then
        baseControl:setState(GlobalMarketSettings.current.deliveryBaseIndex)
        baseControl:setDisabled(not g_currentMission.isMasterUser)
    end

    local literControl = GlobalMarketSettings.CONTROLS["gmSettingsLiterCost"]
    if literControl ~= nil then
        literControl:setState(GlobalMarketSettings.current.deliveryLiterIndex)
        literControl:setDisabled(not g_currentMission.isMasterUser)
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
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, GlobalMarketSettings.refreshMenuState)
    end

    FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
        if gui == "ingameMenuSettings" then
            GlobalMarketSettings.ensureMenuInjected()
            for _, control in pairs(GlobalMarketSettings.CONTROLS) do
                if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
                    FocusManager:loadElementFromCustomValues(control, nil, nil, false, false)
                end
            end
            local settingsPage = g_gui.screenControllers[InGameMenu].pageSettings
            if settingsPage ~= nil and settingsPage.generalSettingsLayout ~= nil then
                settingsPage.generalSettingsLayout:invalidateLayout()
            end
        end
    end)
end

initHooks()
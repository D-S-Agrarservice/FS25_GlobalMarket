-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketSettingsDialog.lua
-- Own GlobalMarket settings page (#40): a dialog with all options in sections, opened from the
-- market menu (spot market footer button, gear button in the header). Admin options are
-- visible to everybody but only editable by admins; personal options are editable by all.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketSettingsDialog = {}
local GlobalMarketSettingsDialog_mt = Class(GlobalMarketSettingsDialog, YesNoDialog)

function GlobalMarketSettingsDialog.new(target, custom_mt)
    return YesNoDialog.new(target, custom_mt or GlobalMarketSettingsDialog_mt)
end

---Opens the settings dialog
function GlobalMarketSettingsDialog.show()
    if g_gui ~= nil then
        g_gui:showDialog("GlobalMarketSettingsDialog")
    end
end

---Gear button in the market menu header and spot market footer button
function GlobalMarketUI:onClickGmSettings()
    GlobalMarketSettingsDialog.show()
end

function GlobalMarketSettingsDialog:onOpen()
    GlobalMarketSettingsDialog:superClass().onOpen(self)
    if self.settingsLayout ~= nil then
        GlobalMarketSettings.buildMenu(self.settingsLayout)
        self.settingsLayout:invalidateLayout()
        local first = GlobalMarketSettings.CONTROLS["gmSettingsBaseCost"]
        if first ~= nil then
            FocusManager:setFocus(first)
        end
    end
end

function GlobalMarketSettingsDialog:onClickBack()
    GlobalMarketSettingsDialog:superClass().onClickBack(self)
    self:close()
    return false
end

---Alternating row backgrounds like the basegame settings page (restart after each section header)
---@param layout table
function GlobalMarketSettings.updateAlternatingRows(layout)
    local colors = (InGameMenuSettingsFrame ~= nil) and InGameMenuSettingsFrame.COLOR_ALTERNATING or nil
    if colors ~= nil then
        local isAlternate = true
        for _, container in pairs(layout.elements) do
            if container.name == "sectionHeader" then
                isAlternate = true
            elseif container.visible and container.setImageColor ~= nil then
                container:setImageColor(nil, unpack(colors[isAlternate]))
                isAlternate = not isAlternate
            end
        end
    end
    layout:invalidateLayout()
end

-- =========================================================================
-- OPTION ROWS (basegame settings profiles, built once into the dialog layout)
-- =========================================================================

function GlobalMarketSettings:addSectionHeader(layout, titleKey)
    local textElement = TextElement.new()
    local textElementProfile = g_gui:getProfile("fs25_settingsSectionHeader")

    textElement.name = "sectionHeader"
    textElement:loadProfile(textElementProfile, true)
    textElement:setText(g_i18n:getText(titleKey) or titleKey)

    layout:addElement(textElement)
    textElement:onGuiSetupFinished()
end

function GlobalMarketSettings:addMultiOption(layout, controlId, titleKey, tooltipKey, texts, callbackName)
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
    local multiTextOptionTooltipProfile = g_gui:getProfile("globalMarketSettingsTooltip")
    multiTextOptionTooltip.name = "ignore"
    multiTextOptionTooltip:loadProfile(multiTextOptionTooltipProfile, true)
    multiTextOptionTooltip:setText(g_i18n:getText(tooltipKey))

    multiTextOption:addElement(multiTextOptionTooltip)
    bitMap:addElement(multiTextOption)
    bitMap:addElement(multiTextOptionTitle)

    multiTextOption:onGuiSetupFinished()
    multiTextOptionTitle:onGuiSetupFinished()
    multiTextOptionTooltip:onGuiSetupFinished()

    layout:addElement(bitMap)
    bitMap:onGuiSetupFinished()

    GlobalMarketSettings.CONTROLS[controlId] = multiTextOption
    return multiTextOption, bitMap
end

function GlobalMarketSettings:addBinaryOption(layout, controlId, titleKey, tooltipKey, callbackName)
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
    local binaryOptionTooltipProfile = g_gui:getProfile("globalMarketSettingsTooltip")
    binaryOptionTooltip.name = "ignore"
    binaryOptionTooltip:loadProfile(binaryOptionTooltipProfile, true)
    binaryOptionTooltip:setText(g_i18n:getText(tooltipKey))

    binaryOption:addElement(binaryOptionTooltip)
    bitMap:addElement(binaryOption)
    bitMap:addElement(binaryOptionTitle)

    binaryOption:onGuiSetupFinished()
    binaryOptionTitle:onGuiSetupFinished()
    binaryOptionTooltip:onGuiSetupFinished()

    layout:addElement(bitMap)
    bitMap:onGuiSetupFinished()

    GlobalMarketSettings.CONTROLS[controlId] = binaryOption
    return binaryOption, bitMap
end

---Builds all option rows into the dialog layout (once) and applies the current values
---@param layout table ScrollingLayout of GlobalMarketSettingsDialog
function GlobalMarketSettings.buildMenu(layout)
    if not GlobalMarketSettings.isMenuInjected then
        GlobalMarketSettings:addSectionHeader(layout, "ui_gm_settings_sec_market")

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
        GlobalMarketSettings:addMultiOption(layout, "gmSettingsBaseCost", "ui_gm_settings_baseCost", "ui_gm_settings_baseCost_desc", baseTexts, "onBaseCostChanged")
        GlobalMarketSettings:addMultiOption(layout, "gmSettingsLiterCost", "ui_gm_settings_literCost", "ui_gm_settings_literCost_desc", literTexts, "onLiterCostChanged")
        GlobalMarketSettings:addMultiOption(layout, "gmSettingsDealerMarkup", "ui_gm_settings_markup", "ui_gm_settings_markup_desc", markupTexts, "onDealerMarkupChanged")
        GlobalMarketSettings:addMultiOption(layout, "gmSettingsCapacity", "ui_gm_settings_capacity", "ui_gm_settings_capacity_desc", capacityTexts, "onCapacityChanged")

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
        GlobalMarketSettings:addMultiOption(layout, "gmSettingsStorageDecay", "ui_gm_settings_storageDecay", "ui_gm_settings_storageDecay_desc", decayTexts, "onStorageDecayChanged")

        local gdModeTexts = {
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_gd_scarcity")) and g_i18n:getText("ui_gm_settings_gd_scarcity") or "Stock-based",
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_gd_random")) and g_i18n:getText("ui_gm_settings_gd_random") or "Random",
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_gd_off")) and g_i18n:getText("ui_gm_settings_gd_off") or "Off"
        }
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsGreatDemandMode", "ui_gm_settings_greatDemandMode",
            "ui_gm_settings_greatDemandMode_desc", gdModeTexts, "onGreatDemandModeChanged"
        )

        GlobalMarketSettings:addSectionHeader(layout, "ui_gm_settings_sec_contracts")
        local npcModeTexts = {
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_npc_all")) and g_i18n:getText("ui_gm_settings_npc_all") or "All",
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_npc_contracts")) and g_i18n:getText("ui_gm_settings_npc_contracts") or "Contracts Only",
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_npc_players")) and g_i18n:getText("ui_gm_settings_npc_players") or "Players Only"
        }
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsNpcActivityMode", "ui_gm_settings_npcActivity",
            "ui_gm_settings_npcActivity_desc", npcModeTexts, "onNpcActivityModeChanged"
        )

        local ocModeTexts = {
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_oc_all")) and g_i18n:getText("ui_gm_settings_oc_all") or "All (Contracts & Offers)",
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_oc_contracts")) and g_i18n:getText("ui_gm_settings_oc_contracts") or "Supply Contracts Only",
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_oc_offers")) and g_i18n:getText("ui_gm_settings_oc_offers") or "Direct Offers Only",
            (g_i18n ~= nil and g_i18n:hasText("ui_gm_settings_oc_local")) and g_i18n:getText("ui_gm_settings_oc_local") or "Local Only"
        }
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsOnlineContractsMode", "ui_gm_settings_onlineContracts",
            "ui_gm_settings_onlineContracts_desc", ocModeTexts, "onOnlineContractsModeChanged"
        )

        -- Contract board limits (#26)
        local limitOffText = g_i18n:getText("ui_gm_settings_decay_off")
        if limitOffText == nil or limitOffText == "ui_gm_settings_decay_off" then limitOffText = "Off" end
        local function buildLimitTexts(values)
            local texts = {}
            for _, val in ipairs(values) do
                table.insert(texts, (val <= 0) and limitOffText or tostring(val))
            end
            return texts
        end
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsMaxFarmContracts", "ui_gm_settings_maxFarmContracts",
            "ui_gm_settings_maxFarmContracts_desc", buildLimitTexts(GlobalMarketSettings.OPTIONS.MAX_FARM_CONTRACTS), "onMaxFarmContractsChanged"
        )
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsNpcContractsTarget", "ui_gm_settings_npcContractsTarget",
            "ui_gm_settings_npcContractsTarget_desc", buildLimitTexts(GlobalMarketSettings.OPTIONS.NPC_CONTRACTS_TARGET), "onNpcContractsTargetChanged"
        )
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsNpcOffersTarget", "ui_gm_settings_npcOffersTarget",
            "ui_gm_settings_npcOffersTarget_desc", buildLimitTexts(GlobalMarketSettings.OPTIONS.NPC_OFFERS_TARGET), "onNpcOffersTargetChanged"
        )
        GlobalMarketSettings:addSectionHeader(layout, "ui_gm_settings_sec_marketplace")
        -- Used vehicle market (#16)
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsVehicleNpcMode", "ui_gm_settings_vehicleNpc", "ui_gm_settings_vehicleNpc_desc",
            { g_i18n:getText("ui_gm_settings_vehicleNpc_off"), g_i18n:getText("ui_gm_settings_vehicleNpc_low"),
                g_i18n:getText("ui_gm_settings_vehicleNpc_normal") }, "onVehicleNpcModeChanged"
        )
        -- Cross-server vehicle market (#36)
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsVehicleOnlineMode", "ui_gm_settings_vehicleOnline", "ui_gm_settings_vehicleOnline_desc",
            { g_i18n:getText("ui_gm_settings_vehicleNpc_off"), g_i18n:getText("ui_gm_settings_vehicleOnline_on") }, "onVehicleOnlineModeChanged"
        )
        -- Livestock market (#15)
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsAnimalNpcMode", "ui_gm_settings_animalNpc", "ui_gm_settings_animalNpc_desc",
            { g_i18n:getText("ui_gm_settings_vehicleNpc_off"), g_i18n:getText("ui_gm_settings_vehicleNpc_low"),
                g_i18n:getText("ui_gm_settings_vehicleNpc_normal") }, "onAnimalNpcModeChanged"
        )

        -- Personal options (local, never synced)
        GlobalMarketSettings:addSectionHeader(layout, "ui_gm_settings_sec_display")
        GlobalMarketSettings:addBinaryOption(layout, "gmSettingsDetailedFinance", "ui_gm_settings_detailedFinance", "ui_gm_settings_detailedFinance_desc", "onDetailedFinanceChanged")
        GlobalMarketSettings:addBinaryOption(layout, "gmSettingsShowIcon", "ui_gm_settings_showIcon", "ui_gm_settings_showIcon_desc", "onShowIconChanged")
        GlobalMarketSettings:addBinaryOption(layout, "gmSettingsIconPulse", "ui_gm_settings_iconPulse", "ui_gm_settings_iconPulse_desc", "onIconPulseChanged")
        GlobalMarketSettings:addBinaryOption(layout, "gmSettingsVehicleNotices", "ui_gm_settings_vehicleNotices", "ui_gm_settings_vehicleNotices_desc", "onVehicleNoticesChanged")

        -- Compatibility & debug (admin)
        GlobalMarketSettings:addSectionHeader(layout, "ui_gm_settings_system_header")
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsCompatMode", "ui_gm_settings_compatMode",
            "ui_gm_settings_compatMode_desc", GlobalMarketSettings.OPTIONS.COMPAT_MODE, "onCompatModeChanged"
        )

        -- 4. DEBUG MODE
        GlobalMarketSettings:addBinaryOption(layout, "gmSettingsDebugMode", "ui_gm_settings_debugMode", "ui_gm_settings_debugMode_desc", "onDebugModeChanged")
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsDebugLevel", "ui_gm_settings_debugLevel",
            "ui_gm_settings_debugLevel_desc", GlobalMarketSettings.OPTIONS.DEBUG_LEVEL, "onDebugLevelChanged"
        )
        GlobalMarketSettings:addMultiOption(
            layout, "gmSettingsDebugDuration", "ui_gm_settings_debugDuration",
            "ui_gm_settings_debugDuration_desc", GlobalMarketSettings.OPTIONS.DEBUG_DURATION, "onDebugDurationChanged"
        )

        GlobalMarketSettings.updateAlternatingRows(layout)
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
    local gdModeControl = GlobalMarketSettings.CONTROLS["gmSettingsGreatDemandMode"]
    if gdModeControl ~= nil then
        gdModeControl:setState(GlobalMarketSettings.current.greatDemandModeIndex or 1)
        gdModeControl:setDisabled(not isAdmin)
    end
    local npcModeControl = GlobalMarketSettings.CONTROLS["gmSettingsNpcActivityMode"]
    if npcModeControl ~= nil then
        npcModeControl:setState(GlobalMarketSettings.current.npcActivityModeIndex or 1)
        npcModeControl:setDisabled(not isAdmin)
    end
    local ocModeControl = GlobalMarketSettings.CONTROLS["gmSettingsOnlineContractsMode"]
    if ocModeControl ~= nil then
        ocModeControl:setState(GlobalMarketSettings.current.onlineContractsModeIndex or 1)
        ocModeControl:setDisabled(not isAdmin)
    end
    local limitControls = {
        {"gmSettingsMaxFarmContracts", "maxFarmContractsIndex"},
        {"gmSettingsNpcContractsTarget", "npcContractsTargetIndex"},
        {"gmSettingsNpcOffersTarget", "npcOffersTargetIndex"},
        {"gmSettingsVehicleNpcMode", "vehicleNpcModeIndex"},
        {"gmSettingsVehicleOnlineMode", "vehicleOnlineModeIndex"},
        {"gmSettingsAnimalNpcMode", "animalNpcModeIndex"}
    }
    for _, entry in ipairs(limitControls) do
        local limitControl = GlobalMarketSettings.CONTROLS[entry[1]]
        if limitControl ~= nil then
            limitControl:setState(GlobalMarketSettings.current[entry[2]] or 3)
            limitControl:setDisabled(not isAdmin)
        end
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

    local vehicleNoticesControl = GlobalMarketSettings.CONTROLS["gmSettingsVehicleNotices"]
    if vehicleNoticesControl ~= nil then
        vehicleNoticesControl:setState(GlobalMarketSettings.current.showVehicleNotices ~= false and 2 or 1)
        vehicleNoticesControl:setDisabled(false)
    end

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

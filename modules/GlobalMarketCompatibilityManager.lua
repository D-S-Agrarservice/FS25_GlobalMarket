--
-- FS25 - GlobalMarket Compatibility Manager
-- Description: Handles dynamic conflict resolution via an updatable XML in the modSettings folder.
-- Includes dynamic firewalls for invasive third-party mods.
--

GMCompatibilityManager = {}
local GMCompatibilityManager_mt = Class(GMCompatibilityManager)

function GMCompatibilityManager.new(customMt)
    local self = setmetatable({}, customMt or GMCompatibilityManager_mt)

    -- The current version of our conflict list (used for network sync)
    self.version = "1.0.0"

    -- Lookup table for parsed conflicts: modName -> action
    self.conflicts = {}

    -- Internal states that other GM modules will read to adjust their behavior
    self.states = {
        isSiloUiDisabled = false,
        isEconomyHookDisabled = false,
        fatalConflictMod = nil -- Stores the name of the incompatible mod for the Strict-Mode kick
    }

    -- Set up directory paths (same logic as GlobalMarketSettings)
    self.modName = g_currentModName or "FS25_GlobalMarket"
    self.directory = string.format("%smodSettings/%s/", getUserProfileAppPath(), self.modName)
    self.filePath = self.directory .. "compatibility.xml"

    return self
end

--- Generates a default compatibility.xml with instructional comments and base fixes.
function GMCompatibilityManager:generateDefaultXML()
    createFolder(self.directory)

    -- Open file for writing natively to preserve formatting and comments
    local file = io.open(self.filePath, "w")
    if file ~= nil then
        local template = [[<?xml version="1.0" encoding="utf-8"?>
<compatibility version="1.0.0">
    <mod name="FS25_InfoDisplayExtension" action="block_game" />
</compatibility>]]

        file:write(template)
        file:close()

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("[Compatibility] Generated default template with IDE fix at: %s", self.filePath)
        end
    else
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:error("[Compatibility] Failed to generate default XML. Permission denied at: %s", self.filePath)
        end
    end
end

--- Loads the compatibility definitions from the local modSettings XML file.
function GMCompatibilityManager:loadFromXML()
    -- If the file doesn't exist, create our commented template first
    if not fileExists(self.filePath) then
        self:generateDefaultXML()
    end

    -- Now proceed to load the (newly created or existing) file normally
    local xmlFile = XMLFile.load("GMCompatXML", self.filePath)
    if xmlFile == nil then
        return false
    end

    -- Read root version parameter (Using getString bypasses schema validation)
    self.version = xmlFile:getString("compatibility#version", "1.0.0")

    -- Clear existing list before parsing
    self.conflicts = {}

    -- Iterate over all defined mods
    for _, modKey in xmlFile:iterator("compatibility.mod") do
        local modName = xmlFile:getString(modKey .. "#name")

        if modName ~= nil and modName ~= "" then
            self.conflicts[modName] = {
                action = xmlFile:getString(modKey .. "#action", "log_only")
            }
        end
    end

    xmlFile:delete()

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info("[Compatibility] Loaded XML version %s with %d entries.", self.version, self:getConflictCount())
    end

    return true
end

--- Validates currently loaded mods against the conflict list.
-- @return boolean true if at least one conflicting mod is active
function GMCompatibilityManager:checkActiveMods()
    local hasActiveConflicts = false

    -- Reset states to default before evaluation
    self.states.isSiloUiDisabled = false
    self.states.isEconomyHookDisabled = false
    self.states.fatalConflictMod = nil

    -- Safety check for Giants ModManager table
    if g_modIsLoaded == nil then
        return false
    end

    -- 1: Ignore | 2: Warn Only | 3: Smart | 4: Paranoia
    local compatMode = 3
    if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil then
        compatMode = GlobalMarketSettings.current.compatModeIndex
    end

    -- Mode 1: Ignore completely
    if compatMode == 1 then
        return false
    end

    for modName, data in pairs(self.conflicts) do
        if g_modIsLoaded[modName] then
            hasActiveConflicts = true
            local action = data.action

            -- Bypass for mods with known, hardcoded firewalls (e.g., IDE)
            if modName == "FS25_InfoDisplayExtension" then
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:info("[Compatibility] IDE detected. Bypassing XML action, handled by native GM Firewall.")
                end
            else
                -- Handle unknown or other conflicting mods based on mode
                if compatMode == 2 then
                    -- Mode 2: Warn Only (Console Log)
                    if GlobalMarket.debugManager ~= nil then
                        GlobalMarket.debugManager:warning("[Compatibility] Conflict ignored: %s (Action: %s)", modName, action)
                    end

                elseif compatMode == 3 then
                    -- Mode 3: Smart Mode (Downgrade fatal blocks to prevent lockouts)
                    if action == "block_game" then
                        if GlobalMarket.debugManager ~= nil then
                            GlobalMarket.debugManager:warning("[Compatibility] SMART MODE: Prevented fatal kick for '%s'. Mod might cause UI issues.", modName)
                        end
                        -- DYNAMIC WARNING: Push a blinking warning to the player in-game using l10n
                        if g_currentMission ~= nil then
                            -- Fallback text just in case the l10n key is missing
                            local fallbackText = "GlobalMarket Warning: Mod '%s' might cause conflicts!"
                            local l10nText = g_i18n:hasText("ui_gm_warning_smart_conflict") and g_i18n:getText("ui_gm_warning_smart_conflict") or fallbackText

                            local warnText = string.format(l10nText, modName)
                            g_currentMission:showBlinkingWarning(warnText, 5000)
                        end
                    else
                        -- Apply safe mitigations (like disable_silo_ui)
                        self:applyMitigation(modName, action)
                    end

                elseif compatMode == 4 then
                    -- Mode 4: Paranoia (Execute exactly as the XML dictates)
                    self:applyMitigation(modName, action)
                end
            end
        end
    end

    -- Deploy native firewalls ONLY in Smart (3) or Paranoia (4) mode
    if compatMode >= 3 then
        self:installFirewalls()
    end

    return hasActiveConflicts
end

--- Executes the mitigation strategy by setting the internal state flags.
-- @param string modName Name of the conflicting mod
-- @param string action The mitigation action defined in the XML
function GMCompatibilityManager:applyMitigation(modName, action)
    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:warning("[Compatibility] Conflicting mod detected: %s. Applying mitigation: %s", modName, action)
    end

    if action == "disable_silo_ui" then
        self.states.isSiloUiDisabled = true
    elseif action == "disable_economy_hook" then
        self.states.isEconomyHookDisabled = true
    elseif action == "block_game" then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:error("[Compatibility] FATAL CONFLICT: %s. Game will be blocked.", modName)
        end
        self.states.fatalConflictMod = modName
    end
    -- Add more actions here as the mod grows
end

--- Kicks the player back to the main menu with a native UI dialog
function GMCompatibilityManager:triggerFatalStop()
    if self.states.fatalConflictMod ~= nil then
        local modName = self.states.fatalConflictMod

        -- Fetch text from l10n and insert the mod name
        local fallbackText = "FATAL CONFLICT: Mod '%s' is incompatible. Game will be blocked to prevent corruption."
        local l10nText = g_i18n:hasText("ui_gm_warning_fatal_conflict") and g_i18n:getText("ui_gm_warning_fatal_conflict") or fallbackText
        local text = string.format(l10nText, modName)

        -- Native Engine Dialog with callback to the main menu
        if g_gui ~= nil then
            g_gui:showDialog("MessageDialog", nil, nil, {
                text = text,
                title = g_i18n:getText("ui_warning") or "Warning",
                dialogType = DialogElement.TYPE_WARNING,
                buttonTexts = { g_i18n:getText("button_ok") or "OK" },
                callback = function()
                    -- This is the native engine command that handles the disconnect/leave (Kick to Menu)
                    g_currentMission:onLeaveGame()
                end
            })
        end
    end
end

--- Installs dynamic firewalls to protect GM components from invasive mods
function GMCompatibilityManager:installFirewalls()

    -- ========================================================
    -- FIREWALL: InfoDisplayExtension (IDE)
    -- ========================================================
    if g_modIsLoaded["FS25_InfoDisplayExtension"] then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("[Compatibility] InfoDisplayExtension detected. Installing instance-level UI firewall for GM objects.")
        end

        local function applyInstanceFirewall(placeable)
            if GlobalMarketAccess ~= nil and GlobalMarketAccess.applyGmPlaceableHooks ~= nil then
                GlobalMarketAccess.applyGmPlaceableHooks(placeable)
                return
            end

            if placeable.isGmMarket and placeable.updateInfo ~= nil then

                -- Prevent double-hooking if the user toggles settings multiple times
                if placeable.hasGmFirewall then
                    return
                end
                placeable.hasGmFirewall = true

                -- We save the original chain (which is currently infected by IDE)
                local originalUpdateInfo = placeable.updateInfo

                -- We override the instance to intercept the UI call
                placeable.updateInfo = function(self, infoTable)

                    -- A dummy function to satisfy the engine's internal superFunc chain
                    -- without accidentally triggering other UI mods again.
                    local dummySuperFunc = function(s, t) end

                    -- Bypass IDE entirely and call our saved, clean GM->Vanilla chain.
                    if self.spec_silo ~= nil and GlobalMarketAccess.cleanSiloUpdateInfo ~= nil then
                        GlobalMarketAccess.cleanSiloUpdateInfo(self, dummySuperFunc, infoTable)

                    elseif self.spec_objectStorage ~= nil and GlobalMarketAccess.cleanObjectStorageUpdateInfo ~= nil then
                        GlobalMarketAccess.cleanObjectStorageUpdateInfo(self, dummySuperFunc, infoTable)

                    else
                        -- Fallback for non-standard GM storages: Let the current chain (including IDE) run
                        if originalUpdateInfo ~= nil then
                            originalUpdateInfo(self, infoTable)
                        end
                    end
                end
            end
        end

        -- 1. Protect PlaceableSilo (InfoTrigger) & 3. Protect ObjectStorage
        -- We apply the firewall dynamically to all already loaded placeables
        if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
            for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                applyInstanceFirewall(placeable)
            end
        end

        -- Catch newly placed buildings during the session
        if Placeable ~= nil and Placeable.finalizePlacement ~= nil then
            Placeable.finalizePlacement = Utils.appendedFunction(Placeable.finalizePlacement, function(placeable)
                applyInstanceFirewall(placeable)
            end)
        end

        -- 2. Protect ProductionPoint
        if ProductionPoint ~= nil and type(ProductionPoint.updateInfo) == "function" then
            local function gmProdUpdateInfo(self, superFunc, infoTable)
                if self.isGmMarket then
                    return
                end

                if superFunc ~= nil then
                    superFunc(self, infoTable)
                end
            end

            ProductionPoint.updateInfo = Utils.overwrittenFunction(ProductionPoint.updateInfo, gmProdUpdateInfo)
        end
    end
end

--- Saves the current compatibility definitions to the local modSettings XML file.
-- Triggered on the Dedi-Server when receiving an update from an Admin.
function GMCompatibilityManager:saveToXML()
    createFolder(self.directory)

    local xmlFile = XMLFile.create("GMCompatXML", self.filePath, "compatibility")
    if xmlFile ~= nil then
        -- Using setString bypasses schema validation for saving
        xmlFile:setString("compatibility#version", self.version)

        local index = 0
        for modName, data in pairs(self.conflicts) do
            local key = string.format("compatibility.mod(%d)", index)
            xmlFile:setString(key .. "#name", modName)
            xmlFile:setString(key .. "#action", data.action)
            index = index + 1
        end

        xmlFile:save()
        xmlFile:delete()

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("[Compatibility] Saved updated list to server's modSettings XML.")
        end
    end
end

--- Utility: Returns the amount of parsed conflicts
function GMCompatibilityManager:getConflictCount()
    local count = 0
    for _ in pairs(self.conflicts) do
        count = count + 1
    end
    return count
end
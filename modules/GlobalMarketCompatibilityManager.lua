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

    -- Read root version parameter
    self.version = xmlFile:getValue("compatibility#version", "1.0.0")

    -- Clear existing list before parsing
    self.conflicts = {}

    -- Iterate over all defined mods
    for _, modKey in xmlFile:iterator("compatibility.mod") do
        local modName = xmlFile:getValue(modKey .. "#name")

        if modName ~= nil and modName ~= "" then
            self.conflicts[modName] = {
                action = xmlFile:getValue(modKey .. "#action", "log_only")
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
-- @return boolean true if at least one conflicting mod is active (useful for restart warnings)
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

    -- Get current compatibility mode from settings (Default to 3: Strict)
    local compatMode = 3
    if GlobalMarketSettings ~= nil and GlobalMarketSettings.current ~= nil then
        compatMode = GlobalMarketSettings.current.compatModeIndex
    end

    -- Mode 1: Ignore. Do absolutely nothing.
    if compatMode == 1 then
        return false
    end

    for modName, data in pairs(self.conflicts) do
        if g_modIsLoaded[modName] then

            -- Bypass for mods with hardcoded firewalls
            if modName == "FS25_InfoDisplayExtension" then
                if GlobalMarket.debugManager ~= nil then
                    GlobalMarket.debugManager:info("[Compatibility] IDE detected. Bypassing fatal stop, relying on Firewall.")
                end
            else
                if compatMode == 2 then
                    -- Mode 2: Warn Only
                    if GlobalMarket.debugManager ~= nil then
                        GlobalMarket.debugManager:warning("[Compatibility] Conflict detected with %s, but mode is 'Warn Only'. No mitigations applied.", modName)
                    end
                elseif compatMode == 3 then
                    -- Mode 3: Strict
                    self:applyMitigation(modName, data.action)
                end

                hasActiveConflicts = true
            end
        end
    end

    -- Deploy hardcoded dynamic firewalls ONLY if in Strict mode
    if compatMode == 3 then
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

--- Wirft den Spieler mit einem nativen UI-Dialog zurück ins Hauptmenü
function GMCompatibilityManager:triggerFatalStop()
    if self.states.fatalConflictMod ~= nil then
        local modName = self.states.fatalConflictMod

        -- Text aus der l10n holen und den Modnamen einfügen
        local text = string.format(g_i18n:getText("ui_gm_warning_fatal_conflict"), modName)

        -- Native Engine Dialog mit Callback zum Hauptmenü
        g_gui:showInfoDialog({
            text = text,
            dialogType = DialogElement.TYPE_WARNING,
            target = self,
            callback = function()
                -- Dies ist der Engine-Befehl, der das Spiel verlässt (Kick to Menu)
                g_currentMission:onLeaveGame()
            end
        })
    end
end

--- Installs dynamic firewalls to protect GM components from invasive mods
function GMCompatibilityManager:installFirewalls()

    -- ========================================================
    -- FIREWALL: InfoDisplayExtension (IDE)
    -- ========================================================
    if g_modIsLoaded["FS25_InfoDisplayExtension"] then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:warning("[Compatibility] InfoDisplayExtension detected. Installing instance-level UI firewall for GM objects.")
        end

        -- This function applies the ninja firewall to a specific building instance
        local function applyInstanceFirewall(placeable)
            -- Check if the building is flagged as GM and the updateInfo function exists
            if placeable.isGmMarket and placeable.updateInfo ~= nil then

                -- 1. Store the original class function (including IDE hooks)
                local originalUpdateInfo = placeable.updateInfo

                -- 2. Overwrite the function ONLY for THIS SINGLE building instance
                placeable.updateInfo = function(self, infoTable)

                    -- 3. Let IDE and Vanilla run first
                    if originalUpdateInfo ~= nil then
                        originalUpdateInfo(self, infoTable)
                    end

                    -- 4. Clear the table! Everything written by IDE/Vanilla gets removed.
                    for i = #infoTable, 1, -1 do
                        infoTable[i] = nil
                    end

                    -- 5. Rebuild the GM display cleanly
                    if self.spec_silo ~= nil and self.spec_silo.loadingStation ~= nil then
                        local farmId = self:getOwnerFarmId()
                        for fillType, fillLevel in pairs(self.spec_silo.loadingStation:getAllFillLevels(farmId)) do
                            if fillLevel > 0.1 then
                                local fillTypeDesc = g_fillTypeManager:getFillTypeByIndex(fillType)
                                if fillTypeDesc ~= nil then
                                    table.insert(infoTable, {
                                        title = fillTypeDesc.title,
                                        text = g_i18n:formatVolume(fillLevel, 0)
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end

        -- STEP A: Apply firewall to all ALREADY LOADED buildings on the map
        -- Since we are in onFinishedLoading, the silos are already spawned in the world.
        if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
            for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
                applyInstanceFirewall(placeable)
            end
        end

        -- STEP B: Apply firewall to all NEWLY PLACED buildings (during the session)
        -- If the player buys a new GM storage in the shop, we intercept it here.
        if Placeable.onFinalizePlacement ~= nil then
            Placeable.onFinalizePlacement = Utils.appendedFunction(Placeable.onFinalizePlacement, function(placeable)
                applyInstanceFirewall(placeable)
            end)
        end
    end
end

--- Saves the current compatibility definitions to the local modSettings XML file.
-- Triggered on the Dedi-Server when receiving an update from an Admin.
function GMCompatibilityManager:saveToXML()
    createFolder(self.directory)

    local xmlFile = XMLFile.create("GMCompatXML", self.filePath, "compatibility")
    if xmlFile ~= nil then
        xmlFile:setValue("compatibility#version", self.version)

        local index = 0
        for modName, data in pairs(self.conflicts) do
            local key = string.format("compatibility.mod(%d)", index)
            xmlFile:setValue(key .. "#name", modName)
            xmlFile:setValue(key .. "#action", data.action)
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
--
-- FS25 - GlobalMarket Compatibility Manager
-- Description: Handles dynamic conflict resolution via an updatable XML in the modSettings folder.
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
        isEconomyHookDisabled = false
    }

    -- Set up directory paths (same logic as GlobalMarketSettings)
    self.modName = g_currentModName or "FS25_GlobalMarket"
    self.directory = string.format("%smodSettings/%s/", getUserProfileAppPath(), self.modName)
    self.filePath = self.directory .. "compatibility.xml"

    return self
end

--- Loads the compatibility definitions from the local modSettings XML file.
function GMCompatibilityManager:loadFromXML()
    if not fileExists(self.filePath) then
        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("[Compatibility] No local compatibility.xml found. Using empty baseline.")
        end
        return false
    end

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

    -- Safety check for Giants ModManager table
    if g_modIsLoaded == nil then
        return false
    end

    for modName, data in pairs(self.conflicts) do
        if g_modIsLoaded[modName] then
            self:applyMitigation(modName, data.action)
            hasActiveConflicts = true
        end
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
    end
    -- Add more actions here as the mod grows
end

--- Utility: Returns the amount of parsed conflicts
function GMCompatibilityManager:getConflictCount()
    local count = 0
    for _ in pairs(self.conflicts) do
        count = count + 1
    end
    return count
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
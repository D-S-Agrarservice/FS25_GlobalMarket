--
-- FS25 - GlobalMarket
-- Event: SyncGlobalMarketCompatibilityEvent
-- Description: Transmits the updated compatibility XML data from an Admin client to the Server.
--

SyncGlobalMarketCompatibilityEvent = {}
local SyncGlobalMarketCompatibilityEvent_mt = Class(SyncGlobalMarketCompatibilityEvent, Event)
InitEventClass(SyncGlobalMarketCompatibilityEvent, "SyncGlobalMarketCompatibilityEvent")

--- Empty constructor for the network stream receiver
function SyncGlobalMarketCompatibilityEvent.emptyNew()
    local self = Event.new(SyncGlobalMarketCompatibilityEvent_mt)
    return self
end

--- Constructor for the sender (Admin Client)
-- @param string version The version string of the local compatibility list
-- @param table conflicts The parsed conflicts table from the local XML
function SyncGlobalMarketCompatibilityEvent.new(version, conflicts)
    local self = SyncGlobalMarketCompatibilityEvent.emptyNew()

    self.version = version or "1.0.0"
    self.conflicts = conflicts or {}

    return self
end

--- Serializes data to be sent over the network
function SyncGlobalMarketCompatibilityEvent:writeStream(streamId, connection)
    -- Write version string
    streamWriteString(streamId, self.version)

    -- Count conflicts for the loop
    local count = 0
    for _ in pairs(self.conflicts) do count = count + 1 end

    -- Write number of conflicts
    streamWriteInt32(streamId, count)

    -- Write conflict data
    for modName, data in pairs(self.conflicts) do
        streamWriteString(streamId, modName)
        streamWriteString(streamId, data.action)
    end
end

--- Deserializes data received from the network
function SyncGlobalMarketCompatibilityEvent:readStream(streamId, connection)
    self.version = streamReadString(streamId)
    self.conflicts = {}

    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local modName = streamReadString(streamId)
        local action = streamReadString(streamId)

        self.conflicts[modName] = {
            action = action
        }
    end

    self:run(connection)
end

--- Executes the event logic (Server-Side)
function SyncGlobalMarketCompatibilityEvent:run(connection)
    -- Security: Only execute on the server (receiving from a client)
    if not connection:getIsServer() then
        local user = g_currentMission.userManager:getUserByConnection(connection)

        -- Double check if the sender is actually an admin/master user
        if user ~= nil and user.isMasterUser then
            local manager = GlobalMarket.compatibilityManager

            if manager ~= nil then
                -- Compare version strings natively using FS25 Utils
                -- Returns 1 if self.version > manager.version
                local versionCheck = Utils.compareVersionStrings(self.version, manager.version)

                if versionCheck == 1 then
                    if GlobalMarket.debugManager ~= nil then
                        GlobalMarket.debugManager:info("[Compatibility] Server received newer XML version (%s) from Admin %s. Updating...", self.version, user.nickname)
                    end

                    -- Inject new data into the server's manager
                    manager.version = self.version
                    manager.conflicts = self.conflicts

                    -- Save the new data to the server's modSettings XML
                    manager:saveToXML()

                    -- Re-evaluate the active mods on the server with the new list
                    local hasActiveConflicts = manager:checkActiveMods()

                    -- If a new conflicting mod is currently running on the server, broadcast a warning
                    if hasActiveConflicts then
                        -- Broadcast warning to ALL clients (including the admin)
                        -- FSBaseMission.INGAME_NOTIFICATION_CRITICAL is the native red UI banner
                        g_server:broadcastEvent(IngameNotificationEvent.new(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, g_i18n:getText("ui_gm_warning_restart_required")))
                    end
                else
                    if GlobalMarket.debugManager ~= nil then
                        GlobalMarket.debugManager:trace("[Compatibility] Server version (%s) is up-to-date or newer. Ignoring Admin payload.", manager.version)
                    end
                end
            end
        else
            if GlobalMarket.debugManager ~= nil then
                GlobalMarket.debugManager:warning("[Compatibility] Unauthorized SyncGlobalMarketCompatibilityEvent received from non-admin client!")
            end
        end
    end
end
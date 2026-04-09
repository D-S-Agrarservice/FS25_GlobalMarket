--
-- FS25 - GlobalMarket Debug Module
-- Description: Professional logging and table dumping system with recursion protection.
-- Uses XML-based Round-Robin file rotation to comply with Giants Engine OS sandboxing.
--

GlobalMarketDebug = {}
local GlobalMarketDebug_mt = Class(GlobalMarketDebug)

-- Constants
GlobalMarketDebug.MAX_DUMP_DEPTH = 5
GlobalMarketDebug.MAX_LOG_FILES = 3
GlobalMarketDebug.DEEP_LOG_DURATION = 60 * 60 * 1000 -- 1 hour in milliseconds

function GlobalMarketDebug.new(modName, baseDir)
    local self = setmetatable({}, GlobalMarketDebug_mt)

    self.modName = modName
    self.baseDir = baseDir
    self.logDir = getUserProfileAppPath() .. "modSettings/" .. modName .. "/logs/"

    self.isActive = true
    self.deepLogActive = false
    self.deepLogEndTime = 0
    self.currentLogFile = nil
    self.currentLogIndex = 1

    self:initLogDirectory()
    self:rotateLogs()
    self:openNewLogFile()

    return self
end

function GlobalMarketDebug:initLogDirectory()
    -- Create the directory safely if it does not exist
    createFolder(self.logDir)
end

function GlobalMarketDebug:rotateLogs()
    -- Using the native XML engine to track rotation to bypass io.open('r') restrictions
    local indexPath = self.logDir .. "log_index.xml"
    local lastIndex = 0

    -- Read the last used index via XML
    if fileExists(indexPath) then
        local xmlFile = XMLFile.load("LogIndexXML", indexPath)
        if xmlFile ~= nil then
            -- Fallback to 0 if the value doesn't exist
            lastIndex = xmlFile:getInt("logIndex#value", 0)
            xmlFile:delete()
        end
    end

    -- Calculate next index (wrap around 1 to MAX)
    self.currentLogIndex = lastIndex + 1
    if self.currentLogIndex > self.MAX_LOG_FILES then
        self.currentLogIndex = 1
    end

    -- Save the new index via XML
    local xmlOut = XMLFile.create("LogIndexXML", indexPath, "logIndex")
    if xmlOut ~= nil then
        xmlOut:setInt("logIndex#value", self.currentLogIndex)
        xmlOut:save()
        xmlOut:delete()
    end
end

function GlobalMarketDebug:openNewLogFile()
    -- Open the file based on the determined rotation index, overwriting old contents
    -- io.open with 'w' mode is permitted by the FS engine
    local filePath = self.logDir .. "gm_dump_" .. self.currentLogIndex .. ".txt"
    self.currentLogFile = io.open(filePath, "w")

    if self.currentLogFile then
        self.currentLogFile:write(string.format("=== %s Debug Log (File %d) ===\n", self.modName, self.currentLogIndex))
        self.currentLogFile:write(string.format("Started: %s\n\n", getDate("%Y-%m-%d %H:%M:%S")))
        self.currentLogFile:flush()
    else
        print(string.format("[%s - ERROR]: Failed to create external debug log at %s", self.modName, filePath))
    end
end

function GlobalMarketDebug:enableDeepLogging(durationHours)
    local hours = durationHours or 1
    self.deepLogActive = true
    self.deepLogEndTime = g_currentMission.environment.dayTime + (hours * 60 * 60 * 1000)

    self:info("Deep logging activated for %d hour(s).", hours)
end

function GlobalMarketDebug:update(dt)
    -- Fallback mechanism to prevent infinite deep logging
    if self.deepLogActive and g_currentMission and g_currentMission.environment then
        if g_currentMission.environment.dayTime > self.deepLogEndTime then
            self.deepLogActive = false
            self:warning("Deep logging duration expired. Reverting to standard INFO level.")
            if self.currentLogFile then
                self.currentLogFile:write("\n--- Deep logging automatically disabled (Time Limit Reached) ---\n")
                self.currentLogFile:flush()
            end
        end
    end
end

-- Helper: Formats strings safely
local function formatMessage(text, ...)
    local arg = {...}
    if #arg > 0 then
        for i = 1, #arg do arg[i] = tostring(arg[i]) end
        local success, result = pcall(string.format, tostring(text), table.unpack(arg))
        return success and result or (tostring(text) .. " [Format Error]")
    end
    return tostring(text)
end

-- Helper: Safely dumps a table with circular reference checks
local function dumpTableSafe(tbl, indent, depth, visited)
    if depth > GlobalMarketDebug.MAX_DUMP_DEPTH then
        return indent .. "[Max Depth Reached]\n"
    end
    if type(tbl) ~= "table" then
        return indent .. tostring(tbl) .. "\n"
    end
    if visited[tbl] then
        return indent .. "[Circular Reference Detected]\n"
    end

    visited[tbl] = true
    local out = ""

    for k, v in pairs(tbl) do
        local keyStr = tostring(k)
        if type(v) == "table" then
            out = out .. indent .. "[" .. keyStr .. "] => Table:\n"
            out = out .. dumpTableSafe(v, indent .. "  ", depth + 1, visited)
        elseif type(v) == "function" then
            out = out .. indent .. "[" .. keyStr .. "] => [function]\n"
        elseif type(v) == "userdata" then
            out = out .. indent .. "[" .. keyStr .. "] => [userdata]\n"
        else
            out = out .. indent .. "[" .. keyStr .. "] => " .. tostring(v) .. "\n"
        end
    end

    return out
end

-- === MAIN API ENDPOINTS ===

function GlobalMarketDebug:info(text, ...)
    if not self.isActive then return end
    print(string.format("[%s - INFO]: %s", self.modName, formatMessage(text, ...)))
end

function GlobalMarketDebug:warning(text, ...)
    if not self.isActive then return end
    print(string.format("[%s - WARNING]: %s", self.modName, formatMessage(text, ...)))
end

function GlobalMarketDebug:error(text, ...)
    if not self.isActive then return end
    print(string.format("[%s - ERROR]: %s", self.modName, formatMessage(text, ...)))
    -- Optional: Dump stack traceback for errors
    print(debug.traceback("", 2))
end

function GlobalMarketDebug:debug(text, dataTable, ...)
    if not self.isActive or not self.deepLogActive or not self.currentLogFile then return end

    local msg = formatMessage(text, ...)
    self.currentLogFile:write(string.format("[DEBUG] %s\n", msg))

    if dataTable ~= nil then
        self.currentLogFile:write(dumpTableSafe(dataTable, "  ", 1, {}) .. "\n")
    end
    self.currentLogFile:flush()
end

function GlobalMarketDebug:trace(text, dataTable, ...)
    if not self.isActive or not self.deepLogActive or not self.currentLogFile then return end

    local msg = formatMessage(text, ...)
    self.currentLogFile:write(string.format("[TRACE] %s\n", msg))

    if dataTable ~= nil then
        self.currentLogFile:write(dumpTableSafe(dataTable, "  ", 1, {}) .. "\n")
    end
    self.currentLogFile:flush()
end

function GlobalMarketDebug:close()
    if self.currentLogFile then
        self.currentLogFile:write("\n=== Log Closed ===\n")
        self.currentLogFile:close()
        self.currentLogFile = nil
    end
end
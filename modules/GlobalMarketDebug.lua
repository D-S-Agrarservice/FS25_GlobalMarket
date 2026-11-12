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
    local modSettingsDir = getUserProfileAppPath() .. "modSettings/" .. self.modName .. "/"
    createFolder(modSettingsDir)
    createFolder(self.logDir)
end

function GlobalMarketDebug:rotateLogs()
    local indexPath = self.logDir .. "log_index.xml"
    local lastIndex = 0

    if fileExists(indexPath) then
        local xmlFile = XMLFile.load("LogIndexXML", indexPath)
        if xmlFile ~= nil then
            lastIndex = xmlFile:getInt("logIndex#value", 0)
            xmlFile:delete()
        end
    end

    self.currentLogIndex = lastIndex + 1
    if self.currentLogIndex > self.MAX_LOG_FILES then
        self.currentLogIndex = 1
    end

    local xmlOut = XMLFile.create("LogIndexXML", indexPath, "logIndex")
    if xmlOut ~= nil then
        xmlOut:setInt("logIndex#value", self.currentLogIndex)
        xmlOut:save()
        xmlOut:delete()
    end
end

function GlobalMarketDebug:openNewLogFile()
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

    -- FIX: Use a simple real-world countdown timer in milliseconds
    -- instead of the easily breakable in-game dayTime.
    self.deepLogTimerLeft = hours * 60 * 60 * 1000

    self:info("Deep logging activated for %d hour(s) real-time.", hours)
end

function GlobalMarketDebug:update(dt)
    if self.deepLogActive then
        -- Subtract the real-world milliseconds passed since the last frame
        self.deepLogTimerLeft = self.deepLogTimerLeft - dt

        if self.deepLogTimerLeft <= 0 then
            self.deepLogActive = false
            self:warning("Deep logging duration expired. Reverting to standard INFO level.")
            if self.currentLogFile then
                self.currentLogFile:write("\n--- Deep logging automatically disabled (Time Limit Reached) ---\n")
                self.currentLogFile:flush()
            end
        end
    end
end

-- Helper: Formats strings safely with explicit type guards (LuaJIT & ModHub compliant)
local function formatMessage(text, ...)
    local fmt = tostring(text)
    local numArgs = select("#", ...)
    if numArgs == 0 then
        return fmt
    end

    local args = { ... }
    local argIdx = 0

    local formatted = string.gsub(fmt, "%%([%-+%s#0]*%d*%.?%d*[cdiouxXeEfgGqs%%])", function(spec)
        if spec == "%" then
            return "%"
        end

        argIdx = argIdx + 1
        local val = args[argIdx]
        local conv = string.sub(spec, -1)

        if conv == "s" or conv == "q" then
            return string.format("%" .. spec, tostring(val))
        end

        local num = tonumber(val)
        if num == nil or num ~= num or num == math.huge or num == -math.huge then
            return tostring(val)
        end

        if conv == "d" or conv == "i" or conv == "u" or conv == "o" or conv == "x" or conv == "X" or conv == "c" then
            num = (num >= 0) and math.floor(num) or math.ceil(num)
        end

        return string.format("%" .. spec, num)
    end)

    return formatted
end

-- Helper: Safely dumps a table with circular reference checks
local function dumpTableSafe(tbl, indent, depth, visited)
    if depth > GlobalMarketDebug.MAX_DUMP_DEPTH then return indent .. "[Max Depth Reached]\n" end
    if type(tbl) ~= "table" then return indent .. tostring(tbl) .. "\n" end
    if visited[tbl] then return indent .. "[Circular Reference Detected]\n" end

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
    printCallstack()
end

-- TEXT ONLY Deep Logs
function GlobalMarketDebug:debug(text, ...)
    if not self.isActive or not self.deepLogActive or not self.currentLogFile then return end
    self.currentLogFile:write(string.format("[DEBUG] %s\n", formatMessage(text, ...)))
    self.currentLogFile:flush()
end

function GlobalMarketDebug:trace(text, ...)
    if not self.isActive or not self.deepLogActive or not self.currentLogFile then return end
    self.currentLogFile:write(string.format("[TRACE] %s\n", formatMessage(text, ...)))
    self.currentLogFile:flush()
end

-- TABLE DUMP Deep Logs
function GlobalMarketDebug:debugTable(text, tbl)
    if not self.isActive or not self.deepLogActive or not self.currentLogFile then return end
    self.currentLogFile:write(string.format("[DEBUG] %s\n", tostring(text)))
    if type(tbl) == "table" then
        self.currentLogFile:write(dumpTableSafe(tbl, "  ", 1, {}) .. "\n")
    end
    self.currentLogFile:flush()
end

function GlobalMarketDebug:traceTable(text, tbl)
    if not self.isActive or not self.deepLogActive or not self.currentLogFile then return end
    self.currentLogFile:write(string.format("[TRACE] %s\n", tostring(text)))
    if type(tbl) == "table" then
        self.currentLogFile:write(dumpTableSafe(tbl, "  ", 1, {}) .. "\n")
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
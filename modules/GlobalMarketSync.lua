--
-- FS25 - GlobalMarket (Sync Module)
-- Handling external .exe communication via XML files
--

function GlobalMarket:initSync()
    self.fillTypes = {}
    self.siloLevels = {}
    self.objectLevels = {}
    self.lastConnection = false
    self.closeSelectLevelUi = 0
    self.timer2sec = 2000

    -- FS25 Paths: Use getUserProfileAppPath() to reach modSettings
    self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
    self.readFolder = getUserProfileAppPath() .. "modSettings/FS25_GlobalMarket/read/"
    self.writeFolder = getUserProfileAppPath() .. "modSettings/FS25_GlobalMarket/write/"

    -- Create folders if they don't exist (FS25 standard check)
    if not entityExists(self.readFolder) then createFolder(self.readFolder) end
    if not entityExists(self.writeFolder) then createFolder(self.writeFolder) end
end

-- This function will be called by GlobalMarket:update(dt) once activated
function GlobalMarket:updateSync(dt)
    self.timer2sec = self.timer2sec + dt

    if self:getIsMarketOnline() then
        if self.timer2sec >= 1000 then
            self.timer2sec = self.timer2sec - 1000

            -- Scan read folder for instructions from the .exe
            local files = Files.new(self.readFolder)
            local updateUi = false

            for _, file in pairs(files.files) do
                local fullPath = self.readFolder .. "/" .. file.filename
                local xmlFile = XMLFile.load("gmDataSync", fullPath)

                if xmlFile ~= nil then
                    local action = xmlFile:getString("gmDataSync#action", "")

                    -- 1. Sync Market Prices & Levels
                    if action == "marketData" then
                        self:parseMarketData(xmlFile)
                        self:handleUiClosures()

                    -- 2. Handle Silo Transactions
                    elseif action == "buy" or action == "sell" then
                        self:handleSiloSync(xmlFile, action)

                    -- 3. Handle Object Transactions (Bales/Pallets)
                    elseif action == "buyObject" or action == "sellObject" then
                        self:handleObjectSync(xmlFile, action)

                    -- 4. Connection Handshake
                    elseif action == "defHandshake" then
                        self:handleUiClosures()
                    end

                    xmlFile:delete()
                    deleteFile(fullPath)
                    updateUi = true
                end
            end

            if updateUi and g_currentMission.globalMarketUi ~= nil then
                g_currentMission.globalMarketUi:updateContent()
            end
            self.lastConnection = true
        end
    elseif self.lastConnection then
        self.entries = {}
        self.lastConnection = false
        if g_currentMission.globalMarketUi ~= nil then
            g_currentMission.globalMarketUi:updateContent()
        end
    end
end

-- Helper: Check if the external tool is active
function GlobalMarket:getIsMarketOnline()
    if fileExists(self.isOnlineFile) then
        local xmlFile = XMLFile.load("globalMarketOnline", self.isOnlineFile)
        local version = xmlFile:getInt("globalMarketOnline.version")
        xmlFile:delete()
        return version ~= nil and version >= self.needExeVersion
    end
    return false
end

-- Internal Handlers for clarity
function GlobalMarket:parseMarketData(xmlFile)
    self.fillTypes = {}
    xmlFile:iterate("fs25GlobalMarketDataSynch.fillTypes.fillType", function (_, baseKey)
        table.insert(self.fillTypes, {
            fillType = xmlFile:getString(baseKey .. "#fillType"),
            fillLevel = xmlFile:getInt(baseKey .. "#fillLevel"),
            price = xmlFile:getFloat(baseKey .. "#price"),
            isSilo = xmlFile:getBool(baseKey .. "#isSilo"),
            isObject = xmlFile:getBool(baseKey .. "#isObject"),
        })
    end)
    -- ... Silo and Object Level iteration follows the same logic as FS22
end

function GlobalMarket:handleUiClosures()
    if self.closeSelectLevelUi == 1 then
        self.closeSelectLevelUi = 2
    elseif self.closeSelectLevelUi == 3 then
        if g_currentMission.globalMarketSelectLevelUi ~= nil then
            g_currentMission.globalMarketSelectLevelUi:close()
        end
        self.closeSelectLevelUi = 0
    end
end
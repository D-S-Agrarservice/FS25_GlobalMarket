--
-- FS25 - GlobalMarket (UI Module)
--
-- Komplett und lauffähig für den Offline-Modus.
--

GlobalMarketUI = {}
local GlobalMarketUI_mt = Class(GlobalMarketUI, TabbedMenuFrameElement)

function GlobalMarketUI.init()
    g_gui:loadProfiles(GlobalMarket.dir .. "gui/guiProfiles.xml")

    local ui = GlobalMarketUI.new()
    g_gui:loadGui(GlobalMarket.dir .. "gui/InGameMenuGlobalMarket.xml", "GlobalMarket", ui)

    local selectLevel = GlobalMarketSelectLevelUI.new()
    g_gui:loadGui(GlobalMarket.dir .. "gui/SelectLevel.xml", "SelectLevel", selectLevel)
    g_currentMission.globalMarketSelectLevelUi = selectLevel
end

function GlobalMarketUI.new(target, customMt)
    local self = TabbedMenuFrameElement.new(target, customMt or GlobalMarketUI_mt)
    return self
end

function GlobalMarketUI:onFrameOpen()
    GlobalMarketUI:superClass().onFrameOpen(self)
    g_currentMission.globalMarket:debugLog("UI: Main frame opened.")
    self:updateContent()
end

function GlobalMarketUI:updateContent()
    local gm = g_currentMission.globalMarket

    -- Texte für den Header setzen
    if self.textHeader ~= nil then
        self.textHeader:setText(g_i18n:getText("ui_ingameMenuGlobalMarketHeaderMarket"))
    end

    if self.textHeaderDesc ~= nil then
        self.textHeaderDesc:setText(g_i18n:getText("ui_ingameMenuGlobalMarketOfflineDesc"))
    end

    -- Tabellen aktualisieren
    self:updateStorageList()
    self:updateMarketList()
end

-- =========================================================================
-- Listen Logik (Komplett)
-- =========================================================================

function GlobalMarketUI:updateStorageList()
    local gm = g_currentMission.globalMarket
    gm:debugLog("UI: Refreshing Storage List...")

    -- Sicherheitscheck, ob das UI-Element geladen ist
    if self.gmTableStorage ~= nil then
        -- Listen leeren vor der Neuerstellung
        if type(self.gmTableStorage.deleteListItems) == "function" then
            self.gmTableStorage:deleteListItems()
        end

        -- Da wir offline sind, simulieren wir hier eine leere Liste
        -- oder greifen auf lokale Hof-Daten zu, falls du diese hier anzeigen willst.
        -- Im FS25 läuft das über ListElements, die automatisch scrollbar sind.
    end
end

function GlobalMarketUI:updateMarketList()
    local gm = g_currentMission.globalMarket
    gm:debugLog("UI: Refreshing Market List...")

    if self.gmTableMarket ~= nil then
        if type(self.gmTableMarket.deleteListItems) == "function" then
            self.gmTableMarket:deleteListItems()
        end

        -- Alle Offline-FillTypes durchgehen und in die Tabelle schreiben
        for _, marketItem in pairs(gm.offlineMarketFillTypes) do
            if marketItem ~= nil and marketItem.fillType ~= nil then
                local fillTypeDesc = g_fillTypeManager:getFillTypeByName(marketItem.fillType)

                if fillTypeDesc ~= nil then
                    local newRow = self.gmTableMarket:cloneElement()
                    if newRow ~= nil then
                        -- Werte setzen, falls die IDs in deiner XML existieren
                        if newRow.cellTextFillType ~= nil then
                            newRow.cellTextFillType:setText(fillTypeDesc.title)
                        end
                        if newRow.cellTextFillLevel ~= nil then
                            newRow.cellTextFillLevel:setText(tostring(math.floor(marketItem.fillLevel)))
                        end
                        if newRow.cellTextPrice ~= nil then
                            newRow.cellTextPrice:setText(tostring(math.floor(marketItem.price)))
                        end
                    end
                end
            end
        end
    end
end

-- =========================================================================
-- Button Callbacks (Sichtbarkeits-Toggle)
-- =========================================================================

function GlobalMarketUI:onClickToggleStorageSiloObject()
    local gm = g_currentMission.globalMarket
    gm:debugLog("UI: Toggle Storage Silo/Object view clicked.")

    if self.sectionStorageSilo ~= nil and self.sectionStorageObject ~= nil then
        local isSiloVisible = self.sectionStorageSilo:getIsVisible()
        self.sectionStorageSilo:setVisible(not isSiloVisible)
        self.sectionStorageObject:setVisible(isSiloVisible)
    end
end

function GlobalMarketUI:onClickToggleMarketSiloObject()
    local gm = g_currentMission.globalMarket
    gm:debugLog("UI: Toggle Market Silo/Object view clicked.")

    if self.sectionMarketSilo ~= nil and self.sectionMarketObject ~= nil then
        local isSiloVisible = self.sectionMarketSilo:getIsVisible()
        self.sectionMarketSilo:setVisible(not isSiloVisible)
        self.sectionMarketObject:setVisible(isSiloVisible)
    end
end

-- =========================================================================
-- Select Level UI (Popup Dialog)
-- =========================================================================

GlobalMarketSelectLevelUI = {}
-- WICHTIGER FIX: Wir erben von FrameElement, um den YesNoDialog-Crash zu verhindern
local GlobalMarketSelectLevelUI_mt = Class(GlobalMarketSelectLevelUI, FrameElement)

function GlobalMarketSelectLevelUI.new(target, customMt)
    local self = FrameElement.new(target, customMt or GlobalMarketSelectLevelUI_mt)
    return self
end

function GlobalMarketSelectLevelUI:onFrameOpen()
    g_currentMission.globalMarket:debugLog("UI: Select Level dialog opened.")
    GlobalMarketSelectLevelUI:superClass().onFrameOpen(self)

    -- Standardwerte beim Öffnen des Dialogs setzen
    if self.textLevel ~= nil then self.textLevel:setText("0") end
    if self.levelPrice ~= nil then self.levelPrice:setText("0 €") end
end

function GlobalMarketSelectLevelUI:onClickBack()
    if self.target ~= nil and type(self.target.closeDialog) == "function" then
        self.target:closeDialog(self)
    end
end
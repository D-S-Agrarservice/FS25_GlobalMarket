--
-- FS25 - GlobalMarket (UI Module)
--

GlobalMarketUI = {}

-- Called during map load to setup all GUI elements
function GlobalMarketUI.init()
    -- Load translations and profiles

    g_gui:loadProfiles(GlobalMarket.dir .. "gui/guiProfiles.xml")

    -- TODO: Initialize and load our custom GUI XMLs here once we adapt them for FS25
    -- local guiGlobalMarket = InGameMenuGlobalMarket.new(g_i18n, g_messageCenter)
    -- g_gui:loadGui(GlobalMarket.dir .. "gui/InGameMenuGlobalMarket.xml", "ingameMenuGlobalMarket", guiGlobalMarket, true)

    -- TODO: Inject into the main game menu once the XMLs are loaded
    -- GlobalMarketUI.fixInGameMenu(guiGlobalMarket, "ingameMenuGlobalMarket", {0,0,1024,1024}, 2, GlobalMarketUI.makeIsGlobalMarketEnabledPredicate())
end

-- Function adapted and optimized for FS25 TabbedMenu structure
function GlobalMarketUI.fixInGameMenu(frame, pageName, uvs, position, predicateFunc)
    local inGameMenu = g_gui.screenControllers[InGameMenu]

    -- Remove existing control ID to prevent UI warnings during reload
    inGameMenu.controlIDs[pageName] = nil
    inGameMenu:registerControls({pageName})

    -- Assign the frame to the menu and expose its fields
    inGameMenu[pageName] = frame
    inGameMenu:addElement(frame)
    inGameMenu:exposeControlsAsFields(pageName)

    -- Define the custom icon path for the tab
    local iconFileName = Utils.getFilename('images/menuIcon.dds', GlobalMarket.dir)

    -- Use the native FS25 TabbedMenu method to handle registration, positioning, and tab integration
    inGameMenu:addPage(frame, position, iconFileName, uvs, predicateFunc)

    -- Apply alignments and rebuild the visual tab list to apply changes
    frame:applyScreenAlignment()
    frame:updateAbsolutePosition()
    inGameMenu:rebuildTabList()
end

-- Predicate to check if the tab should be enabled
function GlobalMarketUI.makeIsGlobalMarketEnabledPredicate()
    return function ()
        return true
    end
end
-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketPermissions.lua
-- Farm permissions and in-menu feedback for the player markets (vehicles, animals, contracts).
-- Follows the basegame rules: admins and farm managers may do everything, other farm members
-- only what their role allows (buy/sell vehicles, trade animals, manage contracts). The server
-- checks every request; the menu checks first and answers with a dialog like the shop does.
-- Author: D-S-Agrarservice
-- =========================================================================================

---Returns true if the local player has a farm permission (admins and farm managers always)
---@param permission string|nil Farm.PERMISSION.*
---@return boolean
function GlobalMarket.getHasMarketPermission(permission)
    if g_currentMission == nil then
        return false
    end
    if permission == nil then
        return true
    end
    return g_currentMission:getHasPlayerPermission(permission) == true
end

---Menu check before an action: shows the "no permission" dialog if the permission is missing
---@param permission string Farm.PERMISSION.*
---@return boolean allowed
function GlobalMarket.checkMarketPermission(permission)
    if GlobalMarket.getHasMarketPermission(permission) then
        return true
    end
    if InfoDialog ~= nil then
        InfoDialog.show(g_i18n:getText("ui_gm_noPermission"), nil, nil, DialogElement.TYPE_WARNING)
    end
    return false
end

---Returns true while the GlobalMarket page of the in-game menu is open (incl. its dialogs)
---@return boolean
function GlobalMarket.getIsMarketMenuOpen()
    local gm = (g_currentMission ~= nil) and g_currentMission.globalMarket or nil
    if gm == nil or gm.ui == nil or g_gui == nil or g_gui.screenControllers == nil then
        return false
    end
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    return g_gui.currentGuiName == "InGameMenu" and inGameMenu ~= nil and inGameMenu.currentPage == gm.ui
end

---Shows a failed request as a dialog while the market menu is open (the HUD is hidden there)
---@param text string
---@return boolean shown false = caller shows the HUD notification
function GlobalMarket.showResultInMarketMenu(text)
    if text == nil or InfoDialog == nil or not GlobalMarket.getIsMarketMenuOpen() then
        return false
    end
    InfoDialog.show(text, nil, nil, DialogElement.TYPE_WARNING)
    return true
end

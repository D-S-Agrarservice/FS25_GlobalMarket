-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketVehicleShopBridge.lua
-- Used vehicle market (#16): opens the basegame ShopConfigScreen for a GM listing
-- (exact configuration incl. custom paint, condition and asking price) and routes the
-- purchase to the GM buy event. Configuration changes are preview-only.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketVehicleShopBridge = {}

-- Active listing context while the shop screen shows a GM listing (nil otherwise)
GlobalMarketVehicleShopBridge.context = nil

-- =========================================================================
-- BASEGAME HOOKS (no effect unless a GM listing is open)
-- =========================================================================

-- setStoreItem() resets configurationData for sale items; inject the listing's custom paint
-- right before the options and the preview vehicle are built from it.
ShopConfigScreen.processStoreItemConfigurations = Utils.prependedFunction(ShopConfigScreen.processStoreItemConfigurations,
    function(screen)
        local pending = screen.gmPendingConfigurationData
        if pending ~= nil then
            screen.gmPendingConfigurationData = nil
            screen.configurationData = pending
        end
    end)

-- Restore the title text and the exit callback when the shop screen closes
ShopConfigScreen.onClose = Utils.appendedFunction(ShopConfigScreen.onClose, function(screen)
    GlobalMarketVehicleShopBridge.restore(screen)
end)

-- =========================================================================
-- OPEN / RESTORE
-- =========================================================================

---Builds the sale item table the shop screen expects (condition + asking price)
local function buildSaleItem(listing, resolved, price)
    -- Active configs count as bought, so the screen never adds their price on top
    local bought = table.clone(resolved.boughtConfigurations, math.huge)
    for name, configId in pairs(resolved.configurations) do
        bought[name] = bought[name] or {}
        bought[name][configId] = true
    end
    return {
        id = 0,
        xmlFilename = resolved.storeItem.xmlFilename,
        boughtConfigurations = bought,
        age = listing.snapshot.age or 0,
        operatingTime = listing.snapshot.operatingTime or 0,
        damage = listing.snapshot.damage or 0,
        wear = listing.snapshot.wear or 0,
        price = price,
        isGenerated = false,
        timeLeft = 1,
        gmListingId = listing.id
    }
end

---Loads the listing's exact configuration into the (already open) shop screen
local function applyListingToScreen(screen, ctx)
    screen.gmPendingConfigurationData = table.clone(ctx.resolved.configurationData, math.huge)
    screen:setStoreItem(ctx.resolved.storeItem, nil, ctx.saleItem, nil, table.clone(ctx.resolved.configurations))
end

---Opens the shop screen for a market listing
---@param listing table
---@param farmId number Buyer farm
---@return boolean opened
function GlobalMarketVehicleShopBridge.openListing(listing, farmId)
    local screen = g_shopConfigScreen
    if screen == nil or listing == nil then
        return false
    end
    local resolved, reason = GlobalMarketVehicleListings.resolveSnapshot(listing.snapshot)
    if resolved == nil then
        InfoDialog.show(GlobalMarket.getVehicleMarketReasonText(reason or "notAvailable"), nil, nil, DialogElement.TYPE_WARNING)
        return true
    end
    if g_currentMission.slotSystem ~= nil and not g_currentMission.slotSystem:hasEnoughSlots(resolved.storeItem) then
        InfoDialog.show(g_i18n:getText(ShopConfigScreen.L10N_SYMBOL.TOO_FEW_SLOTS), nil, nil, DialogElement.TYPE_WARNING)
        return true
    end
    local price = GlobalMarketVehicleListings.getListingPrice(listing) or 0
    local ctx = {
        listing = listing,
        resolved = resolved,
        price = price,
        farmId = farmId,
        saleItem = buildSaleItem(listing, resolved, price)
    }

    g_gui:changeScreen(nil, ShopConfigScreen, InGameMenu)
    -- The context is set after changeScreen, so closing the InGameMenu does not trigger a restore
    GlobalMarketVehicleShopBridge.context = ctx
    screen:setReturnScreenClass(InGameMenu)
    ctx.prevExitCallback = screen.requestExitCallback
    screen:setRequestExitCallback(function()
        g_gui:changeScreen(nil)
    end)
    applyListingToScreen(screen, ctx)
    screen:setCallbacks(GlobalMarketVehicleShopBridge.onBuy, GlobalMarketVehicleShopBridge)

    if screen.configurationsTitle ~= nil then
        ctx.prevTitle = screen.configurationsTitle.text
        screen.configurationsTitle:setText(g_i18n:getText("ui_gm_vehicles_shopHint"))
    end
    return true
end

---Restores the basegame state of the shop screen (called on close)
---@param screen table
function GlobalMarketVehicleShopBridge.restore(screen)
    local ctx = GlobalMarketVehicleShopBridge.context
    if ctx == nil then
        return
    end
    GlobalMarketVehicleShopBridge.context = nil
    screen.gmPendingConfigurationData = nil
    if screen.configurationsTitle ~= nil and ctx.prevTitle ~= nil then
        screen.configurationsTitle:setText(ctx.prevTitle)
    end
    screen:setRequestExitCallback(ctx.prevExitCallback)
end

-- =========================================================================
-- PURCHASE
-- =========================================================================

---Returns true if the buy data still equals the listed configuration (incl. custom paint)
---@param vehicleBuyData table
---@param ctx table
---@return boolean
function GlobalMarketVehicleShopBridge.matchesListing(vehicleBuyData, ctx)
    local selected = vehicleBuyData.configurations or {}
    for name, configId in pairs(ctx.resolved.configurations) do
        if selected[name] ~= configId then
            return false
        end
    end
    if ConfigurationUtil.getConfigurationDataHasChanged ~= nil
        and ConfigurationUtil.getConfigurationDataHasChanged(ctx.resolved.storeItem.xmlFilename,
            ctx.resolved.configurationData, vehicleBuyData.configurationData or {}) then
        return false
    end
    return true
end

---Shop screen buy callback: only the listing as listed can be bought
function GlobalMarketVehicleShopBridge:onBuy(vehicleBuyData, vehicleId)
    local ctx = GlobalMarketVehicleShopBridge.context
    if ctx == nil or vehicleBuyData == nil then
        return
    end
    if not GlobalMarketVehicleShopBridge.matchesListing(vehicleBuyData, ctx) then
        -- target == nil: YesNoDialog calls callback(yes, args)
        YesNoDialog.show(function(yes)
            local current = GlobalMarketVehicleShopBridge.context
            if yes == true and current ~= nil and g_shopConfigScreen ~= nil then
                applyListingToScreen(g_shopConfigScreen, current)
            end
        end, nil, g_i18n:getText("ui_gm_vehicles_configChanged"))
        return
    end
    -- The server builds the vehicle from the listing; only the chosen license plate is taken from the client
    if ctx.listing.isOnline then
        -- Online listing (#36): purchase request to the backend, the vehicle comes with LISTING_BOUGHT
        VehicleMarketActionEvent.dispatch(VehicleMarketActionEvent.ACTION_BUY_ONLINE, ctx.farmId, nil, 0, 1, 1,
            vehicleBuyData.licensePlateData, false, ctx.listing.remoteId)
    else
        VehicleMarketActionEvent.dispatch(VehicleMarketActionEvent.ACTION_BUY, ctx.farmId, nil, ctx.listing.id, 1, 1,
            vehicleBuyData.licensePlateData)
    end
    if g_shopConfigScreen ~= nil then
        g_shopConfigScreen:changeScreen(InGameMenu)
    end
end

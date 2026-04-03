--
-- FS25 - GlobalMarket Dummy Data Provider
--

GlobalMarketDummyData = {}

-- Returns fake storage data
function GlobalMarketDummyData.getStorageList()
    return {
        { title = "WHEAT", level = 12000, icon = "dataS/menu/hud/fillTypes/hud_fill_wheat.png" },
        { title = "BARLEY", level = 4500, icon = "dataS/menu/hud/fillTypes/hud_fill_barley.png" },
        { title = "OAT", level = 8000, icon = "dataS/menu/hud/fillTypes/hud_fill_oat.png" },
        { title = "MAIZE", level = 25000, icon = "dataS/menu/hud/fillTypes/hud_fill_maize.png" }
    }
end

-- Returns fake market data
function GlobalMarketDummyData.getMarketList()
    return {
        { title = "CANOLA", level = 1000, price = 1500, trend = SellingStation.PRICE_CLIMBING },
        { title = "SOYBEAN", level = 500, price = 2800, trend = SellingStation.PRICE_FALLING },
        { title = "SUNFLOWER", level = 3200, price = 1850, trend = SellingStation.PRICE_CLIMBING }
    }
end

-- Returns fake farm/storage locations for the dropdown
function GlobalMarketDummyData.getStorageLocations()
    return {
        { id = 1, name = "Farm Silo 1" },
        { id = 2, name = "Train Silo East" },
        { id = 3, name = "Production Storage" }
    }
end
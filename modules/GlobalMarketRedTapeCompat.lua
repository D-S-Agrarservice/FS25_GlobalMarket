-- =========================================================================
-- GlobalMarketRedTapeCompat
-- Puts the Global Market money types on the tax statement of Red Tape
-- (FS25_RedTape) through its public API RTTaxSystem.registerTaxStatistic.
-- Does nothing without Red Tape or with a Red Tape version that lacks the API.
-- =========================================================================

GlobalMarketRedTapeCompat = {}

-- Statistics with a fixed sign: sales are income, purchases and fees are expenses
GlobalMarketRedTapeCompat.FIXED_KINDS = {
    { statistic = "gmSellBulk",   kind = "income" },
    { statistic = "gmSellBale",   kind = "income" },
    { statistic = "gmSellLiquid", kind = "income" },
    { statistic = "gmSellPiece",  kind = "income" },
    { statistic = "gmSell",       kind = "income" },
    { statistic = "gmBuyBulk",    kind = "expense" },
    { statistic = "gmBuyBale",    kind = "expense" },
    { statistic = "gmBuyLiquid",  kind = "expense" },
    { statistic = "gmBuyPiece",   kind = "expense" },
    { statistic = "gmBuy",        kind = "expense" },
    { statistic = "gmFee",        kind = "expense" }
}

-- Statistics that flow both ways (escrow, refunds, payouts, penalties).
-- They need a kind that follows the sign of the amount; without one they are ignored,
-- because a fixed kind would count e.g. an escrow payment as income.
GlobalMarketRedTapeCompat.SIGNED_STATISTICS = { "gmContracts", "gmPenalties" }

---Returns Red Tape's tax system table, or nil if Red Tape is not active.
---Mods run in their own environment, so the plain global is only a fallback.
---@return table|nil
function GlobalMarketRedTapeCompat.getTaxSystem()
    local taxSystem = nil
    if GMCompatibilityManager ~= nil and GMCompatibilityManager.findModGlobal ~= nil then
        taxSystem = GMCompatibilityManager.findModGlobal("RTTaxSystem")
    end
    if taxSystem == nil and type(RTTaxSystem) == "table" then
        taxSystem = RTTaxSystem
    end
    return taxSystem
end

---Returns the kind for statistics that flow both ways: Red Tape's sign-based kind if it has one, else "ignore"
---@param taxSystem table
---@return string kind
function GlobalMarketRedTapeCompat.getSignedKind(taxSystem)
    local kinds = taxSystem.STAT_KIND
    if type(kinds) == "table" and type(kinds.SIGNED) == "string" then
        return kinds.SIGNED
    end
    return "ignore"
end

---Registers all Global Market statistics with Red Tape. Call on every machine from loadMap or later.
---@return number registered Number of statistics Red Tape accepted
function GlobalMarketRedTapeCompat.init()
    local taxSystem = GlobalMarketRedTapeCompat.getTaxSystem()
    if taxSystem == nil or type(taxSystem.registerTaxStatistic) ~= "function" then
        return 0
    end

    local registered = 0
    local function register(statistic, kind)
        if taxSystem.registerTaxStatistic(statistic, kind) == true then
            registered = registered + 1
        end
    end

    for _, entry in ipairs(GlobalMarketRedTapeCompat.FIXED_KINDS) do
        register(entry.statistic, entry.kind)
    end

    local signedKind = GlobalMarketRedTapeCompat.getSignedKind(taxSystem)
    for _, statistic in ipairs(GlobalMarketRedTapeCompat.SIGNED_STATISTICS) do
        register(statistic, signedKind)
    end

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:info(string.format(
            "[Compatibility] Red Tape detected. Registered %d tax statistics (contracts and penalties: %s).",
            registered, signedKind))
    end
    return registered
end

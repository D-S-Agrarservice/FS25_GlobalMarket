-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractDialogScope.lua
-- Scope selector ("Local / Online") of the direct offer creation: an own row above the
-- terms, like supply contracts and the vehicle market. Offer creation uses five selector
-- rows, so the terms row, amount input, quick steps and receipt move down one row.
-- Author: D-S-Agrarservice
-- =========================================================================================

-- Height of one selector row (matches the globalMarketCDropdown* profiles)
GlobalMarketContractDialog.ROW_SPACING_PX = 46

---Moves terms, amount input, quick steps and receipt one row down for offer creation (or back)
---@param isFiveRows boolean
function GlobalMarketContractDialog:applyScopeRowLayout(isFiveRows)
    local elements = { self.selectorTerms, self.inputGroup, self.stepGroup, self.receiptBox }
    if self.scopeLayoutDefaults == nil then
        if self.dialogElement == nil then
            return
        end
        self.scopeLayoutDefaults = { height = self.dialogElement.size[2], y = {} }
        for i, element in ipairs(elements) do
            self.scopeLayoutDefaults.y[i] = (element ~= nil) and element.position[2] or nil
        end
    end
    local defaults = self.scopeLayoutDefaults
    local shift = isFiveRows and GuiUtils.getNormalizedYValue(string.format("%dpx", GlobalMarketContractDialog.ROW_SPACING_PX)) or 0
    self.dialogElement:setSize(nil, defaults.height + shift)
    for i, element in ipairs(elements) do
        if element ~= nil and defaults.y[i] ~= nil then
            element:setPosition(nil, defaults.y[i] - shift)
        end
    end
    if self.selectorScope ~= nil then
        self.selectorScope:setVisible(isFiveRows)
    end
end

---Returns true if the scope selector of the offer creation is set to online
---@return boolean
function GlobalMarketContractDialog:getIsOfferOnlineSelected()
    local opt = (self.scopeOptions ~= nil and self.selectorScope ~= nil) and self.scopeOptions[self.selectorScope:getState()] or nil
    return opt ~= nil and opt.isOnline == true
end

---Fills the scope selector (online only while allowed for the good) and the terms for the selected scope
---@param fillTypeName string
function GlobalMarketContractDialog:rebuildCreateOfferTerms(fillTypeName)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local allowOnline = gm ~= nil and gm.canPublishOnlineOffer ~= nil and gm:canPublishOnlineOffer(fillTypeName)
    local wasOnline = self:getIsOfferOnlineSelected()

    self.scopeOptions = { { isOnline = false, label = g_i18n:getText("ui_gm_scope_local") } }
    if allowOnline then
        table.insert(self.scopeOptions, { isOnline = true, label = g_i18n:getText("ui_gm_scope_online") })
    end
    if self.selectorScope ~= nil then
        local texts = {}
        for _, opt in ipairs(self.scopeOptions) do
            table.insert(texts, opt.label)
        end
        self.selectorScope:setTexts(texts)
        self.selectorScope:setState((wasOnline and allowOnline) and 2 or 1, false)
        self.selectorScope:setDisabled(not allowOnline)
    end
    self:rebuildCreateOfferTermsForScope()
end

---Fills the terms selector (partial buys x duration) for the selected scope
function GlobalMarketContractDialog:rebuildCreateOfferTermsForScope()
    local isOnline = self:getIsOfferOnlineSelected()
    self.termsOptions = {}
    for _, partial in ipairs({ true, false }) do
        if isOnline then
            local key = partial and "ui_gm_dlg_optTermPartialHours" or "ui_gm_dlg_optTermFullHours"
            for _, h in ipairs(GlobalMarketContracts.ONLINE_OFFER_HOURS) do
                table.insert(self.termsOptions, {
                    isOnline = true, allowPartial = partial, hours = h, label = string.format(g_i18n:getText(key), h)
                })
            end
        else
            local key = partial and "ui_gm_dlg_optTermPartial" or "ui_gm_dlg_optTermFull"
            for m = GlobalMarketContracts.OFFER_DURATION_MIN, GlobalMarketContracts.OFFER_DURATION_MAX do
                table.insert(self.termsOptions, {
                    isOnline = false, allowPartial = partial, months = m, label = string.format(g_i18n:getText(key), m)
                })
            end
        end
    end
    local termTexts = {}
    for _, t in ipairs(self.termsOptions) do
        table.insert(termTexts, t.label)
    end
    self.selectorTerms:setTexts(termTexts)
    self.selectorTerms:setState(math.min(2, #self.termsOptions), false)
end

function GlobalMarketContractDialog:onClickScope(state)
    if self.mode ~= GlobalMarketContractDialog.MODE_CREATE_OFFER then
        return
    end
    self:rebuildCreateOfferTermsForScope()
    self:onAmountChanged()
end

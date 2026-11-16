-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractDialog.lua
-- Modal multi-mode dialog for contracts, +/-10% direct offers, and Pickup Inbox withdrawals.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketContractDialog = {}
local GlobalMarketContractDialog_mt = Class(GlobalMarketContractDialog, YesNoDialog)

GlobalMarketContractDialog.MODE_CREATE_CONTRACT = "CREATE_CONTRACT"
GlobalMarketContractDialog.MODE_CREATE_OFFER    = "CREATE_OFFER"
GlobalMarketContractDialog.MODE_DELIVER_CONTRACT = "DELIVER_CONTRACT"
GlobalMarketContractDialog.MODE_BUY_OFFER       = "BUY_OFFER"
GlobalMarketContractDialog.MODE_CLAIM_INBOX     = "CLAIM_INBOX"

GlobalMarketContractDialog.MAX_OBJECTS_PER_TX = 50
GlobalMarketContractDialog.MAX_CONTRACT_LITERS = 2000000
GlobalMarketContractDialog.CONTRACT_STEPS = { 1000, 10000, 50000 }
GlobalMarketContractDialog.CONTRACT_STEP_LABELS = { "-50k", "-10k", "-1k", "+1k", "+10k", "+50k" }
GlobalMarketContractDialog.BULK_STEPS = { 100, 1000, 10000 }
GlobalMarketContractDialog.BULK_STEP_LABELS = { "-10k", "-1k", "-100", "+100", "+1k", "+10k" }
GlobalMarketContractDialog.OBJECT_STEPS = { 1, 5, 10 }
GlobalMarketContractDialog.OBJECT_STEP_LABELS = { "-10", "-5", "-1", "+1", "+5", "+10" }

local COLOR_LABEL = { 0.78, 0.80, 0.82, 1 }
local COLOR_WHITE = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.85, 0.85, 0.85, 1 }
local COLOR_GREEN = { 0.46, 0.80, 0.15, 1 }
local COLOR_AMBER = { 0.95, 0.68, 0.20, 1 }
local COLOR_RED = { 0.92, 0.22, 0.22, 1 }
local COLOR_BAL_OK = { 0.92, 0.94, 0.96, 1 }

function GlobalMarketContractDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketContractDialog_mt)
    self.mode = GlobalMarketContractDialog.MODE_CREATE_CONTRACT
    self.context = {}
    self.farmId = 1
    self.fillTypeName = ""
    self.fillTypeTitle = ""
    self.currentAmount = 0
    self.maxAmount = 0
    self.currentCountFactor = 1
    self.currentUnitKey = "ui_gm_unit_liter"
    self.currentFormatXml = nil
    self.currentMaxPieces = nil
    self.isAmountLocked = false
    self.primaryOptions = {}
    self.storageOptions = {}
    self.formatOptions = {}
    self.termsOptions = {}
    self.isInitializing = false
    self.isUpdatingAmountText = false
    return self
end

---Collects buyable bale and pallet/BigBag/IBC formats compatible with a target ObjectStorage
function GlobalMarketContractDialog.collectBuyableFormats(fillTypeName, selectedSilo)
    local formats = {}
    local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
    if fillType == nil or selectedSilo == nil or not selectedSilo.isObjectStorage then
        return formats
    end

    if selectedSilo.supportsBales and fillType.isBaleType and g_baleManager ~= nil and g_baleManager.bales ~= nil then
        local seenMapSizes, seenSizeCap, baleFormats, titleCounts = {}, {}, {}, {}
        local mapCustomEnv = (g_currentMission ~= nil and g_currentMission.missionInfo ~= nil)
            and g_currentMission.missionInfo.customEnvironment or nil
        local mapBaseDir = g_currentMission ~= nil and g_currentMission.baseDirectory or nil

        for _, bale in ipairs(g_baleManager.bales) do
            if bale.isAvailable and bale.fillTypes ~= nil then
                for _, ftData in ipairs(bale.fillTypes) do
                    if ftData.fillTypeIndex == fillType.index then
                        local isRound, width, _, length, diameter = g_baleManager:getBaleInfoByXMLFilename(bale.xmlFilename)
                        local sizeKey = isRound
                            and string.format("ROUND_%.2f_%.2f", diameter or 0, width or 0)
                            or string.format("SQUARE_%.2f_%.2f", length or 0, width or 0)
                        local capInt = math.floor((ftData.capacity or 0) + 0.5)
                        local sizeCapKey = string.format("%s_%d", sizeKey, capInt)
                        local isMapOrBase = (bale.customEnvironment == nil)
                            or (mapCustomEnv ~= nil and bale.customEnvironment == mapCustomEnv)
                            or (mapBaseDir ~= nil and mapBaseDir ~= "" and bale.baseDirectory == mapBaseDir)

                        local shouldAdd = false
                        if isMapOrBase then
                            if not seenMapSizes[sizeKey] and not seenSizeCap[sizeCapKey] then
                                seenMapSizes[sizeKey] = true
                                seenSizeCap[sizeCapKey] = true
                                shouldAdd = true
                            end
                        elseif not seenSizeCap[sizeCapKey] then
                            seenSizeCap[sizeCapKey] = true
                            shouldAdd = true
                        end

                        if shouldAdd then
                            local key = isRound and "ui_gm_format_roundbale" or "ui_gm_format_squarebale"
                            local title = string.format("%s (%.2fm)", g_i18n:getText(key), isRound and (diameter or width or 1.25) or (length or 2.40))
                            titleCounts[title] = (titleCounts[title] or 0) + 1
                            table.insert(baleFormats, {
                                title = title,
                                xml = bale.xmlFilename,
                                capacity = ftData.capacity,
                                unitKey = "ui_gm_unit_bale"
                            })
                        end
                    end
                end
            end
        end

        for _, bf in ipairs(baleFormats) do
            if (titleCounts[bf.title] or 0) > 1 then
                bf.title = string.format("%s - %s L", bf.title, g_i18n:formatVolume(bf.capacity or 0, 0))
            end
            table.insert(formats, bf)
        end
    end

    if selectedSilo.supportsPallets and GlobalMarketStoreCache ~= nil then
        for _, f in ipairs(GlobalMarketStoreCache.getFormatsForFillType(fillTypeName) or {}) do
            table.insert(formats, f)
        end
    end

    return formats
end

---Collects non-fermenting owned stacks from an ObjectStorage matching fillTypeName
function GlobalMarketContractDialog.collectOwnedFormats(fillTypeName, selectedSilo, farmId)
    local formats = {}
    local fillType = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
    if fillType == nil or selectedSilo == nil or not selectedSilo.isObjectStorage or selectedSilo.storage == nil then
        return formats
    end

    local spec = selectedSilo.storage.spec_objectStorage
    if spec == nil or spec.objectInfos == nil then
        return formats
    end

    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local tracker = {}
    for _, objectInfo in ipairs(spec.objectInfos) do
        local objFt, objCap, objXml, objFarm, isFerm, isBale = nil, 0, nil, FarmManager.SPECTATOR_FARM_ID, false, false
        if gm ~= nil and gm.inspectObjectInfoEntry ~= nil then
            objFt, objCap, objXml, objFarm, isFerm, isBale = gm:inspectObjectInfoEntry(objectInfo)
        end
        if objFt == fillType.index and objXml ~= nil and not isFerm and objFarm == farmId and objCap > 0 then
            if tracker[objXml] == nil then
                local title = g_i18n:getText("ui_gm_unit_piece")
                local unitKey = isBale and "ui_gm_unit_bale" or "ui_gm_unit_pallet"
                if isBale and g_baleManager ~= nil then
                    local isRound, width, _, length, diameter = g_baleManager:getBaleInfoByXMLFilename(objXml)
                    local key = isRound and "ui_gm_format_roundbale" or "ui_gm_format_squarebale"
                    title = string.format("%s (%.2fm)", g_i18n:getText(key), isRound and (diameter or width or 1.25) or (length or 2.40))
                else
                    local storeItem = g_storeManager ~= nil and g_storeManager:getItemByXMLFilename(objXml) or nil
                    title = (storeItem ~= nil and storeItem.name) or g_i18n:getText("ui_gm_format_pallet")
                end
                tracker[objXml] = {
                    title = title,
                    xml = objXml,
                    capacity = objCap,
                    unitKey = unitKey,
                    actualCount = objectInfo.numObjects or #objectInfo.objects
                }
            else
                tracker[objXml].actualCount = tracker[objXml].actualCount + (objectInfo.numObjects or #objectInfo.objects)
            end
        end
    end

    for _, f in pairs(tracker) do
        table.insert(formats, f)
    end
    return formats
end

---Opens the contract/offer/inbox dialog in the requested mode
function GlobalMarketContractDialog:show(mode, contextData, onConfirmCallback, callbackTarget)
    self.mode = mode
    self.context = contextData or {}
    self.target = callbackTarget
    self.callbackFunc = onConfirmCallback
    self.farmId = self.context.farmId or (g_currentMission ~= nil and g_currentMission:getFarmId() or 1)
    g_gui:showDialog("GlobalMarketContractDialog")
end

function GlobalMarketContractDialog:setAmountInputSilent(text)
    if self.amountInput ~= nil then
        self.isUpdatingAmountText = true
        self.amountInput:setText(tostring(text or "0"))
        self.isUpdatingAmountText = false
    end
end

function GlobalMarketContractDialog:onOpen()
    GlobalMarketContractDialog:superClass().onOpen(self)
    self.isInitializing = true
    self.currentAmount = 0
    self.maxAmount = 0
    self.currentCountFactor = 1
    self.currentUnitKey = "ui_gm_unit_liter"
    self.currentFormatXml = nil
    self.currentMaxPieces = nil
    self.isAmountLocked = false
    self.primaryOptions = {}
    self.storageOptions = {}
    self.formatOptions = {}
    self.termsOptions = {}
    self:setAmountInputSilent("0")
    self.isInitializing = false

    if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        self:setupCreateContractMode()
    elseif self.mode == GlobalMarketContractDialog.MODE_CREATE_OFFER then
        self:setupCreateOfferMode()
    elseif self.mode == GlobalMarketContractDialog.MODE_DELIVER_CONTRACT then
        self:setupDeliverContractMode()
    elseif self.mode == GlobalMarketContractDialog.MODE_BUY_OFFER then
        self:setupBuyOfferMode()
    elseif self.mode == GlobalMarketContractDialog.MODE_CLAIM_INBOX then
        self:setupClaimInboxMode()
    end

    if self.isAmountLocked then
        FocusManager:setFocus(self.selectorStorage ~= nil and self.selectorStorage.visible and self.selectorStorage or self.yesButton)
    else
        FocusManager:setFocus(self.amountInput)
    end
end

function GlobalMarketContractDialog:setHeaderVisuals(titleKey, fillTypeName, buttonKey)
    local ftDesc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
    self.fillTypeName = fillTypeName or ""
    self.fillTypeTitle = (ftDesc ~= nil and ftDesc.title) or self.fillTypeName
    local titlePrefix = g_i18n:getText(titleKey)
    if self.dialogTitleElement ~= nil then
        local txt = (fillTypeName ~= nil and fillTypeName ~= "")
            and string.format("%s: %s", titlePrefix, tostring(self.fillTypeTitle))
            or titlePrefix
        self.dialogTitleElement:setText(txt)
    end
    if self.dialogFillTypeIcon ~= nil then
        if ftDesc ~= nil and ftDesc.hudOverlayFilename ~= nil and ftDesc.hudOverlayFilename ~= "" then
            self.dialogFillTypeIcon:setImageFilename(ftDesc.hudOverlayFilename)
            self.dialogFillTypeIcon:setVisible(true)
        else
            self.dialogFillTypeIcon:setVisible(false)
        end
    end
    if self.headerBoxLayout ~= nil then
        self.headerBoxLayout:invalidateLayout()
    end
    if self.yesButton ~= nil then
        self.yesButton:setText(g_i18n:getText(buttonKey))
    end
end

function GlobalMarketContractDialog:setupCreateContractMode()
    local gm = g_currentMission.globalMarket
    self.primaryOptions = {}
    local rawList = (gm ~= nil and gm:getIsMarketOnline() and gm.fillTypes ~= nil and #gm.fillTypes > 0)
        and gm.fillTypes or (gm ~= nil and gm.offlineMarketFillTypes or {})

    for _, item in ipairs(rawList) do
        local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(item.fillType) or nil
        if desc ~= nil and (GlobalMarketAPI == nil or GlobalMarketAPI.getIsFillTypeAllowed(desc)) then
            local basePrice = gm:getContractReferencePricePer1000(item.fillType)
            table.insert(self.primaryOptions, {
                fillType = item.fillType,
                title = desc.title or item.fillType,
                sortKey = (GlobalMarketUI ~= nil and GlobalMarketUI.normalizeSortTitle)
                    and GlobalMarketUI.normalizeSortTitle(desc.title or item.fillType) or string.lower(item.fillType),
                basePrice = basePrice
            })
        end
    end
    table.sort(self.primaryOptions, function(a, b) return a.sortKey < b.sortKey end)

    self.storageOptions = {}
    for pct = GlobalMarketContracts.CONTRACT_PLAYER_BONUS_MIN, GlobalMarketContracts.CONTRACT_PLAYER_BONUS_MAX do
        table.insert(self.storageOptions, { bonusPct = pct })
    end

    self.termsOptions = {}
    for m = GlobalMarketContracts.CONTRACT_DURATION_MIN, GlobalMarketContracts.CONTRACT_DURATION_MAX do
        table.insert(self.termsOptions, {
            months = m,
            label = string.format(g_i18n:getText("ui_gm_dlg_optDuration"), m)
        })
    end

    self:configureSelectors(true, true, false, true)
    local fillTexts = {}
    for _, opt in ipairs(self.primaryOptions) do
        table.insert(fillTexts, string.format("%s (%s / 1.000 L)", opt.title, g_i18n:formatMoney(opt.basePrice, 0, true, true)))
    end
    if #fillTexts == 0 then
        self.selectorPrimary:setTexts({"-"})
        self.selectorPrimary:setState(1, false)
        self:updateStepButtonLabels()
        self:onAmountChanged()
        return
    end
    self.selectorPrimary:setTexts(fillTexts)
    self.selectorPrimary:setState(1, false)

    local termTexts = {}
    for _, t in ipairs(self.termsOptions) do table.insert(termTexts, t.label) end
    self.selectorTerms:setTexts(termTexts)
    self.selectorTerms:setState(math.min(3, #self.termsOptions), false)

    self:onClickPrimary(1)
    if #self.storageOptions >= 6 then
        self.selectorStorage:setState(6, false) -- Default +10%
        self:onClickStorage(6)
    end
end

function GlobalMarketContractDialog:setupCreateOfferMode()
    local gm = g_currentMission.globalMarket
    self.primaryOptions = {}
    local owned = gm ~= nil and gm:getAggregatedStorageData(self.farmId) or {}

    for _, entry in ipairs(owned) do
        if (entry.level or 0) > 0.01 then
            local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(entry.fillType) or nil
            if desc ~= nil and (GlobalMarketAPI == nil or GlobalMarketAPI.getIsFillTypeAllowed(desc)) then
                local spot = gm:getCurrentMarketPricePer1000(entry.fillType)
                table.insert(self.primaryOptions, {
                    fillType = entry.fillType,
                    title = desc.title or entry.fillType,
                    sortKey = (GlobalMarketUI ~= nil and GlobalMarketUI.normalizeSortTitle)
                        and GlobalMarketUI.normalizeSortTitle(desc.title or entry.fillType) or string.lower(entry.fillType),
                    spotPrice = spot
                })
            end
        end
    end
    table.sort(self.primaryOptions, function(a, b) return a.sortKey < b.sortKey end)

    self.formatOptions = {}
    for d = GlobalMarketContracts.OFFER_DELTA_MIN, GlobalMarketContracts.OFFER_DELTA_MAX do
        table.insert(self.formatOptions, { deltaPct = d })
    end

    self.termsOptions = {}
    for _, partial in ipairs({ true, false }) do
        for m = GlobalMarketContracts.OFFER_DURATION_MIN, GlobalMarketContracts.OFFER_DURATION_MAX do
            local key = partial and "ui_gm_dlg_optTermPartial" or "ui_gm_dlg_optTermFull"
            table.insert(self.termsOptions, {
                allowPartial = partial,
                months = m,
                label = string.format(g_i18n:getText(key), m)
            })
        end
    end

    self:configureSelectors(true, true, true, true)
    local fillTexts = {}
    for _, opt in ipairs(self.primaryOptions) do
        table.insert(fillTexts, string.format("%s (%s / 1.000 L)", opt.title, g_i18n:formatMoney(opt.spotPrice, 0, true, true)))
    end
    if #fillTexts == 0 then
        self.selectorPrimary:setTexts({"-"})
        self.selectorStorage:setTexts({"-"})
        self:updateStepButtonLabels()
        self:onAmountChanged()
        return
    end
    self.selectorPrimary:setTexts(fillTexts)
    self.selectorPrimary:setState(1, false)

    local termTexts = {}
    for _, t in ipairs(self.termsOptions) do table.insert(termTexts, t.label) end
    self.selectorTerms:setTexts(termTexts)
    self.selectorTerms:setState(2, false) -- Default: Allow Partial, 2 Months

    self.selectorFormat:setState(11, false) -- Default: 0%
    self:onClickPrimary(1)
end

function GlobalMarketContractDialog:setupStorageActionMode(titleKey, fillTypeName, buttonKey, lockAmount)
    self.storageOptions = self.context.silos or {}
    self.isAmountLocked = (lockAmount == true)
    self:setHeaderVisuals(titleKey, fillTypeName, buttonKey)
    self:configureSelectors(false, true, false, false)

    local sTexts = {}
    for _, s in ipairs(self.storageOptions) do table.insert(sTexts, s.title) end
    if #sTexts == 0 then
        self.selectorStorage:setTexts({"-"})
        self.maxAmount = 0
        self:updateStepButtonLabels()
        self:onAmountChanged()
        return
    end
    self.selectorStorage:setTexts(sTexts)
    self.selectorStorage:setState(1, false)
    self:onClickStorage(1)
end

function GlobalMarketContractDialog:setupDeliverContractMode()
    local c = self.context.contract or {}
    self:setupStorageActionMode("ui_gm_dlg_deliverContract", c.fillType, "ui_gm_btn_deliver", false)
end

function GlobalMarketContractDialog:setupBuyOfferMode()
    local o = self.context.offer or {}
    self:setupStorageActionMode("ui_gm_dlg_buyOffer", o.fillType, "ui_ingameMenuGlobalMarketSelectBtnBuy", not o.allowPartial)
end

function GlobalMarketContractDialog:setupClaimInboxMode()
    local p = self.context.inboxItem or {}
    self:setupStorageActionMode("ui_gm_dlg_claimInbox", p.fillType, "ui_gm_btn_claim", false)
end

function GlobalMarketContractDialog:configureSelectors(showPrimary, showStorage, showFormat, showTerms)
    if self.selectorPrimary ~= nil then self.selectorPrimary:setVisible(showPrimary) end
    if self.selectorStorage ~= nil then self.selectorStorage:setVisible(showStorage) end
    if self.selectorFormat ~= nil then self.selectorFormat:setVisible(showFormat) end
    if self.selectorTerms ~= nil then self.selectorTerms:setVisible(showTerms) end
end

function GlobalMarketContractDialog:onClickPrimary(state)
    local opt = self.primaryOptions[state]
    if opt == nil then return end

    if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        self:setHeaderVisuals("ui_gm_dlg_createContract", opt.fillType, "ui_gm_btn_create")
        local bTexts = {}
        for _, bo in ipairs(self.storageOptions) do
            local totalPer1k = opt.basePrice * (1 + (bo.bonusPct / 100))
            table.insert(bTexts, string.format(g_i18n:getText("ui_gm_dlg_optBonus"),
                bo.bonusPct, g_i18n:formatMoney(totalPer1k, 0, true, true)))
        end
        self.selectorStorage:setTexts(bTexts)
        local curB = self.selectorStorage:getState()
        self.selectorStorage:setState((curB >= 1 and curB <= #bTexts) and curB or 6, false)
        self.maxAmount = GlobalMarketContractDialog.MAX_CONTRACT_LITERS
        self.currentCountFactor = 1
        self.currentMaxPieces = nil
        self.currentUnitKey = "ui_gm_unit_liter"
        self:updateInfoBanner(string.format("%s: %s / 1.000 L | %s",
            g_i18n:getText("ui_ingameMenuGlobalMarketPrice"),
            g_i18n:formatMoney(opt.basePrice, 0, true, true),
            g_i18n:getText("ui_gm_receipt_inboxTarget")))
        self:updateStepButtonLabels()
        self:onAmountChanged()

    elseif self.mode == GlobalMarketContractDialog.MODE_CREATE_OFFER then
        self:setHeaderVisuals("ui_gm_dlg_createOffer", opt.fillType, "ui_gm_btn_create")
        local dTexts = {}
        for _, dOpt in ipairs(self.formatOptions) do
            local p = opt.spotPrice * (1 + (dOpt.deltaPct / 100))
            table.insert(dTexts, string.format(g_i18n:getText("ui_gm_dlg_optDelta"),
                dOpt.deltaPct, g_i18n:formatMoney(p, 0, true, true)))
        end
        self.selectorFormat:setTexts(dTexts)
        local curD = self.selectorFormat:getState()
        self.selectorFormat:setState((curD >= 1 and curD <= #dTexts) and curD or 11, false)

        -- Flatten available sources + ObjectStorage format stacks into selectorStorage
        local gm = g_currentMission.globalMarket
        local rawSilos = gm ~= nil and gm:getAvailableStorages(opt.fillType, self.farmId, true) or {}
        self.storageOptions = {}
        for _, s in ipairs(rawSilos) do
            if not s.isObjectStorage then
                table.insert(self.storageOptions, s)
            else
                for _, f in ipairs(GlobalMarketContractDialog.collectOwnedFormats(opt.fillType, s, self.farmId)) do
                    table.insert(self.storageOptions, {
                        storage = s.storage,
                        id = s.id,
                        title = string.format("%s: %s (x%d)", s.title, f.title, f.actualCount),
                        level = (f.actualCount or 0) * (f.capacity or 1000),
                        isGmMarket = s.isGmMarket,
                        isObjectStorage = true,
                        formatXml = f.xml,
                        capacityPerObject = f.capacity,
                        unitKey = f.unitKey,
                        actualCount = f.actualCount
                    })
                end
            end
        end
        local sTexts = {}
        for _, s in ipairs(self.storageOptions) do table.insert(sTexts, s.title) end
        if #sTexts == 0 then
            self.selectorStorage:setTexts({"-"})
            self.maxAmount = 0
            self:updateStepButtonLabels()
            self:onAmountChanged()
            return
        end
        self.selectorStorage:setTexts(sTexts)
        self.selectorStorage:setState(1, false)
        self:onClickStorage(1)
    end
end

function GlobalMarketContractDialog:onClickStorage(state)
    if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        local opt = self.primaryOptions[self.selectorPrimary:getState()]
        local bOpt = self.storageOptions[state]
        if opt ~= nil and bOpt ~= nil then
            local eff = (opt.basePrice or 500) * (1 + ((bOpt.bonusPct or 10) / 100))
            self:updateInfoBanner(string.format("+%d%% Bonus -> %s / 1.000 L | %s",
                bOpt.bonusPct or 10, g_i18n:formatMoney(eff, 0, true, true), g_i18n:getText("ui_gm_receipt_inboxTarget")))
        end
        self:onAmountChanged()
        return
    end

    local selectedSilo = self.storageOptions[state]
    if self.mode ~= GlobalMarketContractDialog.MODE_CREATE_OFFER and self.selectorFormat ~= nil then
        self.selectorFormat:setVisible(false)
    end
    self.currentCountFactor = 1
    self.currentUnitKey = "ui_gm_unit_liter"
    self.currentFormatXml = nil
    self.currentMaxPieces = nil

    if selectedSilo == nil then
        self.maxAmount = 0
        self:onAmountChanged()
        return
    end

    if self.mode == GlobalMarketContractDialog.MODE_CREATE_OFFER then
        if selectedSilo.isObjectStorage then
            self.currentCountFactor = selectedSilo.capacityPerObject or 1000
            self.currentUnitKey = selectedSilo.unitKey or "ui_gm_unit_piece"
            self.currentFormatXml = selectedSilo.formatXml
            self.currentMaxPieces = selectedSilo.actualCount or 0
            self.maxAmount = selectedSilo.level or 0
        else
            self.maxAmount = selectedSilo.level or 0
        end
        self:setAmountInputSilent("0")
        self:updateInfoBanner(string.format("%s: %s L",
            g_i18n:getText("ui_ingameMenuGlobalMarketAvailable"),
            g_i18n:formatVolume(self.maxAmount, 0)))
        self:updateStepButtonLabels()
        self:onAmountChanged()
        return
    end

    -- Modes with target/source ObjectStorage format selector: DELIVER_CONTRACT, BUY_OFFER, CLAIM_INBOX
    if self.mode == GlobalMarketContractDialog.MODE_DELIVER_CONTRACT then
        local c = self.context.contract or {}
        local needed = math.max(0, (c.totalLiters or 0) - (c.deliveredLiters or 0))
        self.maxAmount = math.min(selectedSilo.level or 0, needed)
        self.formatOptions = selectedSilo.isObjectStorage
            and GlobalMarketContractDialog.collectOwnedFormats(c.fillType, selectedSilo, self.farmId) or {}
    elseif self.mode == GlobalMarketContractDialog.MODE_BUY_OFFER then
        local o = self.context.offer or {}
        self.maxAmount = math.min(selectedSilo.freeCapacity or 0, o.remainingLiters or 0)
        self.formatOptions = selectedSilo.isObjectStorage
            and GlobalMarketContractDialog.collectBuyableFormats(o.fillType, selectedSilo) or {}
    elseif self.mode == GlobalMarketContractDialog.MODE_CLAIM_INBOX then
        local p = self.context.inboxItem or {}
        self.maxAmount = math.min(selectedSilo.freeCapacity or 0, p.liters or 0)
        self.formatOptions = selectedSilo.isObjectStorage
            and GlobalMarketContractDialog.collectBuyableFormats(p.fillType, selectedSilo) or {}
    end

    if selectedSilo.isObjectStorage and #self.formatOptions > 0 and self.selectorFormat ~= nil then
        local fTexts = {}
        for _, f in ipairs(self.formatOptions) do table.insert(fTexts, f.title) end
        self.selectorFormat:setTexts(fTexts)
        self.selectorFormat:setVisible(true)
        self.selectorFormat:setState(1, false)
        self:onClickFormat(1)
    elseif selectedSilo.isObjectStorage then
        self.maxAmount = 0
        self:refreshNonObjectBannerAndAmount()
    else
        self:refreshNonObjectBannerAndAmount()
    end
end

function GlobalMarketContractDialog:onClickFormat(state)
    if self.mode == GlobalMarketContractDialog.MODE_CREATE_OFFER then
        self:onAmountChanged()
        return
    end

    local f = self.formatOptions[state]
    local selectedSilo = self.storageOptions[self.selectorStorage:getState()]
    if f == nil or selectedSilo == nil then return end

    self.currentFormatXml = f.xml
    self.currentCountFactor = f.capacity or 1000
    self.currentUnitKey = f.unitKey or "ui_gm_unit_piece"

    if self.mode == GlobalMarketContractDialog.MODE_DELIVER_CONTRACT then
        local c = self.context.contract or {}
        local needed = math.max(0, (c.totalLiters or 0) - (c.deliveredLiters or 0))
        local maxByContract = math.max(1, math.ceil(needed / self.currentCountFactor))
        self.currentMaxPieces = math.min(f.actualCount or 0, maxByContract)
    else
        local spec = selectedSilo.storage ~= nil and selectedSilo.storage.spec_objectStorage or nil
        local freeSlots = (spec ~= nil) and math.max(0, (spec.capacity or 250) - (spec.numStoredObjects or 0)) or 0
        local maxLiters = (self.mode == GlobalMarketContractDialog.MODE_BUY_OFFER)
            and (self.context.offer.remainingLiters or 0) or (self.context.inboxItem.liters or 0)
        local maxFromLot = math.floor((maxLiters + 0.01) / self.currentCountFactor)
        self.currentMaxPieces = math.min(freeSlots, maxFromLot)
    end

    self:updateInfoBanner(string.format(g_i18n:getText("ui_gm_format_info"),
        f.title, self.currentMaxPieces, self.currentCountFactor))
    self:updateStepButtonLabels()
    self:setAmountInputSilent("0")
    self:onAmountChanged()
end

function GlobalMarketContractDialog:onClickTerms()
    self:onAmountChanged()
end

function GlobalMarketContractDialog:refreshNonObjectBannerAndAmount()
    local banner = string.format("%s: %s",
        g_i18n:getText("ui_ingameMenuGlobalMarketAvailable"), g_i18n:formatVolume(self.maxAmount, 0))
    if self.mode == GlobalMarketContractDialog.MODE_BUY_OFFER then
        local o = self.context.offer or {}
        local price = (o.refPricePer1000 or 500) * (1 + ((o.priceDeltaPct or 0) / 100))
        banner = string.format("%s | %s: %s / 1.000L (%+d%%)",
            banner, g_i18n:getText("ui_ingameMenuGlobalMarketPrice"),
            g_i18n:formatMoney(price, 0, true, true), o.priceDeltaPct or 0)
    elseif self.mode == GlobalMarketContractDialog.MODE_DELIVER_CONTRACT then
        local c = self.context.contract or {}
        banner = string.format("%s | %s: %s / 1.000L (+%d%%)",
            banner, g_i18n:getText("ui_ingameMenuGlobalMarketPrice"),
            g_i18n:formatMoney(c.basePricePer1000 or 500, 0, true, true), c.bonusPct or 0)
    end
    self:updateInfoBanner(banner)
    self:updateStepButtonLabels()
    self:setAmountInputSilent("0")
    self:onAmountChanged()
end

function GlobalMarketContractDialog:updateInfoBanner(text)
    self.baseInfoText = text or ""
    if self.dialogInfoTextElement ~= nil then
        self.dialogInfoTextElement:setText(self.baseInfoText)
        self.dialogInfoTextElement:setTextColor(COLOR_LABEL[1], COLOR_LABEL[2], COLOR_LABEL[3], COLOR_LABEL[4])
    end
end

function GlobalMarketContractDialog:getEffectiveMaxAmount()
    if self.currentCountFactor > 1 and self.currentMaxPieces ~= nil then
        return math.max(0, math.min(math.floor(self.currentMaxPieces), GlobalMarketContractDialog.MAX_OBJECTS_PER_TX))
    end
    return math.max(0, math.floor(self.maxAmount or 0))
end

function GlobalMarketContractDialog:getLockedFullAmount()
    if not self.isAmountLocked then return nil end
    local o = self.context.offer or {}
    local rem = o.remainingLiters or 0
    if self.currentCountFactor > 1 then
        return math.max(0, math.floor((rem + 0.01) / self.currentCountFactor))
    end
    return math.max(0, math.floor(rem + 0.5))
end

function GlobalMarketContractDialog:updateStepButtonLabels()
    local labels
    if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        labels = GlobalMarketContractDialog.CONTRACT_STEP_LABELS
    elseif self.currentCountFactor > 1 then
        labels = GlobalMarketContractDialog.OBJECT_STEP_LABELS
    else
        labels = GlobalMarketContractDialog.BULK_STEP_LABELS
    end

    local buttons = { self.btnStepMinus3, self.btnStepMinus2, self.btnStepMinus1, self.btnStepPlus1, self.btnStepPlus2, self.btnStepPlus3 }
    for i = 1, 6 do
        if buttons[i] ~= nil then
            buttons[i]:setText(labels[i])
            buttons[i]:setDisabled(self.isAmountLocked)
        end
    end
    if self.zeroButton ~= nil then self.zeroButton:setDisabled(self.isAmountLocked) end
    if self.maxButton ~= nil then self.maxButton:setDisabled(self.isAmountLocked) end
    if self.amountInput ~= nil then self.amountInput:setDisabled(self.isAmountLocked) end
end

function GlobalMarketContractDialog:applyStep(tierIndex, direction)
    if self.isAmountLocked then return end
    local steps
    if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        steps = GlobalMarketContractDialog.CONTRACT_STEPS
    elseif self.currentCountFactor > 1 then
        steps = GlobalMarketContractDialog.OBJECT_STEPS
    else
        steps = GlobalMarketContractDialog.BULK_STEPS
    end
    local cur = tonumber(self.amountInput ~= nil and self.amountInput:getText() or "0") or self.currentAmount or 0
    local nextVal = math.clamp(math.floor(cur + ((steps[tierIndex] or 0) * direction)), 0, self:getEffectiveMaxAmount())
    self:setAmountInputSilent(string.format("%d", nextVal))
    self:onAmountChanged()
end

function GlobalMarketContractDialog:onClickZeroAmount()
    if self.isAmountLocked then return end
    self:setAmountInputSilent("0")
    self:onAmountChanged()
end

function GlobalMarketContractDialog:onClickStepMinus3() self:applyStep(3, -1) end
function GlobalMarketContractDialog:onClickStepMinus2() self:applyStep(2, -1) end
function GlobalMarketContractDialog:onClickStepMinus1() self:applyStep(1, -1) end
function GlobalMarketContractDialog:onClickStepPlus1()  self:applyStep(1, 1)  end
function GlobalMarketContractDialog:onClickStepPlus2()  self:applyStep(2, 1)  end
function GlobalMarketContractDialog:onClickStepPlus3()  self:applyStep(3, 1)  end

function GlobalMarketContractDialog:onClickMaxAmount()
    if self.isAmountLocked then return end
    local fill = self:getEffectiveMaxAmount()
    local money = g_currentMission ~= nil and g_currentMission:getMoney() or 0

    if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        local opt = self.primaryOptions[self.selectorPrimary:getState()]
        local bOpt = self.storageOptions[self.selectorStorage:getState()]
        if opt ~= nil and bOpt ~= nil and money > 0 then
            local ratePerL = (opt.basePrice / 1000) * (1 + (bOpt.bonusPct / 100))
            if ratePerL > 0 then fill = math.min(fill, math.floor(money / ratePerL)) end
        elseif money <= 0 then
            fill = 0
        end
    elseif self.mode == GlobalMarketContractDialog.MODE_BUY_OFFER then
        local o = self.context.offer or {}
        local s = self.storageOptions[self.selectorStorage:getState()]
        local isGm = s ~= nil and s.isGmMarket == true
        local baseFee = isGm and 0 or ((GlobalMarket.DELIVER_COST or 0) * EconomyManager.getCostMultiplier())
        local perL = isGm and 0 or ((GlobalMarket.DELIVER_COST_PERLITER or 0) * EconomyManager.getCostMultiplier())
        local unitCost = ((o.refPricePer1000 or 500) * (1 + ((o.priceDeltaPct or 0) / 100)) / 1000) + perL
        if money <= baseFee or unitCost <= 0 then
            fill = 0
        else
            local affordL = (money - baseFee) / unitCost
            fill = (self.currentCountFactor > 1)
                and math.min(fill, math.floor(affordL / self.currentCountFactor))
                or math.min(fill, math.floor(affordL))
        end
    end

    fill = math.max(0, math.floor(fill))
    self:setAmountInputSilent(string.format("%d", fill))
    self:onAmountChanged()
end

function GlobalMarketContractDialog:onAmountChanged()
    if self.isInitializing or self.isUpdatingAmountText then return end
    local locked = self:getLockedFullAmount()
    local amount
    if locked ~= nil then
        amount = math.min(locked, self:getEffectiveMaxAmount())
        self:setAmountInputSilent(tostring(amount))
    else
        local text = self.amountInput ~= nil and self.amountInput:getText() or "0"
        local parsed = tonumber(text)
        local effMax = self:getEffectiveMaxAmount()
        amount = math.clamp(math.floor(parsed or 0), 0, effMax)
        if self.amountInput ~= nil and parsed ~= nil and (parsed < 0 or parsed > effMax or parsed ~= amount) then
            self:setAmountInputSilent(tostring(amount))
        end
    end
    self.currentAmount = amount

    if self.inputUnitText ~= nil then
        self.inputUnitText:setText(g_i18n:getText((self.currentCountFactor > 1 and self.currentUnitKey) or "ui_gm_unit_liter"))
    end
    self:updateReceipt()
end

function GlobalMarketContractDialog:setReceiptRow(labelEl, valueEl, labelTxt, valTxt, vCol, lCol)
    local lc, vc = lCol or COLOR_LABEL, vCol or COLOR_WHITE
    if labelEl ~= nil then labelEl:setText(labelTxt or ""); labelEl:setTextColor(lc[1], lc[2], lc[3], lc[4]) end
    if valueEl ~= nil then valueEl:setText(valTxt or ""); valueEl:setTextColor(vc[1], vc[2], vc[3], vc[4]) end
end

function GlobalMarketContractDialog:formatShippingValue(isGm, cost, isDeducted)
    if isGm then
        return string.format(g_i18n:getText("ui_gm_receipt_freeTerminal"), g_i18n:formatMoney(0, 0, true, true)), COLOR_GREEN
    elseif cost > 0 then
        return ((isDeducted and "- " or "+ ") .. g_i18n:formatMoney(cost, 0, true, true)), COLOR_AMBER
    end
    return g_i18n:formatMoney(0, 0, true, true), COLOR_MUTED
end

function GlobalMarketContractDialog:updateReceipt()
    local liters = self.currentAmount * self.currentCountFactor
    local money = g_currentMission ~= nil and g_currentMission:getMoney() or 0
    local qtyText = (self.currentCountFactor > 1)
        and string.format("%d %s (%s)", self.currentAmount, g_i18n:getText(self.currentUnitKey or "ui_gm_unit_piece"), g_i18n:formatVolume(liters, 0))
        or g_i18n:formatVolume(liters, 0)
    self:setReceiptRow(self.receiptRow1Label, self.receiptRow1Value, g_i18n:getText("ui_gm_receipt_quantity"), qtyText, COLOR_WHITE)

    local s = self.storageOptions[self.selectorStorage ~= nil and self.selectorStorage:getState() or 1]
    local isGm = s ~= nil and s.isGmMarket == true
    local shipCost = 0
    if s ~= nil and not isGm and liters > 0 and self.mode ~= GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        shipCost = ((GlobalMarket.DELIVER_COST or 0) + ((GlobalMarket.DELIVER_COST_PERLITER or 0) * liters)) * EconomyManager.getCostMultiplier()
    end

    local isDebit, finalTotal, validInput = true, 0, (self.currentAmount > 0)
    if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
        local opt = self.primaryOptions[self.selectorPrimary:getState()]
        local bOpt = self.storageOptions[self.selectorStorage:getState()]
        local basePrice = (opt ~= nil and opt.basePrice) or 500
        local bonusPct = (bOpt ~= nil and bOpt.bonusPct) or 10
        local baseTotal = (liters / 1000) * basePrice
        local bonusVal = baseTotal * (bonusPct / 100)
        finalTotal = (liters > 0) and math.ceil(baseTotal + bonusVal) or 0
        validInput = (liters >= 1000)
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value, g_i18n:getText("ui_gm_receipt_unitPrice"),
            string.format("%s / 1.000 L", g_i18n:formatMoney(basePrice, 0, true, true)), COLOR_MUTED)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value, g_i18n:getText("ui_gm_receipt_goodsValue"),
            g_i18n:formatMoney(baseTotal, 0, true, true), COLOR_WHITE)
        self:setReceiptRow(self.receiptRow4Label, self.receiptRow4Value,
            string.format(g_i18n:getText("ui_gm_receipt_contractBonus"), bonusPct),
            "+ " .. g_i18n:formatMoney(bonusVal, 0, true, true), COLOR_GREEN)
        self:applyFinalBalanceRows(g_i18n:getText("ui_gm_receipt_escrowTotal"), finalTotal, money, true, validInput)

    elseif self.mode == GlobalMarketContractDialog.MODE_CREATE_OFFER then
        isDebit = false
        local opt = self.primaryOptions[self.selectorPrimary:getState()]
        local dOpt = self.formatOptions[self.selectorFormat:getState()]
        local spotPrice = (opt ~= nil and opt.spotPrice) or 500
        local deltaPct = (dOpt ~= nil and dOpt.deltaPct) or 0
        local effPer1k = spotPrice * (1 + (deltaPct / 100))
        local baseVal = (liters / 1000) * effPer1k
        finalTotal = math.max(0, math.floor(baseVal + 0.5) - shipCost)
        local shipTxt, shipCol = self:formatShippingValue(isGm, shipCost, true)
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value, g_i18n:getText("ui_gm_receipt_unitPrice"),
            string.format("%s / 1.000 L (%+d%%)", g_i18n:formatMoney(effPer1k, 0, true, true), deltaPct), COLOR_MUTED)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value, g_i18n:getText("ui_gm_receipt_goodsValue"),
            g_i18n:formatMoney(baseVal, 0, true, true), COLOR_WHITE)
        self:setReceiptRow(self.receiptRow4Label, self.receiptRow4Value, g_i18n:getText("ui_gm_receipt_shipping"), shipTxt, shipCol)
        self:applyFinalBalanceRows(g_i18n:getText("ui_gm_receipt_totalSell"), finalTotal, money, false, validInput and (money >= shipCost))

    elseif self.mode == GlobalMarketContractDialog.MODE_DELIVER_CONTRACT then
        isDebit = false
        local c = self.context.contract or {}
        local needed = math.max(0, (c.totalLiters or 0) - (c.deliveredLiters or 0))
        local credited = math.min(liters, needed)
        local excess = math.max(0, liters - credited)
        local newPct = math.min(100, math.floor((((c.deliveredLiters or 0) + credited) / math.max(1, c.totalLiters or 1)) * 100 + 0.5))
        local basePay = math.floor(((credited / 1000) * (c.basePricePer1000 or 500)) + 0.5)
        local bonusPay = 0
        if ((c.deliveredLiters or 0) + credited) >= ((c.totalLiters or 0) - 0.5) and credited > 0 then
            bonusPay = (c.origin == "PLAYER")
                and math.max(0, math.floor((c.escrowRemaining or 0) - basePay + 0.5))
                or math.floor(((c.totalLiters / 1000) * (c.basePricePer1000 or 500) * ((c.bonusPct or 0) / 100)) + 0.5)
        end
        local spotPay = 0
        if excess > 0.5 and g_currentMission.globalMarket ~= nil then
            spotPay = math.floor(((excess / 1000) * g_currentMission.globalMarket:getCurrentMarketPricePer1000(c.fillType)) + 0.5)
        end
        finalTotal = math.max(0, basePay + bonusPay + spotPay - shipCost)
        local shipTxt, shipCol = self:formatShippingValue(isGm, shipCost, true)
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value, g_i18n:getText("ui_gm_receipt_progressAfter"),
            string.format("%s (%d%%)", g_i18n:formatVolume((c.deliveredLiters or 0) + credited, 0), newPct), COLOR_WHITE)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value, g_i18n:getText("ui_gm_receipt_payoutBonus"),
            string.format("%s / +%s", g_i18n:formatMoney(basePay, 0, true, true), g_i18n:formatMoney(bonusPay + spotPay, 0, true, true)),
            (bonusPay > 0) and COLOR_GREEN or COLOR_WHITE)
        self:setReceiptRow(self.receiptRow4Label, self.receiptRow4Value, g_i18n:getText("ui_gm_receipt_shipping"), shipTxt, shipCol)
        self:applyFinalBalanceRows(g_i18n:getText("ui_gm_receipt_totalSell"), finalTotal, money, false, validInput)

    elseif self.mode == GlobalMarketContractDialog.MODE_BUY_OFFER then
        local o = self.context.offer or {}
        local effPer1k = (o.refPricePer1000 or 500) * (1 + ((o.priceDeltaPct or 0) / 100))
        local baseCost = math.floor((liters * (effPer1k / 1000)) + 0.5)
        finalTotal = baseCost + shipCost
        local fullFitOk = (not self.isAmountLocked) or (liters >= ((o.remainingLiters or 0) - 0.5) and s ~= nil)
        local shipTxt, shipCol = self:formatShippingValue(isGm, shipCost, false)
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value, g_i18n:getText("ui_gm_receipt_goodsValue"),
            g_i18n:formatMoney(baseCost, 0, true, true), COLOR_WHITE)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value, g_i18n:getText("ui_gm_settings_markup"),
            string.format(g_i18n:getText("ui_gm_receipt_zeroCommission"), g_i18n:formatMoney(0, 0, true, true)), COLOR_GREEN)
        self:setReceiptRow(self.receiptRow4Label, self.receiptRow4Value, g_i18n:getText("ui_gm_receipt_shipping"), shipTxt, shipCol)
        self:applyFinalBalanceRows(g_i18n:getText("ui_gm_receipt_totalBuy"), finalTotal, money, true, validInput and fullFitOk)

    elseif self.mode == GlobalMarketContractDialog.MODE_CLAIM_INBOX then
        local p = self.context.inboxItem or {}
        local remain = math.max(0, (p.liters or 0) - liters)
        finalTotal = shipCost
        local shipTxt, shipCol = self:formatShippingValue(isGm, shipCost, false)
        self:setReceiptRow(self.receiptRow2Label, self.receiptRow2Value, g_i18n:getText("ui_gm_receipt_inboxRemain"),
            g_i18n:formatVolume(remain, 0), COLOR_WHITE)
        self:setReceiptRow(self.receiptRow3Label, self.receiptRow3Value, g_i18n:getText("ui_gm_receipt_goodsValue"),
            string.format(g_i18n:getText("ui_gm_receipt_ownedGoods"), g_i18n:formatMoney(0, 0, true, true)), COLOR_GREEN)
        self:setReceiptRow(self.receiptRow4Label, self.receiptRow4Value, g_i18n:getText("ui_gm_receipt_shipping"), shipTxt, shipCol)
        self:applyFinalBalanceRows(g_i18n:getText("ui_gm_receipt_totalBuy"), finalTotal, money, true, validInput)
    end
end

function GlobalMarketContractDialog:applyFinalBalanceRows(totalLabel, finalTotal, money, isDebit, validAction)
    if isDebit and finalTotal > 0 and money < finalTotal then
        self:setReceiptRow(self.receiptTotalLabel, self.receiptTotalValue, totalLabel,
            g_i18n:formatMoney(finalTotal, 0, true, true), COLOR_RED, COLOR_WHITE)
        self:setReceiptRow(self.receiptBalanceLabel, self.receiptBalanceValue, g_i18n:getText("ui_gm_receipt_shortfall"),
            "- " .. g_i18n:formatMoney(finalTotal - money, 0, true, true), COLOR_RED, COLOR_RED)
        if self.yesButton ~= nil then self.yesButton:setDisabled(true) end
        return
    end

    local totalTxt = g_i18n:formatMoney(finalTotal, 0, true, true)
    if not isDebit and finalTotal > 0 then totalTxt = "+ " .. totalTxt end
    local totCol = (self.currentAmount > 0) and COLOR_GREEN or COLOR_MUTED
    self:setReceiptRow(self.receiptTotalLabel, self.receiptTotalValue, totalLabel, totalTxt, totCol, COLOR_WHITE)

    local balAfter = isDebit and (money - finalTotal) or (money + finalTotal)
    self:setReceiptRow(self.receiptBalanceLabel, self.receiptBalanceValue, g_i18n:getText("ui_gm_receipt_balanceAfter"),
        g_i18n:formatMoney(balAfter, 0, true, true), (balAfter < 0) and COLOR_RED or COLOR_BAL_OK, COLOR_LABEL)

    if self.yesButton ~= nil then
        self.yesButton:setDisabled(not validAction)
    end
end

function GlobalMarketContractDialog:onClickOk()
    local liters = self.currentAmount * self.currentCountFactor
    local s = self.storageOptions[self.selectorStorage ~= nil and self.selectorStorage:getState() or 1]

    if liters > 0 and ContractActionEvent ~= nil then
        if self.mode == GlobalMarketContractDialog.MODE_CREATE_CONTRACT then
            local opt = self.primaryOptions[self.selectorPrimary:getState()]
            local bOpt = s
            local tOpt = self.termsOptions[self.selectorTerms:getState()]
            if opt ~= nil and bOpt ~= nil and tOpt ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_CREATE_CONTRACT,
                    self.farmId, 0, opt.fillType, liters, bOpt.bonusPct, tOpt.months, false, nil, false, nil, 0)
            end
        elseif self.mode == GlobalMarketContractDialog.MODE_CREATE_OFFER and s ~= nil then
            local opt = self.primaryOptions[self.selectorPrimary:getState()]
            local dOpt = self.formatOptions[self.selectorFormat:getState()]
            local tOpt = self.termsOptions[self.selectorTerms:getState()]
            if opt ~= nil and dOpt ~= nil and tOpt ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_CREATE_OFFER,
                    self.farmId, 0, opt.fillType, liters, dOpt.deltaPct, tOpt.months,
                    tOpt.allowPartial, s.id, s.isObjectStorage, s.formatXml, s.capacityPerObject or 0)
            end
        elseif self.mode == GlobalMarketContractDialog.MODE_DELIVER_CONTRACT and s ~= nil then
            local c = self.context.contract
            if c ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_DELIVER_CONTRACT,
                    self.farmId, c.id, c.fillType, liters, 0, 1, false,
                    s.id, s.isObjectStorage, self.currentFormatXml, self.currentCountFactor)
            end
        elseif self.mode == GlobalMarketContractDialog.MODE_BUY_OFFER and s ~= nil then
            local o = self.context.offer
            if o ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_BUY_OFFER,
                    self.farmId, o.id, o.fillType, liters, 0, 1, false,
                    s.id, s.isObjectStorage, self.currentFormatXml, self.currentCountFactor)
            end
        elseif self.mode == GlobalMarketContractDialog.MODE_CLAIM_INBOX and s ~= nil then
            local p = self.context.inboxItem
            if p ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_CLAIM_INBOX,
                    self.farmId, p.id, p.fillType, liters, 0, 1, false,
                    s.id, s.isObjectStorage, self.currentFormatXml, self.currentCountFactor)
            end
        end
    end

    if self.callbackFunc ~= nil then
        self.callbackFunc(self.target, self.mode, s ~= nil and s.isObjectStorage == true)
    end
    GlobalMarketContractDialog:superClass().onClickOk(self)
    self:close()
    return false
end

function GlobalMarketContractDialog:onClickBack()
    GlobalMarketContractDialog:superClass().onClickBack(self)
    self:close()
    return false
end

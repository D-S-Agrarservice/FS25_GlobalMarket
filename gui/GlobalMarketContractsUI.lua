-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractsUI.lua
-- Sub-tab controller for Supply Contracts (#25), +/-10% Direct Offers & Pickup Inbox.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketContractsUI = {}
GlobalMarketContractsUI.activeUi = nil

GlobalMarketUI.SUBTAB_SPOT      = 1
GlobalMarketUI.SUBTAB_CONTRACTS = 2

GlobalMarketUI.BOARD_FILTER_ALL       = 1
GlobalMarketUI.BOARD_FILTER_CONTRACTS = 2
GlobalMarketUI.BOARD_FILTER_OFFERS    = 3

local COLOR_ACTIVE_TAB_TEXT = { 0.004, 0.005, 0.004, 1 }
local COLOR_WHITE_TEXT      = { 1, 1, 1, 1 }
local COLOR_BARGAIN         = { 0.46, 0.80, 0.15, 1 }
local COLOR_MARKUP          = { 0.95, 0.68, 0.20, 1 }
local COLOR_URGENT          = { 0.92, 0.28, 0.22, 1 }
local COLOR_LIGHT           = { 0.90, 0.92, 0.82, 1 }
local COLOR_MUTED           = { 0.65, 0.67, 0.70, 1 }

---Initializes Sub-Tab 2 controls and binds SmoothList delegates cleanly onto GlobalMarketContractsUI
function GlobalMarketUI:initContractsSubTab()
    GlobalMarketContractsUI.activeUi = self
    self.activeSubTab = self.activeSubTab or GlobalMarketUI.SUBTAB_SPOT
    self.boardFilter = self.boardFilter or GlobalMarketUI.BOARD_FILTER_ALL
    self.contractsListFocus = "left"
    self.myContractSections = {}
    self.boardContractSections = {}

    if self.gmTableMyContracts ~= nil then
        self.gmTableMyContracts:setDataSource(GlobalMarketContractsUI)
        self.gmTableMyContracts:setDelegate(GlobalMarketContractsUI)
    end
    if self.gmTableContractBoard ~= nil then
        self.gmTableContractBoard:setDataSource(GlobalMarketContractsUI)
        self.gmTableContractBoard:setDelegate(GlobalMarketContractsUI)
    end
    self:setActiveSubTab(self.activeSubTab, false)
end

---Called inside GlobalMarketUI:onFrameOpen to prepare sub-tab buttons, menu footer hints & focus
function GlobalMarketUI:onContractsFrameOpen()
    local backButton = { inputAction = InputAction.MENU_BACK }
    self.switchSubTabButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = self.i18n:getText("ui_gm_subtab_switch"),
        callback = function() self:onClickToggleSubTab() end,
        disabled = false
    }
    self.contractsActionButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = self.i18n:getText("ui_gm_action_acceptContract"),
        callback = function() self:onContractPrimaryAction() end,
        disabled = true
    }
    self.contractsCancelButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = self.i18n:getText("ui_gm_action_cancelListing"),
        callback = function() self:onContractCancelAction() end,
        disabled = true
    }
    self.boardFilterButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = self:getBoardFilterText(),
        callback = function() self:onClickCycleBoardFilter() end,
        disabled = false
    }
    -- Tag/untag the target station on the map (#27), basegame prices menu pattern
    self.contractsMarkerButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("action_tag"),
        callback = function() self:onContractToggleMarker() end,
        disabled = false
    }

    self:updateCategoryModeButtonVisuals()
    self:setActiveSubTab(self.activeSubTab or GlobalMarketUI.SUBTAB_SPOT, false)
    self:updateContent()

    if self.activeSubTab == GlobalMarketUI.SUBTAB_CONTRACTS then
        local focusTarget = (self.contractsListFocus == "right") and self.gmTableContractBoard or self.gmTableMyContracts
        if focusTarget ~= nil then
            FocusManager:setFocus(focusTarget)
        end
    elseif self.gmTableStorage ~= nil then
        FocusManager:setFocus(self.gmTableStorage)
    end
end

function GlobalMarketUI:getBoardFilterText()
    if self.boardFilter == GlobalMarketUI.BOARD_FILTER_CONTRACTS then
        return self.i18n:getText("ui_gm_filter_contracts")
    elseif self.boardFilter == GlobalMarketUI.BOARD_FILTER_OFFERS then
        return self.i18n:getText("ui_gm_filter_offers")
    end
    return self.i18n:getText("ui_gm_filter_all")
end

function GlobalMarketUI:onClickSubTabSpot()
    self:setActiveSubTab(GlobalMarketUI.SUBTAB_SPOT, true)
end

function GlobalMarketUI:onClickSubTabContracts()
    self:setActiveSubTab(GlobalMarketUI.SUBTAB_CONTRACTS, true)
end

function GlobalMarketUI:onClickToggleSubTab()
    local nextTab = (self.activeSubTab == GlobalMarketUI.SUBTAB_SPOT)
        and GlobalMarketUI.SUBTAB_CONTRACTS or GlobalMarketUI.SUBTAB_SPOT
    self:setActiveSubTab(nextTab, true)
end

function GlobalMarketUI:setActiveSubTab(tabIndex, restoreFocus)
    self.activeSubTab = tabIndex or GlobalMarketUI.SUBTAB_SPOT
    local isContracts = (self.activeSubTab == GlobalMarketUI.SUBTAB_CONTRACTS)

    if self.subTabSpotContainer ~= nil then self.subTabSpotContainer:setVisible(not isContracts) end
    if self.subTabContractsContainer ~= nil then self.subTabContractsContainer:setVisible(isContracts) end

    if self.bgSubTabSpotActive ~= nil then self.bgSubTabSpotActive:setVisible(not isContracts) end
    if self.bgSubTabSpotInactive ~= nil then self.bgSubTabSpotInactive:setVisible(isContracts) end
    if self.bgSubTabContractsActive ~= nil then self.bgSubTabContractsActive:setVisible(isContracts) end
    if self.bgSubTabContractsInactive ~= nil then self.bgSubTabContractsInactive:setVisible(not isContracts) end

    local spotCol = isContracts and COLOR_WHITE_TEXT or COLOR_ACTIVE_TAB_TEXT
    local conCol = isContracts and COLOR_ACTIVE_TAB_TEXT or COLOR_WHITE_TEXT
    if self.btnSubTabSpot ~= nil then self.btnSubTabSpot:setTextColor(spotCol[1], spotCol[2], spotCol[3], spotCol[4]) end
    if self.btnSubTabContracts ~= nil then self.btnSubTabContracts:setTextColor(conCol[1], conCol[2], conCol[3], conCol[4]) end

    self:refreshSubTabBadge()
    if isContracts then
        self:updateContractsSubTabContent()
    end
    self:updateActiveSubTabMenuButtons()

    if restoreFocus then
        if isContracts then
            local target = (self.contractsListFocus == "right") and self.gmTableContractBoard or self.gmTableMyContracts
            if target ~= nil then FocusManager:setFocus(target) end
        elseif self.gmTableStorage ~= nil then
            FocusManager:setFocus(self.gmTableStorage)
        end
    end
end

function GlobalMarketUI:refreshSubTabBadge()
    if self.btnSubTabContracts == nil then return end
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    local badge = 0
    if gm ~= nil and farmId > 0 then
        badge = badge + (gm.getActiveAcceptedContractCount ~= nil and gm:getActiveAcceptedContractCount(farmId) or 0)
        for _, p in ipairs(gm.pickupInbox or {}) do
            if p.farmId == farmId and (p.liters or 0) > 0.5 then
                badge = badge + 1
            end
        end
    end
    local baseLabel = self.i18n:getText("ui_gm_subtab_contracts")
    self.btnSubTabContracts:setText(badge > 0 and string.format("%s (%d)", baseLabel, badge) or baseLabel)
end

function GlobalMarketUI:updateActiveSubTabMenuButtons()
    local backButton = { inputAction = InputAction.MENU_BACK }
    if self.activeSubTab == GlobalMarketUI.SUBTAB_CONTRACTS then
        if self.boardFilterButtonInfo ~= nil then
            self.boardFilterButtonInfo.text = self:getBoardFilterText()
        end
        local row = self:getSelectedContractRow()
        local isEmpty = (row == nil or row.kind == "EMPTY_MY" or row.kind == "EMPTY_BOARD")
        local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
        local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0

        local isSpectator = (farmId == nil or farmId <= 0
            or (FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID))
        if self.btnCreateContract ~= nil then
            self.btnCreateContract:setDisabled(isSpectator)
        end
        if self.btnCreateDirectOffer ~= nil then
            self.btnCreateDirectOffer:setDisabled(isSpectator)
        end

        local canPrimary = false
        local canCancel = false
        local actionLabel = self.i18n:getText("ui_gm_action_acceptContract")

        if not isEmpty and not isSpectator then
            if row.kind == "ACTIVE_CONTRACT" then
                actionLabel = self.i18n:getText("ui_gm_action_deliverContract")
                canPrimary = true
            elseif row.kind == "INBOX" then
                actionLabel = self.i18n:getText("ui_gm_action_claimInbox")
                canPrimary = true
            elseif row.kind == "OWN_CONTRACT" then
                local d = row.data
                local isPendingTimedOut = (d ~= nil and d.isOnline == true and d.status == "PENDING_CREATE"
                    and (d.remoteId == nil or d.remoteId == "")
                    and (gm == nil or not gm:getAreOnlineContractsSupported()
                        or ((g_time or 0) - (d.pendingSinceMs or 0)) >= ((GlobalMarketContracts and GlobalMarketContracts.PENDING_ACTION_TIMEOUT_MS) or 30000)))
                canCancel = (d ~= nil and (d.status == "OPEN" or isPendingTimedOut))
            elseif row.kind == "OWN_OFFER" then
                local d = row.data
                local isPendingTimedOut = (d ~= nil and d.isOnline == true and d.status == "PENDING_CREATE"
                    and (d.remoteId == nil or d.remoteId == "")
                    and (gm == nil or not gm:getAreOnlineContractsSupported()
                        or ((g_time or 0) - (d.pendingSinceMs or 0)) >= ((GlobalMarketContracts and GlobalMarketContracts.PENDING_ACTION_TIMEOUT_MS) or 30000)))
                canCancel = (d ~= nil and d.status ~= "PENDING_CANCEL" and (d.status ~= "PENDING_CREATE" or isPendingTimedOut))
            elseif row.kind == "BOARD_CONTRACT" then
                actionLabel = self.i18n:getText("ui_gm_action_acceptContract")
                local activeCnt = (gm ~= nil and gm.getActiveAcceptedContractCount ~= nil)
                    and gm:getActiveAcceptedContractCount(farmId) or 0
                local isPending = (row.data ~= nil and row.data.pendingAcceptFarmId ~= nil)
                canPrimary = (not isPending) and (activeCnt < ((GlobalMarketContracts and GlobalMarketContracts.MAX_ACTIVE_CONTRACTS_PER_FARM) or 3))
            elseif row.kind == "BOARD_OFFER" then
                actionLabel = self.i18n:getText("ui_gm_action_buyOffer")
                canPrimary = true
            end
        end

        -- Primary (MENU_ACCEPT) only for rows that have one; own listings are cancelled via MENU_CANCEL only
        local hasPrimary = not isEmpty and not isSpectator and (row.kind == "ACTIVE_CONTRACT" or row.kind == "INBOX"
            or row.kind == "BOARD_CONTRACT" or row.kind == "BOARD_OFFER")
        local list = { backButton }
        if hasPrimary and self.contractsActionButtonInfo ~= nil then
            self.contractsActionButtonInfo.text = actionLabel
            self.contractsActionButtonInfo.disabled = not canPrimary
            table.insert(list, self.contractsActionButtonInfo)
        end
        if self.switchSubTabButtonInfo ~= nil then table.insert(list, self.switchSubTabButtonInfo) end
        if self.boardFilterButtonInfo ~= nil then table.insert(list, self.boardFilterButtonInfo) end
        if not isEmpty and self.contractsMarkerButtonInfo ~= nil and gm ~= nil and gm.getContractStationHotspot ~= nil
            and (row.kind == "ACTIVE_CONTRACT" or row.kind == "BOARD_CONTRACT")
            and gm:getContractStationHotspot(row.data) ~= nil then
            self.contractsMarkerButtonInfo.text = g_i18n:getText(gm:getIsContractStationMarked(row.data) and "action_untag" or "action_tag")
            table.insert(list, self.contractsMarkerButtonInfo)
        end
        if canCancel and self.contractsCancelButtonInfo ~= nil then
            self.contractsCancelButtonInfo.disabled = false
            table.insert(list, self.contractsCancelButtonInfo)
        end
        self:setMenuButtonInfo(list)
        self:setMenuButtonInfoDirty()
        self:updateSelectionHint(row)
    else
        local list = { backButton }
        if self.actionButtonInfo ~= nil then table.insert(list, self.actionButtonInfo) end
        if self.switchSubTabButtonInfo ~= nil then table.insert(list, self.switchSubTabButtonInfo) end
        if self.categoryModeButtonInfo ~= nil then table.insert(list, self.categoryModeButtonInfo) end
        self:setMenuButtonInfo(list)
        self:setMenuButtonInfoDirty()
    end
end

function GlobalMarketUI:updateContractsSubTabContent()
    self:refreshSubTabBadge()
    if self.btnBoardFilter ~= nil then
        self.btnBoardFilter:setText(self:getBoardFilterText())
    end
    self:applyContractsListsFilter(self.activeSubTab == GlobalMarketUI.SUBTAB_CONTRACTS)
end

function GlobalMarketUI:matchesContractQuery(fillTypeName, extraText)
    local q = GlobalMarketUI.normalizeSortTitle(self.searchFilterText or "")
    if q == "" then return true end
    local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(fillTypeName) or nil
    local locTitle = (desc ~= nil and desc.title) or fillTypeName or ""
    if string.find(GlobalMarketUI.normalizeSortTitle(locTitle), q, 1, true) ~= nil then return true end
    if string.find(GlobalMarketUI.normalizeSortTitle(fillTypeName or ""), q, 1, true) ~= nil then return true end
    if extraText ~= nil and string.find(GlobalMarketUI.normalizeSortTitle(extraText), q, 1, true) ~= nil then return true end
    return false
end

function GlobalMarketUI:applyContractsListsFilter(allowListFocus)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if gm == nil then return end

    local activeSec, activeIdx, activeKind, activeId = 1, 0, nil, nil
    if self.contractsListFocus == "right" and self.gmTableContractBoard ~= nil then
        activeSec, activeIdx = self.gmTableContractBoard:getSelectedPath()
        local cur = self.boardContractSections[activeSec] and self.boardContractSections[activeSec].items[activeIdx] or nil
        if cur ~= nil and cur.data ~= nil then activeKind, activeId = cur.kind, cur.data.id end
    elseif self.gmTableMyContracts ~= nil then
        activeSec, activeIdx = self.gmTableMyContracts:getSelectedPath()
        local cur = self.myContractSections[activeSec] and self.myContractSections[activeSec].items[activeIdx] or nil
        if cur ~= nil and cur.data ~= nil then activeKind, activeId = cur.kind, cur.data.id end
    end

    local activeContracts, inboxItems, ownContracts, ownOffers = {}, {}, {}, {}
    local boardContracts, boardOffers = {}, {}
    local activeAcceptedCount, inboxCount, openContractCount, openOfferCount = 0, 0, 0, 0

    for _, c in ipairs(gm.contracts or {}) do
        local isOwnActive = (c.status == "ACTIVE") and ((c.isOnline and gm.isOwnOnlineIdentity ~= nil
            and gm:isOwnOnlineIdentity(c.contractorServerId, c.contractorFarmId, farmId))
            or (not c.isOnline and c.contractorFarmId == farmId))
        local isOwnIssued = (c.isOnline and gm.isOwnOnlineIdentity ~= nil
            and gm:isOwnOnlineIdentity(c.issuerServerId, c.issuerFarmId, farmId))
            or (not c.isOnline and c.origin == "PLAYER" and c.issuerFarmId == farmId)

        if isOwnActive then
            activeAcceptedCount = activeAcceptedCount + 1
            if self:matchesContractQuery(c.fillType, c.issuerName) then
                table.insert(activeContracts, { kind = "ACTIVE_CONTRACT", fillType = c.fillType, data = c })
            end
        elseif isOwnIssued then
            if self:matchesContractQuery(c.fillType, c.issuerName) then
                table.insert(ownContracts, { kind = "OWN_CONTRACT", fillType = c.fillType, data = c })
            end
        elseif c.status == "OPEN" and (not c.isOnline or (gm.isOnlineContractBoardEnabled ~= nil and gm:isOnlineContractBoardEnabled())) then
            openContractCount = openContractCount + 1
            if self.boardFilter ~= GlobalMarketUI.BOARD_FILTER_OFFERS and self:matchesContractQuery(c.fillType, c.issuerName) then
                table.insert(boardContracts, { kind = "BOARD_CONTRACT", fillType = c.fillType, data = c })
            end
        end
    end

    for _, p in ipairs(gm.pickupInbox or {}) do
        if p.farmId == farmId and (p.liters or 0) > 0.5 then
            inboxCount = inboxCount + 1
            if self:matchesContractQuery(p.fillType, p.sourceLabel) then
                table.insert(inboxItems, { kind = "INBOX", fillType = p.fillType, data = p })
            end
        end
    end

    for _, o in ipairs(gm.directOffers or {}) do
        if (o.remainingLiters or 0) > 0.5 then
            local isOwnOffer = (o.isOnline and gm.isOwnOnlineIdentity ~= nil
                and gm:isOwnOnlineIdentity(o.sellerServerId, o.sellerFarmId, farmId))
                or (not o.isOnline and o.origin == "PLAYER" and o.sellerFarmId == farmId)
            if isOwnOffer then
                if self:matchesContractQuery(o.fillType, o.sellerName) then
                    table.insert(ownOffers, { kind = "OWN_OFFER", fillType = o.fillType, data = o })
                end
            elseif (not o.isOnline or (gm.isOnlineOfferBoardEnabled ~= nil and gm:isOnlineOfferBoardEnabled()))
                and (o.status == nil or o.status == "OPEN") then
                openOfferCount = openOfferCount + 1
                if self.boardFilter ~= GlobalMarketUI.BOARD_FILTER_CONTRACTS and self:matchesContractQuery(o.fillType, o.sellerName) then
                    table.insert(boardOffers, { kind = "BOARD_OFFER", fillType = o.fillType, data = o })
                end
            end
        end
    end

    self.myContractSections = {}
    if #activeContracts > 0 then table.insert(self.myContractSections, { title = self.i18n:getText("ui_gm_sec_activeContracts"), items = activeContracts }) end
    if #inboxItems > 0      then table.insert(self.myContractSections, { title = self.i18n:getText("ui_gm_sec_pickupInbox"),     items = inboxItems }) end
    if #ownContracts > 0    then table.insert(self.myContractSections, { title = self.i18n:getText("ui_gm_sec_ownContracts"),    items = ownContracts }) end
    if #ownOffers > 0       then table.insert(self.myContractSections, { title = self.i18n:getText("ui_gm_sec_ownOffers"),       items = ownOffers }) end
    if #self.myContractSections == 0 then
        table.insert(self.myContractSections, { title = nil, items = { { kind = "EMPTY_MY" } } })
    end

    self.boardContractSections = {}
    if #boardContracts > 0 then table.insert(self.boardContractSections, { title = self.i18n:getText("ui_gm_sec_boardContracts"), items = boardContracts }) end
    if #boardOffers > 0    then table.insert(self.boardContractSections, { title = self.i18n:getText("ui_gm_sec_boardOffers"),    items = boardOffers }) end
    if #self.boardContractSections == 0 then
        table.insert(self.boardContractSections, { title = nil, items = { { kind = "EMPTY_BOARD" } } })
    end

    if self.myContractsSubtitle ~= nil then
        local maxCap = (GlobalMarketContracts and GlobalMarketContracts.MAX_ACTIVE_CONTRACTS_PER_FARM) or 3
        self.myContractsSubtitle:setText(string.format(self.i18n:getText("ui_gm_contracts_mySub"),
            activeAcceptedCount, maxCap, inboxCount))
    end
    if self.boardContractsSubtitle ~= nil then
        self.boardContractsSubtitle:setText(string.format(self.i18n:getText("ui_gm_contracts_boardSub"),
            openContractCount, openOfferCount))
    end

    self.isUpdatingSelection = true
    local wasSearchFocused = (self.searchTextInput ~= nil and FocusManager:getFocusedElement() == self.searchTextInput)
    if self.gmTableMyContracts ~= nil then self.gmTableMyContracts:reloadData() end
    if self.gmTableContractBoard ~= nil then self.gmTableContractBoard:reloadData() end

    self:restoreContractListSelection(activeKind, activeId, activeSec, activeIdx, allowListFocus and not wasSearchFocused)
    if wasSearchFocused and self.searchTextInput ~= nil then
        FocusManager:setFocus(self.searchTextInput)
    end
    self.isUpdatingSelection = false
    self:updateActiveSubTabMenuButtons()
end

function GlobalMarketUI:findContractPath(sections, targetKind, targetId, fbSec, fbIdx)
    if sections == nil or #sections == 0 then return 0, 0 end
    if targetKind ~= nil and targetId ~= nil then
        for sIdx, sec in ipairs(sections) do
            for iIdx, row in ipairs(sec.items) do
                if row.kind == targetKind and row.data ~= nil and row.data.id == targetId then
                    return sIdx, iIdx
                end
            end
        end
    end
    local sec = math.clamp(fbSec or 1, 1, #sections)
    local items = sections[sec].items
    if items ~= nil and #items > 0 then
        return sec, math.clamp(fbIdx or 1, 1, #items)
    end
    return 1, 1
end

function GlobalMarketUI:restoreContractListSelection(kind, id, sec, idx, setFocus)
    if self.contractsListFocus == "right" and self.gmTableContractBoard ~= nil then
        local ns, ni = self:findContractPath(self.boardContractSections, kind, id, sec, idx)
        if ns > 0 and ni > 0 then
            self.gmTableContractBoard:setSelectedItem(ns, ni)
        else
            self.gmTableContractBoard:setSelectedItem(1, 0)
            self.gmTableContractBoard:clearElementSelection()
        end
        if self.gmTableMyContracts ~= nil then
            self.gmTableMyContracts:setSelectedItem(1, 0)
            self.gmTableMyContracts:clearElementSelection()
        end
        if setFocus and self:getIsVisible() then FocusManager:setFocus(self.gmTableContractBoard) end
    elseif self.gmTableMyContracts ~= nil then
        local ns, ni = self:findContractPath(self.myContractSections, kind, id, sec, idx)
        if ns > 0 and ni > 0 then
            self.gmTableMyContracts:setSelectedItem(ns, ni)
        else
            self.gmTableMyContracts:setSelectedItem(1, 0)
            self.gmTableMyContracts:clearElementSelection()
        end
        if self.gmTableContractBoard ~= nil then
            self.gmTableContractBoard:setSelectedItem(1, 0)
            self.gmTableContractBoard:clearElementSelection()
        end
        if setFocus and self:getIsVisible() then FocusManager:setFocus(self.gmTableMyContracts) end
    end
end

function GlobalMarketUI:getSelectedContractRow(overrideSection, overrideIndex)
    local isRight = (self.contractsListFocus == "right")
    local list = isRight and self.gmTableContractBoard or self.gmTableMyContracts
    local sections = isRight and self.boardContractSections or self.myContractSections
    if list == nil and (overrideSection == nil or overrideIndex == nil) then return nil end
    local sec, idx = overrideSection, overrideIndex
    if sec == nil or idx == nil then
        sec, idx = list:getSelectedPath()
    end
    return sections[sec] and sections[sec].items and sections[sec].items[idx] or nil
end

function GlobalMarketUI:updateSelectionHint(row)
    if self.contractsSelectionHint == nil then return end
    if row == nil or row.kind == "EMPTY_MY" or row.kind == "EMPTY_BOARD" or row.data == nil then
        self.contractsSelectionHint:setText(self.i18n:getText("ui_gm_hint_browse"))
        return
    end

    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    local d = row.data

    if row.kind == "ACTIVE_CONTRACT" or row.kind == "BOARD_CONTRACT" then
        if row.kind == "BOARD_CONTRACT" and gm ~= nil and gm.getActiveAcceptedContractCount ~= nil then
            local cap = (GlobalMarketContracts and GlobalMarketContracts.MAX_ACTIVE_CONTRACTS_PER_FARM) or 3
            if gm:getActiveAcceptedContractCount(farmId) >= cap then
                self.contractsSelectionHint:setText(string.format(self.i18n:getText("ui_gm_hint_capReached"), cap))
                return
            end
        end
        local pendingTag = ""
        if d.pendingAcceptFarmId ~= nil or d.status == "PENDING_CREATE" or d.status == "PENDING_CANCEL" then
            pendingTag = " | [" .. (self.i18n:hasText("ui_gm_tag_pending") and self.i18n:getText("ui_gm_tag_pending") or "Pending") .. "]"
        end
        local durTag = (d.isOnline and gm ~= nil and gm.formatContractDurationShort ~= nil)
            and (" | " .. gm:formatContractDurationShort(self.i18n, d)) or ""
        local bonusVal = ((d.totalLiters or 0) / 1000) * (d.basePricePer1000 or 500) * ((d.bonusPct or 0) / 100)
        local stationTag = ""
        if not d.isOnline and d.stationPlaceableId ~= nil and d.stationPlaceableId ~= "" then
            stationTag = " | " .. string.format(self.i18n:getText("ui_gm_hint_stationTarget"), tostring(d.issuerName or "NPC"))
        end
        self.contractsSelectionHint:setText(string.format(self.i18n:getText("ui_gm_hint_contract"),
            d.id, tostring(d.issuerName or "NPC"),
            self.i18n:formatVolume(d.deliveredLiters or 0, 0), self.i18n:formatVolume(d.totalLiters or 0, 0),
            self.i18n:formatMoney(d.basePricePer1000 or 500, 0, true, true),
            d.bonusPct or 0, self.i18n:formatMoney(bonusVal, 0, true, true)) .. stationTag .. durTag .. pendingTag)
    elseif row.kind == "OWN_CONTRACT" then
        local pendingTag = (d.status == "PENDING_CREATE" or d.status == "PENDING_CANCEL")
            and (" | [" .. (self.i18n:hasText("ui_gm_tag_pending") and self.i18n:getText("ui_gm_tag_pending") or "Pending") .. "]") or ""
        local durTag = (d.isOnline and gm ~= nil and gm.formatContractDurationShort ~= nil)
            and (" | " .. gm:formatContractDurationShort(self.i18n, d)) or ""
        self.contractsSelectionHint:setText(string.format(self.i18n:getText("ui_gm_hint_ownContract"),
            d.id, self.i18n:formatVolume(d.deliveredLiters or 0, 0), self.i18n:formatVolume(d.totalLiters or 0, 0),
            self.i18n:formatMoney(d.escrowRemaining or 0, 0, true, true)) .. durTag .. pendingTag)
    elseif row.kind == "BOARD_OFFER" or row.kind == "OWN_OFFER" then
        local eff = (d.refPricePer1000 or 500) * (1 + ((d.priceDeltaPct or 0) / 100))
        local modeStr = self.i18n:getText(d.allowPartial and "ui_gm_tag_partial" or "ui_gm_tag_fullOnly")
        local durTag = (d.isOnline and gm ~= nil and gm.formatContractDurationShort ~= nil)
            and (" | " .. gm:formatContractDurationShort(self.i18n, d)) or ""
        local pendingTag = (d.status == "PENDING_CREATE" or d.status == "PENDING_CANCEL")
            and (" | [" .. (self.i18n:hasText("ui_gm_tag_pending") and self.i18n:getText("ui_gm_tag_pending") or "Pending") .. "]") or ""
        self.contractsSelectionHint:setText(string.format(self.i18n:getText("ui_gm_hint_offer"),
            d.id, tostring(d.sellerName or "NPC"),
            self.i18n:formatVolume(d.remainingLiters or 0, 0),
            self.i18n:formatMoney(eff, 0, true, true), d.priceDeltaPct or 0, modeStr) .. durTag .. pendingTag)
    elseif row.kind == "INBOX" then
        self.contractsSelectionHint:setText(string.format(self.i18n:getText("ui_gm_hint_inbox"),
            d.id, self.i18n:formatVolume(d.liters or 0, 0),
            self.i18n:formatMoney(0, 0, true, true), d.monthsRemaining or 2.0))
    end
end

function GlobalMarketUI:onClickCycleBoardFilter()
    if self.boardFilter == GlobalMarketUI.BOARD_FILTER_ALL then
        self.boardFilter = GlobalMarketUI.BOARD_FILTER_CONTRACTS
    elseif self.boardFilter == GlobalMarketUI.BOARD_FILTER_CONTRACTS then
        self.boardFilter = GlobalMarketUI.BOARD_FILTER_OFFERS
    else
        self.boardFilter = GlobalMarketUI.BOARD_FILTER_ALL
    end
    if self.btnBoardFilter ~= nil then
        self.btnBoardFilter:setText(self:getBoardFilterText())
    end
    self:applyContractsListsFilter(self.activeSubTab == GlobalMarketUI.SUBTAB_CONTRACTS)
end

function GlobalMarketUI:onClickCreatePlayerContract()
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil or gm.contractDialog == nil then return end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId <= 0 or (FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID) then
        return
    end
    gm.contractDialog:show(GlobalMarketContractDialog.MODE_CREATE_CONTRACT, {
        farmId = farmId
    }, self.onContractDialogDone, self)
end

function GlobalMarketUI:onClickCreateDirectOffer()
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil or gm.contractDialog == nil then return end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId <= 0 or (FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID) then
        return
    end
    local owned = gm:getAggregatedStorageData(farmId) or {}
    local hasTradable = false
    for _, entry in ipairs(owned) do
        if (entry.level or 0) > 0.01 then
            local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(entry.fillType) or nil
            if desc ~= nil and (GlobalMarketAPI == nil or GlobalMarketAPI.getIsFillTypeAllowed(desc)) then
                hasTradable = true
                break
            end
        end
    end
    if not hasTradable then
        self:showContractInfoMessage(self.i18n:getText("ui_gm_warn_noStockForOffer"))
        return
    end
    gm.contractDialog:show(GlobalMarketContractDialog.MODE_CREATE_OFFER, {
        farmId = farmId
    }, self.onContractDialogDone, self)
end

function GlobalMarketUI:onContractDialogDone(mode, wasObjectStorage)
    self.refreshCountdown = wasObjectStorage and 1200 or 250
end

function GlobalMarketUI:onContractLeftAction(_, section, index, element)
    self.contractsListFocus = "left"
    if section ~= nil and index ~= nil and self.gmTableMyContracts ~= nil then
        GlobalMarketContractsUI:onListSelectionChanged(self.gmTableMyContracts, section, index)
    end
    -- SmoothList passes the clicked cell on a mouse double-click, but nil when activated via Enter (onFocusActivate)
    self:onContractPrimaryAction(section, index, element ~= nil)
end

function GlobalMarketUI:onContractRightAction(_, section, index)
    self.contractsListFocus = "right"
    if section ~= nil and index ~= nil and self.gmTableContractBoard ~= nil then
        GlobalMarketContractsUI:onListSelectionChanged(self.gmTableContractBoard, section, index)
    end
    self:onContractPrimaryAction(section, index)
end

---Tags/untags the selected contract's target station as map target (incl. navigation), like the basegame prices menu
function GlobalMarketUI:onContractToggleMarker()
    local row = self:getSelectedContractRow()
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if row == nil or row.data == nil or gm == nil or gm.toggleContractStationMarker == nil then
        return
    end
    if row.kind ~= "ACTIVE_CONTRACT" and row.kind ~= "BOARD_CONTRACT" then
        return
    end
    gm:toggleContractStationMarker(row.data)
    self:updateActiveSubTabMenuButtons()
end

function GlobalMarketUI:showContractInfoMessage(text)
    if InfoDialog ~= nil and InfoDialog.INSTANCE ~= nil then
        InfoDialog.show(text, nil, nil, DialogElement.TYPE_WARNING)
    end
end

function GlobalMarketUI:onContractCancelAction(overrideSection, overrideIndex)
    local row = self:getSelectedContractRow(overrideSection, overrideIndex)
    if row == nil or row.data == nil then return end
    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId <= 0 or (FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID) then
        return
    end
    local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(row.fillType) or nil
    local ftTitle = (desc ~= nil and desc.title) or row.fillType

    if row.kind == "OWN_CONTRACT" and (row.data.status == "OPEN" or row.data.status == "PENDING_CREATE") then
        local cId = row.data.id
        local function doCancel(yes)
            if yes == true and ContractActionEvent ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_CANCEL_CONTRACT, farmId, cId, "", 0, 0, 1, false, nil, false, nil, 0)
                self.refreshCountdown = 200
            end
        end
        if YesNoDialog ~= nil and YesNoDialog.INSTANCE ~= nil then
            local msg = string.format(self.i18n:getText("ui_gm_confirm_cancelContractText"),
                cId, self.i18n:formatVolume(row.data.totalLiters or 0, 0), ftTitle)
            YesNoDialog.show(doCancel, nil, msg, self.i18n:getText("ui_gm_action_cancelListing"))
        else
            doCancel(true)
        end
    elseif row.kind == "OWN_OFFER" and row.data.status ~= "PENDING_CANCEL" then
        local oId = row.data.id
        local function doCancel(yes)
            if yes == true and ContractActionEvent ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_CANCEL_OFFER, farmId, oId, "", 0, 0, 1, false, nil, false, nil, 0)
                self.refreshCountdown = 200
            end
        end
        if YesNoDialog ~= nil and YesNoDialog.INSTANCE ~= nil then
            local msg = string.format(self.i18n:getText("ui_gm_confirm_cancelOfferText"),
                oId, self.i18n:formatVolume(row.data.remainingLiters or 0, 0), ftTitle)
            YesNoDialog.show(doCancel, nil, msg, self.i18n:getText("ui_gm_action_cancelListing"))
        else
            doCancel(true)
        end
    end
end

---@param isMouseDoubleClick boolean|nil true only for a real mouse double-click on a list row
function GlobalMarketUI:onContractPrimaryAction(overrideSection, overrideIndex, isMouseDoubleClick)
    local row = self:getSelectedContractRow(overrideSection, overrideIndex)
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if gm == nil or row == nil or row.data == nil or row.kind == "EMPTY_MY" or row.kind == "EMPTY_BOARD" then
        return
    end

    local farmId = g_currentMission:getFarmId()
    if farmId == nil or farmId <= 0 or (FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID) then
        return
    end
    local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(row.fillType) or nil
    local ftTitle = (desc ~= nil and desc.title) or row.fillType

    if row.kind == "OWN_CONTRACT" or row.kind == "OWN_OFFER" then
        -- Own listings: no Enter action (MENU_CANCEL is the labelled cancel key), mouse double-click still cancels
        if isMouseDoubleClick == true then
            self:onContractCancelAction(overrideSection, overrideIndex)
        end
        return
    elseif row.kind == "ACTIVE_CONTRACT" and gm.contractDialog ~= nil then
        local silos = gm:getAvailableStorages(row.fillType, farmId, true) or {}
        if #silos == 0 then
            local c = row.data
            if c ~= nil and not c.isOnline and c.stationPlaceableId ~= nil and c.stationPlaceableId ~= "" then
                -- Station contract (#27): point the player to physical delivery instead of a plain warning
                self:showContractInfoMessage(string.format(self.i18n:getText("ui_gm_info_deliverAtStation"), tostring(c.issuerName or "NPC")))
            else
                self:showContractInfoMessage(self.i18n:getText("ui_gm_warn_noStockForOffer"))
            end
            return
        end
        gm.contractDialog:show(GlobalMarketContractDialog.MODE_DELIVER_CONTRACT,
            { farmId = farmId, contract = row.data, silos = silos }, self.onContractDialogDone, self)
    elseif row.kind == "INBOX" and gm.contractDialog ~= nil then
        local silos = gm:getAvailableStorages(row.fillType, farmId, false) or {}
        if #silos == 0 then
            self:showContractInfoMessage(self.i18n:getText("ui_gm_warn_noStorage"))
            return
        end
        gm.contractDialog:show(GlobalMarketContractDialog.MODE_CLAIM_INBOX,
            { farmId = farmId, inboxItem = row.data, silos = silos }, self.onContractDialogDone, self)
    elseif row.kind == "BOARD_CONTRACT" then
        local cap = (GlobalMarketContracts and GlobalMarketContracts.MAX_ACTIVE_CONTRACTS_PER_FARM) or 3
        if gm.getActiveAcceptedContractCount ~= nil and gm:getActiveAcceptedContractCount(farmId) >= cap then
            return
        end
        local c = row.data
        if c.pendingAcceptFarmId ~= nil then
            return
        end
        local function doAccept(yes)
            if yes == true and ContractActionEvent ~= nil then
                ContractActionEvent.dispatch(ContractActionEvent.ACTION_ACCEPT_CONTRACT, farmId, c.id, "", 0, 0, 1, false, nil, false, nil, 0)
                self.contractsListFocus = "left"
                self.refreshCountdown = 200
            end
        end
        if YesNoDialog ~= nil and YesNoDialog.INSTANCE ~= nil then
            local msg
            if c.isOnline == true and gm.formatContractDurationShort ~= nil then
                local onlineDur = gm:formatContractDurationShort(self.i18n, c)
                local fmt = self.i18n:hasText("ui_gm_confirm_acceptTextOnline")
                    and self.i18n:getText("ui_gm_confirm_acceptTextOnline")
                    or "Accept online contract for %s %s?&#xA;Base Price: %s / 1,000 L  |  Completion Bonus: +%d%%  |  Deadline: %s&#xA;&#xA;Note: Failing to complete before the deadline forfeits the bonus and charges a 15%% penalty on missing volume."
                msg = string.format(fmt, self.i18n:formatVolume(c.totalLiters or 0, 0), ftTitle,
                    self.i18n:formatMoney(c.basePricePer1000 or 500, 0, true, true), c.bonusPct or 0, onlineDur)
            else
                msg = string.format(self.i18n:getText("ui_gm_confirm_acceptText"),
                    self.i18n:formatVolume(c.totalLiters or 0, 0), ftTitle,
                    self.i18n:formatMoney(c.basePricePer1000 or 500, 0, true, true),
                    c.bonusPct or 0, c.monthsRemaining or 1.0)
            end
            YesNoDialog.show(doAccept, nil, msg, self.i18n:getText("ui_gm_confirm_acceptTitle"))
        else
            doAccept(true)
        end
    elseif row.kind == "BOARD_OFFER" and gm.contractDialog ~= nil then
        local silos = gm:getAvailableStorages(row.fillType, farmId, false) or {}
        if #silos == 0 then
            self:showContractInfoMessage(self.i18n:getText("ui_gm_warn_noStorage"))
            return
        end
        gm.contractDialog:show(GlobalMarketContractDialog.MODE_BUY_OFFER,
            { farmId = farmId, offer = row.data, silos = silos }, self.onContractDialogDone, self)
    end
end

-- =========================================================================
-- SMOOTHLST DATASOURCE & DELEGATE (Sub-Tab 2)
-- =========================================================================

function GlobalMarketContractsUI:getNumberOfSections(list)
    local ui = GlobalMarketContractsUI.activeUi
    if ui == nil then return 0 end
    if list == ui.gmTableMyContracts then return #ui.myContractSections end
    if list == ui.gmTableContractBoard then return #ui.boardContractSections end
    return 0
end

function GlobalMarketContractsUI:getTitleForSectionHeader(list, section)
    local ui = GlobalMarketContractsUI.activeUi
    if ui == nil then return nil end
    local sections = (list == ui.gmTableMyContracts) and ui.myContractSections or ui.boardContractSections
    local sec = sections and sections[section]
    return sec and sec.title or nil
end

function GlobalMarketContractsUI:getNumberOfItemsInSection(list, section)
    local ui = GlobalMarketContractsUI.activeUi
    if ui == nil then return 0 end
    local sections = (list == ui.gmTableMyContracts) and ui.myContractSections or ui.boardContractSections
    local sec = sections and sections[section]
    return sec and #sec.items or 0
end

function GlobalMarketContractsUI:populateCellForItemInSection(list, section, index, cell)
    local ui = GlobalMarketContractsUI.activeUi
    if ui == nil then return end
    local sections = (list == ui.gmTableMyContracts) and ui.myContractSections or ui.boardContractSections
    local row = sections and sections[section] and sections[section].items[index] or nil
    if row == nil then return end

    local icon = cell:getAttribute("icon")
    local name = cell:getAttribute("name")
    local marker = cell:getAttribute("marker")
    if marker ~= nil then marker:setVisible(false) end

    if row.kind == "EMPTY_MY" or row.kind == "EMPTY_BOARD" then
        if icon ~= nil then icon:setVisible(false) end
        if name ~= nil then
            name:setText(ui.i18n:getText(row.kind == "EMPTY_MY" and "ui_gm_row_emptyMy" or "ui_gm_row_emptyBoard"))
            name:setTextColor(COLOR_MUTED[1], COLOR_MUTED[2], COLOR_MUTED[3], COLOR_MUTED[4])
        end
        for _, colName in ipairs({ "progress", "terms", "price", "amount" }) do
            local el = cell:getAttribute(colName)
            if el ~= nil then el:setText("") end
        end
        return
    end

    local desc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(row.fillType) or nil
    local ftTitle = (desc ~= nil and desc.title) or row.fillType or ""
    if icon ~= nil then
        if desc ~= nil and desc.hudOverlayFilename ~= nil and desc.hudOverlayFilename ~= "" then
            icon:setImageFilename(desc.hudOverlayFilename)
            icon:setVisible(true)
        else
            icon:setVisible(false)
        end
    end

    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    local d = row.data or {}
    if marker ~= nil and gm ~= nil and gm.getContractStationHotspot ~= nil
        and (row.kind == "ACTIVE_CONTRACT" or row.kind == "BOARD_CONTRACT") then
        local hotspot = gm:getContractStationHotspot(d)
        marker:setVisible(hotspot ~= nil)
        marker.getIsSelected = function()
            return hotspot ~= nil and g_currentMission ~= nil and g_currentMission.currentMapTargetHotspot == hotspot
        end
    end
    local mStr = (gm ~= nil and gm.formatContractDurationShort ~= nil)
        and gm:formatContractDurationShort(ui.i18n, d)
        or string.format(ui.i18n:getText("ui_gm_months_short"), d.monthsRemaining or 1.0)
    local pendingLabel = ui.i18n:hasText("ui_gm_tag_pending") and ui.i18n:getText("ui_gm_tag_pending") or "Pending"
    if list == ui.gmTableMyContracts then
        local progEl, termsEl = cell:getAttribute("progress"), cell:getAttribute("terms")
        if row.kind == "ACTIVE_CONTRACT" or row.kind == "OWN_CONTRACT" then
            local ownerLabel
            if row.kind == "OWN_CONTRACT" then
                if d.status == "PENDING_CREATE" or d.status == "PENDING_CANCEL" then
                    ownerLabel = pendingLabel
                else
                    ownerLabel = ui.i18n:getText(d.status == "OPEN" and "ui_gm_tag_open" or "ui_gm_btn_deliver")
                end
            else
                ownerLabel = tostring(d.issuerName or "NPC")
            end
            local pct = math.min(100, math.floor(((d.deliveredLiters or 0) / math.max(1, d.totalLiters or 1)) * 100 + 0.5))
            if name ~= nil then
                name:setText(string.format("%s (%s)", ftTitle, ownerLabel))
                name:setTextColor(COLOR_WHITE_TEXT[1], COLOR_WHITE_TEXT[2], COLOR_WHITE_TEXT[3], COLOR_WHITE_TEXT[4])
            end
            if progEl ~= nil then
                progEl:setText(string.format("%s / %s (%d%%)",
                    ui.i18n:formatVolume(d.deliveredLiters or 0, 0), ui.i18n:formatVolume(d.totalLiters or 0, 0), pct))
            end
            if termsEl ~= nil then
                termsEl:setText(string.format("+%d%% | %s", d.bonusPct or 0, mStr))
                local isUrgent = (row.kind == "ACTIVE_CONTRACT") and ((d.isOnline and (d.remainingSeconds or 0) <= 43200)
                    or (not d.isOnline and (d.monthsRemaining or 1) <= 0.5))
                local tc = isUrgent and COLOR_URGENT or COLOR_LIGHT
                termsEl:setTextColor(tc[1], tc[2], tc[3], tc[4])
            end
        elseif row.kind == "INBOX" then
            local tag = ui.i18n:getText((d.sourceType == "CONTRACT_DELIVERY") and "ui_gm_tag_inboxDelivery" or "ui_gm_tag_inboxReturn")
            if name ~= nil then
                name:setText(string.format("%s (%s)", ftTitle, tag))
                name:setTextColor(COLOR_WHITE_TEXT[1], COLOR_WHITE_TEXT[2], COLOR_WHITE_TEXT[3], COLOR_WHITE_TEXT[4])
            end
            if progEl ~= nil then progEl:setText(ui.i18n:formatVolume(d.liters or 0, 0)) end
            if termsEl ~= nil then
                termsEl:setText(mStr)
                local tc = ((d.monthsRemaining or 2) <= 0.5) and COLOR_URGENT or COLOR_BARGAIN
                termsEl:setTextColor(tc[1], tc[2], tc[3], tc[4])
            end
        elseif row.kind == "OWN_OFFER" then
            if name ~= nil then
                local titleTxt = (d.status == "PENDING_CREATE" or d.status == "PENDING_CANCEL")
                    and string.format("%s (%s)", ftTitle, pendingLabel) or ftTitle
                name:setText(titleTxt)
                name:setTextColor(COLOR_WHITE_TEXT[1], COLOR_WHITE_TEXT[2], COLOR_WHITE_TEXT[3], COLOR_WHITE_TEXT[4])
            end
            if progEl ~= nil then progEl:setText(ui.i18n:formatVolume(d.remainingLiters or 0, 0)) end
            if termsEl ~= nil then
                termsEl:setText(string.format("%+d%% | %s", d.priceDeltaPct or 0, mStr))
                termsEl:setTextColor(COLOR_LIGHT[1], COLOR_LIGHT[2], COLOR_LIGHT[3], COLOR_LIGHT[4])
            end
        end
    else
        local priceEl, amtEl = cell:getAttribute("price"), cell:getAttribute("amount")
        if row.kind == "BOARD_CONTRACT" then
            if name ~= nil then
                local ownerTxt = (d.pendingAcceptFarmId ~= nil)
                    and string.format("%s | %s", tostring(d.issuerName or "NPC"), pendingLabel)
                    or tostring(d.issuerName or "NPC")
                name:setText(string.format("%s (%s)", ftTitle, ownerTxt))
                name:setTextColor(COLOR_WHITE_TEXT[1], COLOR_WHITE_TEXT[2], COLOR_WHITE_TEXT[3], COLOR_WHITE_TEXT[4])
            end
            if priceEl ~= nil then
                priceEl:setText(string.format("%s (+%d%%)", ui.i18n:formatMoney(d.basePricePer1000 or 500, 0, true, true), d.bonusPct or 0))
                priceEl:setTextColor(COLOR_BARGAIN[1], COLOR_BARGAIN[2], COLOR_BARGAIN[3], COLOR_BARGAIN[4])
            end
            if amtEl ~= nil then
                amtEl:setText(string.format("%s | %s", ui.i18n:formatVolume(d.totalLiters or 0, 0), mStr))
            end
        elseif row.kind == "BOARD_OFFER" then
            local eff = (d.refPricePer1000 or 500) * (1 + ((d.priceDeltaPct or 0) / 100))
            local delta = d.priceDeltaPct or 0
            local pCol = (delta < 0) and COLOR_BARGAIN or ((delta > 0) and COLOR_MARKUP or COLOR_LIGHT)
            local modeTag = ui.i18n:getText(d.allowPartial and "ui_gm_tag_partial" or "ui_gm_tag_fullOnly")
            if name ~= nil then
                name:setText(string.format("%s (%s)", ftTitle, tostring(d.sellerName or "NPC")))
                name:setTextColor(COLOR_WHITE_TEXT[1], COLOR_WHITE_TEXT[2], COLOR_WHITE_TEXT[3], COLOR_WHITE_TEXT[4])
            end
            if priceEl ~= nil then
                priceEl:setText(string.format("%s (%+d%%)", ui.i18n:formatMoney(eff, 0, true, true), delta))
                priceEl:setTextColor(pCol[1], pCol[2], pCol[3], pCol[4])
            end
            if amtEl ~= nil then
                local suffix = d.isOnline and (modeTag .. " | " .. mStr) or modeTag
                amtEl:setText(string.format("%s | %s", ui.i18n:formatVolume(d.remainingLiters or 0, 0), suffix))
            end
        end
    end
end

function GlobalMarketContractsUI:onListSelectionChanged(list, section, index)
    local ui = GlobalMarketContractsUI.activeUi
    if ui == nil or ui.isUpdatingSelection then return end
    ui.isUpdatingSelection = true

    if list == ui.gmTableMyContracts then
        ui.contractsListFocus = "left"
        if ui.gmTableContractBoard ~= nil then
            ui.gmTableContractBoard:setSelectedItem(1, 0)
            ui.gmTableContractBoard:clearElementSelection()
        end
    else
        ui.contractsListFocus = "right"
        if ui.gmTableMyContracts ~= nil then
            ui.gmTableMyContracts:setSelectedItem(1, 0)
            ui.gmTableMyContracts:clearElementSelection()
        end
    end

    ui.isUpdatingSelection = false
    ui:updateActiveSubTabMenuButtons()
end

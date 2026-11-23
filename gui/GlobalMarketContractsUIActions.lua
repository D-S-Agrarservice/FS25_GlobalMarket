-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketContractsUIActions.lua
-- Footer and row actions of the Supply Contracts sub-tab: board filter, create contract or
-- direct offer, cancel, accept/buy and map marker.
-- Author: D-S-Agrarservice
-- =========================================================================================

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
    if not GlobalMarket.checkMarketPermission(Farm.PERMISSION.MANAGE_CONTRACTS) then
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
    if not GlobalMarket.checkMarketPermission(Farm.PERMISSION.MANAGE_CONTRACTS) then
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
    if not GlobalMarket.checkMarketPermission(Farm.PERMISSION.MANAGE_CONTRACTS) then
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
    if not GlobalMarket.checkMarketPermission(Farm.PERMISSION.MANAGE_CONTRACTS) then
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

-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketSettlementAck.lua
-- Online settlements (contracts & vehicles) are acknowledged only after the savegame that
-- contains their booking was written. Until then the backend redelivers them, so a crash or
-- leaving without saving never loses money, goods or vehicles: the reloaded (older) state
-- simply gets the settlement again.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketSettlementAck = {}

GlobalMarketSettlementAck.CONTRACTS = "CONTRACTS"
GlobalMarketSettlementAck.VEHICLES = "VEHICLES"
-- Booked but unsaved settlements per board; older ones are acknowledged without a save, so a
-- session that never saves neither fills the sync files nor outruns the deduplication log
GlobalMarketSettlementAck.MAX_UNSAVED = 32
GlobalMarketSettlementAck.MAX_IDS_PER_ACK = 50

---Returns the acknowledgement lists of a board
---unsaved: booked, not saved yet; written: in globalMarket.xml, the save is still running; ready: saved
---@param gm table
---@param board string
---@return table lists
local function getLists(gm, board)
    gm.settlementAcks = gm.settlementAcks or {}
    local lists = gm.settlementAcks[board]
    if lists == nil then
        lists = { unsaved = {}, written = {}, ready = {} }
        gm.settlementAcks[board] = lists
    end
    return lists
end

---Moves all entries of one list to the end of another one
---@param from table
---@param to table
local function moveAll(from, to)
    for i, id in ipairs(from) do
        table.insert(to, id)
        from[i] = nil
    end
end

---Returns true if a list contains an ID
---@param list table
---@param id string
---@return boolean
local function contains(list, id)
    for _, entry in ipairs(list) do
        if entry == id then
            return true
        end
    end
    return false
end

---Server: a settlement was booked just now, its acknowledgement waits for the next save
---@param board string
---@param settlementId string
function GlobalMarket:deferSettlementAck(board, settlementId)
    local lists = getLists(self, board)
    table.insert(lists.unsaved, settlementId)
    while #lists.unsaved > GlobalMarketSettlementAck.MAX_UNSAVED do
        table.insert(lists.ready, table.remove(lists.unsaved, 1))
    end
end

---Server: returns true while a booked settlement must not be acknowledged yet
---@param settlementId string
---@return boolean
function GlobalMarket:isSettlementAckDeferred(settlementId)
    for _, lists in pairs(self.settlementAcks or {}) do
        if contains(lists.unsaved, settlementId) or contains(lists.written, settlementId) then
            return true
        end
    end
    return false
end

---Server: globalMarket.xml was written with the bookings made so far
function GlobalMarket:onSettlementsWritten()
    for _, lists in pairs(self.settlementAcks or {}) do
        moveAll(lists.unsaved, lists.written)
    end
end

---Server: the running save has finished
---@param success boolean
function GlobalMarket:onSettlementSaveComplete(success)
    for _, lists in pairs(self.settlementAcks or {}) do
        if success then
            moveAll(lists.written, lists.ready)
        else
            -- Keep the original order: the older entries come first
            moveAll(lists.unsaved, lists.written)
            lists.unsaved, lists.written = lists.written, {}
        end
    end
end

---Server: sends one ACK_SETTLEMENT request
---@param board string
---@param settlementIds string Comma-separated
---@return boolean dispatched
function GlobalMarket:sendSettlementAck(board, settlementIds)
    if settlementIds == "" then
        return false
    end
    local payload = { subAction = "ACK_SETTLEMENT", settlementIds = settlementIds }
    if board == GlobalMarketSettlementAck.VEHICLES then
        return self:dispatchVehicleAction(payload)
    end
    payload.actionId = self:nextOnlineContractActionId()
    payload.serverId = self:ensureServerInstanceId()
    return self:dispatchOnlineContractAction(payload)
end

---Server tick: acknowledges saved settlements. If that is not possible right now (offline), the
---backend redelivers them and they are acknowledged then (see the deduplication log).
function GlobalMarket:updateSettlementAcks()
    if g_server == nil then
        return
    end
    for board, lists in pairs(self.settlementAcks or {}) do
        if #lists.ready > 0 then
            local ids = {}
            for i = #lists.ready, 1, -1 do
                table.insert(ids, 1, table.remove(lists.ready, i))
            end
            for first = 1, #ids, GlobalMarketSettlementAck.MAX_IDS_PER_ACK do
                local last = math.min(first + GlobalMarketSettlementAck.MAX_IDS_PER_ACK - 1, #ids)
                self:sendSettlementAck(board, table.concat(ids, ",", first, last))
            end
        end
    end
end

-- =========================================================================
-- SAVE TRACKING
-- =========================================================================

---Remembers whether the following saveSavegame call really saves the game (not while sleeping, not twice)
function GlobalMarket:onBeforeSavegame()
    local isSleeping = g_sleepManager ~= nil and g_sleepManager:getIsSleeping()
    local isSaving = g_savegameController ~= nil and g_savegameController:getIsSaving()
    self.isSavegameWritten = not isSleeping and not isSaving
    self.savegameFinishedEarly = nil
end

---Writes globalMarket.xml together with the savegame
function GlobalMarket:onAfterSavegame()
    if self.isSavegameWritten == false then
        -- The game kept its older savegame: newer market data would not match it
        return
    end
    self:saveToXmlFile()
    -- A blocking save may already be finished at this point
    if self.savegameFinishedEarly ~= nil then
        self:onSettlementSaveComplete(self.savegameFinishedEarly)
        self.savegameFinishedEarly = nil
    end
end

if SavegameController ~= nil and SavegameController.onSaveComplete ~= nil then
    SavegameController.onSaveComplete = Utils.appendedFunction(SavegameController.onSaveComplete, function(_, errorCode)
        local gm = (g_currentMission ~= nil) and g_currentMission.globalMarket or nil
        if gm ~= nil and g_server ~= nil then
            local success = (errorCode == Savegame.ERROR_OK)
            gm.savegameFinishedEarly = success
            gm:onSettlementSaveComplete(success)
        end
    end)
end

-- =========================================================================================
-- FS25_GlobalMarket - GlobalMarketDialog.lua
-- Interactive transaction dialog for storage selection, packaging formats, and fee preview.
-- The receipt is drawn as a paper document: invoice (buy) or credit note (sell), #39.
-- Author: D-S-Agrarservice
-- =========================================================================================

GlobalMarketDialog = {}
local GlobalMarketDialog_mt = Class(GlobalMarketDialog, YesNoDialog)

-- SAFETY CAP: Maximum physical objects per transaction to prevent engine crashes
GlobalMarketDialog.MAX_OBJECTS_PER_TX = 50
GlobalMarketDialog.BULK_STEPS = { 100, 1000, 10000 }
GlobalMarketDialog.BULK_STEP_LABELS = { "-10k", "-1k", "-100", "+100", "+1k", "+10k" }
GlobalMarketDialog.OBJECT_STEPS = { 1, 5, 10 }
GlobalMarketDialog.OBJECT_STEP_LABELS = { "-10", "-5", "-1", "+1", "+5", "+10" }

local COLOR_LABEL = { 0.78, 0.80, 0.82, 1 }
local COLOR_WHITE = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.85, 0.85, 0.85, 1 }
local COLOR_GREEN = { 0.46, 0.80, 0.15, 1 }
local COLOR_AMBER = { 0.95, 0.68, 0.20, 1 }
local COLOR_RED = { 0.92, 0.22, 0.22, 1 }
local COLOR_BAL_OK = { 0.92, 0.94, 0.96, 1 }

-- Paper document (#39): dark ink variants of the colors above (linear color values)
local PAPER_INK = { 0.012, 0.012, 0.015, 1 }
local PAPER_LABEL = { 0.045, 0.045, 0.052, 1 }
local PAPER_COLORS = {
    [COLOR_WHITE] = PAPER_INK,
    [COLOR_LABEL] = PAPER_LABEL,
    [COLOR_MUTED] = { 0.06, 0.06, 0.068, 1 },
    [COLOR_GREEN] = { 0.010, 0.13, 0.008, 1 },
    [COLOR_AMBER] = { 0.33, 0.08, 0.0, 1 },
    [COLOR_RED] = { 0.38, 0.008, 0.008, 1 }
}

function GlobalMarketDialog.new(target, custom_mt)
    local self = YesNoDialog.new(target, custom_mt or GlobalMarketDialog_mt)

    self.actionType = "SELL"
    self.fillTypeTitle = ""
    self.fillTypeName = ""
    self.pricePer1000 = 0
    self.maxAmount = 0
    self.currentAmount = 0
    self.selectedStorageIndex = 1
    self.storageLocations = {}

    return self
end

-- Initializes the dialog with data from the main UI and triggers the display
function GlobalMarketDialog:show(target, callbackFunc, actionType, fillTypeTitle, fillTypeName, price, silos)
    self.target = target
    self.callbackFunc = callbackFunc
    self.actionType = actionType
    self.fillTypeTitle = fillTypeTitle
    self.fillTypeName = fillTypeName
    self.pricePer1000 = price
    self.currentAmount = 0
    self.storageLocations = silos or {}

    if GlobalMarket.debugManager ~= nil then
        GlobalMarket.debugManager:trace("Dialog opened: %s %s (Price: %.2f). Available Storages: %d", actionType, tostring(fillTypeName), price, #self.storageLocations)
    end

    -- We completely rely on the custom GM dialog to handle both bulk
    -- and object storages seamlessly via liter/piece inputs.
    g_gui:showDialog("GlobalMarketDialog")
end

-- Native UI hook triggered right before the dialog becomes visible
function GlobalMarketDialog:onOpen()
    GlobalMarketDialog:superClass().onOpen(self)

    -- Variables for format logic
    self.currentCountFactor = 1
    self.currentFormatXml = nil
    self.availableFormats = {}
    self.baseInfoText = ""

    -- Reset the sticky input field immediately
    if self.amountInput ~= nil then
        self.amountInput:setText("0")
    end

    local titlePrefix = self.actionType == "SELL"
        and (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderStorage") .. ": ")
        or (g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderMarket") .. ": ")
    self.dialogTitleElement:setText(titlePrefix .. tostring(self.fillTypeTitle))

    if self.dialogFillTypeIcon ~= nil then
        local fillTypeDesc = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeByName(self.fillTypeName) or nil
        if fillTypeDesc ~= nil and fillTypeDesc.hudOverlayFilename ~= nil and fillTypeDesc.hudOverlayFilename ~= "" then
            self.dialogFillTypeIcon:setImageFilename(fillTypeDesc.hudOverlayFilename)
            self.dialogFillTypeIcon:setVisible(true)
        else
            self.dialogFillTypeIcon:setVisible(false)
        end
    end
    if self.headerBoxLayout ~= nil then
        self.headerBoxLayout:invalidateLayout()
    end

    local actionText = self.actionType == "SELL" and g_i18n:getText("ui_btn_sell") or g_i18n:getText("ui_btn_buy")
    if self.yesButton ~= nil then
        self.yesButton:setText(actionText)
    end

    local storageNames = {}
    for _, loc in ipairs(self.storageLocations) do
        table.insert(storageNames, loc.title)
    end

    self.storageSelectionElement:setTexts(storageNames)
    self.storageSelectionElement:setState(1, true)
    self:onClickStorage(1)
    self:updateDocumentHeader()

    FocusManager:setFocus(self.amountInput)
end

-- Triggered when the user selects a different storage from the dropdown
function GlobalMarketDialog:onClickStorage(state)
    self.selectedStorageIndex = state
    local selectedSilo = self.storageLocations[state]
    self:updateDocumentPlace()

    -- Hide the format selection by default and reset variables
    if self.formatSelectionElement ~= nil then
        self.formatSelectionElement:setVisible(false)
    end
    self.currentCountFactor = 1
    self.currentFormatXml = nil
    self.availableFormats = {}

    if selectedSilo ~= nil then
        -- 1. Calculate maxAmount for the storage as usual
        if self.actionType == "SELL" then
            self.maxAmount = selectedSilo.level
        else
            local marketStock = 0
            local gm = g_currentMission.globalMarket
            local marketData = (gm:getIsMarketOnline() and gm.fillTypes ~= nil and #gm.fillTypes > 0) and gm.fillTypes or gm.offlineMarketFillTypes

            if marketData ~= nil then
                for _, data in pairs(marketData) do
                    if data.fillType == self.fillTypeName then
                        marketStock = data.fillLevel or 0
                        break
                    end
                end
            end
            self.maxAmount = math.min(selectedSilo.freeCapacity, marketStock)
        end

        -- 2. Handle format selection for ObjectStorages (Bales / Pallets)
        if selectedSilo.isObjectStorage then
            local fillType = g_fillTypeManager:getFillTypeByName(self.fillTypeName)

            if fillType ~= nil then
                if self.actionType == "BUY" then
                    -- BUYING: Scan engine for all possible supported formats
                    if selectedSilo.supportsBales and fillType.isBaleType and g_baleManager ~= nil then
                        local seenMapBaleSizes = {}
                        local seenBaleSizeAndCap = {}
                        local baleFormats = {}
                        local baseTitleCounts = {}

                        local mapCustomEnv = (g_currentMission ~= nil and g_currentMission.missionInfo ~= nil) and g_currentMission.missionInfo.customEnvironment or nil
                        local mapBaseDir = g_currentMission ~= nil and g_currentMission.baseDirectory or nil

                        for _, bale in ipairs(g_baleManager.bales) do
                            if bale.isAvailable and bale.fillTypes ~= nil then
                                for _, ftData in ipairs(bale.fillTypes) do
                                    if ftData.fillTypeIndex == fillType.index then
                                        local isRound, width, height, length, diameter = g_baleManager:getBaleInfoByXMLFilename(bale.xmlFilename)
                                        local sizeKey = isRound
                                            and string.format("ROUND_%.2f_%.2f", diameter or 0, width or 0)
                                            or string.format("SQUARE_%.2f_%.2f_%.2f", length or 0, width or 0, height or 0)
                                        local capInt = math.floor((ftData.capacity or 0) + 0.5)
                                        local sizeCapKey = string.format("%s_%d", sizeKey, capInt)

                                        local isMapOrBaseBale = (bale.customEnvironment == nil)
                                            or (mapCustomEnv ~= nil and bale.customEnvironment == mapCustomEnv)
                                            or (mapBaseDir ~= nil and mapBaseDir ~= "" and bale.baseDirectory == mapBaseDir)

                                        local shouldAdd = false
                                        if isMapOrBaseBale then
                                            -- Map/Basegame bales: Only allow the first matching bale per physical size (mirrors BaleManager:getBaleIndex)
                                            if not seenMapBaleSizes[sizeKey] and not seenBaleSizeAndCap[sizeCapKey] then
                                                seenMapBaleSizes[sizeKey] = true
                                                seenBaleSizeAndCap[sizeCapKey] = true
                                                shouldAdd = true
                                            end
                                        else
                                            -- External Mod/DLC bales: Allow if they introduce new dimensions OR a different capacity (e.g. High-Density / Liftable bales)
                                            if not seenBaleSizeAndCap[sizeCapKey] then
                                                seenBaleSizeAndCap[sizeCapKey] = true
                                                shouldAdd = true
                                            end
                                        end

                                        if shouldAdd then
                                            local title = isRound
                                                and string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_roundbale"), diameter or width or 1.25)
                                                or string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_squarebale"), length or 2.40)

                                            baseTitleCounts[title] = (baseTitleCounts[title] or 0) + 1
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

                        -- Disambiguate dropdown labels if a mod added a variant with the same display length/diameter but different capacity
                        for _, baleFormat in ipairs(baleFormats) do
                            if baseTitleCounts[baleFormat.title] ~= nil and baseTitleCounts[baleFormat.title] > 1 then
                                baleFormat.title = string.format("%s - %s", baleFormat.title, g_i18n:formatVolume(baleFormat.capacity or 0, 0))
                            end
                            table.insert(self.availableFormats, baleFormat)
                        end
                    end

                    -- GM STORE CACHE BRIDGE:
                    -- Strictly fetches dynamically parsed formats (Pallets, BigBags, IBCs)
                    -- from our RAM dictionary. Using an independent 'if' instead of 'elseif'
                    -- allows dual-capable storages (like the GM Terminal) to offer both bales and pallets.
                    if selectedSilo.supportsPallets then
                        if GlobalMarketStoreCache ~= nil then
                            local cachedFormats = GlobalMarketStoreCache.getFormatsForFillType(self.fillTypeName)
                            for _, formatData in ipairs(cachedFormats) do
                                table.insert(self.availableFormats, formatData)
                            end
                        end
                    end

                elseif self.actionType == "SELL" then
                    -- SELLING: Scan the actual storage for formats and count physical objects
                    local spec = selectedSilo.storage.spec_objectStorage
                    if spec ~= nil and spec.objectInfos ~= nil then
                        local formatTracker = {}

                        for _, objectInfo in ipairs(spec.objectInfos) do
                            local obj = objectInfo.objects[1]
                            local objFillType, objXml, objCapacity = nil, nil, 0
                            local isFermenting = false
                            local objFarmId = FarmManager.SPECTATOR_FARM_ID

                            if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                                objFillType = (obj.baleObject ~= nil) and obj.baleObject:getFillType() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillType)
                                objCapacity = (obj.baleObject ~= nil) and obj.baleObject:getFillLevel() or (obj.baleAttributes ~= nil and obj.baleAttributes.fillLevel)
                                objXml = (obj.baleObject ~= nil) and obj.baleObject.xmlFilename or (obj.baleAttributes ~= nil and obj.baleAttributes.xmlFilename)
                                objFarmId = (obj.baleObject ~= nil and obj.baleObject.ownerFarmId) or (obj.baleAttributes ~= nil and obj.baleAttributes.farmId) or FarmManager.SPECTATOR_FARM_ID

                                if obj.baleObject ~= nil and obj.baleObject.isFermenting then isFermenting = true end
                                if obj.baleAttributes ~= nil and obj.baleAttributes.isFermenting then isFermenting = true end
                            elseif obj.REFERENCE_CLASS_NAME == "Vehicle" then
                                objFillType = obj.palletAttributes ~= nil and obj.palletAttributes.fillType
                                objCapacity = obj.palletAttributes ~= nil and obj.palletAttributes.fillLevel
                                objXml = obj.palletAttributes ~= nil and obj.palletAttributes.configFileName
                                objFarmId = obj.palletAttributes ~= nil and obj.palletAttributes.ownerFarmId or FarmManager.SPECTATOR_FARM_ID
                            end

                            local playerFarmId = g_currentMission:getFarmId()

                            -- Only count non-fermenting objects of the selected fillType that belong to the player
                            if objFillType == fillType.index and objXml ~= nil and not isFermenting and objFarmId == playerFarmId then
                                if formatTracker[objXml] == nil then
                                    local title = g_i18n:getText("ui_gm_unit_piece")
                                    local unitKey = "ui_gm_unit_piece"

                                    if obj.REFERENCE_CLASS_NAME == "Bale" or obj.REFERENCE_CLASS_NAME == "PackedBale" then
                                        unitKey = "ui_gm_unit_bale"
                                        if g_baleManager ~= nil then
                                            local isRound, width, height, length, diameter = g_baleManager:getBaleInfoByXMLFilename(objXml)
                                            title = isRound
                                                and string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_roundbale"), diameter or width or 1.25)
                                                or string.format("%s (%.2fm)", g_i18n:getText("ui_gm_format_squarebale"), length or 2.40)
                                        end
                                    else
                                        unitKey = "ui_gm_unit_pallet"
                                        local storeItem = g_storeManager:getItemByXMLFilename(objXml)
                                        title = storeItem ~= nil and storeItem.name or g_i18n:getText("ui_gm_format_pallet")
                                    end

                                    formatTracker[objXml] = {
                                        title = title,
                                        xml = objXml,
                                        capacity = objCapacity,
                                        unitKey = unitKey,
                                        actualCount = objectInfo.numObjects -- Store physical count
                                    }
                                else
                                    -- Add up amounts if there are multiple stacks of the exact same XML format
                                    formatTracker[objXml].actualCount = formatTracker[objXml].actualCount + objectInfo.numObjects
                                end
                            end
                        end

                        -- Move tracker data to our standard availableFormats table
                        for _, formatData in pairs(formatTracker) do
                            table.insert(self.availableFormats, formatData)
                        end
                    end
                end

                -- If formats exist, populate the dropdown texts and show it
                if #self.availableFormats > 0 then
                    local texts = {}
                    for _, format in ipairs(self.availableFormats) do
                        table.insert(texts, format.title)
                    end
                    self.formatSelectionElement:setTexts(texts)
                    self.formatSelectionElement:setVisible(true)
                end
            end
        end

        -- 3. Update the info text below the title (+ remaining GM storage time when selling from a GM terminal, #20)
        self.storageAgeSuffix = (self.actionType == "SELL")
            and GlobalMarketStorageAge.getDialogSuffix(selectedSilo, self.fillTypeName) or ""
        local infoText = string.format("%s: %s | %s: %s / 1.000 L",
            g_i18n:getText("ui_ingameMenuGlobalMarketAvailable"),
            g_i18n:formatVolume(self.maxAmount, 0),
            g_i18n:getText("ui_ingameMenuGlobalMarketPrice"),
            g_i18n:formatMoney(self.pricePer1000, 0, true, true)) .. self.storageAgeSuffix

        self.baseInfoText = infoText
        if self.dialogInfoTextElement ~= nil then
            self.dialogInfoTextElement:setText(infoText)
            self.dialogInfoTextElement:setTextColor(COLOR_LABEL[1], COLOR_LABEL[2], COLOR_LABEL[3], COLOR_LABEL[4])
        end
        self:updateStepButtonLabels()

        -- 4. Trigger follow-up logic
        if #self.availableFormats > 0 then
            self.formatSelectionElement:setState(1, true)
            if self.onClickFormat ~= nil then
                self:onClickFormat(1)
            end
        else
            self:onAmountChanged()
        end
    end
end

-- Triggered when the user changes the object format dropdown (Bales/Pallets)
function GlobalMarketDialog:onClickFormat(state)
    local selectedFormat = self.availableFormats[state]
    if selectedFormat ~= nil then
        self.currentFormatXml = selectedFormat.xml
        self.currentCountFactor = selectedFormat.capacity or 1000
        self.currentUnitKey = selectedFormat.unitKey or "ui_gm_unit_piece"

        local selectedSilo = self.storageLocations[self.selectedStorageIndex]
        local maxPieces = 0

        if selectedSilo ~= nil and selectedSilo.isObjectStorage then
            if self.actionType == "SELL" then
                -- SELLING: Maximum is exactly the number of physical objects in storage
                maxPieces = selectedFormat.actualCount or 0
            else
                -- BUYING: Maximum is determined by free slots and market stock
                local spec = selectedSilo.storage.spec_objectStorage
                local maxCapacity = spec.capacity or 250
                local numStored = spec.numStoredObjects or 0
                local freeSlots = math.max(0, maxCapacity - numStored)

                -- Determine how many pieces we can actually afford from the market stock
                local marketStock = 0
                local gm = g_currentMission.globalMarket
                local marketData = (gm:getIsMarketOnline() and gm.fillTypes ~= nil and #gm.fillTypes > 0) and gm.fillTypes or gm.offlineMarketFillTypes
                if marketData ~= nil then
                    for _, data in pairs(marketData) do
                        if data.fillType == self.fillTypeName then
                            marketStock = data.fillLevel or 0
                            break
                        end
                    end
                end

                local maxPiecesFromMarket = math.floor(marketStock / self.currentCountFactor)
                maxPieces = math.min(freeSlots, maxPiecesFromMarket)
            end
        end

        self.currentMaxPieces = maxPieces

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:debug("Dialog: Format selected '%s' (Capacity: %d, MaxPieces: %d)",
                selectedFormat.title, self.currentCountFactor, self.currentMaxPieces)
        end

        -- Update info text using strict translation system
        local infoText = string.format(g_i18n:getText("ui_gm_format_info"),
            selectedFormat.title, self.currentMaxPieces, self.currentCountFactor) .. (self.storageAgeSuffix or "")
        self.baseInfoText = infoText
        if self.dialogInfoTextElement ~= nil then
            self.dialogInfoTextElement:setText(infoText)
            self.dialogInfoTextElement:setTextColor(COLOR_LABEL[1], COLOR_LABEL[2], COLOR_LABEL[3], COLOR_LABEL[4])
        end
        self:updateStepButtonLabels()

        -- Reset input field and trigger calculation
        if self.amountInput ~= nil then
            self.amountInput:setText("0")
        end
        self:onAmountChanged()
    end
end

-- Returns the clamped upper limit for the active storage and packaging mode
function GlobalMarketDialog:getEffectiveMaxAmount()
    local effectiveMax = self.maxAmount or 0
    if self.currentCountFactor > 1 and self.currentMaxPieces ~= nil then
        effectiveMax = self.currentMaxPieces
        if effectiveMax > GlobalMarketDialog.MAX_OBJECTS_PER_TX then
            effectiveMax = GlobalMarketDialog.MAX_OBJECTS_PER_TX
        end
    end
    return math.max(0, math.floor(effectiveMax))
end

-- Updates quick-step pill button captions cleanly between bulk liters and object pieces
function GlobalMarketDialog:updateStepButtonLabels()
    local labels = (self.currentCountFactor > 1)
        and GlobalMarketDialog.OBJECT_STEP_LABELS
        or GlobalMarketDialog.BULK_STEP_LABELS
    local buttons = {
        self.btnStepMinus3,
        self.btnStepMinus2,
        self.btnStepMinus1,
        self.btnStepPlus1,
        self.btnStepPlus2,
        self.btnStepPlus3
    }
    for i = 1, 6 do
        if buttons[i] ~= nil and labels[i] ~= nil then
            buttons[i]:setText(labels[i])
        end
    end
end

-- Applies a stepped delta from one of the 6 quick-step buttons, clamped to valid limits
function GlobalMarketDialog:applyStepByTier(tierIndex, direction)
    local steps = (self.currentCountFactor > 1)
        and GlobalMarketDialog.OBJECT_STEPS
        or GlobalMarketDialog.BULK_STEPS
    local stepSize = steps[tierIndex] or 0
    local currentText = (self.amountInput ~= nil) and self.amountInput:getText() or nil
    local currentVal = tonumber(currentText) or self.currentAmount or 0
    local effectiveMax = self:getEffectiveMaxAmount()
    local nextVal = math.clamp(math.floor(currentVal + (stepSize * direction)), 0, effectiveMax)

    if self.amountInput ~= nil then
        self.amountInput:setText(string.format("%d", nextVal))
    end
    self:onAmountChanged()
end

-- Resets the quantity field cleanly back to 0
function GlobalMarketDialog:onClickZeroAmount()
    if self.amountInput ~= nil then
        self.amountInput:setText("0")
    end
    self:onAmountChanged()
end

function GlobalMarketDialog:onClickStepMinus3()
    self:applyStepByTier(3, -1)
end

function GlobalMarketDialog:onClickStepMinus2()
    self:applyStepByTier(2, -1)
end

function GlobalMarketDialog:onClickStepMinus1()
    self:applyStepByTier(1, -1)
end

function GlobalMarketDialog:onClickStepPlus1()
    self:applyStepByTier(1, 1)
end

function GlobalMarketDialog:onClickStepPlus2()
    self:applyStepByTier(2, 1)
end

function GlobalMarketDialog:onClickStepPlus3()
    self:applyStepByTier(3, 1)
end

-- Triggered when the user clicks the 'MAX' button next to the input field
function GlobalMarketDialog:onClickMaxAmount()
    local fillAmount = self:getEffectiveMaxAmount()

    if self.actionType == "BUY" then
        local currentMoney = g_currentMission:getMoney()
        local selectedSilo = self.storageLocations[self.selectedStorageIndex]
        local isGmMarket = selectedSilo ~= nil and selectedSilo.isGmMarket

        if currentMoney <= 0 then
            fillAmount = 0
        else
            -- Account for dealer markup and delivery costs in max calculation to avoid liquidity overshoot
            local baseDeliveryFee = isGmMarket and 0 or ((GlobalMarket.DELIVER_COST or 0) * EconomyManager.getCostMultiplier())
            local feePerLiter = isGmMarket and 0 or ((GlobalMarket.DELIVER_COST_PERLITER or 0) * EconomyManager.getCostMultiplier())
            local markupFactor = 1 + ((GlobalMarket.DEALER_MARKUP or 0) / 100)

            -- Combine commodity price (including dealer markup) and delivery fee to get total cost per liter
            local costPerLiter = ((self.pricePer1000 / 1000) * markupFactor) + feePerLiter
            local maxAffordableLiters = 0

            if currentMoney > baseDeliveryFee and costPerLiter > 0 then
                maxAffordableLiters = (currentMoney - baseDeliveryFee) / costPerLiter
            end

            if self.currentCountFactor > 1 then
                local maxAffordablePieces = math.floor(maxAffordableLiters / self.currentCountFactor)
                fillAmount = math.min(fillAmount, maxAffordablePieces)
            else
                fillAmount = math.min(fillAmount, maxAffordableLiters)
            end
        end
    end

    fillAmount = math.max(0, math.floor(fillAmount))

    -- Update the input field and trigger the calculation logic
    if self.amountInput ~= nil then
        self.amountInput:setText(string.format("%d", fillAmount))
        self:onAmountChanged()
    end
end

-- Handles user keyboard input and validates against limits (No logging to prevent spam)
function GlobalMarketDialog:onAmountChanged()
    local text = (self.amountInput ~= nil) and self.amountInput:getText() or "0"
    local parsed = tonumber(text)
    local effectiveMax = self:getEffectiveMaxAmount()
    local amount = math.clamp(math.floor(parsed or 0), 0, effectiveMax)

    if self.amountInput ~= nil and parsed ~= nil and (parsed < 0 or parsed > effectiveMax or parsed ~= amount) then
        self.amountInput:setText(tostring(amount))
    end
    self.currentAmount = amount

    -- Update the dynamic unit text next to the MAX button based on the current format
    if self.inputUnitText ~= nil then
        if self.currentCountFactor > 1 and self.currentUnitKey ~= nil then
            self.inputUnitText:setText(g_i18n:getText(self.currentUnitKey))
        else
            self.inputUnitText:setText(g_i18n:getText("ui_gm_unit_liter"))
        end
    end

    -- Trigger the total value calculation, UI text update, and button state
    self:updateTotalValue()
end

-- Populates a single label/value row inside the receipt card cleanly
function GlobalMarketDialog:setReceiptRow(labelElem, valueElem, labelText, valueText, valueColor, labelColor)
    local lc = labelColor or COLOR_LABEL
    local vc = valueColor or COLOR_WHITE
    if labelElem ~= nil then
        labelElem:setText(labelText or "")
        labelElem:setTextColor(lc[1], lc[2], lc[3], lc[4])
    end
    if valueElem ~= nil then
        valueElem:setText(valueText or "")
        valueElem:setTextColor(vc[1], vc[2], vc[3], vc[4])
    end
end

-- Highlights the per-transaction physical object spawn cap in the subtitle when hit
function GlobalMarketDialog:updateSubtitleCapWarning()
    if self.dialogInfoTextElement == nil or self.baseInfoText == nil then
        return
    end
    local capHit = self.currentCountFactor > 1
        and self.currentAmount >= GlobalMarketDialog.MAX_OBJECTS_PER_TX
        and (self.currentMaxPieces or 0) > GlobalMarketDialog.MAX_OBJECTS_PER_TX

    if capHit then
        local limitWarning = string.format(g_i18n:getText("ui_gm_warning_engineLimit"),
            GlobalMarketDialog.MAX_OBJECTS_PER_TX)
        self.dialogInfoTextElement:setText(self.baseInfoText .. limitWarning)
        self.dialogInfoTextElement:setTextColor(COLOR_AMBER[1], COLOR_AMBER[2], COLOR_AMBER[3], COLOR_AMBER[4])
    else
        self.dialogInfoTextElement:setText(self.baseInfoText)
        self.dialogInfoTextElement:setTextColor(COLOR_LABEL[1], COLOR_LABEL[2], COLOR_LABEL[3], COLOR_LABEL[4])
    end
end

---Sets a row on the paper document: the dark-menu colors are mapped to their ink variants
function GlobalMarketDialog:setPaperRow(labelElem, valueElem, labelText, valueText, valueColor, labelColor)
    self:setReceiptRow(labelElem, valueElem, labelText, valueText,
        PAPER_COLORS[valueColor or COLOR_WHITE] or PAPER_INK, PAPER_COLORS[labelColor or COLOR_LABEL] or PAPER_LABEL)
end

---Fills the letterhead: document type, number and date from the game time, market and farm
function GlobalMarketDialog:updateDocumentHeader()
    local isBuy = (self.actionType == "BUY")
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local gm = g_currentMission ~= nil and g_currentMission.globalMarket or nil
    if self.receiptDocTitle ~= nil then
        self.receiptDocTitle:setText(g_i18n:getText(isBuy and "ui_gm_doc_invoice" or "ui_gm_doc_creditNote"))
    end
    if self.receiptDocNumber ~= nil and env ~= nil then
        -- Cosmetic number from the game time (day, hour, minute), nothing is saved
        local number = string.format("GM-%03d-%02d%02d", env.currentDay or 0, env.currentHour or 0, env.currentMinute or 0)
        self.receiptDocNumber:setText(string.format(g_i18n:getText("ui_gm_doc_number"), number))
    end
    if self.receiptDocDate ~= nil and env ~= nil then
        local dayText = g_i18n:formatDayInPeriod() or ""
        local yearText = string.format(g_i18n:getText("ui_gm_doc_year"), env.currentYear or 1)
        self.receiptDocDate:setText(string.format(g_i18n:getText("ui_gm_doc_date"), dayText .. ", " .. yearText))
    end
    -- Buying: the market delivers to the farm; selling: the farm delivers to the market
    local marketName = (gm ~= nil and gm:getIsMarketOnline() and gm.onlineMarketName) or "Global Market"
    local farm = (g_farmManager ~= nil and g_currentMission ~= nil) and g_farmManager:getFarmById(g_currentMission:getFarmId()) or nil
    local farmName = (farm ~= nil and farm.name) or "-"
    if self.receiptDocFrom ~= nil then
        self.receiptDocFrom:setText(string.format(g_i18n:getText("ui_gm_doc_from"), isBuy and marketName or farmName))
    end
    if self.receiptDocTo ~= nil then
        self.receiptDocTo:setText(string.format(g_i18n:getText("ui_gm_doc_to"), isBuy and farmName or marketName))
    end
    self:updateDocumentPlace()
end

---Shows the selected storage as delivery place (buy) or pickup place (sell)
function GlobalMarketDialog:updateDocumentPlace()
    if self.receiptDocPlace == nil then
        return
    end
    local silo = self.storageLocations[self.selectedStorageIndex]
    local key = (self.actionType == "BUY") and "ui_gm_doc_deliveryPlace" or "ui_gm_doc_pickupPlace"
    self.receiptDocPlace:setText(string.format(g_i18n:getText(key), (silo ~= nil and silo.title) or "-"))
end

-- Calculates the final price, renders the structured 6-row receipt, and validates liquidity
function GlobalMarketDialog:updateTotalValue()
    local totalLiters = self.currentAmount * self.currentCountFactor
    local baseValue = (totalLiters / 1000) * self.pricePer1000

    local markupPct = (self.actionType == "BUY") and (GlobalMarket.DEALER_MARKUP or 0) or 0
    local dealerCosts = (totalLiters > 0 and markupPct > 0) and (baseValue * (markupPct / 100)) or 0

    local selectedSilo = self.storageLocations[self.selectedStorageIndex]
    local isGmMarket = selectedSilo ~= nil and selectedSilo.isGmMarket == true
    local deliveryCosts = 0

    if selectedSilo ~= nil and not isGmMarket and totalLiters > 0 then
        local baseCost = GlobalMarket.DELIVER_COST or 0
        local costPerLiter = GlobalMarket.DELIVER_COST_PERLITER or 0
        deliveryCosts = (baseCost + (costPerLiter * totalLiters)) * EconomyManager.getCostMultiplier()
    end

    local finalTotal = (self.actionType == "BUY")
        and (baseValue + dealerCosts + deliveryCosts)
        or math.max(0, baseValue - deliveryCosts)
    local currentMoney = g_currentMission:getMoney()

    self:updateSubtitleCapWarning()

    -- Row 1: Combined Trade Quantity (pieces + total liters for ObjectStorages, or liters for bulk)
    local qtyValue
    if self.currentCountFactor > 1 then
        qtyValue = string.format("%d %s (%s)",
            self.currentAmount,
            g_i18n:getText(self.currentUnitKey or "ui_gm_unit_piece"),
            g_i18n:formatVolume(totalLiters, 0))
    else
        qtyValue = g_i18n:formatVolume(totalLiters, 0)
    end
    self:setPaperRow(self.receiptRow1Label, self.receiptRow1Value,
        g_i18n:getText("ui_gm_receipt_quantity"), qtyValue, COLOR_WHITE)

    -- Rows 2 & 3: Stable 2-line breakdown without layout jumps
    if self.actionType == "BUY" and markupPct > 0 then
        self:setPaperRow(self.receiptRow2Label, self.receiptRow2Value,
            g_i18n:getText("ui_gm_receipt_goodsValue"),
            g_i18n:formatMoney(baseValue, 0, true, true), COLOR_WHITE)

        local markupText = (dealerCosts > 0)
            and ("+ " .. g_i18n:formatMoney(dealerCosts, 0, true, true))
            or g_i18n:formatMoney(0, 0, true, true)
        self:setPaperRow(self.receiptRow3Label, self.receiptRow3Value,
            string.format("%s (%d%%)", g_i18n:getText("ui_gm_settings_markup"), markupPct),
            markupText, (dealerCosts > 0) and COLOR_AMBER or COLOR_MUTED)
    else
        local unitText
        if self.currentCountFactor > 1 then
            local unitPrice = (self.currentCountFactor / 1000) * self.pricePer1000
            unitText = string.format("%s / %s",
                g_i18n:formatMoney(unitPrice, 0, true, true),
                g_i18n:getText(self.currentUnitKey or "ui_gm_unit_piece"))
        else
            unitText = string.format("%s / 1.000 L", g_i18n:formatMoney(self.pricePer1000, 0, true, true))
        end
        self:setPaperRow(self.receiptRow2Label, self.receiptRow2Value,
            g_i18n:getText("ui_gm_receipt_unitPrice"), unitText, COLOR_MUTED)
        self:setPaperRow(self.receiptRow3Label, self.receiptRow3Value,
            g_i18n:getText("ui_gm_receipt_goodsValue"),
            g_i18n:formatMoney(baseValue, 0, true, true), COLOR_WHITE)
    end

    -- Row 4: Shipping costs (green GM Logistics Terminal free shipping highlight)
    local shipText
    local shipColor
    if isGmMarket then
        shipText = string.format(g_i18n:getText("ui_gm_receipt_freeTerminal"),
            g_i18n:formatMoney(0, 0, true, true))
        shipColor = COLOR_GREEN
    elseif deliveryCosts > 0 then
        local sign = (self.actionType == "BUY") and "+ " or "- "
        shipText = sign .. g_i18n:formatMoney(deliveryCosts, 0, true, true)
        shipColor = COLOR_AMBER
    else
        shipText = g_i18n:formatMoney(0, 0, true, true)
        shipColor = COLOR_MUTED
    end
    self:setPaperRow(self.receiptRow4Label, self.receiptRow4Value,
        g_i18n:getText("ui_gm_receipt_shipping"), shipText, shipColor)

    -- Rows 5 & 6: Total price/proceeds and live post-transaction balance (or shortfall warning)
    local totalLabel = g_i18n:getText((self.actionType == "SELL")
        and "ui_gm_receipt_totalSell" or "ui_gm_receipt_totalBuy")
    local hasEnoughMoney = (self.actionType ~= "BUY") or (finalTotal <= 0) or (currentMoney >= finalTotal)

    if not hasEnoughMoney then
        self:setPaperRow(self.receiptTotalLabel, self.receiptTotalValue,
            totalLabel, g_i18n:formatMoney(finalTotal, 0, true, true), COLOR_RED, COLOR_WHITE)

        local shortfall = finalTotal - currentMoney
        self:setReceiptRow(self.receiptBalanceLabel, self.receiptBalanceValue,
            g_i18n:getText("ui_gm_receipt_shortfall"),
            "- " .. g_i18n:formatMoney(shortfall, 0, true, true), COLOR_RED, COLOR_RED)

        if self.yesButton ~= nil then
            self.yesButton:setDisabled(true)
        end
    else
        local totalText = g_i18n:formatMoney(finalTotal, 0, true, true)
        if self.actionType == "SELL" and finalTotal > 0 then
            totalText = "+ " .. totalText
        end
        self:setPaperRow(self.receiptTotalLabel, self.receiptTotalValue,
            totalLabel, totalText, (self.currentAmount > 0) and COLOR_GREEN or COLOR_MUTED, COLOR_WHITE)

        local balanceAfter = (self.actionType == "BUY")
            and (currentMoney - finalTotal)
            or (currentMoney + finalTotal)
        self:setReceiptRow(self.receiptBalanceLabel, self.receiptBalanceValue,
            g_i18n:getText("ui_gm_receipt_balanceAfter"),
            g_i18n:formatMoney(balanceAfter, 0, true, true),
            (balanceAfter < 0) and COLOR_RED or COLOR_BAL_OK, COLOR_LABEL)

        if self.yesButton ~= nil then
            self.yesButton:setDisabled(self.currentAmount <= 0)
        end
    end
end

-- Triggered when the user confirms the transaction popup
function GlobalMarketDialog:onClickOk()
    local selectedStorage = self.storageLocations[self.storageSelectionElement:getState()]

    if self.callbackFunc ~= nil and selectedStorage ~= nil then
        -- Backend expects volume in liters; convert object piece count to total liters before sending
        local litersToProcess = self.currentAmount
        if self.currentCountFactor > 1 then
            litersToProcess = self.currentAmount * self.currentCountFactor
        end

        if GlobalMarket.debugManager ~= nil then
            GlobalMarket.debugManager:info("Dialog Confirmed: Dispatching %s transaction for %.2f L of %s.", self.actionType, litersToProcess, tostring(self.fillTypeName))
        end

        -- Pass the calculated liters to the main UI callback
        self.callbackFunc(self.target, litersToProcess, selectedStorage.id, self.actionType, self.fillTypeName, selectedStorage.isObjectStorage, self.currentFormatXml, self.currentCountFactor)
    end

    GlobalMarketDialog:superClass().onClickOk(self)
    self:close()

    return false
end

function GlobalMarketDialog:onClickBack()
    GlobalMarketDialog:superClass().onClickBack(self)
    self:close()
    return false
end

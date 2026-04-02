--
-- FS22 - GlobalMarket - SelectLevel
--
-- @Interface: 1.9.1.0 b23678
-- @Author: KR-Softwares
-- @Date: 12.05.2023
-- @Version: 1.0.0.0
--
-- @Support: -
--
-- Changelog:
-- 	v1.0.0.0 (12.05.2023):
--		Release fs22
--

SelectLevel = {
	CONTROLS = {
        BTN_BACK = "btnBack",
        BTN_SELLBUY = "btnSellBuy",
		DIALOGDATA = "dialogTitle",
		CELLTEXT_FILLTYPE= "cellTextFillType",
		CELLTEXT_FILLLEVEL = "cellTextFillLevel",
		CELLTEXT_PRICE = "cellTextPrice",
		TEXT_LEVEL = "textLevel",
		TEXT_LEVEL_UNIT = "textLevelUnit",
		PRICE_TEXT = "levelPriceText",
		PRICE = "levelPrice",
		PRICEDELIVERY = "levelDeliveryPrice",
		PRICE_NOT_ENOUGH_MONEY = "levelPriceNotEnoughMoney",
		TABLE_STORAGES = "gmTableSelectStorage",
		TABLE_STORAGES = "gmTableSelectStorage",
		DIALOG_STANDARD = "dialogElement",
		DIALOG_STORAGE = "dialogElementStorage",
		DIALOG_LOADING = "dialogElementLoading",
	}
}
local SelectLevel_mt = Class(SelectLevel, MessageDialog)

SelectLevel.MODE_NONE = 0
SelectLevel.MODE_STORAGE = 1
SelectLevel.MODE_STORAGE_OBJECT = 2
SelectLevel.MODE_MARKET = 3
SelectLevel.MODE_MARKET_OBJECT = 4

function SelectLevel.new(target, custom_mt)
	local self = MessageDialog.new(target, custom_mt or SelectLevel_mt)

	self:registerControls(SelectLevel.CONTROLS)

	self.maxLevel = 0
	self.currentPrice = 0
	self.currentCountFactor = 1
	self.currentAttributes = ""
	self.currentXmlFilename = ""
	self.currentObjectId = 0
	self.currentFillType = ""
	self.currentFillTypeIndex = 0
	self.sellStorageId = 0
	self.isGmPlaceable = false
	
	return self
end

function SelectLevel:onCreate()
	SelectLevel:superClass().onCreate(self)    
end

function SelectLevel:onGuiSetupFinished()
	SelectLevel:superClass().onGuiSetupFinished(self)

	self.gmTableSelectStorage:setDataSource(self)
	self.gmTableSelectStorage:setDelegate(self)

	local old = self.textLevelUnit.onFocusLeave

	function self.textLevelUnit.onFocusLeave(...)
		old(...)
		self:onEnterPressedNumber()
	end
end

function SelectLevel:onOpen()
	SelectLevel:superClass().onOpen(self)
	self.currentMode = SelectLevel.MODE_NONE
		
	self.textLevel:setText("0")
	self.levelPrice:setText(g_i18n:formatMoney(0, 0, true))
	self.btnSellBuy:setDisabled(true)
	self.levelPriceNotEnoughMoney:setVisible(false)

	self.dialogElement:setVisible(true)
	self.dialogElementLoading:setVisible(false)

	self.text_pallet = g_i18n:getText("category_pallets")

    g_currentMission.globalMarketSelectLevelUi = self

	self:updateContent()
end

function SelectLevel:setData(mode, data)
	self.currentMode = mode
	self.maxLevel = data.fillLevel
	self.currentCountFactor = 1
	
	if self.currentMode == SelectLevel.MODE_STORAGE_OBJECT or self.currentMode == SelectLevel.MODE_MARKET_OBJECT then
		self.maxLevel = data.count
		self.currentCountFactor = data.fillLevel
		self.currentAttributes = data.attributes
		self.currentXmlFilename = data.xmlFilename
		self.currentObjectId = data.objectId
	elseif self.currentMode == SelectLevel.MODE_MARKET then
		self.maxLevel = g_currentMission.globalMarket:getMarketSiloLevelByFillType(data.fillType)
	end

	self.sellStorageId = data.storageId
	self.isGmPlaceable = data.isGmMarketPlaceable
    
	self.dialogElementStorage:setVisible(self.currentMode == SelectLevel.MODE_MARKET or self.currentMode == SelectLevel.MODE_MARKET_OBJECT)

	self.textLevelUnit:setText(g_i18n:getVolumeUnit(true))

	self.currentFillType = data.fillType
	self.currentFillTypeIndex = g_fillTypeManager:getFillTypeByName(data.fillType).index    
	self.cellTextFillType:setText(g_fillTypeManager:getFillTypeTitleByIndex(self.currentFillTypeIndex))		
	
	self.currentPrice = g_currentMission.globalMarket:getPriceByFillType(data.fillType)
	
	if self.isGmPlaceable or false then
		self.levelDeliveryPrice:setText(g_i18n:formatMoney(0))
	else
		self.levelDeliveryPrice:setText(g_i18n:formatMoney(GlobalMarket.DELIVER_COST * EconomyManager.getCostMultiplier()))
	end

	if self.currentMode == SelectLevel.MODE_STORAGE then
		self.dialogTitle:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderStorage"))  
		self.btnSellBuy:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectBtnSell"))
		self.levelPriceText:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderSellPrice"))
		self.cellTextFillLevel:setText(g_i18n:formatVolume(data.fillLevel, 0))  
		self.cellTextPrice:setText(g_i18n:formatMoney(self.currentPrice * 1000 * EconomyManager.getPriceMultiplier(), 0, true) .. " / 1000 " .. g_i18n:getVolumeUnit())
	elseif self.currentMode == SelectLevel.MODE_STORAGE_OBJECT then
		local unit = self.text_pallet
		if data.isBale then 
			local isRoundbale, bWidth, bHeight, bLength, bDiameter, maxStackHeight = g_baleManager:getBaleInfoByXMLFilename(data.xmlFilename)
			if isRoundbale then unit = g_i18n:getText("fillType_roundBale") else unit = g_i18n:getText("fillType_squareBale") end
		end
		self.textLevelUnit:setText(unit)
		self.dialogTitle:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderStorage"))
		self.btnSellBuy:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectBtnSell"))
		self.cellTextFillLevel:setText(data.count .. " " .. unit)  
		self.levelPriceText:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderSellPrice"))
		self.cellTextPrice:setText(g_i18n:formatMoney(self.currentPrice * self.currentCountFactor * EconomyManager.getPriceMultiplier(), 0, true) .. " / " .. unit)
	elseif self.currentMode == SelectLevel.MODE_MARKET then
		self.dialogTitle:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderMarket"))
		self.btnSellBuy:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectBtnBuy"))
		self.cellTextFillLevel:setText(g_i18n:formatVolume(g_currentMission.globalMarket:getMarketSiloLevelByFillType(self.currentFillType), 0))  
		self.levelPriceText:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderBuyPrice"))
		self.cellTextPrice:setText(g_i18n:formatMoney(self.currentPrice * 1000 * EconomyManager.getPriceMultiplier(), 0, true) .. " / 1000 " .. g_i18n:getVolumeUnit())
	elseif self.currentMode == SelectLevel.MODE_MARKET_OBJECT then
		local unit = self.text_pallet
		if g_currentMission.globalMarket:objectIsBale(data.attributes) then 
			local isRoundbale, bWidth, bHeight, bLength, bDiameter, maxStackHeight = g_baleManager:getBaleInfoByXMLFilename(data.xmlFilename)
			if isRoundbale then unit = g_i18n:getText("fillType_roundBale") else unit = g_i18n:getText("fillType_squareBale") end
		end
		self.textLevelUnit:setText(unit)
		self.dialogTitle:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderMarket"))
		self.btnSellBuy:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectBtnBuy"))
		self.cellTextFillLevel:setText(data.count .. " " .. unit)  
		self.levelPriceText:setText(g_i18n:getText("ui_ingameMenuGlobalMarketSelectHeaderBuyPrice"))
		self.cellTextPrice:setText(g_i18n:formatMoney(self.currentPrice * self.currentCountFactor * EconomyManager.getPriceMultiplier(), 0, true) .. " / " .. unit)
	end
	
	self:updateContent()
end

function SelectLevel:onEnterPressedNumber()
	local level = self.textLevel.text
	local levelN = tonumber(level)
	local isGmPlaceable = self.isGmPlaceable or false
	if levelN == nil then		
		levelN = 0
	else
		if levelN > self.maxLevel then levelN = self.maxLevel end

		if self.currentMode == SelectLevel.MODE_MARKET and self.storages[self.currentSelectStorageSection] ~= nil and 
			self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex] ~= nil then
			local capa = self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex]:getFreeCapacity(self.currentFillTypeIndex)
			if levelN > capa then
				levelN = capa
			end		
			isGmPlaceable = self:getIsGmObjectPlaceable(self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex])
		elseif self.currentMode == SelectLevel.MODE_MARKET_OBJECT and self.storages[self.currentSelectStorageSection] ~= nil and 
			self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex] ~= nil then
			local spec =  self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex].spec_objectStorage
			local capa = spec.capacity - #spec.storedObjects
			if levelN > capa then
				levelN = capa
			end	
			isGmPlaceable = self:getIsGmObjectPlaceable(self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex])
		end
	end
	
	if isGmPlaceable then
		self.levelDeliveryPrice:setText(g_i18n:formatMoney(0))
	else
		self.levelDeliveryPrice:setText(g_i18n:formatMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * levelN* self.currentCountFactor) * EconomyManager.getCostMultiplier()))
	end
	
	local endPrice = levelN * self.currentPrice * self.currentCountFactor * EconomyManager.getPriceMultiplier()
	local notEnoughMoney = endPrice > g_currentMission:getMoney(g_currentMission.inGameMenu.playerFarmId) and self.currentMode == SelectLevel.MODE_MARKET and self.currentMode == SelectLevel.MODE_MARKET_OBJECT

	self.btnSellBuy:setDisabled(levelN == 0 or notEnoughMoney)
	self.levelPrice:setText(g_i18n:formatMoney(endPrice, 0, true))
	self.textLevel:setText(tostring(levelN))
	self.levelPriceNotEnoughMoney:setVisible(notEnoughMoney)
end

function SelectLevel:onClose()
	SelectLevel:superClass().onClose(self)
    g_currentMission.globalMarketSelectLevelUi = nil
end

function SelectLevel:onClickBack(sender)
	self:close()
end

function SelectLevel:onClickSellBuy()	
	self.dialogElement:setVisible(false)
	self.dialogElementLoading:setVisible(true)
	self.dialogElementStorage:setVisible(false)

	local count = nil
	local attributes = nil
	local objectId = nil
	local fillLevel = tonumber(self.textLevel.text)
	local storageId = self.sellStorageId

	if self.currentMode == SelectLevel.MODE_STORAGE_OBJECT then
		count = fillLevel
		fillLevel = self.currentCountFactor
		attributes = self.currentAttributes
		storageId = self.sellStorageId
	elseif self.currentMode == SelectLevel.MODE_MARKET_OBJECT then
		count = fillLevel
		fillLevel = self.currentCountFactor
		objectId = self.currentObjectId
		storageId = self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex].id
	elseif self.currentMode == SelectLevel.MODE_MARKET then
		storageId = self.storages[self.currentSelectStorageSection].entries[self.currentSelectStorageIndex].id
	end
	
	g_currentMission.globalMarket:onSellBuy(self.currentMode, string.upper(self.currentFillType), fillLevel, storageId, count, attributes, objectId)
end

function SelectLevel:updateContent()  	
	self.storages = {
		{
			title = "",
			entries = {}
		}
	}

	if self.currentMode == SelectLevel.MODE_MARKET then 
		for storage, _ in pairs(g_currentMission.storageSystem.storages) do
			if storage.ownerFarmId == g_currentMission.inGameMenu.playerFarmId then
				table.insert(self.storages[1].entries, storage)
			end
		end
	elseif self.currentMode == SelectLevel.MODE_MARKET_OBJECT then
		for _,storage in pairs(g_currentMission.placeableSystem.placeables) do
			if storage.spec_objectStorage ~= nil then
				if storage.ownerFarmId == g_currentMission.inGameMenu.playerFarmId then

					local canStore = true
					
					local _, bWidth, bHeight, bLength, bDiameter, _ = g_baleManager:getBaleInfoByXMLFilename(self.currentXmlFilename)
					bLength = bLength or bDiameter
					bHeight = bHeight or bDiameter

					if storage.spec_objectStorage.maxLength < bLength or storage.spec_objectStorage.maxHeight < bHeight or storage.spec_objectStorage.maxWidth < bWidth then
						canStore = false
					end

					if canStore then
						table.insert(self.storages[1].entries, storage)
					end
				end
			end
		end
	end
	
	self.gmTableSelectStorage:reloadData()
end

function SelectLevel:getStorageName(storage)
	if storage.spec_objectStorage == nil then
		for _,s in pairs(storage.unloadingStations) do		
			return g_storeManager:getItemByXMLFilename(s.owningPlaceable.configFileName).name
		end
	else
		return g_storeManager:getItemByXMLFilename(storage.xmlFile.filename).name
		
	end
	return "no name"
end

function SelectLevel:getIsGmObjectPlaceable(storage) 
	if storage.spec_objectStorage ~= nil then
		return storage.spec_objectStorage.isGmMarket
	elseif storage.isGmMarket ~= nil then
		return storage.isGmMarket
	end
	return false
end

function SelectLevel:getNumberOfSections(list)
	return #self.storages
end

function SelectLevel:getNumberOfItemsInSection(list, section)
	return #self.storages[section].entries 
end

function SelectLevel:getTitleForSectionHeader(list, section)
	return self.storages[section].title  
end

function SelectLevel:populateCellForItemInSection(list, section, index, cell)
	local storage = self.storages[section].entries[index]	
	cell:getAttribute("name"):setText(self:getStorageName(storage))
	
	if self.currentMode == SelectLevel.MODE_MARKET then 
		cell:getAttribute("free"):setText(g_i18n:formatVolume(storage:getFreeCapacity(self.currentFillTypeIndex), 0))	
	elseif self.currentMode == SelectLevel.MODE_MARKET_OBJECT then	
		local spec = storage.spec_objectStorage
		cell:getAttribute("free"):setText(spec.capacity - #spec.storedObjects, 0)		
	end
end

function SelectLevel:onListSelectionChanged(list, section, index)  
	self.currentSelectStorageSection = section
	self.currentSelectStorageIndex = index	 	
	self:onEnterPressedNumber()
end

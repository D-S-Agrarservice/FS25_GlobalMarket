--
-- FS22 - GlobalMarket - InGameMenuGlobalMarket
--
-- @Interface: 1.9.1.0 b23678
-- @Author: KR-Softwares
-- @Date: 12.05.2023
-- @Version: 1.0.0.0
--
-- @Support: -
--
-- Changelog:
-- 	v1.0.0.0 (29.01.2022):
--      Release FS22
--
	--DebugUtil.printTableRecursively(self.storageSections, " -", 0, 2)

InGameMenuGlobalMarket = {}
InGameMenuGlobalMarket._mt = Class(InGameMenuGlobalMarket, TabbedMenuFrameElement)

InGameMenuGlobalMarket.CONTROLS = {
	TEXT_HEADER = "textHeader",
	TEXT_HEADER_DESC = "textHeaderDesc",
	TABLE_STORAGE = "gmTableStorage",
	TABLE_STORAGE_TEMPLATE = "gmTableStorageRowTemplate",
	TABLE_STORAGE_SLIDER = "tableSliderStorage",
	TABLE_STORAGE_OBJECT = "gmTableStorageObject",
	TABLE_STORAGE_OBJECT_TEMPLATE = "gmTableStorageObjectRowTemplate",
	TABLE_STORAGE_OBJECT_SLIDER = "tableSliderStorageObject",
	TABLE_MARKET = "gmTableMarket",
	TABLE_MARKET_OBJECT = "gmTableMarketObject",
	TABLE_MARKET_TEMPLATE = "gmTableMarketRowTemplate",
	TABLE_MARKET_TEMPLATE_OBJECT = "gmTableMarketObjectRowTemplate",
	TABLE_MARKET_SLIDER = "tableSliderMarket",
	TABLE_MARKET_SLIDER_OBJECT = "tableSliderMarketObject",
	BTN_MARKET_TOGGLE = "btnToggleMarket",
	BTN_MARKET_TOGGLTEXT = "btnToggleMarketText",
	BTN_STORAGESILOOBJECT_TOGGL = "btnToggleStorageSiloObject",
	BTN_STORAGESILOOBJECT_TOGGLTEXT = "btnToggleStorageSiloObjectText",
	BTN_MARKETSILOOBJECT_TOGGLTEXT = "btnToggleMarketSiloObjectText",
	SECTION_STORAGE_SILO = "sectionStorageSilo",
	SECTION_STORAGE_OBJECT = "sectionStorageObject",
	SECTION_MARKET_SILO = "sectionMarketSilo",
	SECTION_MARKET_OBJECT = "sectionMarketObject",
}

function InGameMenuGlobalMarket.new(i18n, messageCenter)
	local self = InGameMenuGlobalMarket:superClass().new(nil, InGameMenuGlobalMarket._mt)

    self.name = "InGameMenuGlobalMarket"
    self.i18n = i18n
    self.messageCenter = messageCenter

	if not g_currentMission:getIsServer() then
        self.messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self.notifyPlayerFarmChanged, self)
    end
    
    self:registerControls(InGameMenuGlobalMarket.CONTROLS)

	local showButtons = not g_currentMission.missionDynamicInfo.isMultiplayer or g_currentMission.inGameMenu.playerFarmId ~= FarmManager.SPECTATOR_FARM_ID

    self.backButtonInfo = {
		inputAction = InputAction.MENU_BACK
	}

	self.btnSell = {
		text = self.i18n:getText("ui_btn_sell"),
		inputAction = InputAction.MENU_EXTRA_1,
        disabled = false,
		callback = function ()
			self:onClickSellFromGm()
		end
	}    

	self.btnBuy = {
		text = self.i18n:getText("ui_btn_buy"),
		inputAction = InputAction.MENU_ACCEPT,
        disabled = false,
		callback = function ()
			self:onClickBuyFromGm()
		end
	}   

    self:setMenuButtonInfo({
        self.backButtonInfo,
        self.btnSell,
        self.btnBuy,
    })

	self.storages = {}
	self.storageObject = {}
	self.storageSections = {}
	self.storageObjectSections = {}
	self.marketEntriesSilo = {}
	self.marketEntriesObject = {}
	self.marketEntriesSiloSections = {}
	self.marketEntriesObjectSections = {}
	self.showMarketAll = true
	self.showStorageSilo = true
	self.showMarketSilo = true
	   
    return self
end

function InGameMenuGlobalMarket:notifyPlayerFarmChanged(player)
    self:setMenuButtonInfoDirty()
end

function InGameMenuGlobalMarket:delete()
	InGameMenuGlobalMarket:superClass().delete(self)
end

function InGameMenuGlobalMarket:copyAttributes(src)
    InGameMenuGlobalMarket:superClass().copyAttributes(self, src)
    self.i18n = src.i18n
    self.messageCenter = src.messageCenter
end

function InGameMenuGlobalMarket:onGuiSetupFinished()
	InGameMenuGlobalMarket:superClass().onGuiSetupFinished(self)

	self.gmTableStorage.isStorage = true
	self.gmTableStorage:setDataSource(self)
	self.gmTableStorage:setDelegate(self)

	self.gmTableStorageObject.isStorageObject = true
	self.gmTableStorageObject:setDataSource(self)
	self.gmTableStorageObject:setDelegate(self)

	self.gmTableMarket.isMarket = true
	self.gmTableMarket:setDataSource(self)
	self.gmTableMarket:setDelegate(self) 

	self.gmTableMarketObject.isMarketObject = true
	self.gmTableMarketObject:setDataSource(self)
	self.gmTableMarketObject:setDelegate(self) 
end

function InGameMenuGlobalMarket:initialize()
end

function InGameMenuGlobalMarket:onFrameOpen()
	InGameMenuGlobalMarket:superClass().onFrameOpen(self)   
    self:updateContent()
	
	if self.showMarketAll then
		self.btnToggleMarketText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleTrue"))
	else
		self.btnToggleMarketText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleFalse"))
	end
	
	if self.showStorageSilo then
		self.btnToggleStorageSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageSilo"))
	else
		self.btnToggleStorageSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageObject"))
	end
	
	if self.showMarketSilo then
		self.btnToggleMarketSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageSilo"))
	else
		self.btnToggleMarketSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageObject"))
	end

	self.sectionStorageSilo:setVisible(self.showStorageSilo)
	self.sectionStorageObject:setVisible(not self.showStorageSilo)
	
	self.sectionMarketSilo:setVisible(self.showMarketSilo)
	self.sectionMarketObject:setVisible(not self.showMarketSilo)
	
    g_currentMission.globalMarketUi = self
end

function InGameMenuGlobalMarket:onFrameClose()
	InGameMenuGlobalMarket:superClass().onFrameClose(self)   
    g_currentMission.globalMarketUi = nil
end

function InGameMenuGlobalMarket:updateContent()  
	local marketIsOnline = g_currentMission.globalMarket:getIsMarketOnline()
	if marketIsOnline then
		self.textHeader:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOnline"))
		self.textHeaderDesc:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOnlineDesc"))
	else		
		self.textHeader:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOffline"))
		self.textHeaderDesc:setText(self.i18n:getText("ui_ingameMenuGlobalMarketOfflineDesc"))
	end

	self.storages = {}
	for storage, _ in pairs(g_currentMission.storageSystem.storages) do
		if storage.ownerFarmId == g_currentMission.inGameMenu.playerFarmId then
			for fillType, fillLevel in pairs(storage.fillLevels) do
				if fillLevel > 0 then
					table.insert(self.storages, storage)
					break
				end
			end
		end
	end

	self.storageObject = {}
	for _,storage in pairs(g_currentMission.placeableSystem.placeables) do
		if storage.spec_objectStorage ~= nil then
			if storage.ownerFarmId == g_currentMission.inGameMenu.playerFarmId then
				if storage.spec_objectStorage.numStoredObjects > 0 then
					table.insert(self.storageObject, storage)
				end
			end
		end
	end
	
	self.marketEntriesSilo = {}
	self.marketEntriesObject = {}

	if marketIsOnline then
		for _,e in pairs(g_currentMission.globalMarket.fillTypes) do
			if self.showMarketAll or (g_currentMission.globalMarket.siloLevels[e.fillType] ~= nil and g_currentMission.globalMarket.siloLevels[e.fillType] > 0) then
				table.insert(self.marketEntriesSilo, e)
			end
		end
		
		for _,e in pairs(g_currentMission.globalMarket.objectLevels) do
			table.insert(self.marketEntriesObject, e)
		end
	else
		for _,e in pairs(g_currentMission.globalMarket.offlineMarketFillTypes) do
			if (self.showMarketAll or e.fillLevel > 0) and g_fillTypeManager:getFillTypeByName(e.fillType) ~= nil then
				table.insert(self.marketEntriesSilo, e)
			end
		end

		--todo offline objects
	end
	
	self:sortList()
	self.gmTableStorage:reloadData()
	self.gmTableStorageObject:reloadData()
	self.gmTableMarket:reloadData()
	self.gmTableMarketObject:reloadData()
    self:setMenuButtonInfoDirty()
end

function InGameMenuGlobalMarket:getMenuButtonInfo() 
	local buttons = {}
	local showButtons = not g_currentMission.missionDynamicInfo.isMultiplayer or g_currentMission.inGameMenu.playerFarmId ~= FarmManager.SPECTATOR_FARM_ID

	self.btnSell.disabled = not (showButtons and ((self.showStorageSilo and table.getn(self.storages) > 0) or (not self.showStorageSilo and table.getn(self.storageObject) > 0)))
	self.btnBuy.disabled = not (showButtons and ((self.showMarketSilo and table.getn(self.marketEntriesSilo) > 0) or (not self.showMarketSilo and table.getn(self.marketEntriesObject) > 0)))
	
	if self.showMarketSilo and self.marketEntriesSiloSections[self.currentSelectMarketSection] ~= nil and  self.marketEntriesSiloSections[self.currentSelectMarketSection].entries[self.currentSelectMarketIndex] ~= nil then
		local e = self.marketEntriesSiloSections[self.currentSelectMarketSection].entries[self.currentSelectMarketIndex]
		self.btnBuy.disabled = self.btnBuy.disabled or self.showMarketSilo and g_currentMission.globalMarket:getMarketSiloLevelByFillType(e.fillType) == 0
	end
		
	table.insert(buttons, self.backButtonInfo)
	table.insert(buttons, self.btnSell)
	table.insert(buttons, self.btnBuy)

	return buttons
end

function InGameMenuGlobalMarket:sortList()
	self.storageSections = {}
	self.storageObjectSections = {}
	self.marketEntriesSiloSections = {
		{
			title = "",
			entries = {}
		}
	}
	self.marketEntriesObjectSections = {}

	--Storage silo
	for _,storage in pairs(self.storages) do
		local levels = {}
		for fillType, fillLevel in pairs(storage.fillLevels) do
			if fillLevel > 0 then
				table.insert(levels, { fillType = g_fillTypeManager:getFillTypeNameByIndex(fillType), fillLevel = fillLevel, storageId = storage.id, isGmMarketPlaceable = self:getIsGmObjectPlaceable(storage) })
			end
		end

		table.insert(self.storageSections, { title = self:getStorageName(storage), levels = levels })
	end

	--Storage object
	for _,storage in pairs(self.storageObject) do
		local levels = {}
		local objectInfos = storage:getObjectStorageObjectInfos()

		for _, objectInfo in pairs(objectInfos) do
			if objectInfo.objects[1] ~= nil then
				local o = objectInfo.objects[1]		
						
				local tmpO = o
				if o.baleAttributes ~= nil then o = o.baleAttributes else o = o.palletAttributes end
				if o ~= nil then
					local xmlFilename = o.configFileName or o.xmlFilename
					if KKSoftwaresUtils.stringStarts(xmlFilename, "data/objects") then
						table.insert(levels, { 
							fillType = g_fillTypeManager:getFillTypeNameByIndex(o.fillType), 
							fillLevel = o.fillLevel, 
							count = objectInfo.numObjects, 
							isBale = objectInfo.objects[1].baleAttributes ~= nil, 
							storageId = storage.id,
							xmlFilename = o.configFileName or o.xmlFilename,
							attributes = self:getAttributeString(tmpO),
							isGmMarketPlaceable = storage.spec_objectStorage.isGmMarket
						})
					end
				else
					--DebugUtil.printTableRecursively(storage:getObjectStorageObjectInfos(), " -", 0, 4)
					--print("Error: No attributes found in storage!")
				end
			end
		end
		
		table.insert(self.storageObjectSections, { title = self:getStorageName(storage), levels = levels })
	end

	--Market silo
	for _,e in pairs(self.marketEntriesSilo) do
		table.insert(self.marketEntriesSiloSections[1].entries, e)
	end 

	--Market object
	local sortByFillType = {}

	for _,e in pairs(self.marketEntriesObject) do
		if sortByFillType[e.fillType] == nil then
			sortByFillType[e.fillType] = {}
		end
		table.insert(sortByFillType[e.fillType], e)
	end

	for fillTypeName, entries in pairs(sortByFillType) do
		table.insert(self.marketEntriesObjectSections, { title = g_fillTypeManager:getFillTypeTitleByIndex(g_fillTypeManager:getFillTypeByName(fillTypeName).index), entries = entries })
	end
		 
end

function InGameMenuGlobalMarket:getAttributeString(data)
	local attributeText = ""
	if data.palletAttributes ~= nil then
		attributeText = attributeText .. "isBigBag" .. "=" .. tostring(data.palletAttributes.isBigBag) .. ";"
		local fillUnit = 1
		if data.palletAttributes.configurations ~= nil then fillUnit = data.palletAttributes.configurations.fillUnit end
		attributeText = attributeText .. "configurationsFillUnit" .. "=" .. tostring(fillUnit) .. ";"
		attributeText = attributeText .. "fillLevel" .. "=" .. tostring(data.palletAttributes.fillLevel) .. ";"
		attributeText = attributeText .. "configFileName" .. "=" .. tostring(data.palletAttributes.configFileName) .. ";"
		attributeText = attributeText .. "fillTypeName" .. "=" .. tostring(g_fillTypeManager:getFillTypeNameByIndex(data.palletAttributes.fillType)) .. ";"

	elseif data.baleAttributes ~= nil then
		attributeText = attributeText .. "fillLevel" .. "=" .. tostring(data.baleAttributes.fillLevel) .. ";"

		if data.baleAttributes.isFermenting == nil then
			attributeText = attributeText .. "isFermenting" .. "=" .. tostring(false) .. ";"
		else
			attributeText = attributeText .. "isFermenting" .. "=" .. tostring(data.baleAttributes.isFermenting) .. ";"
		end
		
		if data.baleAttributes.baleValueScale == nil then
			attributeText = attributeText .. "baleValueScale" .. "=" .. tostring(1) .. ";"
		else
			attributeText = attributeText .. "baleValueScale" .. "=" .. tostring(data.baleAttributes.baleValueScale) .. ";"
		end

		attributeText = attributeText .. "xmlFilename" .. "=" .. tostring(data.baleAttributes.xmlFilename) .. ";"
		--attributeText = attributeText .. "fermentationTime" .. "=" .. tostring(data.baleAttributes.fermentationTime) .. ";"
		if data.baleAttributes.wrappingColor ~= nil then
			attributeText = attributeText .. "wrappingColor[1]" .. "=" .. tostring(data.baleAttributes.wrappingColor[1]) .. ";"
			attributeText = attributeText .. "wrappingColor[2]" .. "=" .. tostring(data.baleAttributes.wrappingColor[2]) .. ";"
			attributeText = attributeText .. "wrappingColor[3]" .. "=" .. tostring(data.baleAttributes.wrappingColor[3]) .. ";"
			attributeText = attributeText .. "wrappingColor[4]" .. "=" .. tostring(data.baleAttributes.wrappingColor[4]) .. ";"
		else
			attributeText = attributeText .. "wrappingColor[1]" .. "=" .. tostring(1) .. ";"
			attributeText = attributeText .. "wrappingColor[2]" .. "=" .. tostring(1) .. ";"
			attributeText = attributeText .. "wrappingColor[3]" .. "=" .. tostring(1) .. ";"
			attributeText = attributeText .. "wrappingColor[4]" .. "=" .. tostring(1) .. ";"
		end
		attributeText = attributeText .. "fillTypeName" .. "=" .. tostring(g_fillTypeManager:getFillTypeNameByIndex(data.baleAttributes.fillType)) .. ";"
		attributeText = attributeText .. "wrappingState" .. "=" .. tostring(data.baleAttributes.wrappingState)
	end

	return attributeText
end

function InGameMenuGlobalMarket:getStorageName(storage)
	if storage.spec_objectStorage == nil then
		for _,s in pairs(storage.unloadingStations) do		
			return g_storeManager:getItemByXMLFilename(s.owningPlaceable.configFileName).name
		end
	else
		return g_storeManager:getItemByXMLFilename(storage.xmlFile.filename).name
		
	end
	return "no name"
end

function InGameMenuGlobalMarket:getIsGmObjectPlaceable(storage) 
	if storage.spec_objectStorage ~= nil then
		return storage.spec_objectStorage.isGmMarket
	elseif storage.isGmMarket ~= nil then
		return storage.isGmMarket
	end
	return false
end
	
function InGameMenuGlobalMarket:getNumberOfSections(list)
	if list.isStorage then
		return #self.storageSections
	elseif list.isStorageObject then
		return #self.storageObjectSections
	elseif list.isMarket then
		return #self.marketEntriesSiloSections
	elseif list.isMarketObject then
		return #self.marketEntriesObjectSections
	end    
end

function InGameMenuGlobalMarket:getNumberOfItemsInSection(list, section)
	if list.isStorage then
		return #self.storageSections[section].levels 
	elseif list.isStorageObject then
		return #self.storageObjectSections[section].levels 
	elseif list.isMarket then
		return #self.marketEntriesSiloSections[section].entries 
	elseif list.isMarketObject then
		return #self.marketEntriesObjectSections[section].entries 
	end  
end

function InGameMenuGlobalMarket:getTitleForSectionHeader(list, section)
	if list.isStorage then
		return self.storageSections[section].title 
	elseif list.isStorageObject then
		return self.storageObjectSections[section].title 
	elseif list.isMarket then
		return self.marketEntriesSiloSections[section].title 
	elseif list.isMarketObject then
		return self.marketEntriesObjectSections[section].title 
	end 
end

function InGameMenuGlobalMarket:populateCellForItemInSection(list, section, index, cell)
	if list.isStorage then
		local data = self.storageSections[section].levels[index]	
		cell:getAttribute("filltype"):setText(g_fillTypeManager:getFillTypeTitleByIndex(g_fillTypeManager:getFillTypeByName(data.fillType).index))
		cell:getAttribute("level"):setText(g_i18n:formatVolume(data.fillLevel, 0))		
	elseif list.isStorageObject then
		local data = self.storageObjectSections[section].levels[index]		
		cell:getAttribute("filltype"):setText(g_fillTypeManager:getFillTypeTitleByIndex(g_fillTypeManager:getFillTypeByName(data.fillType).index) .. " (" .. g_i18n:formatVolume(data.fillLevel, 0) .. ")")
		
		local addText = ""
		local unit = g_i18n:getText("category_pallets")
		if g_currentMission.globalMarket:objectIsBale(data.attributes) then 
			local isRoundbale, bWidth, bHeight, bLength, bDiameter, maxStackHeight = g_baleManager:getBaleInfoByXMLFilename(data.xmlFilename)
			if isRoundbale then 
				unit = g_i18n:getText("fillType_roundBale") 
				addText = " (" .. bDiameter .. "m)"
			else 
				unit = g_i18n:getText("fillType_squareBale") 
				addText = " (" .. bWidth .. "m)"
			end
		end
		cell:getAttribute("count"):setText(data.count .. " " .. unit .. addText) 
	elseif list.isMarket then
		local data = self.marketEntriesSiloSections[section].entries[index]	
		local fillType = g_fillTypeManager:getFillTypeByName(data.fillType)
		local fillTypeName = "unknown filltype: " .. data.fillType
		if fillType ~= nil then
			fillTypeName = g_fillTypeManager:getFillTypeTitleByIndex(g_fillTypeManager:getFillTypeByName(data.fillType).index)
		end
		
		cell:getAttribute("filltype"):setText(fillTypeName) 
		cell:getAttribute("level"):setText(g_i18n:formatVolume(g_currentMission.globalMarket:getMarketSiloLevelByFillType(data.fillType), 0))		
		cell:getAttribute("price"):setText(g_i18n:formatMoney(g_currentMission.globalMarket:getPriceByFillType(data.fillType) * 1000 * EconomyManager.getPriceMultiplier(), 0, true) .. " / 1000 " .. g_i18n:getVolumeUnit())		 
	elseif list.isMarketObject then
		local data = self.marketEntriesObjectSections[section].entries[index]	

		local addText = ""
		local unit = g_i18n:getText("category_pallets")
		if g_currentMission.globalMarket:objectIsBale(data.attributes) then
			local attributes = g_currentMission.globalMarket:parseAttributes(data.attributes)
			local isRoundbale, bWidth, bHeight, bLength, bDiameter, maxStackHeight = g_baleManager:getBaleInfoByXMLFilename(attributes.xmlFilename)
			if isRoundbale then 
				unit = g_i18n:getText("fillType_roundBale") 
				addText = " (" .. bDiameter .. "m)"
			else 
				unit = g_i18n:getText("fillType_squareBale") 
				addText = " (" .. bWidth .. "m)"
			end
		end

		cell:getAttribute("level"):setText(g_i18n:formatVolume(data.fillLevel, 0)) 
		cell:getAttribute("count"):setText(data.count .. " " .. unit .. addText) 
		cell:getAttribute("price"):setText(g_i18n:formatMoney(g_currentMission.globalMarket:getPriceByFillType(data.fillType) * data.fillLevel * EconomyManager.getPriceMultiplier(), 0, true) .. " / " .. unit) 
	end 
end

function InGameMenuGlobalMarket:onListSelectionChanged(list, section, index)    
	if list.isStorage then
		self.currentSelectStorageSection = section
		self.currentSelectStorageIndex = index	         
	elseif list.isStorageObject then
		self.currentSelectStorageObjectSection = section
		self.currentSelectStorageObjectIndex = index	
	elseif list.isMarket then
		self.currentSelectMarketSection = section
		self.currentSelectMarketIndex = index	 
	elseif list.isMarketObject then
		self.currentSelectMarketObjectSection = section
		self.currentSelectMarketObjectIndex = index	     
	end 
    
	self:setMenuButtonInfoDirty()
end

function InGameMenuGlobalMarket:onClickSellFromGm()
	if self.showStorageSilo and self.currentSelectStorageSection ~= nil and self.currentSelectStorageIndex ~= nil then
		local dialog = g_gui:showDialog("SelectLevel")
		if dialog ~= nil then			
			dialog.target:setData(SelectLevel.MODE_STORAGE, self.storageSections[self.currentSelectStorageSection].levels[self.currentSelectStorageIndex])
		end  
	end  
	if not self.showStorageSilo and self.currentSelectStorageObjectSection ~= nil and self.currentSelectStorageObjectIndex ~= nil then
		local dialog = g_gui:showDialog("SelectLevel")
		if dialog ~= nil then			
			dialog.target:setData(SelectLevel.MODE_STORAGE_OBJECT, self.storageObjectSections[self.currentSelectStorageObjectSection].levels[self.currentSelectStorageObjectIndex])
		end  
	end  
end

function InGameMenuGlobalMarket:onClickBuyFromGm()
	if self.showMarketSilo and self.currentSelectMarketSection ~= nil and self.currentSelectMarketIndex ~= nil then
		local dialog = g_gui:showDialog("SelectLevel")
		if dialog ~= nil then
			dialog.target:setData(SelectLevel.MODE_MARKET, self.marketEntriesSiloSections[self.currentSelectMarketSection].entries[self.currentSelectMarketIndex])
		end  
	end  
	if not self.showMarketSilo and self.currentSelectMarketObjectSection ~= nil and self.currentSelectMarketObjectIndex ~= nil then
		local dialog = g_gui:showDialog("SelectLevel")
		if dialog ~= nil then
			dialog.target:setData(SelectLevel.MODE_MARKET_OBJECT, self.marketEntriesObjectSections[self.currentSelectMarketObjectSection].entries[self.currentSelectMarketObjectIndex])
		end  
	end 
end

function InGameMenuGlobalMarket:onClickToggleMarket()
    self.showMarketAll = not self.showMarketAll   

	if self.showMarketAll then
		self.btnToggleMarketText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleTrue"))
	else
		self.btnToggleMarketText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleFalse"))
	end
    self:updateContent()
end

function InGameMenuGlobalMarket:onClickToggleStorageSiloObject() 
    self.showStorageSilo = not self.showStorageSilo   

	self.sectionStorageSilo:setVisible(self.showStorageSilo)
	self.sectionStorageObject:setVisible(not self.showStorageSilo)

	if self.showStorageSilo then
		self.btnToggleStorageSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageSilo"))
	else
		self.btnToggleStorageSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageObject"))
	end
end

function InGameMenuGlobalMarket:onClickToggleMarketSiloObject() 
    self.showMarketSilo = not self.showMarketSilo   

	self.sectionMarketSilo:setVisible(self.showMarketSilo)
	self.sectionMarketObject:setVisible(not self.showMarketSilo)

	if self.showMarketSilo then
		self.btnToggleMarketSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageSilo"))
	else
		self.btnToggleMarketSiloObjectText:setText(self.i18n:getText("ui_ingameMenuGlobalMarketToggleStorageObject"))
	end
end


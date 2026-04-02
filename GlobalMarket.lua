--
-- FS22 - GlobalMarket
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
--      - Release
--

GlobalMarket = {}
GlobalMarket.dir = g_currentModDirectory
GlobalMarket.modName = g_currentModName
GlobalMarket.needExeVersion = 1000

source(GlobalMarket.dir .. "KKSoftwaresUtils.lua")
source(GlobalMarket.dir .. "events/SellBuySiloGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyMarketGlobalMarketEvent.lua")
source(GlobalMarket.dir .. "events/SellBuyOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/SynchOfflineMarketEvent.lua")
source(GlobalMarket.dir .. "events/InitOfflineMarketEvent.lua")

source(GlobalMarket.dir .. "gui/InGameMenuGlobalMarket.lua")
source(GlobalMarket.dir .. "gui/SelectLevel.lua")

GlobalMarket.PRICE_MIN = 0.8
GlobalMarket.PRICE_MAX = 1.2
GlobalMarket.PRICE_LEVEL_MAX = 10000000
GlobalMarket.DELIVER_COST = 200
GlobalMarket.DELIVER_COST_PERLITER = 0.01

function GlobalMarket:loadMap()
	KKSoftwaresUtils.loadTextFromMod(GlobalMarket.modName, GlobalMarket.dir)
	KKSoftwaresUtils.mergeModTranslations(g_i18n)

	local ui = g_currentMission.inGameMenu

    g_gui:loadProfiles(GlobalMarket.dir .. "gui/guiProfiles.xml")

	local guiGlobalMarket = InGameMenuGlobalMarket.new(g_i18n, g_messageCenter) 
	g_gui:loadGui(GlobalMarket.dir .. "gui/InGameMenuGlobalMarket.xml", "ingameMenuGlobalMarket", guiGlobalMarket, true)
	
	local selectLevel = SelectLevel.new(g_i18n) 
	g_gui:loadGui(GlobalMarket.dir .. "gui/SelectLevel.xml", "SelectLevel", selectLevel)

	GlobalMarket.fixInGameMenu(guiGlobalMarket,"ingameMenuGlobalMarket", {0,0,1024,1024}, 2, GlobalMarket:makeIsGlobalMarketEnabledPredicate())

	g_currentMission.globalMarket = self

	self.fillTypes = {}
	self.siloLevels = {}
	self.objectLevels = {}
	self.lastConnection = false
	self.closeSelectLevelUi = 0

	self.isOnlineFile = getUserProfileAppPath() .. "globalMarketOnline.xml"
	self.readFolder = getUserProfileAppPath() .. "modSettings/FS22_GlobalMarket/read/"
	self.writeFolder = getUserProfileAppPath() .. "modSettings/FS22_GlobalMarket/write/"
		
    self.timer2sec = 2000

	FSBaseMission.saveSavegame = Utils.appendedFunction(FSBaseMission.saveSavegame, GlobalMarket.saveToXmlFile)
	
	self.offlineMarketFillTypes = {}
	self:loadOfflineMarket()
	self:loadFromXMLFile()
	
	g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)

	guiGlobalMarket:initialize()	
end

function GlobalMarket:makeIsGlobalMarketEnabledPredicate()
	return function ()
		return true
	end
end

function GlobalMarket:getIsMarketOnline() 
    if fileExists(self.isOnlineFile) then
        local xmlFile = loadXMLFile("globalMarketOnline", self.isOnlineFile)
        local version = getXMLInt(xmlFile, "globalMarketOnline.version")
        delete(xmlFile)
        return version >= GlobalMarket.needExeVersion
	end
	return false
end

function GlobalMarket:update(dt)
    self.timer2sec = self.timer2sec + dt    

	if self:getIsMarketOnline() then
		if self.timer2sec >= 1000  then
			self.timer2sec = self.timer2sec - 1000
			
			local files = Files.new(self.readFolder)
			local updateUi = false
			for _,file in pairs(files.files) do      
				local fullPath = self.readFolder .. "/" .. file.filename    
				
				local xmlFile = XMLFile.load("fs22GlobalMarketDataSynch", fullPath)					
				if xmlFile ~= nil then -- avoid sharing violation nil error
					local action = xmlFile:getString("fs22GlobalMarketDataSynch#action", "")
				
					if action == "marketData" then
						self.fillTypes = {}
						xmlFile:iterate("fs22GlobalMarketDataSynch.fillTypes.fillType", function (_, baseKey)
							local fillType = xmlFile:getString(baseKey .. "#fillType")
							local fillLevel = xmlFile:getInt(baseKey .. "#fillLevel")
							local price = xmlFile:getFloat(baseKey .. "#price")
							local isSilo = xmlFile:getBool(baseKey .. "#isSilo")
							local isObject = xmlFile:getBool(baseKey .. "#isObject")
					
							if fillType ~= nil and fillLevel ~= nil and price ~= nil and isSilo ~= nil and isObject ~= nil then
								table.insert(self.fillTypes, {
									fillType = fillType,
									fillLevel = fillLevel,
									price = price,
									isSilo = isSilo,
									isObject = isObject,
								})
							end
						end)
						
						self.siloLevels = {}
						xmlFile:iterate("fs22GlobalMarketDataSynch.siloLevels.level", function (_, baseKey)
							local fillType = xmlFile:getString(baseKey .. "#fillType")
							local fillLevel = xmlFile:getInt(baseKey .. "#fillLevel")
					
							if fillType ~= nil and fillLevel ~= nil then
								self.siloLevels[fillType] = fillLevel
							end
						end)
						
						self.objectLevels = {}
						xmlFile:iterate("fs22GlobalMarketDataSynch.objectLevels.level", function (_, baseKey)
							local fillType = xmlFile:getString(baseKey .. "#fillType")
							local fillLevel = xmlFile:getInt(baseKey .. "#fillLevel")
							local count = xmlFile:getInt(baseKey .. "#count")
							local attributes = xmlFile:getString(baseKey .. "#attributes")
							local objectId = xmlFile:getInt(baseKey .. "#objectId")
					
							if fillType ~= nil and fillLevel ~= nil and count ~= nil and attributes ~= nil then
								table.insert(self.objectLevels, {
									fillType = fillType,
									fillLevel = fillLevel,
									count = count,
									attributes = attributes,
									objectId = objectId,
								})
							end
						end)
							
						if self.closeSelectLevelUi == 2 then 
							g_currentMission.globalMarketSelectLevelUi:close()
							self.closeSelectLevelUi = 0
						elseif self.closeSelectLevelUi == 1 then 
							self.closeSelectLevelUi = 3
						end	
					elseif action == "buy" or action == "sell" then 
						local fillType = xmlFile:getString("fs22GlobalMarketDataSynch#fillType")
						local fillLevel = xmlFile:getInt("fs22GlobalMarketDataSynch#fillLevel")
						local price = xmlFile:getFloat("fs22GlobalMarketDataSynch#price")
						local storageId = xmlFile:getInt("fs22GlobalMarketDataSynch#storageId")

						for storage, _ in pairs(g_currentMission.storageSystem.storages) do
							if storage.id == storageId then
								if not g_currentMission.missionDynamicInfo.isMultiplayer then
									if action == "buy" then
										self:buySilo(price, g_currentMission.inGameMenu.playerFarmId, fillType, fillLevel, storage, g_currentMission.playerUserId)
									else
										self:sellSilo(price, g_currentMission.inGameMenu.playerFarmId, fillType, fillLevel, storage, g_currentMission.playerUserId)
									end
								else 
									if action == "buy" then
										g_client:getServerConnection():sendEvent(SellBuySiloGlobalMarketEvent.new(SellBuySiloGlobalMarketEvent.ACTION_BUY, 
											price, g_currentMission.inGameMenu.playerFarmId, fillType, fillLevel, storage, g_currentMission.playerUserId))
									else
										g_client:getServerConnection():sendEvent(SellBuySiloGlobalMarketEvent.new(SellBuySiloGlobalMarketEvent.ACTION_SELL, 
											price, g_currentMission.inGameMenu.playerFarmId, fillType, fillLevel, storage, g_currentMission.playerUserId))
									end									 
								end
							end
						end							
					elseif action == "buyObject" then
						local fillType = xmlFile:getString("fs22GlobalMarketDataSynch#fillType")
						local fillLevel = xmlFile:getInt("fs22GlobalMarketDataSynch#fillLevel")
						local price = xmlFile:getFloat("fs22GlobalMarketDataSynch#price")
						local storageId = xmlFile:getFloat("fs22GlobalMarketDataSynch#storageId")
						local count = xmlFile:getInt("fs22GlobalMarketDataSynch#count")
						local objectId = xmlFile:getInt("fs22GlobalMarketDataSynch#objectId")
						local attributes = xmlFile:getString("fs22GlobalMarketDataSynch#attributes")
						
						for _,storage in pairs(g_currentMission.placeableSystem.placeables) do
							if storage.spec_objectStorage ~= nil then
								if storage.id == storageId and storage.ownerFarmId == g_currentMission.inGameMenu.playerFarmId then
									if not g_currentMission.missionDynamicInfo.isMultiplayer then
										self:buyObject(price, g_currentMission.inGameMenu.playerFarmId, count, attributes, storage, g_currentMission.playerUserId)
									else
										g_client:getServerConnection():sendEvent(SellBuyMarketGlobalMarketEvent.new(SellBuyMarketGlobalMarketEvent.ACTION_BUY, 
											price, g_currentMission.inGameMenu.playerFarmId, count, attributes, storage, g_currentMission.playerUserId))
									end
									break
								end
							end
						end	
					elseif action == "sellObject" then
						local fillType = xmlFile:getString("fs22GlobalMarketDataSynch#fillType")
						local fillLevel = xmlFile:getInt("fs22GlobalMarketDataSynch#fillLevel")
						local price = xmlFile:getFloat("fs22GlobalMarketDataSynch#price")
						local storageId = xmlFile:getFloat("fs22GlobalMarketDataSynch#storageId")
						local count = xmlFile:getInt("fs22GlobalMarketDataSynch#count")
						local attributes = xmlFile:getString("fs22GlobalMarketDataSynch#attributes")
									
						for _,storage in pairs(g_currentMission.placeableSystem.placeables) do
							if storage.spec_objectStorage ~= nil then
								if storage.id == storageId and storage.ownerFarmId == g_currentMission.inGameMenu.playerFarmId then
									if not g_currentMission.missionDynamicInfo.isMultiplayer then
										self:sellObject(price, g_currentMission.inGameMenu.playerFarmId, count, attributes, storage, g_currentMission.playerUserId)
									else
										g_client:getServerConnection():sendEvent(SellBuyMarketGlobalMarketEvent.new(SellBuyMarketGlobalMarketEvent.ACTION_SELL, 
											price, g_currentMission.inGameMenu.playerFarmId, count, attributes, storage, g_currentMission.playerUserId))
									end
									break
								end
							end
						end		
					elseif action == "defHandshake"	then
						if self.closeSelectLevelUi == 1 then 
							self.closeSelectLevelUi = 2 
						elseif self.closeSelectLevelUi == 3 then 
							g_currentMission.globalMarketSelectLevelUi:close()
							self.closeSelectLevelUi = 0
						end		
					end
					getfenv(0)["deleteFile"](fullPath)
					updateUi = true
				end
			end

			if updateUi and g_currentMission.globalMarketUi ~= nil then
            	g_currentMission.globalMarketUi:updateContent()
			end

			self.lastConnection = true
		end	
	elseif self.lastConnection then
		self.entries = {}
		self.lastConnection = false

		if g_currentMission.globalMarketUi ~= nil then
			g_currentMission.globalMarketUi:updateContent()
		end
	end
end

function GlobalMarket:sellSilo(price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
	self:sellBuySilo(MoneyType.SOLD_PRODUCTS, price, playerFarmId, fillTypeName, fillLevel * -1, storage, playerUserId)
end

function GlobalMarket:buySilo(price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
	self:sellBuySilo(MoneyType.BOUGHT_MATERIALS, price * -1, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
end

function GlobalMarket:sellBuySilo(moneyType, price, playerFarmId, fillTypeName, fillLevel, storage, playerUserId)
	if g_server ~= nil then
		g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, moneyType, true, true)	
		
		if not storage.isGmMarket then
			g_currentMission:addMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * fillLevel) * EconomyManager.getCostMultiplier() * -1, playerFarmId, MoneyType.OTHER, true, true)	
		end
		
		local fillTypeIndex = g_fillTypeManager:getFillTypeByName(fillTypeName).index
					
		storage:setFillLevel(storage:getFillLevel(fillTypeIndex) + fillLevel, fillTypeIndex, nil)
		storage:raiseDirtyFlags(storage.storageDirtyFlag)
	end
				
	if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
		if self.closeSelectLevelUi == 1 then 
			self.closeSelectLevelUi = 2 
		elseif self.closeSelectLevelUi == 3 then 
			g_currentMission.globalMarketSelectLevelUi:close()
			self.closeSelectLevelUi = 0
		end	
	end
end

function GlobalMarket:sellObject(price, playerFarmId, count, attributes, storage, playerUserId)
	if g_server ~= nil then

		g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, MoneyType.SOLD_PRODUCTS, true, true)		


		local attributesParsed = self:parseAttributes(attributes)
		local spec = storage.spec_objectStorage
		
		if not spec.isGmMarket then
			g_currentMission:addMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * attributesParsed.fillLevel * count) * EconomyManager.getCostMultiplier() * -1, playerFarmId, MoneyType.OTHER, true, true)	
		end

		for i=1, count do
			for i = 1, #spec.storedObjects do
				local object = spec.storedObjects[i]					

				if object ~= nil then
					if object.palletAttributes ~= nil then 
						if object.palletAttributes.configFileName == attributesParsed.configFileName
							and object.palletAttributes.fillLevel == attributesParsed.fillLevel
							and object.palletAttributes.isBigBag == attributesParsed.isBigBag
							and object.palletAttributes.fillType == attributesParsed.fillType then

							g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedPallets", -1)
							table.remove(spec.storedObjects, i)
							break
						end										
					elseif object.baleAttributes ~= nil then 
						if object.baleAttributes.xmlFilename == attributesParsed.xmlFilename
							and object.baleAttributes.fillLevel == attributesParsed.fillLevel
							--and object.baleAttributes.isFermenting == attributesParsed.isFermenting
							and object.baleAttributes.baleValueScale == attributesParsed.baleValueScale
							and object.baleAttributes.wrappingState == attributesParsed.wrappingState
							--and object.baleAttributes.fermentationTime == attributesParsed.fermentationTime
							and object.baleAttributes.fillType == attributesParsed.fillType then

							g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedBales", -1)
							table.remove(spec.storedObjects, i)
							break
						end		
					end
				end
			end
		end
		
		spec.numStoredObjects = #spec.storedObjects
		storage:setObjectStorageObjectInfosDirty()		
		storage:updateObjectStorageObjectInfos()			
		storage:raiseDirtyFlags(spec.dirtyFlag)
	end	
				
	if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
		if self.closeSelectLevelUi == 1 then 
			self.closeSelectLevelUi = 2 
		elseif self.closeSelectLevelUi == 3 then 
			g_currentMission.globalMarketSelectLevelUi:close()
			self.closeSelectLevelUi = 0
		end	
	end
end

function GlobalMarket:buyObject(price, playerFarmId, count, attributes, storage, playerUserId)
	if g_server ~= nil then
		g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier() * -1, playerFarmId, MoneyType.BOUGHT_MATERIALS, true, true)	
		local attributesParsed = self:parseAttributes(attributes)
		local spec = storage.spec_objectStorage
		
		if not spec.isGmMarket then
			g_currentMission:addMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * attributesParsed.fillLevel * count) * EconomyManager.getCostMultiplier() * -1, playerFarmId, MoneyType.OTHER, true, true)	
		end

		for i=1, count do
			if self:objectIsBale(attributes) then
				local abstractObjectClass = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Bale"]
				local abstractBale = abstractObjectClass.new()
				abstractBale.baleAttributes = attributesParsed
				abstractBale.baleAttributes.farmId = playerFarmId
							
				g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedBales", 1)
				
				storage:addAbstactObjectToObjectStorage(abstractBale)
			else
				local abstractObjectClass = PlaceableObjectStorage.ABSTRACT_OBJECTS_BY_CLASS_NAME["Vehicle"]
				local abstractPallet = abstractObjectClass.new()
				abstractPallet.palletAttributes = attributesParsed
				abstractPallet.palletAttributes.ownerFarmId = playerFarmId
				
				g_farmManager:updateFarmStats(storage:getOwnerFarmId(), "storedPallets", 1)

				storage:addAbstactObjectToObjectStorage(abstractPallet)
			end
			
			storage:setObjectStorageObjectInfosDirty()		
			storage:updateObjectStorageObjectInfos()		
			storage:raiseDirtyFlags(storage.spec_objectStorage.dirtyFlag)
		end
	end	
				
	if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
		if self.closeSelectLevelUi == 1 then 
			self.closeSelectLevelUi = 2 
		elseif self.closeSelectLevelUi == 3 then 
			g_currentMission.globalMarketSelectLevelUi:close()
			self.closeSelectLevelUi = 0
		end	
	end
end

function GlobalMarket:sellBuyOfflineMarket(price, moneyType, playerFarmId, level, filltypeName, storage, playerUserId)
	if g_server ~= nil then	
		for _,ft in pairs(self.offlineMarketFillTypes) do
			if ft.fillType == filltypeName then		
				ft.fillLevel = ft.fillLevel + (level * -1)
				ft.price = GlobalMarket.calcOfflinePrice(ft.normalPrice, ft.fillLevel) 
			end
		end	

		g_currentMission:addMoney(price * EconomyManager.getPriceMultiplier(), playerFarmId, moneyType, true, true)			
		
		if not storage.isGmMarket then
			g_currentMission:addMoney((GlobalMarket.DELIVER_COST + GlobalMarket.DELIVER_COST_PERLITER * level) * EconomyManager.getCostMultiplier() * -1, playerFarmId, MoneyType.OTHER, true, true)	
		end

		local fillTypeIndex = g_fillTypeManager:getFillTypeByName(filltypeName).index								
		storage:setFillLevel(storage:getFillLevel(fillTypeIndex) + level, fillTypeIndex, nil)
		
		g_server:broadcastEvent(SynchOfflineMarketEvent.new())		
	end

	if g_client ~= nil and g_currentMission.playerUserId == playerUserId then
		if g_currentMission.globalMarketUi ~= nil then
			g_currentMission.globalMarketUi:updateContent()
		end

		if g_currentMission.globalMarketSelectLevelUi ~= nil then
			g_currentMission.globalMarketSelectLevelUi:close()
		end
	end
end

function GlobalMarket:parseAttributes(strData)
	local data = {}
	local resTable = {}
	local splitData = KKSoftwaresUtils.splitString(strData, ";")

	for _,e in pairs(splitData) do
		local eSplit = KKSoftwaresUtils.splitString(e, "=")
		data[eSplit[1]] = eSplit[2]
	end

	if data['isBigBag'] ~= nil then
		resTable.isBigBag = KKSoftwaresUtils.convertToBool(data['isBigBag'])
		resTable.configurations = {}
		resTable.configurations.fillUnit = tonumber(data['configurationsFillUnit'])
		resTable.fillLevel = tonumber(data['fillLevel'])
		resTable.configFileName = data['configFileName']
		resTable.fillType = g_fillTypeManager:getFillTypeByName(data['fillTypeName']).index
	else
		resTable.fillLevel = tonumber(data['fillLevel'])
		resTable.isFermenting = false -- KKSoftwaresUtils.convertToBool(data['isFermenting'])
		resTable.baleValueScale = tonumber(data['baleValueScale'])
		resTable.xmlFilename = data['xmlFilename']
		--resTable.fermentationTime = tonumber(data['fermentationTime'])
		resTable.wrappingColor = {}
		resTable.wrappingColor[1] = tonumber(data['wrappingColor[1]'])
		resTable.wrappingColor[2] = tonumber(data['wrappingColor[2]'])
		resTable.wrappingColor[3] = tonumber(data['wrappingColor[3]'])
		resTable.wrappingColor[4] = tonumber(data['wrappingColor[4]'])
		resTable.wrappingState = tonumber(data['wrappingState'])
		resTable.isMissionBale = false		
		resTable.fillType = g_fillTypeManager:getFillTypeByName(data['fillTypeName']).index
	end

	return resTable
end

function GlobalMarket:objectIsBale(strData)
	return string.find(strData, "baleValueScale") ~= nil
end

function GlobalMarket:delete()
	
end

function GlobalMarket:loadOfflineMarket()
	local path = GlobalMarket.dir .. "offlineMarket.xml"
	local xmlFile = XMLFile.load("fs22_offlineMarket", path)

	xmlFile:iterate("fs22_offlineMarket.fillTypes.fillType", function (_, baseKey)
		local name = xmlFile:getString(baseKey .. "#name")
		local price = xmlFile:getFloat(baseKey .. "#price")

		local level = math.random (0, 50) * 10000
		if name ~= nil and price ~= nil then
			table.insert(self.offlineMarketFillTypes, {
				fillType = name,
				fillLevel = level,
				normalPrice = price,
				price = GlobalMarket.calcOfflinePrice(price, level)
			})
		end
	end)
end

function GlobalMarket.calcOfflinePrice(price, currentLevel) 
	local fillTypeMinPrice = price * GlobalMarket.PRICE_MIN
	local fillTypeMaxPrice = price * GlobalMarket.PRICE_MAX
	local diffPrice = fillTypeMaxPrice - fillTypeMinPrice
	return fillTypeMaxPrice - (diffPrice / GlobalMarket.PRICE_LEVEL_MAX * math.min(currentLevel, GlobalMarket.PRICE_LEVEL_MAX))
end

function GlobalMarket:getPriceByFillType(fillType)
	if self:getIsMarketOnline() then
		for _,e in pairs(self.fillTypes) do
			if e.fillType == fillType then return e.price end
		end
	else
		for _,e in pairs(self.offlineMarketFillTypes) do
			if e.fillType == fillType then return e.price end
		end
	end
	return 0
end

function GlobalMarket:getMarketSiloLevelByFillType(fillType)
	if self:getIsMarketOnline() then
		if self.siloLevels[fillType] == nil then return 0 end
		return self.siloLevels[fillType]
	else
		for _,e in pairs(self.offlineMarketFillTypes) do
			if e.fillType == fillType then return e.fillLevel end
		end
	end
	return 0
end

function GlobalMarket:saveToXmlFile()
	if(not g_currentMission:getIsServer()) then return end

	local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory.."/"
	if savegameFolderPath == nil then
		savegameFolderPath = ('%ssavegame%d'):format(getUserProfileAppPath(), g_currentMission.missionInfo.savegameIndex.."/")
	end

	local path = savegameFolderPath.."globalMarket.xml"
	local xmlFile = XMLFile.create("globalMarket", path, "globalMarket")
	
	xmlFile:setTable("globalMarket.offlineMarket.fillTypes.fillType", g_currentMission.globalMarket.offlineMarketFillTypes, function (key, info, _)
		xmlFile:setString(key .. "#fillType", info.fillType)
		xmlFile:setInt(key .. "#level", info.fillLevel)
	end)
    
	xmlFile:save()
	xmlFile:delete()
end

function GlobalMarket:loadFromXMLFile()
	if(not g_currentMission:getIsServer()) then return end
	
	local savegameFolderPath = g_currentMission.missionInfo.savegameDirectory;
	if savegameFolderPath == nil then
		savegameFolderPath = ('%ssavegame%d'):format(getUserProfileAppPath(), g_currentMission.missionInfo.savegameIndex)
	end
	savegameFolderPath = savegameFolderPath.."/"
	local key = "globalMarket"

	local path = savegameFolderPath.."globalMarket.xml"
	if fileExists(path) then
		local xmlFile = XMLFile.load("globalMarket", path)
		
		xmlFile:iterate("globalMarket.offlineMarket.fillTypes.fillType", function (_, baseKey)
			local fillType = xmlFile:getString(baseKey .. "#fillType")
			local level = xmlFile:getInt(baseKey .. "#level")
	
			for _,ft in pairs(g_currentMission.globalMarket.offlineMarketFillTypes) do
				if ft.fillType == fillType then
					ft.fillLevel = level
					break
				end
			end
		end)

		xmlFile:delete()
	end
end

function GlobalMarket:onHourChanged(currentHour)
	if g_server ~= nil then
		for _,ft in pairs(self.offlineMarketFillTypes) do
			ft.fillLevel = math.max(ft.fillLevel + math.random (-4000, 5000), 0)
		end
		g_client:getServerConnection():sendEvent(SynchOfflineMarketEvent.new())		
	end
end

function GlobalMarket:onSellBuy(mode, filltypeName, level, storageId, count, attributes, objectId) 	
	if self:getIsMarketOnline() then
		local freeFile = ""
		local i = 0
		while true do
			local searchPath = string.format("%s/%s.xml", self.writeFolder, i)
			if not fileExists(searchPath) then
				freeFile = searchPath
				break
			end
			i = i + 1
		end
	
		local xmlFile = XMLFile.create("fs22GlobalMarketDataSynch", freeFile, "fs22GlobalMarketDataSynch", nil)
	
		local action = "sell"	
		if mode == SelectLevel.MODE_MARKET then action = "buy" end
		if mode == SelectLevel.MODE_MARKET_OBJECT then action = "buyObject" end
		if mode == SelectLevel.MODE_STORAGE_OBJECT then action = "sellObject" end
		xmlFile:setString("fs22GlobalMarketDataSynch#action", action)
		xmlFile:setString("fs22GlobalMarketDataSynch#fillType", filltypeName)
		xmlFile:setInt("fs22GlobalMarketDataSynch#fillLevel", level)
		xmlFile:setInt("fs22GlobalMarketDataSynch#storageId", storageId)

		if mode == SelectLevel.MODE_STORAGE_OBJECT then
			xmlFile:setInt("fs22GlobalMarketDataSynch#count", count)
			xmlFile:setString("fs22GlobalMarketDataSynch#attributes", attributes)
		elseif mode == SelectLevel.MODE_MARKET_OBJECT then
			xmlFile:setInt("fs22GlobalMarketDataSynch#count", count)
			xmlFile:setInt("fs22GlobalMarketDataSynch#objectId", objectId)
		end

		xmlFile:save()
		xmlFile:delete()
		self.closeSelectLevelUi = 1
	else
		for _,ft in pairs(self.offlineMarketFillTypes) do
			if ft.fillType == filltypeName then		
				
				local price = ft.price * level
				
				local moneyType = MoneyType.SOLD_PRODUCTS
				if mode == SelectLevel.MODE_MARKET then
					price = price * -1
					moneyType = MoneyType.BOUGHT_MATERIALS
				else 
					level = level * -1
				end
										
				for storage, _ in pairs(g_currentMission.storageSystem.storages) do
					if storage.id == storageId then						
						if not g_currentMission.missionDynamicInfo.isMultiplayer then
							self:sellBuyOfflineMarket(price, moneyType, g_currentMission.inGameMenu.playerFarmId, level, filltypeName, storage, g_currentMission.playerUserId)				
						else 
							g_client:getServerConnection():sendEvent(SellBuyOfflineMarketEvent.new(price, g_currentMission.inGameMenu.playerFarmId, level, 
								filltypeName, storage, g_currentMission.playerUserId))
						end
						break
					end
				end							
				break
			end
		end
	end
end

-- from Courseplay
function GlobalMarket.fixInGameMenu(frame,pageName,uvs,position,predicateFunc)
	local inGameMenu = g_gui.screenControllers[InGameMenu]

	-- remove all to avoid warnings
	for k, v in pairs({pageName}) do
		inGameMenu.controlIDs[v] = nil
	end

	inGameMenu:registerControls({pageName})

	
	inGameMenu[pageName] = frame
	inGameMenu.pagingElement:addElement(inGameMenu[pageName])

	inGameMenu:exposeControlsAsFields(pageName)

	for i = 1, #inGameMenu.pagingElement.elements do
		local child = inGameMenu.pagingElement.elements[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.elements, i)
			table.insert(inGameMenu.pagingElement.elements, position, child)
			break
		end
	end

	for i = 1, #inGameMenu.pagingElement.pages do
		local child = inGameMenu.pagingElement.pages[i]
		if child.element == inGameMenu[pageName] then
			table.remove(inGameMenu.pagingElement.pages, i)
			table.insert(inGameMenu.pagingElement.pages, position, child)
			break
		end
	end

	inGameMenu.pagingElement:updateAbsolutePosition()
	inGameMenu.pagingElement:updatePageMapping()
	
	inGameMenu:registerPage(inGameMenu[pageName], position, predicateFunc)
	local iconFileName = Utils.getFilename('images/menuIcon.dds', GlobalMarket.dir)
	inGameMenu:addPageTab(inGameMenu[pageName],iconFileName, GuiUtils.getUVs(uvs))
	inGameMenu[pageName]:applyScreenAlignment()
	inGameMenu[pageName]:updateAbsolutePosition()

	for i = 1, #inGameMenu.pageFrames do
		local child = inGameMenu.pageFrames[i]
		if child == inGameMenu[pageName] then
			table.remove(inGameMenu.pageFrames, i)
			table.insert(inGameMenu.pageFrames, position, child)
			break
		end
	end

	inGameMenu:rebuildTabList()
end

addModEventListener(GlobalMarket)

function GlobalMarket:updateUi(streamId, timestamp, connection)
	if g_currentMission.globalMarketUi ~= nil then
		g_currentMission.globalMarketUi:updateContent()
	end
end

function GlobalMarket:updateUiObject(streamId, timestamp, connection)
	if g_currentMission.globalMarketUi ~= nil then
		g_currentMission.globalMarketUi:updateContent()
	end
end

Storage.readUpdateStream = Utils.appendedFunction(Storage.readUpdateStream, GlobalMarket.updateUi)
PlaceableObjectStorage.onReadUpdateStream = Utils.appendedFunction(PlaceableObjectStorage.onReadUpdateStream, GlobalMarket.updateUiObject)

-- call init event
function GlobalMarket:sendInitialClientState(connection, user, farm)
	connection:sendEvent(SynchOfflineMarketEvent.new())
end

FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, GlobalMarket.sendInitialClientState)

-- read gm market placeables
function GlobalMarket.PlaceableObjectStorage_registerXMLPaths(schema, basePath)
	schema:register(XMLValueType.BOOL, basePath .. ".objectStorage#isGmMarket", "ObjectStorage is GlobalMarketPlaceable", false)
end
PlaceableObjectStorage.registerXMLPaths = Utils.appendedFunction(PlaceableObjectStorage.registerXMLPaths, GlobalMarket.PlaceableObjectStorage_registerXMLPaths)

function GlobalMarket.Storage_registerXMLPaths(schema, basePath)
	schema:register(XMLValueType.BOOL, basePath .. "#isGmMarket", "Storage is GlobalMarketPlaceable", false)
end
Storage.registerXMLPaths = Utils.appendedFunction(Storage.registerXMLPaths, GlobalMarket.Storage_registerXMLPaths)

function GlobalMarket:PlaceableObjectStorage_onLoad(savegame)
	local spec = self.spec_objectStorage
	spec.isGmMarket = self.xmlFile:getValue("placeable.objectStorage#isGmMarket", false)
end
PlaceableObjectStorage.onLoad = Utils.appendedFunction(PlaceableObjectStorage.onLoad, GlobalMarket.PlaceableObjectStorage_onLoad)


function GlobalMarket.appendedFunction2(oldFunc, newFunc)
    if oldFunc ~= nil then
        return function (s, ...)
            local val = oldFunc(s, ...)
			newFunc(s, ...)
			return val
        end;
    else
        return newFunc
    end
end

function GlobalMarket:Storage_load(components, xmlFile, key, i3dMappings)
	self.isGmMarket = xmlFile:getValue(key .. "#isGmMarket", false)
end
Storage.load = GlobalMarket.appendedFunction2(Storage.load, GlobalMarket.Storage_load)


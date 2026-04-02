--
-- FS22 - KKSoftwaresUtils
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
--      - First Release
--      - Support mod: GlobalMarket 1.0.0.0
--

KKSoftwaresUtils = {}

KKSoftwaresUtils.fallbackText = {}

function KKSoftwaresUtils.loadTextFromMod(modName, loadingDirectory)
	if loadingDirectory ~= nil then
		local baseLanguageFullPath = KKSoftwaresUtils.getLanguagesFullPath(loadingDirectory)
		KKSoftwaresUtils.loadLanguagesEntries(modName, baseLanguageFullPath, "l10n.elements.e(%d)")

		local fallbackPath = string.gsub(baseLanguageFullPath, "l10n" .. g_languageSuffix, "l10n_en")
		KKSoftwaresUtils.loadLanguagesEntries(modName, fallbackPath, "l10n.elements.e(%d)", KKSoftwaresUtils.fallbackText)
        
        --print("Standard language XML file has been loaded successfully.")
	end
end

function KKSoftwaresUtils.getLanguagesFullPath(modPath)
	local languageSuffixs = {g_languageSuffix, "_en"}
	for i = 1, 2 do
		local fullPath = string.format("%sl10n%s.xml", modPath, languageSuffixs[i])
		if fileExists(fullPath) then
			return fullPath
		else
			fullPath = string.format("%slanguages/l10n%s.xml", modPath, languageSuffixs[i])
			if fileExists(fullPath) then
				return fullPath
			end
		end
	end

	return
end

function KKSoftwaresUtils.loadLanguagesEntries(modName, fullPath, baseKey, globalTexts)
	if globalTexts == nil then
		globalTexts = getfenv(0).g_i18n.texts
	end
	
	local duplicateTable = {}
	local rootModName = KKSoftwaresUtils.getRootModName(modName)

	local xmlFile = loadXMLFile("TempConfig", fullPath)

	local i = 0
	while true do
		local key = string.format(baseKey, i)
		if not hasXMLProperty(xmlFile, key) then
			break
		end

		local k = getXMLString(xmlFile, key.."#k")
		local v = getXMLString(xmlFile, key.."#v")

		if k ~= nil and v ~= nil then
            if globalTexts[k] == nil then
                globalTexts[k] = v
            else
                table.insert(duplicateTable, k)
            end
		end

		i = i + 1
	end

	delete(xmlFile)

	if #duplicateTable > 0 then
		local text = "The following duplicate text entries have been found in '%s' (%s)! Please remove these."
		--g_debug:printWarning(self.scriptDebugId, text, fullPath, modName)

		for i = 1, #duplicateTable do
			local name = duplicateTable[i]
			--g_debug:printWarning(self.scriptDebugId, "      %d: %s", i, name)
		end

		duplicateTable = nil
	end
end

function KKSoftwaresUtils.stringStarts(String,Start)
	return string.sub(String,1,string.len(Start))==Start
 end
 

function KKSoftwaresUtils.getText(textName, endText, backup)
	if textName ~= nil then
		local text = backup or ""

		if textName:sub(1, 6) == "$l10n_" then
			local subText = textName:sub(7)
			if g_i18n:hasText(subText) then
				text = g_i18n:getText(subText)
			end
		elseif g_i18n:hasText(textName) then
			text = g_i18n:getText(textName)
		end

		if text ~= "" then
			if endText ~= nil then
				return text .. tostring(endText)
			end

			return text
		end

		if KKSoftwaresUtils.fallbackText[textName] ~= nil then
			return KKSoftwaresUtils.fallbackText[textName]
		end

		return g_i18n:getText(textName)
	end

	return ""
end

function KKSoftwaresUtils.getRootModName(modName)
	if modName:sub(1, 5) == "FS22_" then
		if modName:sub(-7) == "_update" then
			return modName:sub(6, modName:len() - 7)
		else
			return modName:sub(6)
		end
	else
		if modName:sub(-7) == "_update" then
			return modName:sub(1, modName:len() - 7)
		else
			return modName:sub(1)
		end
	end
end

-- Copy from Gps-Mod :)
function KKSoftwaresUtils.mergeModTranslations(i18n)
    -- We can copy all our translations to the global table because we prefix everything with guidanceSteering_
    -- Thanks for blocking the getfenv Giants..
    local modEnvMeta = getmetatable(_G)
    local env = modEnvMeta.__index

    local global = env.g_i18n.texts
    for key, text in pairs(i18n.texts) do
        global[key] = text
    end
end

function KKSoftwaresUtils.appendedFunction2(oldFunc, newFunc)
    if oldFunc ~= nil then
        return function (s, ...)
            local val = oldFunc(s, ...)
			newFunc(s, ...)
			return val
        end
    else
        return newFunc
    end
end

--https://www.codegrepper.com/code-examples/whatever/lua+check+if+string+is+number
function KKSoftwaresUtils.getStringIsInteger(str)
	return not (str == "" or str:find("%D"))
end

function KKSoftwaresUtils.splitString(s, delimiter)
	local result = {}
	for match in (s..delimiter):gmatch("(.-)"..delimiter) do
		table.insert(result, match)
	end

	return result
end

function KKSoftwaresUtils.convertToBool(val)
	return val == "true" or val == "True" or val == "TRUE" or val == "1"
end
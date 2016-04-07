-- The Group Resource Protocol
-- *bitArray* flags, *uint8* magicka percentage, *uint8* stamina percentage[, *uint16* magicka maximum, *uint16* stamina maximum]
-- flags:
--   1: isFullUpdate - the user is sending max values in addition to percentages in this packet
--   2: requestsFullUpdate - the user does not have all the necessary data and wants to have a full update from everyone (e.g. after reloading the ui)
--   3: sharesPercentagesOnly - the user does not want to share maximum values
--   4: largeMagickaPool - the user has more than 2^16 magicka, so the value has been divided by 2; around 100k magicka seems to be the most that is possible right now
--   5: largeStaminaPool - the user has more than 2^16 stamina, so the value has been divided by 2

local LGS = LibStub("LibGroupSocket")
local type, version = LGS.MESSAGE_TYPE_RESOURCES, 1
local handler, saveData = LGS:RegisterHandler(type, version)
if(not handler) then return end
local SKIP_CREATE = true
local ON_RESOURCES_CHANGED = "OnResourcesChanged"
local MIN_SEND_TIMEOUT = 2
local MIN_COMBAT_SEND_TIMEOUT = 1
local Log = LGS.Log

handler.resources = {}
local resources = handler.resources
local sendFullUpdate = true
local needFullUpdate = true
local lastSendTime = 0
local defaultData = {
	version = 1,
	enabled = true,
	percentOnly = true,
}

local function GetCachedUnitResources(unitTag, skipCreate)
	local unitName = GetUnitName(unitTag)
	local unitResources = resources[unitName]
	if(not unitResources and not skipCreate) then
		resources[unitName] = {
			[POWERTYPE_MAGICKA] = { current = 1000, maximum = 1000, percent = 255 },
			[POWERTYPE_STAMINA] = { current = 1000, maximum = 1000, percent = 255 },
			percentageOnly = true,
			hasFullData = false,
			lastUpdate = 0,
		}
		unitResources = resources[unitName]
	end
	return unitResources
end

function handler:GetLastUpdateTime(unitTag)
	local unitResources = GetCachedUnitResources(unitTag, SKIP_CREATE)
	if(unitResources) then return unitResources.lastUpdate end
	return -1
end

local function OnData(unitTag, data, isSelf)
	local index, bitIndex = 1, 1
	local isFullUpdate, index, bitIndex = LGS:ReadBit(data, index, bitIndex)
	local requestsFullUpdate, index, bitIndex = LGS:ReadBit(data, index, bitIndex)
	local sharesPercentagesOnly, index, bitIndex = LGS:ReadBit(data, index, bitIndex)
	local largeMagickaPool, index, bitIndex = LGS:ReadBit(data, index, bitIndex)
	local largeStaminaPool, index, bitIndex = LGS:ReadBit(data, index, bitIndex)
	--	Log("OnData %s (%d byte): is full: %s, needs full: %s, percent only: %s", GetUnitName(unitTag), #data, tostring(isFullUpdate), tostring(requestsFullUpdate), tostring(sharesPercentagesOnly))
	index = index + 1
	if(not isSelf and requestsFullUpdate) then
		sendFullUpdate = true
	end

	local expectedLength = isFullUpdate and 7 or 3
	if(#data < expectedLength) then Log("ResourceHandler received only %d of %d byte", #data, expectedLength) return end

	local unitResources = GetCachedUnitResources(unitTag)
	local magicka = unitResources[POWERTYPE_MAGICKA]
	local stamina = unitResources[POWERTYPE_STAMINA]

	unitResources.percentageOnly = sharesPercentagesOnly

	magicka.percent, index = LGS:ReadUint8(data, index)
	stamina.percent, index = LGS:ReadUint8(data, index)

	if(sharesPercentagesOnly) then
		magicka.maximum = 1000
		stamina.maximum = 1000
		unitResources.hasFullData = false
	elseif(isFullUpdate) then
		magicka.maximum, index = LGS:ReadUint16(data, index)
		if(largeMagickaPool) then magicka.maximum = magicka.maximum * 2 end
		stamina.maximum, index = LGS:ReadUint16(data, index)
		if(largeStaminaPool) then stamina.maximum = stamina.maximum * 2 end
		unitResources.hasFullData = true
	elseif(not unitResources.hasFullData and not isSelf) then
		needFullUpdate = true
	end

	magicka.current = math.floor((magicka.percent / 255) * magicka.maximum)
	stamina.current = math.floor((stamina.percent / 255) * stamina.maximum)

	unitResources.lastUpdate = GetTimeStamp()

	--	Log("magicka: %d/%d stamina: %d/%d", magicka.current, magicka.maximum, stamina.current, stamina.maximum)
	LGS.cm:FireCallbacks(ON_RESOURCES_CHANGED, unitTag, magicka.current, magicka.maximum, stamina.current, stamina.maximum, isSelf)
end

function handler:RegisterForResourcesChanges(callback)
	LGS.cm:RegisterCallback(ON_RESOURCES_CHANGED, callback)
end

function handler:UnregisterForResourcesChanges(callback)
	LGS.cm:UnregisterCallback(ON_RESOURCES_CHANGED, callback)
end

local function GetPowerValues(unitResources, powerType)
	local data = unitResources[powerType]
	local current, maximum = GetUnitPower("player", powerType)
	local percent = math.floor(current / maximum * 255)
	return data, current, maximum, percent
end

function handler:Send()
	if(not saveData.enabled or not IsUnitGrouped("player")) then return end
	local now = GetTimeStamp()
	local timeout = IsUnitInCombat("player") and MIN_COMBAT_SEND_TIMEOUT or MIN_SEND_TIMEOUT
	if(now - lastSendTime < timeout) then return end

	local unitResources = GetCachedUnitResources("player")
	local magicka, magickaCurrent, magickaMaximum, magickaPercent = GetPowerValues(unitResources, POWERTYPE_MAGICKA)
	local stamina, staminaCurrent, staminaMaximum, staminaPercent = GetPowerValues(unitResources, POWERTYPE_STAMINA)

	local percentOnly = saveData.percentOnly
	sendFullUpdate = sendFullUpdate or (not percentOnly and (magicka.maximum ~= magickaMaximum or stamina.maximum ~= staminaMaximum))
	if(magicka.percent ~= magickaPercent or stamina.percent ~= staminaPercent or sendFullUpdate or needFullUpdate) then
		local largeMagickaPool = (magickaMaximum >= 2^16)
		local largeStaminaPool = (staminaMaximum >= 2^16)

		local data = {}
		local index, bitIndex = 1, 1
		index, bitIndex = LGS:WriteBit(data, index, bitIndex, (sendFullUpdate and not percentOnly))
		index, bitIndex = LGS:WriteBit(data, index, bitIndex, needFullUpdate)
		index, bitIndex = LGS:WriteBit(data, index, bitIndex, percentOnly)
		if(sendFullUpdate and not percentOnly) then
			index, bitIndex = LGS:WriteBit(data, index, bitIndex, largeMagickaPool)
			index, bitIndex = LGS:WriteBit(data, index, bitIndex, largeStaminaPool)
		else
			index, bitIndex = LGS:WriteBit(data, index, bitIndex, false)
			index, bitIndex = LGS:WriteBit(data, index, bitIndex, false)
		end
		index = index + 1
		index = LGS:WriteUint8(data, index, magickaPercent)
		index = LGS:WriteUint8(data, index, staminaPercent)
		if(sendFullUpdate and not percentOnly) then
			if(largeMagickaPool) then magickaMaximum = math.floor(magickaMaximum / 2) end
			index = LGS:WriteUint16(data, index, magickaMaximum)

			if(largeStaminaPool) then staminaMaximum = math.floor(staminaMaximum / 2) end
			index = LGS:WriteUint16(data, index, staminaMaximum)
		end

		--		Log("Send %d byte: is full: %s, needs full: %s, percent only: %s", #data, tostring(sendFullUpdate), tostring(needFullUpdate), tostring(percentOnly))
		if(LGS:Send(type, data)) then
			lastSendTime = now
			magicka.percent = magickaPercent
			stamina.percent = staminaPercent
			if(sendFullUpdate and not percentOnly) then
				if(largeMagickaPool) then magicka.maximum = magicka.maximum * 2 end
				magicka.maximum = magickaMaximum
				if(largeStaminaPool) then stamina.maximum = stamina.maximum * 2 end
				stamina.maximum = staminaMaximum
			end
			sendFullUpdate = false
			needFullUpdate = false
		end
	end
end

local function OnUpdate()
	handler:Send()
end

local isActive = false

local function StartSending()
	if(not isActive and saveData.enabled and IsUnitGrouped("player")) then
		EVENT_MANAGER:RegisterForUpdate("LibGroupSocketResourceHandler", 1000, OnUpdate)
		isActive = true
	end
end

local function StopSending()
	if(isActive) then
		EVENT_MANAGER:UnregisterForUpdate("LibGroupSocketResourceHandler")
		isActive = false
	end
end

local function OnUnitCreated(_, unitTag)
	sendFullUpdate = true
	StartSending()
end

local function OnUnitDestroyed(_, unitTag)
	resources[GetUnitName(unitTag)] = nil
	if(isActive and not IsUnitGrouped("player")) then
		StopSending()
	end
end

function handler:InitializeSettings(optionsData, IsSendingDisabled) -- TODO: localization
	optionsData[#optionsData + 1] = {
		type = "header",
		name = "Resource Handler",
	}
optionsData[#optionsData + 1] = {
	type = "checkbox",
	name = "Enable sending",
	tooltip = "Controls if the handler does send data. It will still receive and process incoming data.",
	getFunc = function() return saveData.enabled end,
	setFunc = function(value)
		saveData.enabled = value
		if(value) then StartSending() else StopSending() end
	end,
	disabled = IsSendingDisabled,
	default = defaultData.enabled
}
optionsData[#optionsData + 1] = {
	type = "checkbox",
	name = "Send percentages only",
	tooltip = "If this is turned on, your maximum resources won't be shared with your group members",
	getFunc = function() return saveData.percentOnly end,
	setFunc = function(value) saveData.percentOnly = value end,
	disabled = IsSendingDisabled,
	default = defaultData.percentOnly
}
end

local function Unload()
	LGS.cm:UnregisterCallback(type, handler.dataHandler)
	EVENT_MANAGER:UnregisterForEvent("LibGroupSocketResourceHandler", EVENT_UNIT_CREATED)
	EVENT_MANAGER:UnregisterForEvent("LibGroupSocketResourceHandler", EVENT_UNIT_DESTROYED)
	StopSending()
end

local function Load()
	if(not saveData.version) then
		ZO_DeepTableCopy(defaultData, saveData)
	end
	--	if(saveData.version == 1) then
	--		-- update it
	--	end

	handler.dataHandler = OnData
	LGS.cm:RegisterCallback(type, OnData)
	EVENT_MANAGER:RegisterForEvent("LibGroupSocketResourceHandler", EVENT_UNIT_CREATED, OnUnitCreated)
	EVENT_MANAGER:RegisterForEvent("LibGroupSocketResourceHandler", EVENT_UNIT_DESTROYED, OnUnitDestroyed)
	handler.Unload = Unload

	StartSending()
end

if(handler.Unload) then handler.Unload() end
Load()

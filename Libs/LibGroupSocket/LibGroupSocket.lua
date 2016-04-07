local LIB_IDENTIFIER = "LibGroupSocket"
local lib = LibStub:NewLibrary(LIB_IDENTIFIER, 1)

if not lib then
	return	-- already loaded and no upgrade necessary
end

local LMP = LibStub("LibMapPing", true)
if(not LMP) then
	error(string.format("[%s] Cannot load without LibMapPing", LIB_IDENTIFIER))
end

local LGPS = LibStub("LibGPS2", true)
if(not LGPS) then
	error(string.format("[%s] Cannot load without LibGPS2", LIB_IDENTIFIER))
end

local function Log(message, ...)
	df("[%s] %s", LIB_IDENTIFIER, message:format(...))
end
lib.Log = Log

--/script PingMap(89, 1, 1 / 2^16, 1 / 2^16) StartChatInput(table.concat({GetMapPlayerWaypoint()}, ","))
-- smallest step is around 1.428571431461e-005 for Wrothgar, so there should be 70000 steps
-- Coldharbour has a similar step size, meaning we can send 4 bytes of data per ping on both
local WROTHGAR_MAP_INDEX = 27
local COLDHARBOUR_MAP_INDEX = 23
local MAP_METRICS = {
	[WROTHGAR_MAP_INDEX] = { zoneIndex = GetZoneIndex(684), stepSize =  1.428571431461e-005 },
	[COLDHARBOUR_MAP_INDEX] = { zoneIndex = GetZoneIndex(347), stepSize = 1.4285034012573e-005 },
}
local NO_UPDATE = true

--lib.debug = true -- TODO
lib.cm = lib.cm or ZO_CallbackObject:New()
lib.outgoing = lib.outgoing or {}
lib.incoming = lib.incoming or {}
lib.handlers = lib.handlers or {}
local handlers = lib.handlers
local suppressedList = {}
local panel, button, entry

function lib:GetMapIndexForUnit(unitTag)
	if(MAP_METRICS[WROTHGAR_MAP_INDEX].zoneIndex == GetUnitZoneIndex(unitTag)) then
		return COLDHARBOUR_MAP_INDEX
	else
		return WROTHGAR_MAP_INDEX
	end
end

function lib:GetStepSizeForUnit(unitTag)
	return MAP_METRICS[lib:GetMapIndexForUnit(unitTag)].stepSize
end

------------------------------------------------------- Settings ------------------------------------------------------

local defaultData = {
	version = 1,
	enabled = false,
	autoDisableOnGroupLeft = true,
	autoDisableOnSessionStart = true,
	handlers = {},
}

LibGroupSockets_Data = LibGroupSockets_Data or {}
local saveData = LibGroupSockets_Data[GetDisplayName()] or ZO_DeepTableCopy(defaultData)
LibGroupSockets_Data[GetDisplayName()] = saveData

local function UpgradeSaveData()
--if(saveData.version == 1) then
--	saveData.setting = defaultData.setting
--	saveData.version = 2
--end
end

local function RefreshSettingsPanel()
	if(not panel) then return end
	CALLBACK_MANAGER:FireCallbacks("LAM-RefreshPanel", panel)
end

local function RefreshGroupMenuKeyboard()
	if(not button) then return end
	ZO_CheckButton_SetCheckState(button, saveData.enabled)
end

local function RefreshGroupMenuGamepad(noUpdate)
	if(not entry) then return end
	entry:SetText(saveData.enabled and "Disable sending" or "Enable sending")
	if(not noUpdate) then
		GAMEPAD_GROUP_MENU:UpdateMenuList()
	end
end

local function InitializeGroupMenu()
	if(not ZO_GroupMenu_Keyboard) then return end
	-- keyboard
	button = CreateControlFromVirtual("$(parent)_LibGroupSocketToggle", ZO_GroupMenu_Keyboard, "ZO_CheckButton_Text")
	ZO_CheckButton_SetLabelText(button, "LibGroupSocket Sending:")
	ZO_CheckButton_SetCheckState(button, saveData.enabled)
	ZO_CheckButton_SetToggleFunction(button, function(control, checked)
		if(checked ~= saveData.enabled) then
			saveData.enabled = checked
			RefreshSettingsPanel()
			RefreshGroupMenuGamepad()
		end
	end)
	button.label:ClearAnchors()
	button.label:SetAnchor(TOPLEFT, ZO_GroupMenu_Keyboard, TOPLEFT, 10, 30)
	button:SetAnchor(LEFT, button.label, RIGHT, -40, 0)

	-- gamepad
	local menu = GAMEPAD_GROUP_MENU
	local MENU_ENTRY_TYPE_LGS_TOGGLE = #menu.menuEntries + 1
	entry = ZO_GamepadEntryData:New("")
	RefreshGroupMenuGamepad(NO_UPDATE)
	entry.type = MENU_ENTRY_TYPE_LGS_TOGGLE
	entry:SetHeader("LibGroupSocket")
	menu.menuEntries[MENU_ENTRY_TYPE_LGS_TOGGLE] = entry

	local list = GAMEPAD_GROUP_MENU:GetMainList()
	local originalCommit = list.Commit
	list.Commit = function(self, ...)
		list:AddEntryWithHeader("ZO_GamepadMenuEntryTemplate", entry)
		originalCommit(self, ...)
	end

	local InitializeKeybindDescriptors = menu.InitializeKeybindDescriptors
	menu.InitializeKeybindDescriptors = function(self)
		InitializeKeybindDescriptors(self)

		local primary = menu.keybindStripDescriptor[1]
		local callback = primary.callback
		primary.callback = function()
			callback()
			local type = list:GetTargetData().type
			if type == MENU_ENTRY_TYPE_LGS_TOGGLE then
				PlaySound(SOUNDS.DEFAULT_CLICK)
				saveData.enabled = not saveData.enabled
				RefreshSettingsPanel()
				RefreshGroupMenuKeyboard()
				RefreshGroupMenuGamepad()
			end
		end
	end
end

local function InitializeSettingsPanel() -- TODO: localization
	local LAM = LibStub("LibAddonMenu-2.0", true)
	if(LAM) then -- if LAM is not available, it is not the stand alone version of LGS. As we can't save anything in that case, we don't bother enforcing a dependency.
		local function IsSendingDisabled() return not saveData.enabled end

		local panelData = {
			type = "panel",
			name = "LibGroupSocket",
			author = "sirinsidiator",
			version = "VERSION_NUMBER",
			registerForRefresh = true,
			registerForDefaults = true
		}
		panel = LAM:RegisterAddonPanel("LibGroupSocketOptions", panelData)

		local optionsData = {}
		if(not lib.standalone) then -- the stand alone version contains a file that sets standalone = true
			optionsData[#optionsData + 1] = {
				type = "description",
				text = "No stand alone installation detected. Settings won't be saved.",
				reference = "LibGroupSocketStandAloneWarning"
			}
		end

		optionsData[#optionsData + 1] = {
			type = "header",
			name = "General",
		}
		optionsData[#optionsData + 1] = {
			type = "checkbox",
			name = "Enable Sending",
			tooltip = "Controls if the library sends any data. It will still receive and process data.",
			getFunc = function() return saveData.enabled end,
			setFunc = function(value)
				saveData.enabled = value
				RefreshGroupMenuKeyboard()
				RefreshGroupMenuGamepad()
			end,
			default = defaultData.enabled
		}
		optionsData[#optionsData + 1] = {
			type = "checkbox",
			name = "Disable On Group Left",
			tooltip = "Automatically disables sending when you leave a group in order to prevent accidentally sending data to a new group.",
			getFunc = function() return saveData.autoDisableOnGroupLeft end,
			setFunc = function(value) saveData.autoDisableOnGroupLeft = value end,
			default = defaultData.enabled
		}
		optionsData[#optionsData + 1] = {
			type = "checkbox",
			name = "Disable On Session Start",
			tooltip = "Automatically disables sending when you start the game in order to prevent accidentally sending data to an existing group.",
			getFunc = function() return saveData.autoDisableOnSessionStart end,
			setFunc = function(value) saveData.autoDisableOnSessionStart = value end,
			default = defaultData.enabled
		}

		for handlerType, handler in pairs(handlers) do
			if(handler.InitializeSettings) then
				handler:InitializeSettings(optionsData, IsSendingDisabled)
			end
		end
		LAM:RegisterOptionControls("LibGroupSocketOptions", optionsData)
	end
end

------------------------------------------------- OutgoingPacket Class ------------------------------------------------

local OutgoingPacket = ZO_Object:Subclass()

function OutgoingPacket:New(messageType, data)
	local object = ZO_Object.New(self)
	object.messageType = messageType
	object.header = lib:EncodeHeader(messageType, #data)
	object.data = data
	object.index = 0
	return object
end

function OutgoingPacket:GetNext()
	local next
	if(self.index < 1) then
		next = self.header
	else
		next = self.data[self.index] or 0
	end
	self.index = self.index + 1
	return next
end

function OutgoingPacket:GetNextCoordinates()
	local stepSize = lib:GetStepSizeForUnit("player")
	return lib:EncodeData(self:GetNext(), self:GetNext(), self:GetNext(), self:GetNext(), stepSize)
end

function OutgoingPacket:HasMore()
	return self.index <= #self.data
end

------------------------------------------------- IncomingPacket Class ------------------------------------------------

local IncomingPacket = ZO_Object:Subclass()

function IncomingPacket:New(unitTag)
	local object = ZO_Object.New(self)
	object.messageType = -1
	object.data = {}
	object.length = 0
	object.stepSize = lib:GetStepSizeForUnit(unitTag)
	return object
end

function IncomingPacket:AddCoordinates(x, y)
	local b0, b1, b2, b3 = lib:DecodeData(x, y, self.stepSize)
	local data = self.data
	if(self.messageType < 0) then
		self.messageType, self.length = lib:DecodeHeader(b0)
	else
		data[#data + 1] = b0
	end
	if(#data < self.length) then data[#data + 1] = b1 end
	if(#data < self.length) then data[#data + 1] = b2 end
	if(#data < self.length) then data[#data + 1] = b3 end
end

function IncomingPacket:IsComplete()
	return self.length > 0 and #self.data >= self.length
end

local function IsValidMessageType(messageType)
	return not (messageType < 0 or messageType > 31)
end

function IncomingPacket:HasValidHeader()
	return IsValidMessageType(self.messageType) and self.length > 0 and self.length < 8
end

function IncomingPacket:IsValid()
	return self:HasValidHeader() and #self.data == self.length
end

--------------------------------------------- Byte Manipulation Utilities ---------------------------------------------

--- Reads a bit from the data stream and increments the index and bit index accordingly
--- data - an array of integers between 0 and 255
--- index - the current position to read from
--- bitIndex - the current bit inside the current byte (starts from 1)
--- returns the state of the bit, the next position in the data array and the next bitIndex
function lib:ReadBit(data, index, bitIndex)
	local p = 2 ^ (bitIndex - 1)
	local isSet = (data[index] % (p + p) >= p)
	local nextIndex = (bitIndex >= 8 and index + 1 or index)
	local nextBitIndex = (bitIndex >= 8 and 1 or bitIndex + 1)
	return isSet, nextIndex, nextBitIndex
end

--- Writes a bit to the data stream and increments the index and bit index accordingly
--- data - an array of integers between 0 and 255
--- index - the current position to write to
--- bitIndex - the current bit inside the current byte (starts from 1)
--- value - the new state of the bit
--- returns the next position in the data array and the next bitIndex
function lib:WriteBit(data, index, bitIndex, value)
	local p = 2 ^ (bitIndex - 1)
	local oldValue = data[index] or 0
	local isSet = (oldValue % (p + p) >= p)
	if(isSet and not value) then
		oldValue = oldValue - p
	elseif(not isSet and value) then
		oldValue = oldValue + p
	end
	data[index] = oldValue
	local nextIndex = (bitIndex >= 8 and index + 1 or index)
	local nextBitIndex = (bitIndex >= 8 and 1 or bitIndex + 1)
	return nextIndex, nextBitIndex
end

--- Reads a single byte from the data stream, converts it into a string character and increments the index accordingly
--- data - an array of integers between 0 and 255
--- index - the current position to read from
--- returns the character and the next position in the data array
function lib:ReadChar(data, index)
	return string.char(data[index]), index + 1
end

--- Writes a single character to the data stream and increments the index accordingly
--- data - an array of integers between 0 and 255
--- index - the current position to write to
--- value - a single character or a string of characters
--- [charIndex] - optional index of the character that should be written to the data stream. Defaults to the first character
--- returns the next position in the data array
function lib:WriteChar(data, index, value, charIndex)
	data[index] = value:byte(charIndex)
	return index + 1
end

--- Reads a single byte from the data stream and increments the index accordingly
--- data - an array of integers between 0 and 255
--- index - the current position to read from
--- returns the 8-bit unsigned integer and the next position in the data array
function lib:ReadUint8(data, index)
	return data[index], index + 1
end

--- Writes an 8-bit unsigned integer to the data stream and increments the index accordingly
--- The value is clamped and floored to match the data type.
--- data - an array of integers between 0 and 255
--- index - the current position to write to
--- value - an 8-bit unsigned integer
--- returns the next position in the data array
function lib:WriteUint8(data, index, value)
	data[index] = math.min(0xff, math.max(0x00, math.floor(value)))
	return index + 1
end

--- Reads two byte from the data stream, converts them to one integer and increments the index accordingly
--- data - an array of integers between 0 and 255
--- index - the current position to read from
--- returns the 16-bit unsigned integer and the next position in the data array
function lib:ReadUint16(data, index)
	return (data[index] * 0x100 + data[index + 1]), index + 2
end

--- Writes a 16-bit unsigned integer to the data stream and increments the index accordingly
--- The value is clamped and floored to match the data type.
--- data - an array of integers between 0 and 255
--- index - the current position to write to
--- value - a 16-bit unsigned integer
--- returns the next position in the data array
function lib:WriteUint16(data, index, value)
	value = math.min(0xffff, math.max(0x0000, math.floor(value)))
	data[index] = math.floor(value / 0x100)
	data[index + 1] = value % 0x100
	return index + 2
end

--- Converts 4 bytes of data into coordinates for a map ping
--- b0 to b3 - integers between 0 and 255
--- step size specifies the smallest possible increment for the coordinates on a map
--- returns normalized x and y coordinates
function lib:EncodeData(b0, b1, b2, b3, stepSize)
	b0 = b0 or 0
	b1 = b1 or 0
	b2 = b2 or 0
	b3 = b3 or 0
	return (b0 * 0x100 + b1) * stepSize, (b2 * 0x100 + b3) * stepSize
end

--- Converts normalized map ping coordinates into 4 bytes of data
--- step size specifies the smallest possible increment for the coordinates on a map
--- returns 4 integers between 0 and 255
function lib:DecodeData(x, y, stepSize)
	x = math.floor(x / stepSize + 0.5) -- round to next integer
	y = math.floor(y / stepSize + 0.5)
	local b0 = math.floor(x / 0x100)
	local b1 = x % 0x100
	local b2 = math.floor(y / 0x100)
	local b3 = y % 0x100
	return b0, b1, b2, b3
end

--- Packs a 5-bit messageType and a 3-bit length value into one byte of data
--- messageType - integer between 0 and 31
--- length - integer between 0 and 7
--- returns encoded header byte
function lib:EncodeHeader(messageType, length)
	return messageType * 0x08 + length
end

--- Unpacks a 5-bit messageType and a 3-bit length value from one byte of data
--- value - integer between 0 and 255
--- returns messageType and length
function lib:DecodeHeader(value)
	local messageType = math.floor(value / 0x08)
	local length = value % 0x08
	return messageType, length
end

--------------------------------------------------- Data Processing ---------------------------------------------------

local function SetMapPingOnCommonMap(x, y)
	local pingType = MAP_PIN_TYPE_PING
	if(lib.debug and not IsUnitGrouped("player")) then
		pingType = MAP_PIN_TYPE_PLAYER_WAYPOINT
	end
	LGPS:PushCurrentMap()
	SetMapToMapListIndex(lib:GetMapIndexForUnit("player"))
	LMP:SetMapPing(pingType, MAP_TYPE_LOCATION_CENTERED, x, y)
	LGPS:PopCurrentMap()
end

local function GetMapPingOnCommonMap(pingType, pingTag)
	LGPS:PushCurrentMap()
	SetMapToMapListIndex(lib:GetMapIndexForUnit(pingTag))
	local x, y = LMP:GetMapPing(pingType, pingTag)
	LGPS:PopCurrentMap()
	return x, y
end

local function DoSend(isFirst)
	local packet = lib.outgoing[1]
	if(not packet) then Log("Tried to send when no data in queue") return end
	lib.isSending = true

	local x, y = packet:GetNextCoordinates()
	SetMapPingOnCommonMap(x, y)

	lib.hasMore = packet:HasMore()
	if(not lib.hasMore) then
		table.remove(lib.outgoing, 1)
		lib.hasMore = (#lib.outgoing > 0)
	end
end

local function IsValidData(data)
	if(#data > 7) then
		Log("Tried to send %d of 7 allowed bytes", #data)
		return false
	end
	for i = 1, #data do
		local value = data[i]
		if(type(value) ~= "number" or value < 0 or value > 255) then
			Log("Invalid value '%s' at position %d in byte data", tostring(value), i)
			return false
		end
	end
	return true
end

--- Queues up to seven byte of data of the selected messageType for broadcasting to all group members
--- messageType - the protocol that is used for encoding the sent data
--- data - up to 7 byte of custom data. if more than 3 bytes are passed, the data will take 2 map pins to arrive.
--- returns true if the data was successfully queued. Data won't be queued when the general sending setting is off or an invalid value was passed.
function lib:Send(messageType, data)
	if(not saveData.enabled) then return false end
	if(not IsValidMessageType(messageType)) then Log("tried to send invalid messageType %s", tostring(messageType)) return false end
	if(not IsValidData(data)) then return false end
	--  TODO like all other api functions, this one also has a message rate limit. We need to avoid sending too much or we risk getting kicked
	lib.outgoing[#lib.outgoing + 1] = OutgoingPacket:New(messageType, data)
	if(not lib.isSending) then
		DoSend()
	else
		lib.hasMore = true
	end
	return true
end

local function HandleDataPing(pingType, pingTag, x, y, isPingOwner)
	x, y = GetMapPingOnCommonMap(pingType, pingTag)
	if(not LMP:IsPositionOnMap(x, y)) then return false end
	if(not lib.incoming[pingTag]) then
		lib.incoming[pingTag] = IncomingPacket:New(pingTag)
	end
	local packet = lib.incoming[pingTag]
	packet:AddCoordinates(x, y)
	if(not packet:HasValidHeader()) then -- it might be a user set ping
		lib.incoming[pingTag] = nil
		return false
	end
	if(packet:IsComplete()) then
		lib.incoming[pingTag] = nil
		if(packet:IsValid()) then
			lib.cm:FireCallbacks(packet.messageType, pingTag, packet.data, isPingOwner)
		else
			lib.incoming[pingTag] = nil
			Log("received invalid packet from %s", GetUnitName(pingTag))
			return false
		end
	end
	if(isPingOwner) then
		if(lib.hasMore) then
			DoSend()
		else
			lib.isSending = false
		end
	end
	return true
end

-------------------------------------------------- Map Ping Handling --------------------------------------------------
local function GetKey(pingType, pingTag)
	return string.format("%d_%s", pingType, pingTag)
end

local function SuppressPing(pingType, pingTag)
	local key = GetKey(pingType, pingTag)
	if(not suppressedList[key]) then
		LMP:SuppressPing(pingType, pingTag)
		suppressedList[key] = true
	end
end

local function UnsuppressPing(pingType, pingTag)
	local key = GetKey(pingType, pingTag)
	if(suppressedList[key]) then
		LMP:UnsuppressPing(pingType, pingTag)
		suppressedList[key] = false
	end
end

LMP:RegisterCallback("BeforePingAdded", function(pingType, pingTag, x, y, isPingOwner)
	if(pingType == MAP_PIN_TYPE_PING or (lib.debug and not IsUnitGrouped("player") and pingType == MAP_PIN_TYPE_PLAYER_WAYPOINT)) then
		if(HandleDataPing(pingType, pingTag, x, y, isPingOwner)) then -- it is a valid data ping
			SuppressPing(pingType, pingTag)
		else -- ping is set by player
			UnsuppressPing(pingType, pingTag)
		end
	end
end)

LMP:RegisterCallback("AfterPingRemoved", function(pingType, pingTag, x, y, isPingOwner)
	UnsuppressPing(pingType, pingTag)
end)

---------------------------------------------------- Data Handlers ----------------------------------------------------

lib.MESSAGE_TYPE_RESERVED = 0 --- reserved in case we ever have more than 31 message types. can also be used for local tests
lib.MESSAGE_TYPE_RESOURCES = 1 --- for exchanging stamina and magicka values

--- Registers a handler module for a specific data type.
--- This module will keep everything related to data handling out of any single addon,
--- in order to let multiple addons use the same messageType.
--- messageType - The messageType the handler will take care of
--- handlerVersion - The loaded handler version. Works like the minor version in LibStub and prevents older instances from overwriting a newer one
--- returns the handler object and saveData for the messageType
function lib:RegisterHandler(messageType, handlerVersion)
	if handlers[messageType] and handlers[messageType].version >= handlerVersion then
		return false
	else
		handlers[messageType] = handlers[messageType] or {}
		handlers[messageType].version = handlerVersion
		saveData.handlers[messageType] = saveData.handlers[messageType] or {}
		return handlers[messageType], saveData.handlers[messageType]
	end
end

--- Gives access to an already registered handler for addons.
--- messageType - The messageType of the handler
--- returns the handler object
function lib:GetHandler(messageType)
	return handlers[messageType]
end

--------------------------------------------------------- Misc --------------------------------------------------------

--- Register for unprocessed data of a messageType
function lib:RegisterCallback(messageType, callback)
	self.cm:RegisterCallback(messageType, callback)
end

--- Unregister for unprocessed data of a messageType
function lib:UnregisterCallback(messageType, callback)
	self.cm:UnregisterCallback(messageType, callback)
end

---------------------------------------------------- Initialization ---------------------------------------------------

local function Unload()
	EVENT_MANAGER:UnregisterForEvent(LIB_IDENTIFIER, EVENT_PLAYER_ACTIVATED)
	EVENT_MANAGER:UnregisterForEvent(LIB_IDENTIFIER, EVENT_UNIT_DESTROYED)
end

local function Load()
	UpgradeSaveData()

	EVENT_MANAGER:RegisterForEvent(LIB_IDENTIFIER, EVENT_UNIT_DESTROYED, function()
		if(saveData.autoDisableOnGroupLeft and not IsUnitGrouped("player")) then
			saveData.enabled = false
			RefreshSettingsPanel()
			RefreshGroupMenuKeyboard()
			RefreshGroupMenuGamepad()
		end
	end)

	-- don't initialize the settings menu before we can be sure that it is the newest version of the lib
	EVENT_MANAGER:RegisterForEvent(LIB_IDENTIFIER, EVENT_PLAYER_ACTIVATED, function()
		EVENT_MANAGER:UnregisterForEvent(LIB_IDENTIFIER, EVENT_PLAYER_ACTIVATED)
		if(saveData.autoDisableOnSessionStart) then
			saveData.enabled = false -- don't need to refresh the settings or group menu here, because they are not initialized yet
		end

		InitializeSettingsPanel()
		InitializeGroupMenu()
	end)

	SLASH_COMMANDS["/lgs"] = function(value)
		saveData.enabled = (value == "1")
		Log("Data sending %s", saveData.enabled and "enabled" or "disabled")
		RefreshSettingsPanel()
		RefreshGroupMenuKeyboard()
		RefreshGroupMenuGamepad()
	end

	lib.Unload = Unload
end

if(lib.Unload) then lib.Unload() end
Load()

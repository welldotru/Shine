--[[
	Shine extension system.

	Supports server side, client side and shared plugins.
]]

local include = Script.Load
local next = next
local pcall = pcall
local setmetatable = setmetatable
local StringExplode = string.Explode

Shine.Plugins = {}

local ExtensionPath = "lua/shine/extensions/"

--Here we collect every extension file so we can be sure it exists before attempting to load it.
local PluginFiles = {}
Shared.GetMatchingFileNames( ExtensionPath.."*.lua", true, PluginFiles )

--Convert to faster table.
for i = 1, #PluginFiles do
	PluginFiles[ PluginFiles[ i ] ] = true
	PluginFiles[ i ] = nil
end

local PluginMeta = {}
PluginMeta.__index = PluginMeta

function PluginMeta:AddDTVar( Type, Name, Default )
	self.DTVars = self.DTVars or {}
	self.DTVars.Keys = self.DTVars.Keys or {}
	self.DTVars.Defaults = self.DTVars.Defaults or {}

	self.DTVars.Keys[ Name ] = Type
	self.DTVars.Defaults[ Name ] = Default
end

function PluginMeta:SetDTAccess( Access )
	self.DTVars.Access = Access
end

function PluginMeta:InitDataTable( Name )
	self.dt = Shine:CreateDataTable( "Shine_DT_"..Name, self.DTVars.Keys, self.DTVars.Defaults, self.DTVars.Access )

	self.DTVars = nil
end

function Shine:RegisterExtension( Name, Table )
	self.Plugins[ Name ] = setmetatable( Table, PluginMeta )
end

function Shine:LoadExtension( Name, DontEnable )
	local ClientFile = ExtensionPath..Name.."/client.lua"
	local ServerFile = ExtensionPath..Name.."/server.lua"
	local SharedFile = ExtensionPath..Name.."/shared.lua"
	
	local IsShared = PluginFiles[ ClientFile ] and PluginFiles[ SharedFile ] or PluginFiles[ ServerFile ]

	if PluginFiles[ SharedFile ] then
		include( SharedFile )

		local Plugin = self.Plugins[ Name ]

		if not Plugin then
			return false, "plugin did not register itself"
		end

		if Plugin.SetupDataTable then --Networked variables.
			Plugin:SetupDataTable()
			Plugin:InitDataTable( Name )
		end
	end

	--Client plugins load automatically, but enable themselves later when told to.
	if Client then
		local OldValue = Plugin
		Plugin = self.Plugins[ Name ]

		if PluginFiles[ ClientFile ] then
			include( ClientFile )
		end

		Plugin = OldValue --Just in case someone else uses Plugin as a global...

		return true
	end

	if not PluginFiles[ ServerFile ] then
		ServerFile = ExtensionPath..Name..".lua"

		if not PluginFiles[ ServerFile ] then
			return false, "plugin does not exist."
		end
	end

	--Global value so that the server file has access to the same table the shared one created.
	local OldValue = Plugin

	if IsShared then
		Plugin = self.Plugins[ Name ]
	end

	include( ServerFile )

	--Clean it up afterwards ready for the next extension.
	if IsShared then
		Plugin = OldValue
	end

	local Plugin = self.Plugins[ Name ]

	if not Plugin then
		return false, "plugin did not register itself."
	end

	Plugin.IsShared = IsShared and true or nil

	if DontEnable then return true end
	
	return self:EnableExtension( Name )
end

--Shared extensions need to be enabled once the server tells it to.
function Shine:EnableExtension( Name )
	local Plugin = self.Plugins[ Name ]

	if not Plugin then
		return false, "plugin does not exist"
	end

	if Plugin.Enabled then
		self:UnloadExtension( Name )
	end

	if Plugin.HasConfig then
		Plugin:LoadConfig()
	end

	if Server and Plugin.IsShared and next( self.GameIDs ) then --We need to inform clients to enable the client portion.
		Server.SendNetworkMessage( "Shine_PluginEnable", { Plugin = Name, Enabled = true }, true )
	end

	return Plugin:Initialise()
end

function Shine:UnloadExtension( Name )
	local Plugin = self.Plugins[ Name ]

	if not Plugin then return end

	Plugin:Cleanup()

	Plugin.Enabled = false

	if Server and Plugin.IsShared and next( self.GameIDs ) then
		Server.SendNetworkMessage( "Shine_PluginEnable", { Plugin = Name, Enabled = false }, true )
	end
end

local ClientPlugins = {}

--[[
	Prepare client side plugins.

	Important to note: Shine does not support hot loading plugin files. That is, it will only know about plugin files that were present when it started.
]]
for Path in pairs( PluginFiles ) do
	local Folders = StringExplode( Path, "/" )
	local Name = Folders[ 3 ]

	if Folders[ 4 ] and not ClientPlugins[ Name ] then
		ClientPlugins[ Name ] = "boolean" --Generate the network message.
		Shine:LoadExtension( Name, true ) --Shared plugins should load into memory for network messages.
	end
end

Shared.RegisterNetworkMessage( "Shine_PluginSync", ClientPlugins )
Shared.RegisterNetworkMessage( "Shine_PluginEnable", {
	Plugin = "string (25)",
	Enabled = "boolean"
} )

if Server then
	Shine.Hook.Add( "ClientConfirmConnect", "PluginSync", function( Client )
		local Message = {}

		for Name in pairs( ClientPlugins ) do
			if Shine.Plugins[ Name ] and Shine.Plugins[ Name ].Enabled then
				Message[ Name ] = true
			else
				Message[ Name ] = false
			end
		end

		Server.SendNetworkMessage( Client, "Shine_PluginSync", Message, true )
	end )
elseif Client then
	Client.HookNetworkMessage( "Shine_PluginSync", function( Data )
		for Name, Enabled in pairs( Data ) do
			if Enabled then
				Shine:EnableExtension( Name )
			end
		end
	end )

	Client.HookNetworkMessage( "Shine_PluginEnable", function( Data )
		local Name = Data.Plugin
		local Enabled = Data.Enabled

		if Enabled then
			Shine:EnableExtension( Name )
		else
			Shine:UnloadExtension( Name )
		end
	end )
end

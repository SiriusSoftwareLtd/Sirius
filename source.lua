--[[

Sirius

© 2026 Corridon Capital. 
All Rights Reserved.

--]]

--[[

Sirius Pre-Hyperion Todo List

High Priority
 - Invisible, Godmode
 - All Scripts buttons and Universal scripts
 - Chat Spam Detection
 - Custom Script Prompts
 - Player Kill, Spectate and ESP via Playerlist
 - http.request support for Sirius Intelligent HTTP Interception
 - Performance Improvements to Roblox itself
 
Moderate Priority
 - Spectate Animation, like GTA serverhop, tween to high in the sky, then tween to other player's head
 - Chat Spy Tracking: Follows who they're whispering to based on original message
 - Starlight 
 - Chatlogs
 - GTA Serverhop
 - Anti-Spam (chat) formula, based on text length, caps, emojis etc.
 - Reduce any form of detection of Sirius
 - Automated lowering of graphics on lower FPS, ensure no false positives
 
Potential Future Setting Options
 - Block entire domain or just the specific page in the Sirius Intelligent Flow Interception. Do this on case by case, e.g blocked = {"link.com", true} - true being whether its the domain or not
 - Serverhop type (default/gta)
 - Hook Specific Functions to reduce the need for external scripts
 
--]]

-- Ensure the game is loaded.
--
-- game.Loaded fires exactly once, so waiting on it after it has already fired blocks
-- forever. IsLoaded() guards that, but the two disagree on auto-execute: the signal has
-- gone while IsLoaded() still reads false, and Sirius stops here with no error, nothing on
-- screen and no way for the user to tell it ever ran. Polling the flag instead cannot miss
-- an edge, and the deadline means a client that never reports loaded costs a few seconds
-- rather than the whole launch.
if not game:IsLoaded() then
	local deadline = os.clock() + 10
	while not game:IsLoaded() and os.clock() < deadline do
		task.wait()
	end
end

-- Check License Tier
local Pro = true -- We're open sourced now!

-- Executor Feature Detection
-- Optional globals vary wildly between executors, so every one is resolved through a
-- typeof() check up front. Anything missing stays nil and every call site guards on it,
-- which stops a single absent function from aborting startup for the whole script.
local function optional(value)
	return typeof(value) == "function" and value or nil
end

local setFpsCap = optional(setfpscap)
local getExecutorName = optional(identifyexecutor)
local getCustomAsset = optional(getcustomasset)
local getConnectionsFor = optional(getconnections)
local hookMetamethod = optional(hookmetamethod)
local getHiddenUI = optional(gethui)
local cloneRef = optional(cloneref)
local getEnv = optional(getgenv)

-- The executor's shared environment. Falls back to _G so the caches and re-run sentinels
-- still have somewhere to live on executors that don't expose getgenv.
local env = getEnv and getEnv() or _G

-- Prefer the executor's own service clones where available; a cloneref'd handle isn't
-- reachable from the game's own scripts, which is what the "reduce detection" TODO wants.
local function getService(name)
	local service = game:GetService(name)
	return cloneRef and cloneRef(service) or service
end

-- Create Variables for Roblox Services
local coreGui = getService("CoreGui")
local httpService = getService("HttpService")
local lighting = getService("Lighting")
local players = getService("Players")
local replicatedStorage = getService("ReplicatedStorage")
local runService = getService("RunService")
local guiService = getService("GuiService")
local statsService = getService("Stats")
local starterGui = getService("StarterGui")
local teleportService = getService("TeleportService")
local tweenService = getService("TweenService")
local userInputService = getService("UserInputService")
local textChatService = getService("TextChatService")
local marketplaceService = getService("MarketplaceService")
local gameSettings = UserSettings():GetService("UserGameSettings")

local useStudio = runService:IsStudio()

-- Loads and executes a function hosted on a remote URL, cancelling the request if the URL
-- takes too long to respond. Ported from Rayfield so a slow CDN can't stall startup.
local function loadWithTimeout(url, timeout)
	assert(type(url) == "string", "Expected string, got " .. type(url))
	timeout = timeout or 5
	local requestCompleted = false
	local success, result = false, nil

	local requestThread = task.spawn(function()
		local fetchSuccess, fetchResult = pcall(game.HttpGet, game, url)
		-- A "successful" request can still come back empty
		if not fetchSuccess or #fetchResult == 0 then
			if fetchSuccess and #fetchResult == 0 then
				fetchResult = "Empty response"
			end
			success, result = false, fetchResult
			requestCompleted = true
			return
		end

		local execSuccess, execResult = pcall(function()
			return loadstring(fetchResult)()
		end)
		success, result = execSuccess, execResult
		requestCompleted = true
	end)

	local timeoutThread = task.delay(timeout, function()
		if not requestCompleted then
			warn("Sirius | Request for " .. url .. " timed out after " .. tostring(timeout) .. " seconds")
			task.cancel(requestThread)
			result = "Request timed out"
			requestCompleted = true
		end
	end)

	while not requestCompleted do
		task.wait()
	end

	if coroutine.status(timeoutThread) ~= "dead" then
		task.cancel(timeoutThread)
	end

	if not success then
		warn("Sirius | Failed to process " .. tostring(url) .. ": " .. tostring(result))
		return nil
	end

	return result
end

-- Every connection Sirius opens is registered here so teardown can close all of them at once.
local connections = {}
local function track(connection)
	table.insert(connections, connection)
	return connection
end

-- Case-insensitive literal replace. string.gsub treats its needle as a Lua pattern, so names
-- containing -, ., ( or % broke or errored; this walks plain-text matches instead.
local function replacePlain(haystack, needleLower, replacement)
	if needleLower == "" then
		return haystack
	end

	local lowered = string.lower(haystack)
	local out, cursor = {}, 1

	while true do
		local startIndex, endIndex = string.find(lowered, needleLower, cursor, true)
		if not startIndex then
			break
		end

		table.insert(out, string.sub(haystack, cursor, startIndex - 1))
		table.insert(out, replacement)
		cursor = endIndex + 1
	end

	if cursor == 1 then
		return haystack
	end

	table.insert(out, string.sub(haystack, cursor))
	return table.concat(out)
end

-- Shortens a value for display only. The stored value is never overwritten with the result.
local function truncateForDisplay(value, limit)
	local text = tostring(value)
	limit = limit or 24
	if #text <= limit then
		return text
	end
	return string.sub(text, 1, limit - 2) .. ".."
end

-- Variables
local camera = workspace.CurrentCamera
local getMessage = replicatedStorage:WaitForChild("DefaultChatSystemChatEvents", 1) and replicatedStorage.DefaultChatSystemChatEvents:WaitForChild("OnMessageDoneFiltering", 1)
-- Roblox retired the legacy chat system; anything built on DefaultChatSystemChatEvents only
-- works in experiences still opted into it. Checked once here rather than at each call site.
local legacyChatActive = getMessage ~= nil and textChatService.ChatVersion == Enum.ChatVersion.LegacyChatService
local localPlayer = players.LocalPlayer
local notifications = {}
local friendsCooldown = 0
local promptedDisconnected = false
local smartBarOpen = false
local debounce = false
local searchingForPlayer = false
local musicQueue = {}
local playGeneration = 0 -- bumped to invalidate parked Ended:Wait coroutines in playNext
local currentAudio
local lowerName = localPlayer.Name:lower()
local lowerDisplayName = localPlayer.DisplayName:lower()
local placeId = game.PlaceId
local jobId = game.JobId
local checkingForKey
local originalTextValues = {}
local creatorId = game.CreatorId
local noclipDefaults = {}
local movers = {}
local creatorType = game.CreatorType
local espContainer = Instance.new("Folder", getHiddenUI and getHiddenUI() or coreGui)
espContainer.Name = "SiriusESP"
local locatedPlayers = {} -- per-player ESP toggles, independent from the global ESP action
local espConnections = {} -- [player] = RBXScriptConnection for CharacterAdded
local descendantAddedConn -- top-level DescendantAdded; tracked so we can disconnect on teardown
local oldVolume = gameSettings.MasterVolume
local baseFieldOfView = camera.FieldOfView -- captured once; Home restores to this rather than doing relative maths
local homeFieldOfView -- the FOV in effect when Home was last opened
local placeName -- resolved once at startup so the JobId copy button never yields on click

-- Configurable Core Values
local siriusValues = {
	siriusVersion = "1.28",
	siriusName = "Sirius",
	releaseType = "Stable",
	siriusFolder = "Sirius",
	settingsFile = "settings.srs",
	interfaceAsset = 14183548964,
	cdn = "https://cdn.sirius.menu/SIRIUS-SCRIPT-CORE-ASSETS/",
	icons = "https://cdn.sirius.menu/SIRIUS-SCRIPT-CORE-ASSETS/Icons/",
	-- The per-experience game scripts, the neon module and the sense ESP library were all
	-- removed: their URLs pointed at a branch that no longer exists and at the retired
	-- shlexware org, so every fetch 404'd. Experience Sync went with them.
	executors = {
		"synapse x",
		"script-ware",
		"krnl",
		"scriptware",
		"comet",
		"valyse",
		"fluxus",
		"electron",
		"hydrogen",
		"wave",
		"solara",
		"xeno",
		"swift",
		"delta",
		"codex",
		"arceus x",
		"trigon",
		"vegax",
		"cryptic",
	},
	disconnectTypes = { { "ban", { "ban", "perm" } }, { "network", { "internet connection", "network" } } },
	nameGeneration = {
		adjectives = { "Cool", "Awesome", "Epic", "Ninja", "Super", "Mystic", "Swift", "Golden", "Diamond", "Silver", "Mint", "Roblox", "Amazing" },
		nouns = { "Player", "Gamer", "Master", "Legend", "Hero", "Ninja", "Wizard", "Champion", "Warrior", "Sorcerer" },
	},
	administratorRoles = { "mod", "admin", "staff", "dev", "founder", "owner", "supervis", "manager", "management", "executive", "president", "chairman", "chairwoman", "chairperson", "director" },
	transparencyProperties = {
		UIStroke = { "Transparency" },
		Frame = { "BackgroundTransparency" },
		TextButton = { "BackgroundTransparency", "TextTransparency" },
		TextLabel = { "BackgroundTransparency", "TextTransparency" },
		TextBox = { "BackgroundTransparency", "TextTransparency" },
		ImageLabel = { "BackgroundTransparency", "ImageTransparency" },
		ImageButton = { "BackgroundTransparency", "ImageTransparency" },
		ScrollingFrame = { "BackgroundTransparency", "ScrollBarImageTransparency" },
	},
	buttonPositions = { Character = UDim2.new(0.5, -155, 1, -29), Scripts = UDim2.new(0.5, -122, 1, -29), Playerlist = UDim2.new(0.5, -68, 1, -29) },
	chatSpy = {
		enabled = true,
		visual = {
			Color = Color3.fromRGB(26, 148, 255),
			Font = Enum.Font.SourceSansBold,
			TextSize = 18,
		},
	},
	pingProfile = {
		recentPings = {},
		adaptiveBaselinePings = {},
		pingNotificationCooldown = 0,
		maxSamples = 12, -- max num of recent pings stored
		spikeThreshold = 1.75, -- high Ping in comparison to average ping (e.g 100 avg would be high at 150)
		adaptiveBaselineSamples = 30, -- how many samples Sirius takes before deciding on a fixed high ping value
		adaptiveHighPingThreshold = 120, -- default value
	},
	frameProfile = {
		frameNotificationCooldown = 0,
		fpsQueueSize = 10,
		lowFPSThreshold = 20, -- what's low fps!??!?!
		totalFPS = 0,
		fpsQueue = {},
	},
	actions = {
		{
			name = "Noclip",
			images = { 14385986465, 9134787693 },
			color = Color3.fromRGB(0, 170, 127),
			enabled = false,
			rotateWhileEnabled = false,
			callback = function() end,
		},
		{
			name = "Flight",
			images = { 9134755504, 14385992605 },
			color = Color3.fromRGB(170, 37, 46),
			enabled = false,
			rotateWhileEnabled = false,
			callback = function(value)
				local character = localPlayer.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid.PlatformStand = value
				end
			end,
		},
		{
			name = "Refresh",
			images = { 9134761478, 9134761478 },
			color = Color3.fromRGB(61, 179, 98),
			enabled = false,
			rotateWhileEnabled = true,
			disableAfter = 3,
			callback = function()
				task.spawn(function()
					local character = localPlayer.Character
					if character then
						local cframe = character:GetPivot()
						local humanoid = character:FindFirstChildOfClass("Humanoid")
						if humanoid then
							humanoid:ChangeState(Enum.HumanoidStateType.Dead)
						end
						character = localPlayer.CharacterAdded:Wait()
						task.defer(character.PivotTo, character, cframe)
					end
				end)
			end,
		},
		{
			name = "Respawn",
			images = { 9134762943, 9134762943 },
			color = Color3.fromRGB(49, 88, 193),
			enabled = false,
			rotateWhileEnabled = true,
			disableAfter = 2,
			callback = function()
				local character = localPlayer.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then
					humanoid:ChangeState(Enum.HumanoidStateType.Dead)
				end
			end,
		},
		{
			name = "Invulnerability",
			images = { 9134765994, 14386216487 },
			color = Color3.fromRGB(193, 46, 90),
			enabled = false,
			rotateWhileEnabled = false,
			callback = function() end,
		},
		{
			name = "Fling",
			images = { 9134785384, 14386226155 },
			color = Color3.fromRGB(184, 85, 61),
			enabled = false,
			rotateWhileEnabled = true,
			callback = function(value)
				local character = localPlayer.Character
				local primaryPart = character and character.PrimaryPart
				if primaryPart then
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Massless = value
							part.CustomPhysicalProperties = PhysicalProperties.new(value and math.huge or 0.7, 0.3, 0.5)
						end
					end

					primaryPart.Anchored = true
					primaryPart.AssemblyLinearVelocity = Vector3.zero
					primaryPart.AssemblyAngularVelocity = Vector3.zero

					if movers[3] then
						movers[3].Parent = value and primaryPart or nil
					end

					task.delay(0.5, function()
						primaryPart.Anchored = false
					end)
				end
			end,
		},
		{
			name = "Extrasensory Perception",
			images = { 9134780101, 14386232387 },
			color = Color3.fromRGB(214, 182, 19),
			enabled = false,
			rotateWhileEnabled = false,
			callback = function(value)
				for _, highlight in ipairs(espContainer:GetChildren()) do
					highlight.Enabled = value or locatedPlayers[highlight.Name] == true
				end
			end,
		},
		{
			name = "Night and Day",
			images = { 9134778004, 10137794784 },
			color = Color3.fromRGB(102, 75, 190),
			enabled = false,
			rotateWhileEnabled = false,
			callback = function(value)
				tweenService:Create(lighting, TweenInfo.new(0.5), { ClockTime = value and 12 or 24 }):Play()
			end,
		},
		{
			name = "Global Audio",
			images = { 9134774810, 14386246782 },
			color = Color3.fromRGB(202, 103, 58),
			enabled = false,
			rotateWhileEnabled = false,
			callback = function(value)
				if value then
					oldVolume = gameSettings.MasterVolume
					gameSettings.MasterVolume = 0
				else
					gameSettings.MasterVolume = oldVolume
				end
			end,
		},
		{
			name = "Visibility",
			images = { 14386256326, 9134770786 },
			color = Color3.fromRGB(62, 94, 170),
			enabled = false,
			rotateWhileEnabled = false,
			callback = function() end,
		},
	},
	sliders = {
		{
			name = "player speed",
			color = Color3.fromRGB(44, 153, 93),
			values = { 0, 300 },
			default = 16,
			value = 16,
			active = false,
			callback = function(value)
				local character = localPlayer.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then -- was `if character`, which let a Humanoid-less character through
					humanoid.WalkSpeed = value
				end
			end,
		},
		{
			name = "jump power",
			color = Color3.fromRGB(59, 126, 184),
			values = { 0, 350 },
			default = 50,
			value = 16,
			active = false,
			callback = function(value)
				local character = localPlayer.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if humanoid then -- was `if character`, which let a Humanoid-less character through
					if humanoid.UseJumpPower then
						humanoid.JumpPower = value
					else
						humanoid.JumpHeight = value
					end
				end
			end,
		},
		{
			name = "flight speed",
			color = Color3.fromRGB(177, 45, 45),
			values = { 1, 25 },
			default = 3,
			value = 3,
			active = false,
			callback = function() end, -- read directly by the Heartbeat flight loop
		},
		{
			name = "field of view",
			color = Color3.fromRGB(198, 178, 75),
			values = { 45, 120 },
			default = 70,
			value = 16,
			active = false,
			callback = function(value)
				tweenService:Create(camera, TweenInfo.new(0.6, Enum.EasingStyle.Exponential), { FieldOfView = value }):Play()
			end,
		},
	},
}

local siriusSettings = {
	{
		name = "General",
		description = "The general settings for Sirius, from simple to unique features.",
		color = Color3.new(0.117647, 0.490196, 0.72549),
		minimumLicense = "Free",
		categorySettings = {
			{
				name = "Anonymous Client",
				description = "Randomise your username in real-time in any CoreGui parented interface, including Sirius. You will still appear as your actual name to others in-game. This setting can be performance intensive.",
				settingType = "Boolean",
				current = false,

				id = "anonmode",
			},
			{
				name = "Chat Spy",
				description = "Display whispers usually hidden from you in the chat box. This requires the legacy Roblox chat system; experiences on TextChatService route whispers through channels the client never receives, so Sirius will tell you when it is unavailable rather than silently doing nothing.",
				settingType = "Boolean",
				current = true,

				id = "chatspy",
			},
			{
				name = "Hide Toggle Button",
				description = "This will remove the option to open the smartBar with the toggle button.",
				settingType = "Boolean",
				current = false,

				id = "hidetoggle",
			},
			{
				name = "Now Playing Notifications",
				description = "When active, Sirius will notify you when the next song in your Music queue plays.",
				settingType = "Boolean",
				current = true,

				id = "nowplaying",
			},
			{
				name = "Friend Notifications",
				settingType = "Boolean",
				current = true,

				id = "friendnotifs",
			},
			{
				name = "Load Hidden",
				settingType = "Boolean",
				current = false,

				id = "loadhidden",
			},
			{
				name = "Startup Sound Effect",
				settingType = "Boolean",
				current = true,

				id = "startupsound",
			},
			{
				name = "Anti Idle",
				description = "Remove all callbacks and events linked to the LocalPlayer Idled state. This may prompt detection from Adonis or similar anti-cheats.",
				settingType = "Boolean",
				current = true,

				id = "antiidle",
			},
			{
				name = "Client-Based Anti Kick",
				description = "Cancel any kick request involving you sent by the client. This may prompt detection from Adonis or similar anti-cheats. You will need to rejoin and re-run Sirius to toggle.",
				settingType = "Boolean",
				current = false,

				id = "antikick",
			},
			{
				name = "Muffle audio while unfocused",
				settingType = "Boolean",
				current = true,

				id = "muffleunfocused",
			},
		},
	},
	{
		name = "Keybinds",
		description = "Assign keybinds to actions or change keybinds such as the one to open/close Sirius.",
		color = Color3.new(0.0941176, 0.686275, 0.509804),
		minimumLicense = "Free",
		categorySettings = {
			{
				name = "Toggle smartBar",
				settingType = "Key",
				current = "K",
				id = "smartbar",
			},
			{
				name = "Open ScriptSearch",
				settingType = "Key",
				current = "T",
				id = "scriptsearch",
			},
			{
				name = "NoClip",
				settingType = "Key",
				current = nil,
				id = "noclip",
				actionIndex = 1,
				callback = function()
					local noclip = siriusValues.actions[1]
					noclip.enabled = not noclip.enabled
					noclip.callback(noclip.enabled)
				end,
			},
			{
				name = "Flight",
				settingType = "Key",
				current = nil,
				id = "flight",
				actionIndex = 2,
				callback = function()
					local flight = siriusValues.actions[2]
					flight.enabled = not flight.enabled
					flight.callback(flight.enabled)
				end,
			},
			{
				name = "Refresh",
				settingType = "Key",
				current = nil,
				id = "refresh",
				actionIndex = 3,
				callback = function()
					local refresh = siriusValues.actions[3]
					if not refresh.enabled then
						refresh.enabled = true
						refresh.callback()
					end
				end,
			},
			{
				name = "Respawn",
				settingType = "Key",
				current = nil,
				id = "respawn",
				actionIndex = 4,
				callback = function()
					local respawn = siriusValues.actions[4]
					if not respawn.enabled then
						respawn.enabled = true
						respawn.callback()
					end
				end,
			},
			{
				name = "Invulnerability",
				settingType = "Key",
				current = nil,
				id = "invulnerability",
				actionIndex = 5,
				callback = function()
					local invulnerability = siriusValues.actions[5]
					invulnerability.enabled = not invulnerability.enabled
					invulnerability.callback(invulnerability.enabled)
				end,
			},
			{
				name = "Fling",
				settingType = "Key",
				current = nil,
				id = "fling",
				actionIndex = 6,
				callback = function()
					local fling = siriusValues.actions[6]
					fling.enabled = not fling.enabled
					fling.callback(fling.enabled)
				end,
			},
			{
				name = "ESP",
				settingType = "Key",
				current = nil,
				id = "esp",
				actionIndex = 7,
				callback = function()
					local esp = siriusValues.actions[7]
					esp.enabled = not esp.enabled
					esp.callback(esp.enabled)
				end,
			},
			{
				name = "Night and Day",
				settingType = "Key",
				current = nil,
				id = "nightandday",
				actionIndex = 8,
				callback = function()
					local nightandday = siriusValues.actions[8]
					nightandday.enabled = not nightandday.enabled
					nightandday.callback(nightandday.enabled)
				end,
			},
			{
				name = "Global Audio",
				settingType = "Key",
				current = nil,
				id = "globalaudio",
				actionIndex = 9,
				callback = function()
					local globalaudio = siriusValues.actions[9]
					globalaudio.enabled = not globalaudio.enabled
					globalaudio.callback(globalaudio.enabled)
				end,
			},
			{
				name = "Visibility",
				settingType = "Key",
				current = nil,
				id = "visibility",
				actionIndex = 10,
				callback = function()
					local visibility = siriusValues.actions[10]
					visibility.enabled = not visibility.enabled
					visibility.callback(visibility.enabled)
				end,
			},
		},
	},
	{
		name = "Performance",
		description = "Tweak and test your performance settings for Roblox in Sirius.",
		color = Color3.new(1, 0.376471, 0.168627),
		minimumLicense = "Free",
		categorySettings = {
			{
				name = "Artificial FPS Limit",
				description = "Sirius will automatically set your FPS to this number when you are tabbed-in to Roblox.",
				settingType = "Number",
				values = { 20, 5000 },
				current = 240,

				id = "fpscap",
			},
			{
				name = "Limit FPS while unfocused",
				description = "Sirius will automatically set your FPS to 60 when you tab-out or unfocus from Roblox.",
				settingType = "Boolean", -- number for the cap below!! with min and max val
				current = true,

				id = "fpsunfocused",
			},
			{
				name = "Adaptive Latency Warning",
				description = "Sirius will check your average latency in the background and notify you if your current latency significantly goes above your average latency.",
				settingType = "Boolean",
				current = true,

				id = "latencynotif",
			},
			{
				name = "Adaptive Performance Warning",
				description = "Sirius will check your average FPS in the background and notify you if your current FPS goes below a specific number.",
				settingType = "Boolean",
				current = true,

				id = "fpsnotif",
			},
		},
	},
	{
		name = "Detections",
		description = "Sirius detects and prevents anything malicious or possibly harmful to your wellbeing.",
		color = Color3.new(0.705882, 0, 0),
		minimumLicense = "Free",
		categorySettings = {
			{
				name = "Spatial Shield",
				description = "Suppress loud sounds played from any audio source in-game, in real-time with Spatial Shield.",
				settingType = "Boolean",
				minimumLicense = "Pro",
				current = true,

				id = "spatialshield",
			},
			{
				name = "Spatial Shield Threshold",
				description = "How loud a sound needs to be to be suppressed.",
				settingType = "Number",
				minimumLicense = "Pro",
				values = { 100, 1000 },
				current = 300,

				id = "spatialshieldthreshold",
			},
			{
				name = "Moderator Detection",
				description = "Be notified whenever Sirius detects a player joins your session that could be a game moderator.",
				settingType = "Boolean",
				minimumLicense = "Pro",
				current = true,

				id = "moddetection",
			},
			{
				name = "Intelligent HTTP Interception",
				description = "Block external HTTP/HTTPS requests from being sent/recieved and ask you before allowing it to run.",
				settingType = "Boolean",
				minimumLicense = "Essential",
				current = true,

				id = "intflowintercept",
			},
			{
				name = "Intelligent Clipboard Interception",
				description = "Block your clipboard from being set and ask you before allowing it to set your clipboard.",
				settingType = "Boolean",
				minimumLicense = "Essential",
				current = true,

				id = "intflowinterceptclip",
			},
		},
	},
	{
		name = "Logging",
		description = "Send logs to your specified webhook URL of things like player joins and leaves and messages.",
		color = Color3.new(0.905882, 0.780392, 0.0666667),
		minimumLicense = "Free",
		categorySettings = {
			{
				name = "Log Messages",
				description = "Log messages sent by any player to your webhook.",
				settingType = "Boolean",
				current = false,

				id = "logmsg",
			},
			{
				name = "Message Webhook URL",
				description = "Discord Webhook URL",
				settingType = "Input",
				current = "No Webhook",

				id = "logmsgurl",
			},
			{
				name = "Log PlayerAdded and PlayerRemoving",
				description = "Log whenever any player leaves or joins your session.",
				settingType = "Boolean",
				current = false,

				id = "logplrjoinleave",
			},
			{
				name = "Player Added and Removing Webhook URL",
				description = "Discord Webhook URL",
				settingType = "Input",
				current = "No Webhook",

				id = "logplrjoinleaveurl",
			},
		},
	},
}

-- Generate random username
local randomAdjective = siriusValues.nameGeneration.adjectives[math.random(1, #siriusValues.nameGeneration.adjectives)]
local randomNoun = siriusValues.nameGeneration.nouns[math.random(1, #siriusValues.nameGeneration.nouns)]
local randomNumber = math.random(100, 3999) -- You can customize the range
local randomUsername = randomAdjective .. randomNoun .. randomNumber

-- Initialise Sirius Client Interface
local guiParent = getHiddenUI and getHiddenUI() or (useStudio and localPlayer:WaitForChild("PlayerGui")) or coreGui
local sirius = guiParent:FindFirstChild("Sirius")
if sirius then
	sirius:Destroy()
end

-- In Studio there's no GetObjects, so the interface is expected to sit next to this script.
local function loadInterface()
	if useStudio then
		local container = script.Parent
		return container and container:FindFirstChild(siriusValues.siriusName)
	end
	-- Indexing [1] directly threw its own error when the fetch came back empty, which
	-- then read as "GetObjects is broken" rather than "the asset didn't arrive".
	local objects = game:GetObjects("rbxassetid://" .. siriusValues.interfaceAsset)
	return objects and objects[1]
end

-- GetObjects has two distinct failure modes and they used to share one silent exit: it can
-- throw, or it can succeed and hand back an empty table because the asset did not come down
-- for this client. The second is transient and worth retrying; neither is worth ending the
-- script over without telling anyone.
local uiResult, uiError
for attempt = 1, 3 do
	local success, result = pcall(loadInterface)
	if success and result then
		uiResult = result
		break
	end
	uiError = success and "the interface asset returned nothing" or tostring(result)
	if attempt < 3 then
		task.wait(attempt)
	end
end

-- The old message named only the pcall's error value, so the empty-asset case printed
-- "nil" and said nothing about what had gone wrong. Both causes are spelled out now, and
-- the line says Sirius is stopping -- the previous wording read as a warning about a
-- missing extra rather than the end of the launch.
if not uiResult then
	warn("Sirius | Couldn't load the interface asset after 3 attempts (" .. tostring(uiError) .. "). Sirius has not started.")
	return
end

local UI = uiResult
UI.Name = siriusValues.siriusName
UI.Parent = guiParent
UI.Enabled = false

-- Create Variables for Interface Elements
local characterPanel = UI.Character
local customScriptPrompt = UI.CustomScriptPrompt
local securityPrompt = UI.SecurityPrompt
local disconnectedPrompt = UI.Disconnected
local gameDetectionPrompt = UI.GameDetection
local homeContainer = UI.Home
local moderatorDetectionPrompt = UI.ModeratorDetectionPrompt
local musicPanel = UI.Music
local notificationContainer = UI.Notifications
local playerlistPanel = UI.Playerlist
local scriptSearch = UI.ScriptSearch
local scriptsPanel = UI.Scripts
local settingsPanel = UI.Settings
local smartBar = UI.SmartBar
local toggle = UI.Toggle
local toastsContainer = UI.Toasts

-- Interface Caching
-- Reset per run: carrying a previous session's list over means closing Home re-enables
-- interfaces the current experience never had open.
env.cachedInGameUI = {}
env.cachedCoreUI = {}

-- Malicious Behavior Prevention
--
-- Both interception hooks replace a global, so a second execution would otherwise wrap
-- Sirius' own wrapper and show one prompt per run. The pristine functions are stashed under
-- a sentinel on first run and re-read on every run after that, so re-executing is idempotent.
local indexSetClipboard = "setclipboard"

-- Widened to match Rayfield: several executors only expose their request function under a
-- namespace, and the old two-entry check left originalRequest nil on those.
local index = (http_request and "http_request") or "request"
local rawRequest = env.request or env.http_request or (env.http and env.http.request) or (env.syn and env.syn.request) or (env.fluxus and env.fluxus.request)

if env.siriusOriginals == nil then
	env.siriusOriginals = {
		request = rawRequest,
		setclipboard = env[indexSetClipboard],
	}
end

local originalRequest = env.siriusOriginals.request
local originalSetClipboard = env.siriusOriginals.setclipboard

-- put this into siriusValues, like the fps and ping shit
local suppressedSounds = {}
local soundSuppressionNotificationCooldown = 0
local soundInstances = {}
local trackedSounds = {} -- [Sound] = true, replaces the linear table.find scan
local trackedText = {} -- [TextLabel|TextButton] = true
local cachedIds = {}
local cachedText = {}

if not legacyChatActive then
	siriusValues.chatSpy.enabled = false
end

-- Call External Modules

-- httpRequest
local httpRequest = originalRequest

-- Sirius Functions
local function checkSirius()
	return UI.Parent
end

local function getPing()
	local success, ping = pcall(function()
		return statsService.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	return success and math.clamp(ping, 10, 700) or 0
end

-- Parents are created before their children; the old ordering made Assets/Icons first, which
-- failed on executors that don't create intermediate directories and then skipped Assets
-- entirely on the ones that do.
local function checkFolder()
	if not (isfolder and makefolder) then
		return
	end

	local root = siriusValues.siriusFolder
	for _, path in ipairs({ root, root .. "/Music", root .. "/Assets", root .. "/Assets/Icons" }) do
		if not isfolder(path) then
			makefolder(path)
		end
	end

	if writefile and isfile and not isfile(root .. "/Music/readme.txt") then
		writefile(root .. "/Music/readme.txt", "Hey there! Place your MP3 or other audio files in this folder, and have the ability to play them through the Sirius Music UI!")
	end
end

local function isPanel(name)
	return not table.find({ "Home", "Music", "Settings" }, name)
end

-- Both fetchers used to `return` from inside their pcall closure, so the value never left the
-- function and every caller saw nil.
local function fetchFromCDN(path, write, savePath)
	local success, file = pcall(game.HttpGet, game, siriusValues.cdn .. path)
	if not success or not file or #file == 0 then
		return nil
	end

	if not write then
		return file
	end
	if not writefile then
		return file
	end

	checkFolder()
	pcall(writefile, siriusValues.siriusFolder .. "/" .. savePath, file)

	return file
end

local function storeOriginalText(element)
	if originalTextValues[element] == nil then
		originalTextValues[element] = element.Text
	end
end

local function undoAnonymousChanges()
	for element, originalText in pairs(originalTextValues) do
		element.Text = originalText
	end
end

local function isHighlightEnabledFor(playerName)
	return siriusValues.actions[7].enabled or locatedPlayers[playerName] == true
end

local function createEsp(player)
	if player == localPlayer or not checkSirius() then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 0
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.Adornee = player.Character
	highlight.Name = player.Name
	highlight.Enabled = isHighlightEnabledFor(player.Name)
	highlight.Parent = espContainer

	if espConnections[player] then
		espConnections[player]:Disconnect()
	end
	espConnections[player] = player.CharacterAdded:Connect(function(character)
		if not checkSirius() then
			return
		end
		task.wait()
		highlight.Adornee = character
	end)
end

local function makeDraggable(object)
	local dragging = false
	local relative = nil

	local offset = Vector2.zero
	local screenGui = object:FindFirstAncestorWhichIsA("ScreenGui")
	if screenGui and screenGui.IgnoreGuiInset then
		offset += guiService:GetGuiInset()
	end

	object.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		local inputType = input.UserInputType.Name
		if inputType == "MouseButton1" or inputType == "Touch" then
			relative = object.AbsolutePosition + object.AbsoluteSize * object.AnchorPoint - userInputService:GetMouseLocation()
			dragging = true
		end
	end)

	local inputEnded = userInputService.InputEnded:Connect(function(input)
		if not dragging then
			return
		end

		local inputType = input.UserInputType.Name
		if inputType == "MouseButton1" or inputType == "Touch" then
			dragging = false
		end
	end)

	local renderStepped = runService.RenderStepped:Connect(function()
		if dragging then
			local position = userInputService:GetMouseLocation() + relative + offset
			object.Position = UDim2.fromOffset(position.X, position.Y)
		end
	end)

	object.Destroying:Connect(function()
		inputEnded:Disconnect()
		renderStepped:Disconnect()
	end)
end

-- Looks up the grid button for an action. The old checkAction matched the *setting* name against
-- the *action* name and always returned a table even on a miss, so callers' `if action then`
-- guard never fired. Two names never matched ('NoClip' vs 'Noclip', 'ESP' vs 'Extrasensory
-- Perception'), which meant those keybinds threw on every press.
local function actionButton(action)
	if not action then
		return nil
	end
	return characterPanel.Interactions.Grid:FindFirstChild(action.name)
end

-- The category-scoped form used to `return` after examining the first category regardless of
-- whether it matched, so scoped lookups only worked when the target happened to be first.
local function checkSetting(settingTarget, categoryTarget)
	for _, category in ipairs(siriusSettings) do
		if not categoryTarget or category.name == categoryTarget then
			for _, setting in ipairs(category.categorySettings) do
				if setting.name == settingTarget then
					return setting
				end
			end
		end
	end

	return nil
end

-- Every checkSetting caller immediately reads .current, so a typo'd or removed name used to
-- throw at the call site. Callers get a stable default instead.
local function settingValue(settingTarget, fallback)
	local setting = checkSetting(settingTarget)
	if setting == nil or setting.current == nil then
		return fallback
	end
	return setting.current
end

local function wipeTransparency(ins, target, checkSelf, tween, duration)
	local transparencyProperties = siriusValues.transparencyProperties

	local function applyTransparency(obj)
		-- ClassName / GetDescendants; the lowercase aliases are deprecated legacy spellings
		local properties = transparencyProperties[obj.ClassName]

		if properties then
			local tweenProperties = {}

			for _, property in ipairs(properties) do
				tweenProperties[property] = target
			end

			for property, transparency in pairs(tweenProperties) do
				if tween then
					tweenService:Create(obj, TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { [property] = transparency }):Play()
				else
					obj[property] = transparency
				end
			end
		end
	end

	if checkSelf then
		applyTransparency(ins)
	end

	for _, descendant in ipairs(ins:GetDescendants()) do
		applyTransparency(descendant)
	end
end

local function blurSignature(value)
	if not value then
		if lighting:FindFirstChild("SiriusBlur") then
			lighting:FindFirstChild("SiriusBlur"):Destroy()
		end
	else
		if not lighting:FindFirstChild("SiriusBlur") then
			local blurLight = Instance.new("DepthOfFieldEffect", lighting)
			blurLight.Name = "SiriusBlur"
			blurLight.Enabled = true
			blurLight.FarIntensity = 0
			blurLight.FocusDistance = 51.6
			blurLight.InFocusRadius = 50
			blurLight.NearIntensity = 0.8
		end
	end
end

local function figureNotifications()
	if checkSirius() then
		local notificationsSize = 0

		if #notifications > 0 then
			blurSignature(true)
		else
			blurSignature(false)
		end

		for i = #notifications, 1, -1 do
			local notification = notifications[i]
			if notification then
				if notificationsSize == 0 then
					notificationsSize = notification.Size.Y.Offset + 2
				else
					notificationsSize += notification.Size.Y.Offset + 5
				end
				local desiredPosition = UDim2.new(0.5, 0, 0, notificationsSize)
				if notification.Position ~= desiredPosition then
					notification:TweenPosition(desiredPosition, "Out", "Quint", 0.8, true)
				end
			end
		end
	end
end

local function queueNotification(Title, Description, Image)
	task.spawn(function()
		if checkSirius() then
			local newNotification = notificationContainer.Template:Clone()
			newNotification.Parent = notificationContainer
			newNotification.Name = Title or "Unknown Title"
			newNotification.Visible = true

			newNotification.Title.Text = Title or "Unknown Title"
			newNotification.Description.Text = Description or "Unknown Description"
			newNotification.Time.Text = "now"

			-- Prepare for animation
			newNotification.AnchorPoint = Vector2.new(0.5, 1)
			newNotification.Position = UDim2.new(0.5, 0, -1, 0)
			newNotification.Size = UDim2.new(0, 320, 0, 500)
			newNotification.Description.Size = UDim2.new(0, 241, 0, 400)
			wipeTransparency(newNotification, 1, true)

			newNotification.Description.Size = UDim2.new(0, 241, 0, newNotification.Description.TextBounds.Y)
			newNotification.Size = UDim2.new(0, 100, 0, newNotification.Description.TextBounds.Y + 50)

			table.insert(notifications, newNotification)
			figureNotifications()

			local notificationSound = Instance.new("Sound")
			notificationSound.Parent = UI
			notificationSound.SoundId = "rbxassetid://255881176"
			notificationSound.Name = "notificationSound"
			notificationSound.Volume = 0.65
			notificationSound.PlayOnRemove = true
			notificationSound:Destroy()

			if not tonumber(Image) then
				newNotification.Icon.Image = "rbxassetid://14317577326"
			else
				newNotification.Icon.Image = "rbxassetid://" .. tostring(Image)
			end

			newNotification:TweenPosition(UDim2.new(0.5, 0, 0, newNotification.Size.Y.Offset + 2), "Out", "Quint", 0.9, true)
			task.wait(0.1)
			tweenService:Create(newNotification, TweenInfo.new(0.8, Enum.EasingStyle.Exponential), { Size = UDim2.new(0, 320, 0, newNotification.Description.TextBounds.Y + 50) }):Play()
			task.wait(0.05)
			tweenService:Create(newNotification, TweenInfo.new(0.8, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.35 }):Play()
			tweenService:Create(newNotification.UIStroke, TweenInfo.new(0.6, Enum.EasingStyle.Exponential), { Transparency = 0.7 }):Play()
			task.wait(0.05)
			tweenService:Create(newNotification.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), { ImageTransparency = 0 }):Play()
			task.wait(0.04)
			tweenService:Create(newNotification.Title, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), { TextTransparency = 0 }):Play()
			task.wait(0.04)
			tweenService:Create(newNotification.Description, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), { TextTransparency = 0.15 }):Play()
			tweenService:Create(newNotification.Time, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), { TextTransparency = 0.5 }):Play()

			newNotification.Interact.MouseButton1Click:Connect(function()
				local foundNotification = table.find(notifications, newNotification)
				if foundNotification then
					table.remove(notifications, foundNotification)
				end

				tweenService
					:Create(newNotification, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Position = UDim2.new(1.5, 0, 0, newNotification.Position.Y.Offset) })
					:Play()

				task.wait(0.4)
				newNotification:Destroy()
				figureNotifications()
				return
			end)

			local waitTime = (#newNotification.Description.Text * 0.1) + 2
			if waitTime <= 1 then
				waitTime = 2.5
			elseif waitTime > 10 then
				waitTime = 10
			end

			task.wait(waitTime)

			local foundNotification = table.find(notifications, newNotification)
			if foundNotification then
				table.remove(notifications, foundNotification)
			end

			tweenService:Create(newNotification, TweenInfo.new(0.8, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Position = UDim2.new(1.5, 0, 0, newNotification.Position.Y.Offset) }):Play()

			task.wait(1.2)
			newNotification:Destroy()
			figureNotifications()
		end
	end)
end

local function checkLastVersion()
	checkFolder()

	local lastVersion = isfile and isfile(siriusValues.siriusFolder .. "/" .. "version.srs") and readfile(siriusValues.siriusFolder .. "/" .. "version.srs") or nil

	if lastVersion then
		if lastVersion ~= siriusValues.siriusVersion then
			queueNotification("Sirius has been updated", "Sirius has been updated to version " .. siriusValues.siriusVersion .. ", check our Discord for all new features and changes.", 4400701828)
		end
	end

	if writefile then
		writefile(siriusValues.siriusFolder .. "/" .. "version.srs", siriusValues.siriusVersion)
	end
end

local function removeReverbs(timing)
	timing = timing or 0.65

	for _, sound in ipairs(soundInstances) do
		if sound:FindFirstChild("SiriusAudioProfile") then
			local reverb = sound:FindFirstChild("SiriusAudioProfile")
			tweenService:Create(reverb, TweenInfo.new(timing, Enum.EasingStyle.Exponential), { HighGain = 0 }):Play()
			tweenService:Create(reverb, TweenInfo.new(timing, Enum.EasingStyle.Exponential), { LowGain = 0 }):Play()
			tweenService:Create(reverb, TweenInfo.new(timing, Enum.EasingStyle.Exponential), { MidGain = 0 }):Play()

			task.delay(timing + 0.03, reverb.Destroy, reverb)
		end
	end
end

-- Iterative rather than recursive: the old version called itself once per track, and because
-- that call wasn't in tail position the stack grew for the whole length of the queue.
local function playNext()
	playGeneration += 1
	local thisGen = playGeneration

	while true do
		if #musicQueue == 0 then
			if currentAudio then
				currentAudio.Playing = false
				currentAudio.SoundId = ""
			end
			musicPanel.Playing.Text = "Not Playing"
			return
		end

		if not currentAudio then
			local newAudio = Instance.new("Sound")
			newAudio.Parent = UI
			newAudio.Name = "Audio"
			currentAudio = newAudio
		end

		local entry = musicQueue[1]
		local assetSuccess, asset = pcall(getCustomAsset, siriusValues.siriusFolder .. "/Music/" .. entry.sound)

		if musicPanel.Queue.List:FindFirstChild(tostring(entry.instanceName)) then
			musicPanel.Queue.List:FindFirstChild(tostring(entry.instanceName)):Destroy()
		end

		if not assetSuccess or not asset then
			-- Unreadable file: drop it and move on instead of stalling the whole queue
			queueNotification("Unable to play file", entry.sound .. " could not be loaded and has been skipped.", 4370341699)
			table.remove(musicQueue, 1)
			continue
		end

		if settingValue("Now Playing Notifications") then
			queueNotification("Now Playing", entry.sound, 4400695581)
		end

		currentAudio.SoundId = asset
		musicPanel.Playing.Text = entry.sound
		currentAudio:Play()
		musicPanel.Menu.TogglePlaying.ImageRectOffset = currentAudio.Playing and Vector2.new(804, 124) or Vector2.new(764, 244)
		currentAudio.Ended:Wait()

		if thisGen ~= playGeneration then
			return
		end -- superseded by Next/skip; let the active call do the table.remove

		table.remove(musicQueue, 1)
	end
end

local function addToQueue(file)
	if not (getCustomAsset and isfile) then
		return
	end
	if not file or file == "" then
		return
	end
	checkFolder()
	if not isfile(siriusValues.siriusFolder .. "/Music/" .. file) then
		queueNotification("Unable to locate file", "Please ensure that your audio file is in the Sirius/Music folder and that you are including the file extension (e.g mp3 or ogg).", 4370341699)
		return
	end
	musicPanel.AddBox.Input.Text = ""

	local newAudio = musicPanel.Queue.List.Template:Clone()
	newAudio.Parent = musicPanel.Queue.List
	newAudio.Size = UDim2.new(0, 254, 0, 40)
	newAudio.Close.ImageTransparency = 1
	newAudio.Name = file
	-- Measured against the filename, not the cloned template's placeholder text, which is what
	-- the old check read - so truncation fired off a constant instead of the actual length.
	if string.len(file) > 26 then
		newAudio.FileName.Text = string.sub(file, 1, 24) .. ".."
	else
		newAudio.FileName.Text = file
	end
	newAudio.Visible = true
	newAudio.Duration.Text = ""

	table.insert(musicQueue, { sound = file, instanceName = newAudio.Name })

	local lengthSuccess, lengthAsset = pcall(getCustomAsset, siriusValues.siriusFolder .. "/Music/" .. file)
	if lengthSuccess and lengthAsset then
		local getLength = Instance.new("Sound")
		getLength.Parent = workspace
		getLength.SoundId = lengthAsset
		getLength.Volume = 0
		getLength:Play()
		task.wait(0.05)
		if newAudio.Parent then
			newAudio.Duration.Text = tostring(math.round(getLength.TimeLength)) .. "s"
		end
		getLength:Stop()
		getLength:Destroy()
	end

	newAudio.MouseEnter:Connect(function()
		tweenService:Create(newAudio, TweenInfo.new(0.45, Enum.EasingStyle.Exponential), { BackgroundColor3 = Color3.fromRGB(100, 100, 100) }):Play()
		tweenService:Create(newAudio.Close, TweenInfo.new(0.45, Enum.EasingStyle.Exponential), { ImageTransparency = 0 }):Play()
		tweenService:Create(newAudio.Duration, TweenInfo.new(0.45, Enum.EasingStyle.Exponential), { TextTransparency = 1 }):Play()
	end)

	newAudio.MouseLeave:Connect(function()
		tweenService:Create(newAudio.Close, TweenInfo.new(0.45, Enum.EasingStyle.Exponential), { ImageTransparency = 1 }):Play()
		tweenService:Create(newAudio, TweenInfo.new(0.45, Enum.EasingStyle.Exponential), { BackgroundColor3 = Color3.fromRGB(0, 0, 0) }):Play()
		tweenService:Create(newAudio.Duration, TweenInfo.new(0.45, Enum.EasingStyle.Exponential), { TextTransparency = 0.7 }):Play()
	end)

	newAudio.Close.MouseButton1Click:Connect(function()
		-- The old version looped over every field of each queue entry. `sound` and `instanceName`
		-- hold the same filename, so each match fired twice and removed two entries - silently
		-- dropping the following track. One indexed pass, matched on one field, with a break.
		local removedIndex
		for i = 1, #musicQueue do
			if musicQueue[i].instanceName == newAudio.Name then
				removedIndex = i
				break
			end
		end

		if not removedIndex then
			newAudio:Destroy()
			return
		end

		local wasPlaying = removedIndex == 1 and currentAudio ~= nil and currentAudio.Playing

		table.remove(musicQueue, removedIndex)
		newAudio:Destroy()

		-- Only restart playback when the track we removed is the one currently playing
		if wasPlaying then
			task.spawn(playNext)
		end
	end)

	if #musicQueue == 1 then
		playNext()
	end
end

local function openMusic()
	debounce = true
	musicPanel.Visible = true
	musicPanel.Queue.List.Template.Visible = false

	debounce = false
end

local function closeMusic()
	debounce = true
	musicPanel.Visible = false

	debounce = false
end

local function createReverb(timing)
	for _, sound in ipairs(soundInstances) do
		if not sound:FindFirstChild("SiriusAudioProfile") then
			local reverb = Instance.new("EqualizerSoundEffect")

			reverb.Name = "SiriusAudioProfile"
			reverb.Parent = sound

			reverb.Enabled = false

			reverb.HighGain = 0
			reverb.LowGain = 0
			reverb.MidGain = 0
			reverb.Enabled = true

			if timing then
				tweenService:Create(reverb, TweenInfo.new(timing, Enum.EasingStyle.Exponential), { HighGain = -20 }):Play()
				tweenService:Create(reverb, TweenInfo.new(timing, Enum.EasingStyle.Exponential), { LowGain = 5 }):Play()
				tweenService:Create(reverb, TweenInfo.new(timing, Enum.EasingStyle.Exponential), { MidGain = -20 }):Play()
			end
		end
	end
end

-- Experience Sync (the per-experience game scripts) was removed: siriusValues.rawTree pointed
-- at a branch of this repo that no longer exists, so every fetch 404'd. The creator identity it
-- populated is now resolved directly, because Moderator Detection reads it and previously never
-- saw it set - Experience Sync was disabled, so the detection could never fire.
siriusValues.currentCreator = creatorType == Enum.CreatorType.Group and "group" or creatorId
siriusValues.currentGroup = creatorType == Enum.CreatorType.Group and creatorId or nil

local function updateSliderPadding()
	for _, v in pairs(siriusValues.sliders) do
		-- Viewport changes can land before sortActions() has built the slider objects
		if v.object then
			v.padding = {
				v.object.Interact.AbsolutePosition.X,
				v.object.Interact.AbsolutePosition.X + v.object.Interact.AbsoluteSize.X,
			}
		end
	end
end

local function updateSlider(data, setValue, forceValue)
	if not data.object or not data.padding then
		return
	end

	local inverse_interpolation

	if setValue then
		setValue = math.clamp(setValue, data.values[1], data.values[2])
		inverse_interpolation = (setValue - data.values[1]) / (data.values[2] - data.values[1])
	else
		-- Player:GetMouse() is deprecated and reports nothing on touch devices, so the sliders
		-- were desktop-only. UserInputService covers mouse, touch and pen with one call.
		local pointerX = userInputService:GetMouseLocation().X
		local posX = math.clamp(pointerX, data.padding[1], data.padding[2])
		local span = data.padding[2] - data.padding[1]
		inverse_interpolation = span > 0 and (posX - data.padding[1]) / span or 0
	end

	tweenService:Create(data.object.Progress, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(inverse_interpolation, 0, 1, 0) }):Play()

	local value = math.floor(data.values[1] + (data.values[2] - data.values[1]) * inverse_interpolation + 0.5)
	data.object.Information.Text = value .. " " .. data.name
	data.value = value

	-- Parenthesised: this used to read (callback and not setValue) or forceValue, so a forced
	-- update on a slider without a callback called nil.
	if data.callback and (not setValue or forceValue) then
		data.callback(value)
	end
end

local function resetSliders()
	for _, v in pairs(siriusValues.sliders) do
		updateSlider(v, v.default, true)
	end
end

local function sortActions()
	characterPanel.Interactions.Grid.Template.Visible = false
	characterPanel.Interactions.Sliders.Template.Visible = false

	for _, action in ipairs(siriusValues.actions) do
		local newAction = characterPanel.Interactions.Grid.Template:Clone()
		newAction.Name = action.name
		newAction.Parent = characterPanel.Interactions.Grid
		newAction.BackgroundColor3 = action.color
		newAction.UIStroke.Color = action.color
		newAction.Icon.Image = "rbxassetid://" .. action.images[2]
		newAction.Visible = true

		newAction.BackgroundTransparency = 0.8
		newAction.Transparency = 0.7

		newAction.MouseEnter:Connect(function()
			characterPanel.Interactions.ActionsTitle.Text = string.upper(action.name)
			if action.enabled or debounce then
				return
			end
			tweenService:Create(newAction, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.4 }):Play()
			tweenService:Create(newAction.UIStroke, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Transparency = 0.6 }):Play()
		end)

		newAction.MouseLeave:Connect(function()
			if action.enabled or debounce then
				return
			end
			tweenService:Create(newAction, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.55 }):Play()
			tweenService:Create(newAction.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.4 }):Play()
		end)

		characterPanel.Interactions.Grid.MouseLeave:Connect(function()
			characterPanel.Interactions.ActionsTitle.Text = "PLAYER ACTIONS"
		end)

		newAction.Interact.MouseButton1Click:Connect(function()
			local success = pcall(function()
				action.enabled = not action.enabled
				action.callback(action.enabled)

				if action.enabled then
					newAction.Icon.Image = "rbxassetid://" .. action.images[1]
					tweenService:Create(newAction, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.1 }):Play()
					tweenService:Create(newAction.UIStroke, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
					tweenService:Create(newAction.Icon, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0.1 }):Play()

					if action.disableAfter then
						task.delay(action.disableAfter, function()
							action.enabled = false
							newAction.Icon.Image = "rbxassetid://" .. action.images[2]
							tweenService:Create(newAction, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.55 }):Play()
							tweenService:Create(newAction.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.4 }):Play()
							tweenService:Create(newAction.Icon, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { ImageTransparency = 0.5 }):Play()
						end)
					end

					if action.rotateWhileEnabled then
						repeat
							newAction.Icon.Rotation = 0
							tweenService:Create(newAction.Icon, TweenInfo.new(0.75, Enum.EasingStyle.Quint), { Rotation = 360 }):Play()
							task.wait(1)
						until not action.enabled
						newAction.Icon.Rotation = 0
					end
				else
					newAction.Icon.Image = "rbxassetid://" .. action.images[2]
					tweenService:Create(newAction, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.55 }):Play()
					tweenService:Create(newAction.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.4 }):Play()
					tweenService:Create(newAction.Icon, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { ImageTransparency = 0.5 }):Play()
				end
			end)

			if not success then
				queueNotification("Action Error", "This action ('" .. action.name .. "') had an error while running, please report this to the Sirius team at sirius.menu/discord", 4370336704)
				action.enabled = false
				newAction.Icon.Image = "rbxassetid://" .. action.images[2]
				tweenService:Create(newAction, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.55 }):Play()
				tweenService:Create(newAction.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.4 }):Play()
				tweenService:Create(newAction.Icon, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { ImageTransparency = 0.5 }):Play()
			end
		end)
	end

	-- The character can exist without a Humanoid mid-spawn; indexing straight through used to
	-- throw here, which aborted start() and left the whole interface half-built.
	local startingHumanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
	if startingHumanoid and not startingHumanoid.UseJumpPower then
		siriusValues.sliders[2].name = "jump height"
		siriusValues.sliders[2].default = 7.2
		siriusValues.sliders[2].value = 7.2
		siriusValues.sliders[2].values = { 0, 120 }
	end

	for _, slider in ipairs(siriusValues.sliders) do
		local newSlider = characterPanel.Interactions.Sliders.Template:Clone()
		newSlider.Name = slider.name .. " Slider"
		newSlider.Parent = characterPanel.Interactions.Sliders
		newSlider.BackgroundColor3 = slider.color
		newSlider.Progress.BackgroundColor3 = slider.color
		newSlider.UIStroke.Color = slider.color
		newSlider.Information.Text = slider.name
		newSlider.Visible = true

		slider.object = newSlider

		slider.padding = {
			newSlider.Interact.AbsolutePosition.X,
			newSlider.Interact.AbsolutePosition.X + newSlider.Interact.AbsoluteSize.X,
		}

		newSlider.MouseEnter:Connect(function()
			if debounce or slider.active then
				return
			end
			tweenService:Create(newSlider, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.85 }):Play()
			tweenService:Create(newSlider.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.6 }):Play()
			tweenService:Create(newSlider.Information, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { TextTransparency = 0.2 }):Play()
		end)

		newSlider.MouseLeave:Connect(function()
			if debounce or slider.active then
				return
			end
			tweenService:Create(newSlider, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.8 }):Play()
			tweenService:Create(newSlider.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.5 }):Play()
			tweenService:Create(newSlider.Information, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { TextTransparency = 0.3 }):Play()
		end)

		newSlider.Interact.MouseButton1Down:Connect(function()
			if debounce or not checkSirius() then
				return
			end

			slider.active = true
			updateSlider(slider)

			tweenService:Create(slider.object, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.9 }):Play()
			tweenService:Create(slider.object.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 1 }):Play()
			tweenService:Create(slider.object.Information, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { TextTransparency = 0.05 }):Play()
		end)

		updateSlider(slider, slider.default)
	end
end

local function getAdaptiveHighPingThreshold()
	local adaptiveBaselinePings = siriusValues.pingProfile.adaptiveBaselinePings

	if #adaptiveBaselinePings == 0 then
		return siriusValues.pingProfile.adaptiveHighPingThreshold
	end

	table.sort(adaptiveBaselinePings)
	local median
	if #adaptiveBaselinePings % 2 == 0 then
		median = (adaptiveBaselinePings[#adaptiveBaselinePings / 2] + adaptiveBaselinePings[#adaptiveBaselinePings / 2 + 1]) / 2
	else
		median = adaptiveBaselinePings[math.ceil(#adaptiveBaselinePings / 2)]
	end

	return median * siriusValues.pingProfile.spikeThreshold
end

local function checkHighPing()
	local recentPings = siriusValues.pingProfile.recentPings
	local adaptiveBaselinePings = siriusValues.pingProfile.adaptiveBaselinePings

	local currentPing = getPing()
	table.insert(recentPings, currentPing)

	if #recentPings > siriusValues.pingProfile.maxSamples then
		table.remove(recentPings, 1)
	end

	if #adaptiveBaselinePings < siriusValues.pingProfile.adaptiveBaselineSamples then
		if currentPing >= 350 then
			currentPing = 300
		end

		table.insert(adaptiveBaselinePings, currentPing)

		return false
	end

	local averagePing = 0
	for _, ping in ipairs(recentPings) do
		averagePing = averagePing + ping
	end
	averagePing = averagePing / #recentPings

	if averagePing > getAdaptiveHighPingThreshold() then
		return true
	end

	return false
end

local function checkTools()
	task.wait(0.03)
	local backpack = localPlayer:FindFirstChildOfClass("Backpack")
	local character = localPlayer.Character

	-- Used to fall off the end returning nil when a backpack existed but held no tools
	return (backpack and backpack:FindFirstChildOfClass("Tool") ~= nil) or (character and character:FindFirstChildOfClass("Tool") ~= nil) or false
end

local function closePanel(panelName, openingOther)
	local button = smartBar.Buttons:FindFirstChild(panelName)
	local panel = UI:FindFirstChild(panelName)

	-- Guards run before debounce is claimed. Bailing out after setting it left the flag stuck
	-- true, which locks every panel, Home, Settings, Music and ScriptSearch for the session.
	if not isPanel(panelName) then
		return
	end
	if not (panel and button) then
		return
	end

	debounce = true

	local panelSize = UDim2.new(0, 581, 0, 246)

	if not openingOther then
		if panel.Name == "Character" then -- Character Panel Animation
			tweenService:Create(characterPanel.Interactions.PropertiesTitle, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()

			for _, slider in ipairs(characterPanel.Interactions.Sliders:GetChildren()) do
				if slider.ClassName == "Frame" then
					tweenService:Create(slider, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
					tweenService:Create(slider.Progress, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
					tweenService:Create(slider.UIStroke, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
					tweenService:Create(slider.Shadow, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
					tweenService:Create(slider.Information, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play() -- tween the text after
				end
			end

			tweenService:Create(characterPanel.Interactions.Reset, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
			tweenService:Create(characterPanel.Interactions.ActionsTitle, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()

			for _, gridButton in ipairs(characterPanel.Interactions.Grid:GetChildren()) do
				if gridButton.ClassName == "Frame" then
					tweenService:Create(gridButton, TweenInfo.new(0.21, Enum.EasingStyle.Exponential), { BackgroundTransparency = 1 }):Play()
					tweenService:Create(gridButton.UIStroke, TweenInfo.new(0.1, Enum.EasingStyle.Exponential), { Transparency = 1 }):Play()
					tweenService:Create(gridButton.Icon, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
					tweenService:Create(gridButton.Shadow, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
				end
			end

			tweenService:Create(characterPanel.Interactions.Serverhop, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
			tweenService:Create(characterPanel.Interactions.Serverhop.Title, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
			tweenService:Create(characterPanel.Interactions.Serverhop.UIStroke, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()

			tweenService:Create(characterPanel.Interactions.Rejoin, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
			tweenService:Create(characterPanel.Interactions.Rejoin.Title, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
			tweenService:Create(characterPanel.Interactions.Rejoin.UIStroke, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
		elseif panel.Name == "Scripts" then -- Scripts Panel Animation
			for _, scriptButton in ipairs(scriptsPanel.Interactions.Selection:GetChildren()) do
				if scriptButton.ClassName == "Frame" then
					tweenService:Create(scriptButton, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
					if scriptButton:FindFirstChild("Icon") then
						tweenService:Create(scriptButton.Icon, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
					end
					tweenService:Create(scriptButton.Title, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
					if scriptButton:FindFirstChild("Subtitle") then
						tweenService:Create(scriptButton.Subtitle, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
					end
					tweenService:Create(scriptButton.UIStroke, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
				end
			end
		elseif panel.Name == "Playerlist" then -- Playerlist Panel Animation
			for _, playerIns in ipairs(playerlistPanel.Interactions.List:GetDescendants()) do
				if playerIns.ClassName == "Frame" then
					tweenService:Create(playerIns, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
				elseif playerIns.ClassName == "TextLabel" or playerIns.ClassName == "TextButton" then
					tweenService:Create(playerIns, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
				elseif playerIns.ClassName == "ImageLabel" or playerIns.ClassName == "ImageButton" then
					tweenService:Create(playerIns, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
					if playerIns.Name == "Avatar" then
						tweenService:Create(playerIns, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
					end
				elseif playerIns.ClassName == "UIStroke" then
					tweenService:Create(playerIns, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
				end
			end

			tweenService:Create(playerlistPanel.Interactions.SearchFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
			tweenService:Create(playerlistPanel.Interactions.SearchFrame.Icon, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
			tweenService:Create(playerlistPanel.Interactions.SearchFrame.SearchBox, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
			tweenService:Create(playerlistPanel.Interactions.SearchFrame.UIStroke, TweenInfo.new(0.15, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
			tweenService:Create(playerlistPanel.Interactions.List, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { ScrollBarImageTransparency = 1 }):Play()
		end

		tweenService:Create(panel.Icon, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
		tweenService:Create(panel.Title, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(panel.UIStroke, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
		tweenService:Create(panel.Shadow, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
		task.wait(0.03)

		tweenService:Create(panel, TweenInfo.new(0.75, Enum.EasingStyle.Exponential, Enum.EasingDirection.InOut), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(panel, TweenInfo.new(1.1, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), { Size = button.Size }):Play()
		tweenService:Create(panel, TweenInfo.new(0.65, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { Position = siriusValues.buttonPositions[panelName] }):Play()
		tweenService:Create(toggle, TweenInfo.new(0.6, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 1, -85) }):Play()
	end

	-- Animate interactive elements
	if openingOther then
		tweenService:Create(panel, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { Position = UDim2.new(0.5, 350, 1, -90) }):Play()
		wipeTransparency(panel, 1, true, true, 0.3)
	end

	task.wait(0.5)
	panel.Size = panelSize
	panel.Visible = false

	debounce = false
end

local function openPanel(panelName)
	if debounce then
		return
	end
	local button = smartBar.Buttons:FindFirstChild(panelName)
	local panel = UI:FindFirstChild(panelName)

	-- Same as closePanel: never claim the debounce before the guards have passed
	if not isPanel(panelName) then
		return
	end
	if not (panel and button) then
		return
	end

	debounce = true

	for _, otherPanel in ipairs(UI:GetChildren()) do
		if smartBar.Buttons:FindFirstChild(otherPanel.Name) then
			if isPanel(otherPanel.Name) and otherPanel.Visible then
				task.spawn(closePanel, otherPanel.Name, true)
				task.wait()
			end
		end
	end

	local panelSize = UDim2.new(0, 581, 0, 246)

	panel.Size = button.Size
	panel.Position = siriusValues.buttonPositions[panelName]

	wipeTransparency(panel, 1, true)

	panel.Visible = true

	tweenService:Create(toggle, TweenInfo.new(0.65, Enum.EasingStyle.Quint), { Position = UDim2.new(0.5, 0, 1, -(panelSize.Y.Offset + 95)) }):Play()

	tweenService:Create(panel, TweenInfo.new(0.1, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(panel, TweenInfo.new(0.8, Enum.EasingStyle.Exponential), { Size = panelSize }):Play()
	tweenService:Create(panel, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.5, 0, 1, -90) }):Play()
	task.wait(0.1)
	tweenService:Create(panel.Shadow, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
	tweenService:Create(panel.Icon, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
	task.wait(0.05)
	tweenService:Create(panel.Title, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(panel.UIStroke, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { Transparency = 0.95 }):Play()
	task.wait(0.05)

	-- Animate interactive elements
	if panel.Name == "Character" then -- Character Panel Animation
		tweenService:Create(characterPanel.Interactions.PropertiesTitle, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 0.65 }):Play()

		local sliderInfo = {}
		for _, slider in ipairs(characterPanel.Interactions.Sliders:GetChildren()) do
			if slider.ClassName == "Frame" then
				table.insert(sliderInfo, { slider.Name, slider.Progress.Size, slider.Information.Text })
				slider.Progress.Size = UDim2.new(0, 0, 1, 0)
				slider.Progress.BackgroundTransparency = 0

				tweenService:Create(slider, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.8 }):Play()
				tweenService:Create(slider.UIStroke, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Transparency = 0.5 }):Play()
				tweenService:Create(slider.Shadow, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { ImageTransparency = 0.6 }):Play()
				tweenService:Create(slider.Information, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
			end
		end

		for _, sliderV in pairs(sliderInfo) do
			if characterPanel.Interactions.Sliders:FindFirstChild(sliderV[1]) then
				local slider = characterPanel.Interactions.Sliders:FindFirstChild(sliderV[1])
				local tweenValue = Instance.new("IntValue", UI)
				local tweenTo
				local name

				for _, sliderFound in ipairs(siriusValues.sliders) do
					if sliderFound.name .. " Slider" == slider.Name then
						tweenTo = sliderFound.value
						name = sliderFound.name
						break
					end
				end

				tweenService:Create(slider.Progress, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Size = sliderV[2] }):Play()

				local function animateNumber(n)
					tweenService:Create(tweenValue, TweenInfo.new(0.35, Enum.EasingStyle.Exponential), { Value = n }):Play()
					task.delay(0.4, tweenValue.Destroy, tweenValue)
				end

				tweenValue:GetPropertyChangedSignal("Value"):Connect(function()
					slider.Information.Text = tostring(tweenValue.Value) .. " " .. name
				end)

				animateNumber(tweenTo)
			end
		end

		tweenService:Create(characterPanel.Interactions.Reset, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
		tweenService:Create(characterPanel.Interactions.ActionsTitle, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 0.65 }):Play()

		for _, gridButton in ipairs(characterPanel.Interactions.Grid:GetChildren()) do
			if gridButton.ClassName == "Frame" then
				for _, action in ipairs(siriusValues.actions) do
					if action.name == gridButton.Name then
						if action.enabled then
							tweenService:Create(gridButton, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.1 }):Play()
							tweenService:Create(gridButton.UIStroke, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
							tweenService:Create(gridButton.Icon, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0.1 }):Play()
						else
							tweenService:Create(gridButton, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.55 }):Play()
							tweenService:Create(gridButton.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.4 }):Play()
							tweenService:Create(gridButton.Icon, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { ImageTransparency = 0.5 }):Play()
						end
						break
					end
				end

				tweenService:Create(gridButton.Shadow, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { ImageTransparency = 0.6 }):Play()
			end
		end

		tweenService:Create(characterPanel.Interactions.Serverhop, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
		tweenService:Create(characterPanel.Interactions.Serverhop.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.5 }):Play()
		tweenService:Create(characterPanel.Interactions.Serverhop.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()

		tweenService:Create(characterPanel.Interactions.Rejoin, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
		tweenService:Create(characterPanel.Interactions.Rejoin.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.5 }):Play()
		tweenService:Create(characterPanel.Interactions.Rejoin.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
	elseif panel.Name == "Scripts" then -- Scripts Panel Animation
		for _, scriptButton in ipairs(scriptsPanel.Interactions.Selection:GetChildren()) do
			if scriptButton.ClassName == "Frame" then
				tweenService:Create(scriptButton, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
				if scriptButton:FindFirstChild("Icon") then
					tweenService:Create(scriptButton.Icon, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
				end
				tweenService:Create(scriptButton.Title, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
				if scriptButton:FindFirstChild("Subtitle") then
					tweenService:Create(scriptButton.Subtitle, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
				end
				tweenService:Create(scriptButton.UIStroke, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { Transparency = 0.2 }):Play()
			end
		end
	elseif panel.Name == "Playerlist" then -- Playerlist Panel Animation
		for _, playerIns in ipairs(playerlistPanel.Interactions.List:GetDescendants()) do
			if playerIns.Name ~= "Interact" and playerIns.Name ~= "Role" then
				if playerIns.ClassName == "Frame" then
					tweenService:Create(playerIns, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
				elseif playerIns.ClassName == "TextLabel" or playerIns.ClassName == "TextButton" then
					tweenService:Create(playerIns, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
				elseif playerIns.ClassName == "ImageLabel" or playerIns.ClassName == "ImageButton" then
					tweenService:Create(playerIns, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
					if playerIns.Name == "Avatar" then
						tweenService:Create(playerIns, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
					end
				elseif playerIns.ClassName == "UIStroke" then
					tweenService:Create(playerIns, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
				end
			end
		end

		tweenService:Create(playerlistPanel.Interactions.SearchFrame, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
		tweenService:Create(playerlistPanel.Interactions.SearchFrame.Icon, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
		task.wait(0.01)
		tweenService:Create(playerlistPanel.Interactions.SearchFrame.SearchBox, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
		tweenService:Create(playerlistPanel.Interactions.SearchFrame.UIStroke, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { Transparency = 0.2 }):Play()
		task.wait(0.05)
		tweenService:Create(playerlistPanel.Interactions.List, TweenInfo.new(0.35, Enum.EasingStyle.Quint), { ScrollBarImageTransparency = 0.7 }):Play()
	end

	task.wait(0.45)
	debounce = false
end

local function rejoin()
	queueNotification("Rejoining Session", "We're queueing a rejoin to this session, give us a moment.", 4400696294)

	if #players:GetPlayers() <= 1 then
		task.wait()
		teleportService:Teleport(placeId, localPlayer)
	else
		teleportService:TeleportToPlaceInstance(placeId, jobId, localPlayer)
	end
end

local function serverhop()
	local highestPlayers = 0
	local target

	-- A rate-limited or offline games API used to throw straight out of the click handler
	local success, response = pcall(function()
		return httpService:JSONDecode(game:HttpGetAsync("https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Asc&limit=100"))
	end)

	if not success or not response or not response.data then
		return queueNotification("Unable to find servers", "Sirius couldn't reach the Roblox server list, this is usually rate limiting. Try again in a moment.", 4370317928)
	end

	for _, v in ipairs(response.data) do
		if type(v) == "table" and v.maxPlayers > v.playing and v.id ~= jobId then
			if v.playing > highestPlayers then
				highestPlayers = v.playing
				target = v.id
			end
		end
	end

	if not target then
		return queueNotification("No Servers Found", "We couldn't find another server, this may be the only server.", 4370317928)
	end

	queueNotification("Teleporting", "We're now moving you to the new session, this may take a few seconds.", 4335479121)
	task.wait(0.3)

	local hopped = pcall(teleportService.TeleportToPlaceInstance, teleportService, placeId, target)
	if not hopped then
		queueNotification("Teleport Failed", "Roblox refused the teleport to that server. Try again in a moment.", 4370317928)
	end
end

-- game:Shutdown() is a server method; client availability depends entirely on the executor and
-- it was being called bare from two user-facing buttons. Fall back to the home page.
local function leaveExperience()
	if pcall(function()
		game:Shutdown()
	end) then
		return
	end
	if pcall(teleportService.Teleport, teleportService, 0, localPlayer) then
		return
	end
	queueNotification("Unable to leave", "Sirius couldn't close the experience from here, you'll need to leave manually.", 4370317928)
end

local function ensureFrameProperties()
	UI.Enabled = true
	characterPanel.Visible = false
	customScriptPrompt.Visible = false
	disconnectedPrompt.Visible = false
	playerlistPanel.Interactions.List.Template.Visible = false
	gameDetectionPrompt.Visible = false
	homeContainer.Visible = false
	moderatorDetectionPrompt.Visible = false
	musicPanel.Visible = false
	notificationContainer.Visible = true
	playerlistPanel.Visible = false
	scriptSearch.Visible = false
	scriptsPanel.Visible = false
	settingsPanel.Visible = false
	smartBar.Visible = false
	musicPanel.Playing.Text = "Not Playing"
	-- Music needs getcustomasset to load local files at all
	if not getCustomAsset then
		smartBar.Buttons.Music.Visible = false
	end
	toastsContainer.Visible = true
	makeDraggable(settingsPanel)
	makeDraggable(musicPanel)
end

local function checkFriends()
	if friendsCooldown == 0 then
		friendsCooldown = 25

		local playersFriends = {}
		local success, page = pcall(players.GetFriendsAsync, players, localPlayer.UserId)

		if success then
			repeat
				local info = page:GetCurrentPage()
				for _, friendInfo in pairs(info) do
					table.insert(playersFriends, friendInfo)
				end
				if not page.IsFinished then
					page:AdvanceToNextPageAsync()
				end
			until page.IsFinished
		end

		local friendsInTotal = 0
		local onlineFriends = 0
		local friendsInGame = 0

		for _, v in pairs(playersFriends) do
			friendsInTotal = friendsInTotal + 1

			if v.IsOnline then
				onlineFriends = onlineFriends + 1
			end

			if players:FindFirstChild(v.Username) then
				friendsInGame = friendsInGame + 1
			end
		end

		if not checkSirius() then
			return
		end

		homeContainer.Interactions.Friends.All.Value.Text = tostring(friendsInTotal) .. " friends"
		homeContainer.Interactions.Friends.Offline.Value.Text = tostring(friendsInTotal - onlineFriends) .. " friends"
		homeContainer.Interactions.Friends.Online.Value.Text = tostring(onlineFriends) .. " friends"
		homeContainer.Interactions.Friends.InGame.Value.Text = tostring(friendsInGame) .. " friends"
	else
		friendsCooldown -= 1
	end
end

-- Connected once at load. These used to be wired up inside promptModerator, so after N
-- detections a single click on Leave fired N times.
local closeModPrompt

moderatorDetectionPrompt.Leave.MouseButton1Click:Connect(function()
	if closeModPrompt then
		closeModPrompt()
	end
	leaveExperience()
end)

moderatorDetectionPrompt.Serverhop.MouseEnter:Connect(function()
	tweenService:Create(moderatorDetectionPrompt.ServersAvailableFade, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.5 }):Play()
end)

moderatorDetectionPrompt.Serverhop.MouseLeave:Connect(function()
	tweenService:Create(moderatorDetectionPrompt.ServersAvailableFade, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
end)

moderatorDetectionPrompt.Serverhop.MouseButton1Click:Connect(function()
	if not moderatorDetectionPrompt.Visible then
		return
	end
	task.spawn(serverhop)
	if closeModPrompt then
		closeModPrompt()
	end
end)

moderatorDetectionPrompt.Close.MouseButton1Click:Connect(function()
	if closeModPrompt then
		closeModPrompt()
	end
end)

local function promptModerator(player, role)
	if moderatorDetectionPrompt.Visible then
		return
	end

	moderatorDetectionPrompt.Size = UDim2.new(0, 283, 0, 175)
	moderatorDetectionPrompt.UIGradient.Offset = Vector2.new(0, 1)
	wipeTransparency(moderatorDetectionPrompt, 1, true)

	moderatorDetectionPrompt.DisplayName.Text = player.DisplayName
	moderatorDetectionPrompt.Rank.Text = role
	moderatorDetectionPrompt.Avatar.Image = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. player.UserId .. "&width=420&height=420&format=png"

	moderatorDetectionPrompt.Visible = true

	-- Assume a hop is possible and correct it once the server list lands. Blocking the prompt
	-- on an unguarded HTTP call meant a rate-limited response threw and left it half-drawn.
	moderatorDetectionPrompt.Serverhop.Visible = true
	moderatorDetectionPrompt.ServersAvailableFade.Visible = true

	task.spawn(function()
		local serversAvailable = false
		local success, response = pcall(function()
			return httpService:JSONDecode(game:HttpGetAsync("https://games.roblox.com/v1/games/" .. placeId .. "/servers/Public?sortOrder=Asc&limit=100"))
		end)

		if success and response and response.data then
			for _, v in ipairs(response.data) do
				if type(v) == "table" and v.maxPlayers > v.playing and v.id ~= jobId then
					serversAvailable = true
					break
				end
			end
		end

		if not moderatorDetectionPrompt.Visible then
			return
		end

		moderatorDetectionPrompt.Serverhop.Visible = serversAvailable
		moderatorDetectionPrompt.ServersAvailableFade.Visible = serversAvailable
	end)

	tweenService:Create(moderatorDetectionPrompt, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(moderatorDetectionPrompt, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 300, 0, 186) }):Play()
	tweenService:Create(moderatorDetectionPrompt.UIGradient, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.65) }):Play()
	tweenService:Create(moderatorDetectionPrompt.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(moderatorDetectionPrompt.Subtitle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(moderatorDetectionPrompt.Avatar, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.7 }):Play()
	tweenService:Create(moderatorDetectionPrompt.Avatar, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
	tweenService:Create(moderatorDetectionPrompt.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(moderatorDetectionPrompt.Rank, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(moderatorDetectionPrompt.Serverhop, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.7 }):Play()
	tweenService:Create(moderatorDetectionPrompt.Leave, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.7 }):Play()
	task.wait(0.2)
	tweenService:Create(moderatorDetectionPrompt.Serverhop, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(moderatorDetectionPrompt.Leave, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	task.wait(0.3)
	tweenService:Create(moderatorDetectionPrompt.Close, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0.6 }):Play()

	closeModPrompt = function()
		tweenService:Create(moderatorDetectionPrompt, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 283, 0, 175) }):Play()
		tweenService:Create(moderatorDetectionPrompt.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 1) }):Play()
		tweenService:Create(moderatorDetectionPrompt.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Subtitle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Avatar, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Avatar, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Rank, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Serverhop, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Leave, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Serverhop, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Leave, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(moderatorDetectionPrompt.Close, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
		task.wait(0.5)
		moderatorDetectionPrompt.Visible = false
	end
end

local function UpdateHome()
	if not checkSirius() then
		return
	end
	-- Home used to refresh every second whether or not it was on screen, which meant a paginated
	-- GetFriendsAsync every 25s for a panel the player may never have opened.
	if not homeContainer.Visible then
		return
	end

	local function format(Int)
		return string.format("%02i", Int)
	end

	local function convertToHMS(Seconds)
		local Minutes = (Seconds - Seconds % 60) / 60
		Seconds = Seconds - Minutes * 60
		local Hours = (Minutes - Minutes % 60) / 60
		Minutes = Minutes - Hours * 60
		return format(Hours) .. ":" .. format(Minutes) .. ":" .. format(Seconds)
	end

	-- Home Title
	homeContainer.Title.Text = "Welcome home, " .. localPlayer.DisplayName

	-- Players
	homeContainer.Interactions.Server.Players.Value.Text = #players:GetPlayers() .. " playing"
	homeContainer.Interactions.Server.MaxPlayers.Value.Text = players.MaxPlayers .. " players can join this server"

	-- Ping
	homeContainer.Interactions.Server.Latency.Value.Text = math.floor(getPing()) .. "ms"

	-- Time
	homeContainer.Interactions.Server.Time.Value.Text = convertToHMS(time())

	-- Region
	homeContainer.Interactions.Server.Region.Value.Text = "Unable to retrieve region"

	-- Player Information
	homeContainer.Interactions.User.Avatar.Image = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. localPlayer.UserId .. "&width=420&height=420&format=png"
	homeContainer.Interactions.User.Title.Text = localPlayer.DisplayName
	homeContainer.Interactions.User.Subtitle.Text = localPlayer.Name

	-- Update Executor
	-- identifyexecutor isn't universal. Calling it bare threw once per second here, which took
	-- every other field in this function down with it.
	local executorName
	if getExecutorName then
		local nameSuccess, name = pcall(getExecutorName)
		executorName = (nameSuccess and type(name) == "string" and #name > 0) and name or nil
	end

	homeContainer.Interactions.Client.Title.Text = executorName or "Unknown Executor"

	if not executorName then
		homeContainer.Interactions.Client.Subtitle.Text = "Sirius couldn't identify this executor - it may still work just fine."
	elseif not table.find(siriusValues.executors, string.lower(executorName)) then
		homeContainer.Interactions.Client.Subtitle.Text = "This executor is not verified as supported - but may still work just fine."
	end

	-- Update Friends Statuses
	checkFriends()
end

local function openHome()
	if debounce then
		return
	end
	debounce = true
	homeContainer.Visible = true

	-- UpdateHome now no-ops while Home is hidden, so populate it once on the way in rather than
	-- showing up to a second of stale values.
	task.spawn(UpdateHome)

	-- The FOV the player had before Home touched it. Open used to add 5, then read the camera
	-- again mid-tween and subtract 40 from that moving value, and close added a flat 35 back -
	-- so the FOV drifted a little further on every open/close cycle.
	local restoreFieldOfView = camera.FieldOfView
	homeFieldOfView = restoreFieldOfView

	local homeBlur = Instance.new("BlurEffect", lighting)
	homeBlur.Size = 0
	homeBlur.Name = "HomeBlur"

	homeContainer.BackgroundTransparency = 1
	homeContainer.Title.TextTransparency = 1
	homeContainer.Subtitle.TextTransparency = 1

	for _, homeItem in ipairs(homeContainer.Interactions:GetChildren()) do
		wipeTransparency(homeItem, 1, true)

		homeItem.Position = UDim2.new(0, homeItem.Position.X.Offset - 20, 0, homeItem.Position.Y.Offset - 20)
		homeItem.Size = UDim2.new(0, homeItem.Size.X.Offset + 30, 0, homeItem.Size.Y.Offset + 20)

		if homeItem.UIGradient.Offset.Y > 0 then
			homeItem.UIGradient.Offset = Vector2.new(0, homeItem.UIGradient.Offset.Y + 3)
			homeItem.UIStroke.UIGradient.Offset = Vector2.new(0, homeItem.UIStroke.UIGradient.Offset.Y + 3)
		else
			homeItem.UIGradient.Offset = Vector2.new(0, homeItem.UIGradient.Offset.Y - 3)
			homeItem.UIStroke.UIGradient.Offset = Vector2.new(0, homeItem.UIStroke.UIGradient.Offset.Y - 3)
		end
	end

	tweenService:Create(homeContainer, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.9 }):Play()
	tweenService:Create(homeBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Size = 5 }):Play()

	tweenService:Create(camera, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { FieldOfView = restoreFieldOfView + 5 }):Play()

	task.wait(0.25)

	local playerGui = localPlayer:FindFirstChildWhichIsA("PlayerGui")

	table.clear(env.cachedInGameUI)

	if playerGui then
		for _, inGameUI in ipairs(playerGui:GetChildren()) do
			if inGameUI:IsA("ScreenGui") and inGameUI.Enabled and inGameUI ~= UI then
				table.insert(env.cachedInGameUI, inGameUI)
				inGameUI.Enabled = false
			end
		end
	end

	table.clear(env.cachedCoreUI)

	for _, coreUI in ipairs({ "PlayerList", "Chat", "EmotesMenu", "Health", "Backpack" }) do
		local coreSuccess, enabled = pcall(starterGui.GetCoreGuiEnabled, starterGui, Enum.CoreGuiType[coreUI])
		if coreSuccess and enabled then
			table.insert(env.cachedCoreUI, coreUI)
			pcall(starterGui.SetCoreGuiEnabled, starterGui, Enum.CoreGuiType[coreUI], false)
		end
	end

	createReverb(0.8)

	tweenService:Create(camera, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { FieldOfView = math.max(restoreFieldOfView - 35, 20) }):Play()

	tweenService:Create(homeContainer, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.7 }):Play()
	tweenService:Create(homeContainer.Title, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(homeContainer.Subtitle, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 0.4 }):Play()
	tweenService:Create(homeBlur, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Size = 20 }):Play()

	for _, homeItem in ipairs(homeContainer.Interactions:GetChildren()) do
		for _, otherHomeItem in ipairs(homeItem:GetDescendants()) do
			if otherHomeItem.ClassName == "Frame" then
				tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.7 }):Play()
			elseif otherHomeItem.ClassName == "TextLabel" then
				if otherHomeItem.Name == "Title" then
					tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
				else
					tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
				end
			elseif otherHomeItem.ClassName == "ImageLabel" then
				tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.8 }):Play()
				tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
			end
		end

		tweenService:Create(homeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
		tweenService:Create(homeItem.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
		tweenService:Create(homeItem, TweenInfo.new(0.5, Enum.EasingStyle.Back), { Position = UDim2.new(0, homeItem.Position.X.Offset + 20, 0, homeItem.Position.Y.Offset + 20) }):Play()
		tweenService:Create(homeItem, TweenInfo.new(0.5, Enum.EasingStyle.Back), { Size = UDim2.new(0, homeItem.Size.X.Offset - 30, 0, homeItem.Size.Y.Offset - 20) }):Play()

		task.delay(0.03, function()
			if homeItem.UIGradient.Offset.Y > 0 then
				tweenService:Create(homeItem.UIGradient, TweenInfo.new(1, Enum.EasingStyle.Exponential), { Offset = Vector2.new(0, homeItem.UIGradient.Offset.Y - 3) }):Play()
				tweenService:Create(homeItem.UIStroke.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), { Offset = Vector2.new(0, homeItem.UIStroke.UIGradient.Offset.Y - 3) }):Play()
			else
				tweenService:Create(homeItem.UIGradient, TweenInfo.new(1, Enum.EasingStyle.Exponential), { Offset = Vector2.new(0, homeItem.UIGradient.Offset.Y + 3) }):Play()
				tweenService:Create(homeItem.UIStroke.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), { Offset = Vector2.new(0, homeItem.UIStroke.UIGradient.Offset.Y + 3) }):Play()
			end
		end)

		task.wait(0.02)
	end

	task.wait(0.85)

	debounce = false
end

local function closeHome()
	if debounce then
		return
	end
	debounce = true

	-- Restore the exact FOV Home was opened at instead of adding a fixed amount back
	tweenService:Create(camera, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { FieldOfView = homeFieldOfView or baseFieldOfView }):Play()

	for _, obj in ipairs(lighting:GetChildren()) do
		if obj.Name == "HomeBlur" then
			tweenService:Create(obj, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Size = 0 }):Play()
			task.delay(0.6, obj.Destroy, obj)
		end
	end

	tweenService:Create(homeContainer, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
	tweenService:Create(homeContainer.Title, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
	tweenService:Create(homeContainer.Subtitle, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()

	for _, homeItem in ipairs(homeContainer.Interactions:GetChildren()) do
		for _, otherHomeItem in ipairs(homeItem:GetDescendants()) do
			if otherHomeItem.ClassName == "Frame" then
				tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
			elseif otherHomeItem.ClassName == "TextLabel" then
				tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
			elseif otherHomeItem.ClassName == "ImageLabel" then
				tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
				tweenService:Create(otherHomeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
			end
		end
		tweenService:Create(homeItem, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(homeItem.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
	end

	task.wait(0.2)

	-- Instances, not names. Matching by name re-enabled any interface sharing a name with one we
	-- hid, and the old nested loop walked the whole PlayerGui once per cached entry.
	for _, cachedUI in ipairs(env.cachedInGameUI) do
		if cachedUI.Parent then
			cachedUI.Enabled = true
		end
	end
	table.clear(env.cachedInGameUI)

	for _, coreUI in ipairs(env.cachedCoreUI) do
		pcall(starterGui.SetCoreGuiEnabled, starterGui, Enum.CoreGuiType[coreUI], true)
	end
	table.clear(env.cachedCoreUI)

	removeReverbs(0.5)

	task.wait(0.52)

	homeContainer.Visible = false
	debounce = false
end

local function openScriptSearch()
	debounce = true

	scriptSearch.Size = UDim2.new(0, 480, 0, 23)
	scriptSearch.Position = UDim2.new(0.5, 0, 0.5, 0)
	scriptSearch.SearchBox.Position = UDim2.new(0.509, 0, 0.5, 0)
	scriptSearch.Icon.Position = UDim2.new(0.04, 0, 0.5, 0)
	scriptSearch.SearchBox.Text = ""
	scriptSearch.UIGradient.Offset = Vector2.new(0, 2)
	scriptSearch.SearchBox.PlaceholderText = "Search ScriptBlox.com"
	scriptSearch.List.Template.Visible = false
	scriptSearch.List.Visible = false
	scriptSearch.Visible = true

	wipeTransparency(scriptSearch, 1, true)

	tweenService:Create(scriptSearch, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(scriptSearch, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 580, 0, 43) }):Play()
	tweenService:Create(scriptSearch.Shadow, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0.85 }):Play()
	task.wait(0.03)
	tweenService:Create(scriptSearch.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
	task.wait(0.02)
	tweenService:Create(scriptSearch.SearchBox, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()

	task.wait(0.3)
	scriptSearch.SearchBox:CaptureFocus()
	task.wait(0.2)
	debounce = false
end

local function closeScriptSearch()
	debounce = true

	wipeTransparency(scriptSearch, 1, false)

	task.wait(0.1)

	scriptSearch.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	scriptSearch.UIGradient.Enabled = false
	tweenService:Create(scriptSearch, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 520, 0, 0) }):Play()
	scriptSearch.SearchBox:ReleaseFocus()

	task.wait(0.5)

	for _, createdScript in ipairs(scriptSearch.List:GetChildren()) do
		if createdScript.Name ~= "Placeholder" and createdScript.Name ~= "Template" and createdScript.ClassName == "Frame" then
			createdScript:Destroy()
		end
	end

	task.wait(0.1)
	scriptSearch.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	scriptSearch.Visible = false
	scriptSearch.UIGradient.Enabled = true
	debounce = false
end

local function createScript(result)
	local newScript = UI.ScriptSearch.List.Template:Clone()
	newScript.Name = result.title
	newScript.Parent = UI.ScriptSearch.List
	newScript.Visible = true

	for _, tag in ipairs(newScript.Tags:GetChildren()) do
		if tag.ClassName == "Frame" then
			tag.Shadow.ImageTransparency = 1
			tag.BackgroundTransparency = 1
			tag.Title.TextTransparency = 1
		end
	end

	task.spawn(function()
		local response

		local success = pcall(function()
			local responseRequest = httpRequest({
				Url = "https://www.scriptblox.com/api/script/" .. result["slug"],
				Method = "GET",
			})

			response = httpService:JSONDecode(responseRequest.Body)
		end)

		if not success or not response or not response.script then
			return
		end

		newScript.ScriptDescription.Text = response.script.features

		local likes = response.script.likeCount
		local dislikes = response.script.dislikeCount

		if likes ~= dislikes then
			newScript.Tags.Review.Title.Text = (likes > dislikes) and "Positive Reviews" or "Negative Reviews"
			newScript.Tags.Review.BackgroundColor3 = (likes > dislikes) and Color3.fromRGB(0, 139, 102) or Color3.fromRGB(180, 0, 0)
			newScript.Tags.Review.Size = (likes > dislikes) and UDim2.new(0, 145, 1, 0) or UDim2.new(0, 150, 1, 0)
		elseif likes > 0 then
			newScript.Tags.Review.Title.Text = "Mixed Reviews"
			newScript.Tags.Review.BackgroundColor3 = Color3.fromRGB(198, 132, 0)
			newScript.Tags.Review.Size = UDim2.new(0, 130, 1, 0)
		else
			newScript.Tags.Review.Visible = false
		end

		newScript.ScriptAuthor.Text = "uploaded by " .. response.script.owner.username
		newScript.Tags.Verified.Visible = response.script.owner.verified or false

		tweenService:Create(newScript, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.8 }):Play()
		tweenService:Create(newScript.ScriptName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
		tweenService:Create(newScript.Execute, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.8 }):Play()
		tweenService:Create(newScript.Execute, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()

		newScript.Tags.Visible = true

		tweenService:Create(newScript.ScriptDescription, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
		tweenService:Create(newScript.ScriptAuthor, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.7 }):Play()

		for _, tag in ipairs(newScript.Tags:GetChildren()) do
			if tag.ClassName == "Frame" then
				tweenService:Create(tag.Shadow, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
				tweenService:Create(tag, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
				tweenService:Create(tag.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
			end
		end
	end)

	wipeTransparency(newScript, 1, true)

	newScript.ScriptName.Text = result.title

	newScript.Tags.Visible = false
	newScript.Tags.Patched.Visible = result.isPatched or false

	newScript.Execute.MouseButton1Click:Connect(function()
		-- The search endpoint doesn't always include a script body; loadstring(nil) threw here
		if type(result.script) ~= "string" or #result.script == 0 then
			queueNotification("ScriptSearch", "ScriptBlox didn't return a script body for " .. result.title .. ".", 4384402990)
			return
		end

		queueNotification("ScriptSearch", "Running " .. result.title .. " via ScriptSearch", 4384403532)
		closeScriptSearch()

		-- A third-party script that fails to compile or errors on load shouldn't surface as an
		-- unexplained Sirius error
		local chunk, compileError = loadstring(result.script)
		if not chunk then
			queueNotification("ScriptSearch", "Couldn't run " .. result.title .. ": " .. tostring(compileError), 4384402990)
			return
		end

		local runSuccess, runError = pcall(chunk)
		if not runSuccess then
			queueNotification("ScriptSearch", result.title .. " errored while running: " .. tostring(runError), 4384402990)
		end
	end)
end

local function extractDomain(link)
	local domainToReturn = link:match("([%w-_]+%.[%w-_%.]+)")
	return domainToReturn
end

-- Reading the allowlist sits on the hot path of the request hook, so a corrupt or truncated
-- allowedLinks.srs used to throw out of JSONDecode and break every HTTP request in the session.
local function readAllowlist()
	if not (isfile and readfile) then
		return nil
	end

	local path = siriusValues.siriusFolder .. "/" .. "allowedLinks.srs"
	local readSuccess, raw = pcall(function()
		return isfile(path) and readfile(path) or nil
	end)

	if not readSuccess or not raw then
		return nil
	end

	local decodeSuccess, decoded = pcall(httpService.JSONDecode, httpService, raw)
	if not decodeSuccess or type(decoded) ~= "table" then
		warn("Sirius | allowedLinks.srs was unreadable and has been ignored")
		return nil
	end

	return decoded
end

local SECURITY_PROMPT_TIMEOUT = 60 -- seconds before an unanswered prompt denies by default

local function securityDetection(title, content, link, gradient, actions)
	if not checkSirius() then
		return
	end

	local domain = extractDomain(link) or link
	checkFolder()
	local currentAllowlist = readAllowlist()
	if currentAllowlist and table.find(currentAllowlist, domain) then
		return true
	end

	local newSecurityPrompt = securityPrompt:Clone()

	newSecurityPrompt.Parent = UI
	newSecurityPrompt.Name = link

	wipeTransparency(newSecurityPrompt, 1, true)
	newSecurityPrompt.Size = UDim2.new(0, 478, 0, 150)

	newSecurityPrompt.Title.Text = title
	newSecurityPrompt.Subtitle.Text = content
	newSecurityPrompt.FoundLink.Text = domain

	newSecurityPrompt.Visible = true
	newSecurityPrompt.UIGradient.Color = gradient

	newSecurityPrompt.Buttons.Template.Visible = false

	local function closeSecurityPrompt()
		tweenService:Create(newSecurityPrompt, TweenInfo.new(0.52, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 500, 0, 165) }):Play()
		tweenService:Create(newSecurityPrompt, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(newSecurityPrompt.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(newSecurityPrompt.Subtitle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		tweenService:Create(newSecurityPrompt.FoundLink, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()

		for _, button in ipairs(newSecurityPrompt.Buttons:GetChildren()) do
			if button.Name ~= "Template" and button.ClassName == "TextButton" then
				tweenService:Create(button, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
				tweenService:Create(button, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
			end
		end
		task.wait(0.55)
		newSecurityPrompt:Destroy()
	end

	local decision

	for _, action in ipairs(actions) do
		local newAction = newSecurityPrompt.Buttons.Template:Clone()
		newAction.Name = action[1]
		newAction.Text = action[1]
		newAction.Parent = newSecurityPrompt.Buttons
		newAction.Visible = true
		newAction.Size = UDim2.new(0, newAction.TextBounds.X + 50, 0, 36) -- textbounds

		newAction.MouseButton1Click:Connect(function()
			if decision ~= nil then
				return
			end -- one answer per prompt

			if action[2] then
				if action[3] and writefile then
					checkFolder()
					local allowed = currentAllowlist or {}
					table.insert(allowed, domain)
					pcall(writefile, siriusValues.siriusFolder .. "/" .. "allowedLinks.srs", httpService:JSONEncode(allowed))
				end
				decision = true
			else
				decision = false
			end

			closeSecurityPrompt()
		end)
	end

	tweenService:Create(newSecurityPrompt, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 576, 0, 181) }):Play()
	tweenService:Create(newSecurityPrompt, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(newSecurityPrompt.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(newSecurityPrompt.Subtitle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
	task.wait(0.03)
	tweenService:Create(newSecurityPrompt.FoundLink, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.2 }):Play()

	task.wait(0.1)

	for _, button in ipairs(newSecurityPrompt.Buttons:GetChildren()) do
		if button.Name ~= "Template" and button.ClassName == "TextButton" then
			tweenService:Create(button, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.7 }):Play()
			tweenService:Create(button, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.05 }):Play()
			task.wait(0.1)
		end
	end

	newSecurityPrompt.FoundLink.MouseEnter:Connect(function()
		newSecurityPrompt.FoundLink.Text = link
		tweenService:Create(newSecurityPrompt.FoundLink, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.4 }):Play()
	end)

	newSecurityPrompt.FoundLink.MouseLeave:Connect(function()
		newSecurityPrompt.FoundLink.Text = domain
		tweenService:Create(newSecurityPrompt.FoundLink, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.2 }):Play()
	end)

	-- An unanswered prompt used to park the calling script forever, because the request hook is
	-- synchronous. Time out and deny instead - failing closed is the safe direction here.
	local deadline = os.clock() + SECURITY_PROMPT_TIMEOUT
	while decision == nil do
		if os.clock() > deadline then
			decision = false
			task.spawn(closeSecurityPrompt)
			break
		end
		if not newSecurityPrompt.Parent then
			decision = false
			break
		end
		task.wait()
	end

	return decision
end

-- Only install the interception hooks if there's something real to fall back to; the old code
-- replaced the global unconditionally, so on an executor without a request function the
-- replacement ended up calling nil.
if originalRequest then
	env[index] = function(data)
		-- Callers can pass anything; the old code indexed data.Url straight away
		if type(data) ~= "table" then
			return originalRequest(data)
		end

		if not (checkSirius() and settingValue("Intelligent HTTP Interception")) then
			return originalRequest(data)
		end

		local title = "Do you trust this source?"
		local content = "Sirius has prevented data from being sent off-client, would you like to allow data to be sent or retrieved from this source?"
		local url = data.Url or data.url or "Unknown Link"
		local gradient = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)), ColorSequenceKeypoint.new(1, Color3.new(0.764706, 0.305882, 0.0941176)) })
		local actions = { { "Always Allow", true, true }, { "Allow just this once", true }, { "Don't Allow", false } }

		if url == "http://127.0.0.1:6463/rpc?v=1" and data.Body then
			-- A malformed RPC body used to throw straight out of the hook
			local decodeSuccess, bodyDecoded = pcall(httpService.JSONDecode, httpService, data.Body)

			if decodeSuccess and type(bodyDecoded) == "table" and bodyDecoded.cmd == "INVITE_BROWSER" then
				title = "Would you like to join this Discord server?"
				content = "Sirius has prevented your Discord client from automatically joining this Discord server, would you like to continue and join, or block it?"
				url = bodyDecoded.args and bodyDecoded.args.code and "discord.gg/" .. bodyDecoded.args.code or "Unknown Invite"
				gradient = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)), ColorSequenceKeypoint.new(1, Color3.new(0.345098, 0.396078, 0.94902)) })
				actions = { { "Allow", true }, { "Don't Allow", false } }
			end
		end

		if securityDetection(title, content, url, gradient, actions) then
			return originalRequest(data)
		end

		-- Callers expect a response table; returning nothing made them error on the denial path
		return {
			Success = false,
			StatusCode = 403,
			StatusMessage = "Blocked by Sirius",
			Headers = {},
			Body = "",
		}
	end

	-- Executors expose the same function under several names; keep them all pointing at the hook
	for _, alias in ipairs({ "request", "http_request" }) do
		if env[alias] then
			env[alias] = env[index]
		end
	end
end

if originalSetClipboard then
	env[indexSetClipboard] = function(data)
		if not (checkSirius() and settingValue("Intelligent Clipboard Interception")) then
			return originalSetClipboard(data)
		end

		local title = "Would you like to copy this to your clipboard?"
		local content = "Sirius has prevented a script from setting the below text to your clipboard, would you like to allow this, or prevent it from copying?"
		local url = tostring(data or "Unknown Clipboard")
		local gradient = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)), ColorSequenceKeypoint.new(1, Color3.new(0.776471, 0.611765, 0.529412)) })
		local actions = { { "Allow", true }, { "Don't Allow", false } }

		if securityDetection(title, content, url, gradient, actions) then
			return originalSetClipboard(data)
		end
	end
end

local function searchScriptBlox(query)
	local response

	if not httpRequest then
		queueNotification("ScriptSearch", "ScriptSearch needs an executor with a request function, and this one doesn't expose it.", 4384402990)
		closeScriptSearch()
		return
	end

	local success = pcall(function()
		local responseRequest = httpRequest({
			Url = "https://scriptblox.com/api/script/search?q=" .. httpService:UrlEncode(query) .. "&mode=free&max=20&page=1",
			Method = "GET",
		})

		response = httpService:JSONDecode(responseRequest.Body)
	end)

	-- The old code checked `success` here but then indexed response.result.scripts further down
	-- without ever checking that the shape was what it expected
	if not success or type(response) ~= "table" or type(response.result) ~= "table" or type(response.result.scripts) ~= "table" then
		queueNotification("ScriptSearch", "ScriptSearch backend encountered an error, try again later", 4384402990)
		closeScriptSearch()
		return
	end

	tweenService:Create(scriptSearch.NoScriptsTitle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
	tweenService:Create(scriptSearch.NoScriptsDesc, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()

	for _, createdScript in ipairs(scriptSearch.List:GetChildren()) do
		if createdScript.Name ~= "Placeholder" and createdScript.Name ~= "Template" and createdScript.ClassName == "Frame" then
			wipeTransparency(createdScript, 1, true)
		end
	end

	scriptSearch.List.Visible = true
	task.wait(0.5)

	scriptSearch.List.CanvasPosition = Vector2.new(0, 0)

	for _, createdScript in ipairs(scriptSearch.List:GetChildren()) do
		if createdScript.Name ~= "Placeholder" and createdScript.Name ~= "Template" and createdScript.ClassName == "Frame" then
			createdScript:Destroy()
		end
	end

	tweenService:Create(scriptSearch, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 580, 0, 529) }):Play()
	tweenService:Create(scriptSearch.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.054, 0, 0.056, 0) }):Play()
	tweenService:Create(scriptSearch.SearchBox, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.523, 0, 0.056, 0) }):Play()
	tweenService:Create(scriptSearch.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.6) }):Play()

	local scriptCreated = false
	for _, scriptResult in ipairs(response.result.scripts) do
		-- scriptCreated used to be set even when createScript threw, so a page of failures
		-- still reported as results
		if pcall(createScript, scriptResult) then
			scriptCreated = true
		end
	end

	if not scriptCreated then
		task.wait(0.2)
		tweenService:Create(scriptSearch.NoScriptsTitle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
		task.wait(0.1)
		tweenService:Create(scriptSearch.NoScriptsDesc, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	else
		tweenService:Create(scriptSearch.List, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { ScrollBarImageTransparency = 0 }):Play()
	end
end

-- coreGui.RobloxGui.Backpack was indexed directly in three places. RobloxGui isn't guaranteed to
-- exist (and its layout has moved before), so a miss threw on the very first smartBar open.
local function getRobloxBackpack()
	local robloxGui = coreGui:FindFirstChild("RobloxGui")
	return robloxGui and robloxGui:FindFirstChild("Backpack")
end

local function openSmartBar()
	smartBarOpen = true

	local backpack = getRobloxBackpack()
	if backpack then
		backpack.Position = UDim2.new(0, 0, 0, 0)
	end

	-- Set Values for frame properties
	smartBar.BackgroundTransparency = 1
	smartBar.Time.TextTransparency = 1
	smartBar.UIStroke.Transparency = 1
	smartBar.Shadow.ImageTransparency = 1
	smartBar.Visible = true
	smartBar.Position = UDim2.new(0.5, 0, 1.05, 0)
	smartBar.Size = UDim2.new(0, 531, 0, 64)
	toggle.Rotation = 180
	toggle.Visible = not settingValue("Hide Toggle Button")

	if checkTools() then
		toggle.Position = UDim2.new(0.5, 0, 1, -68)
	else
		toggle.Position = UDim2.new(0.5, 0, 1, -5)
	end

	for _, button in ipairs(smartBar.Buttons:GetChildren()) do
		button.UIGradient.Rotation = -120
		button.UIStroke.UIGradient.Rotation = -120
		button.Size = UDim2.new(0, 30, 0, 30)
		button.Position = UDim2.new(button.Position.X.Scale, 0, 1.3, 0)
		button.BackgroundTransparency = 1
		button.UIStroke.Transparency = 1
		button.Icon.ImageTransparency = 1
	end

	if backpack then
		tweenService:Create(backpack, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Position = UDim2.new(-0.325, 0, 0, 0) }):Play()
	end

	tweenService:Create(toggle, TweenInfo.new(0.82, Enum.EasingStyle.Quint), { Rotation = 0 }):Play()
	tweenService:Create(smartBar, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Position = UDim2.new(0.5, 0, 1, -12) }):Play()
	tweenService:Create(toastsContainer, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.5, 0, 1, -110) }):Play()
	tweenService:Create(toggle, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Position = UDim2.new(0.5, 0, 1, -85) }):Play()
	tweenService:Create(smartBar, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 581, 0, 70) }):Play()
	tweenService:Create(smartBar, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(smartBar.Shadow, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
	tweenService:Create(smartBar.Time, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(smartBar.UIStroke, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Transparency = 0.95 }):Play()
	tweenService:Create(toggle, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()

	for _, button in ipairs(smartBar.Buttons:GetChildren()) do
		tweenService:Create(button.UIStroke, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
		tweenService:Create(button, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 36, 0, 36) }):Play()
		tweenService:Create(button.UIGradient, TweenInfo.new(1, Enum.EasingStyle.Quint), { Rotation = 50 }):Play()
		tweenService:Create(button.UIStroke.UIGradient, TweenInfo.new(1, Enum.EasingStyle.Quint), { Rotation = 50 }):Play()
		tweenService:Create(button, TweenInfo.new(0.8, Enum.EasingStyle.Exponential), { Position = UDim2.new(button.Position.X.Scale, 0, 0.5, 0) }):Play()
		tweenService:Create(button, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
		tweenService:Create(button.Icon, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
		task.wait(0.03)
	end
end

local function closeSmartBar()
	smartBarOpen = false

	for _, otherPanel in ipairs(UI:GetChildren()) do
		if smartBar.Buttons:FindFirstChild(otherPanel.Name) then
			if isPanel(otherPanel.Name) and otherPanel.Visible then
				task.spawn(closePanel, otherPanel.Name, true)
				task.wait()
			end
		end
	end

	tweenService:Create(smartBar.Time, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
	for _, Button in ipairs(smartBar.Buttons:GetChildren()) do
		tweenService:Create(Button.UIStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
		tweenService:Create(Button, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 30, 0, 30) }):Play()
		tweenService:Create(Button, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
		tweenService:Create(Button.Icon, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
	end

	local backpack = getRobloxBackpack()
	if backpack then
		tweenService:Create(backpack, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Position = UDim2.new(0, 0, 0, 0) }):Play()
	end

	tweenService:Create(smartBar, TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { BackgroundTransparency = 1 }):Play()
	tweenService:Create(smartBar.UIStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
	tweenService:Create(smartBar.Shadow, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
	tweenService:Create(smartBar, TweenInfo.new(0.5, Enum.EasingStyle.Back), { Size = UDim2.new(0, 531, 0, 64) }):Play()
	tweenService:Create(smartBar, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 1, 73) }):Play()

	-- If tools, move the toggle
	if checkTools() then
		tweenService:Create(toggle, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 1, -68) }):Play()
		tweenService:Create(toastsContainer, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 1, -90) }):Play()
		tweenService:Create(toggle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Rotation = 180 }):Play()
	else
		tweenService:Create(toastsContainer, TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 1, -28) }):Play()
		tweenService:Create(toggle, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut), { Position = UDim2.new(0.5, 0, 1, -5) }):Play()
		tweenService:Create(toggle, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Rotation = 180 }):Play()
	end
end

local function windowFocusChanged(value)
	if not checkSirius() then
		return
	end

	if value then -- Window Focused
		-- setfpscap isn't present on every executor. This ran on the startup path via start(),
		-- so calling it bare aborted the entire script before any UI or events were wired up.
		if setFpsCap then
			local cap = tonumber(settingValue("Artificial FPS Limit"))
			if cap then
				pcall(setFpsCap, cap)
			end
		end
		removeReverbs(0.5)
	else -- Window unfocused
		if settingValue("Muffle audio while unfocused") then
			createReverb(0.7)
		end
		if setFpsCap and settingValue("Limit FPS while unfocused") then
			pcall(setFpsCap, 60)
		end
	end
end

-- SetCore("ChatMakeSystemMessage") only reaches the legacy chat window. On TextChatService the
-- equivalent is DisplaySystemMessage on a channel we're actually in.
local function displaySystemMessage(visuals)
	if legacyChatActive then
		local success = pcall(starterGui.SetCore, starterGui, "ChatMakeSystemMessage", visuals)
		if success then
			return
		end
	end

	pcall(function()
		local channels = textChatService:FindFirstChild("TextChannels")
		local general = channels and channels:FindFirstChild("RBXGeneral")
		if general then
			general:DisplaySystemMessage(visuals.Text)
		end
	end)
end

-- Webhook posts were duplicated across three call sites, each building the same table and each
-- firing at a placeholder URL when logging was on but no webhook had been set.
local function postWebhook(url, payload)
	if not originalRequest then
		return
	end
	if type(url) ~= "string" or not url:match("^https?://") then
		return
	end

	local encodeSuccess, body = pcall(httpService.JSONEncode, httpService, payload)
	if not encodeSuccess then
		return
	end

	task.spawn(function()
		pcall(originalRequest, {
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
end

local function onChatted(player, message)
	local enabled = settingValue("Chat Spy") and siriusValues.chatSpy.enabled
	local chatSpyVisuals = siriusValues.chatSpy.visual

	if not message or not checkSirius() then
		return
	end

	if enabled and player ~= localPlayer then
		local message2 = message:gsub("[\n\r]", ""):gsub("\t", " "):gsub("[ ]+", " ")
		local hidden = true

		local get = getMessage.OnClientEvent:Connect(function(packet, channel)
			local speakerPlayer = packet.FromSpeaker and players:FindFirstChild(packet.FromSpeaker)
			if
				packet.SpeakerUserId == player.UserId
				and packet.Message == message2:sub(#message2 - #packet.Message + 1)
				and (channel == "All" or (channel == "Team" and speakerPlayer and speakerPlayer.Team == localPlayer.Team))
			then
				hidden = false
			end
		end)

		task.wait(1)

		get:Disconnect()

		if hidden and enabled then
			chatSpyVisuals.Text = "Sirius Spy - [" .. player.Name .. "]: " .. message2
			displaySystemMessage(chatSpyVisuals)
		end
	end

	if settingValue("Log Messages") then
		postWebhook(settingValue("Message Webhook URL"), {
			["content"] = message,
			["avatar_url"] = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. player.UserId .. "&width=420&height=420&format=png",
			["username"] = player.DisplayName,
			["allowed_mentions"] = { parse = {} },
		})
	end
end

local function sortPlayers()
	-- The old version called table.remove while iterating the same array with ipairs, so every
	-- removal shifted the list under the iterator and half the entries were skipped - leaving
	-- Template/Placeholder frames in the sort and mis-ordering the rest.
	local entries = {}
	for _, child in ipairs(playerlistPanel.Interactions.List:GetChildren()) do
		if child.ClassName == "Frame" and child.Name ~= "Placeholder" and child.Name ~= "Template" then
			table.insert(entries, child)
		end
	end

	table.sort(entries, function(playerA, playerB)
		return playerA.Name:lower() < playerB.Name:lower()
	end)

	for index, frame in ipairs(entries) do
		frame.LayoutOrder = index
	end
end

-- Spectate: point the camera at another player's humanoid and restore it on toggle-off. Kept
-- purely client-side, so it works anywhere without touching the server.
local spectating

local function restoreCamera()
	spectating = nil
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	camera.CameraType = Enum.CameraType.Custom
end

local function toggleSpectate(player)
	if spectating == player then
		restoreCamera()
		queueNotification("Stopped Spectating", "Camera returned to your character.", 4400696294)
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not humanoid then
		queueNotification("Unable to Spectate", player.DisplayName .. " doesn't have a loaded character right now.", 4370317928)
		return false
	end

	spectating = player
	camera.CameraSubject = humanoid
	camera.CameraType = Enum.CameraType.Custom
	queueNotification("Spectating", "Now spectating " .. player.DisplayName .. ".", 4400696294)
	return true
end

local function teleportTo(player)
	-- player.Character rather than a workspace name lookup: plenty of experiences reparent or
	-- rename characters, and the name lookup would happily match an unrelated part.
	local targetCharacter = player.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	local localCharacter = localPlayer.Character
	local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")

	if targetRoot and localRoot then
		queueNotification("Teleportation", "Teleporting to " .. player.DisplayName .. ".")
		-- Preserve our own orientation instead of snapping to an identity rotation
		localRoot.CFrame = CFrame.new(targetRoot.Position) * (localRoot.CFrame - localRoot.CFrame.Position)
	else
		queueNotification("Teleportation Error", player.DisplayName .. " cannot be teleported to right now.")
	end
end

local function createPlayer(player)
	if not checkSirius() then
		return
	end

	if playerlistPanel.Interactions.List:FindFirstChild(player.Name) then
		return
	end

	local newPlayer = playerlistPanel.Interactions.List.Template:Clone()
	newPlayer.Name = player.Name
	newPlayer.Parent = playerlistPanel.Interactions.List
	newPlayer.Visible = not searchingForPlayer

	newPlayer.NoActions.Visible = false
	newPlayer.PlayerInteractions.Visible = false
	newPlayer.Role.Visible = false

	newPlayer.Size = UDim2.new(0, 539, 0, 45)
	newPlayer.DisplayName.Position = UDim2.new(0, 53, 0.5, 0)
	newPlayer.DisplayName.Size = UDim2.new(0, 224, 0, 16)
	newPlayer.Avatar.Size = UDim2.new(0, 30, 0, 30)

	sortPlayers()

	newPlayer.DisplayName.TextTransparency = 0
	newPlayer.DisplayName.TextScaled = true
	newPlayer.DisplayName.FontFace.Weight = Enum.FontWeight.Medium
	newPlayer.DisplayName.Text = player.DisplayName
	newPlayer.Avatar.Image = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. player.UserId .. "&width=420&height=420&format=png"

	if creatorType == Enum.CreatorType.Group then
		task.spawn(function()
			local role = player:GetRoleInGroup(creatorId)
			if role == "Guest" then
				newPlayer.Role.Text = "Group Rank: None"
			else
				newPlayer.Role.Text = "Group Rank: " .. role
			end

			newPlayer.Role.Visible = true
			newPlayer.Role.TextTransparency = 1
		end)
	end

	local function openInteractions()
		if newPlayer.PlayerInteractions.Visible then
			return
		end

		newPlayer.PlayerInteractions.BackgroundTransparency = 1
		for _, interaction in ipairs(newPlayer.PlayerInteractions:GetChildren()) do
			if interaction.ClassName == "Frame" and interaction.Name ~= "Placeholder" then
				interaction.BackgroundTransparency = 1
				interaction.Shadow.ImageTransparency = 1
				interaction.Icon.ImageTransparency = 1
				interaction.UIStroke.Transparency = 1
			end
		end

		newPlayer.PlayerInteractions.Visible = true

		for _, interaction in ipairs(newPlayer.PlayerInteractions:GetChildren()) do
			if interaction.ClassName == "Frame" and interaction.Name ~= "Placeholder" then
				tweenService:Create(interaction.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
				tweenService:Create(interaction.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
				tweenService:Create(interaction.Shadow, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
				tweenService:Create(interaction, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
			end
		end
	end

	local function closeInteractions()
		if not newPlayer.PlayerInteractions.Visible then
			return
		end
		for _, interaction in ipairs(newPlayer.PlayerInteractions:GetChildren()) do
			if interaction.ClassName == "Frame" and interaction.Name ~= "Placeholder" then
				tweenService:Create(interaction.UIStroke, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
				tweenService:Create(interaction.Icon, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
				tweenService:Create(interaction.Shadow, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
				tweenService:Create(interaction, TweenInfo.new(0.3, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
			end
		end
		task.wait(0.35)
		newPlayer.PlayerInteractions.Visible = false
	end

	newPlayer.MouseEnter:Connect(function()
		if debounce or not playerlistPanel.Visible then
			return
		end
		tweenService:Create(newPlayer.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
		tweenService:Create(newPlayer.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
	end)

	newPlayer.MouseLeave:Connect(function()
		if debounce or not playerlistPanel.Visible then
			return
		end
		task.spawn(closeInteractions)
		tweenService:Create(newPlayer.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0, 53, 0.5, 0) }):Play()
		tweenService:Create(newPlayer, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 539, 0, 45) }):Play()
		tweenService:Create(newPlayer.Avatar, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 30, 0, 30) }):Play()
		tweenService:Create(newPlayer.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
		tweenService:Create(newPlayer.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
		tweenService:Create(newPlayer.Role, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
	end)

	newPlayer.Interact.MouseButton1Click:Connect(function()
		if debounce or not playerlistPanel.Visible then
			return
		end
		if creatorType == Enum.CreatorType.Group then
			tweenService:Create(newPlayer.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0, 73, 0.39, 0) }):Play()
			tweenService:Create(newPlayer.Role, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
		else
			tweenService:Create(newPlayer.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0, 73, 0.5, 0) }):Play()
		end

		if player ~= localPlayer then
			openInteractions()
		end

		tweenService:Create(newPlayer, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 539, 0, 75) }):Play()

		tweenService:Create(newPlayer.DisplayName, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
		tweenService:Create(newPlayer.Avatar, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 50, 0, 50) }):Play()
		tweenService:Create(newPlayer.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
	end)

	-- Kill was never implemented - the handler played a colour animation and raised a
	-- "Simulating Kill Notification" toast. Killing another player is server-authoritative and
	-- can't be done generically from the client, so the button is hidden rather than faked.
	newPlayer.PlayerInteractions.Kill.Visible = false

	newPlayer.PlayerInteractions.Teleport.Interact.MouseButton1Click:Connect(function()
		tweenService:Create(newPlayer.PlayerInteractions.Teleport, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { BackgroundColor3 = Color3.fromRGB(0, 152, 111) }):Play()
		tweenService:Create(newPlayer.PlayerInteractions.Teleport.Icon, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { ImageColor3 = Color3.fromRGB(220, 220, 220) }):Play()
		tweenService:Create(newPlayer.PlayerInteractions.Teleport.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Color = Color3.fromRGB(0, 152, 111) }):Play()
		teleportTo(player)
		task.wait(0.5)
		tweenService:Create(newPlayer.PlayerInteractions.Teleport, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { BackgroundColor3 = Color3.fromRGB(50, 50, 50) }):Play()
		tweenService:Create(newPlayer.PlayerInteractions.Teleport.Icon, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { ImageColor3 = Color3.fromRGB(100, 100, 100) }):Play()
		tweenService:Create(newPlayer.PlayerInteractions.Teleport.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Color = Color3.fromRGB(60, 60, 60) }):Play()
	end)

	-- Spectate now actually spectates instead of raising a "Simulating Spectate" toast
	newPlayer.PlayerInteractions.Spectate.Interact.MouseButton1Click:Connect(function()
		local nowSpectating = toggleSpectate(player)

		local activeColor = Color3.fromRGB(0, 152, 111)
		local idleColor = Color3.fromRGB(50, 50, 50)

		tweenService:Create(newPlayer.PlayerInteractions.Spectate, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { BackgroundColor3 = nowSpectating and activeColor or idleColor }):Play()
		tweenService
			:Create(
				newPlayer.PlayerInteractions.Spectate.Icon,
				TweenInfo.new(0.4, Enum.EasingStyle.Quint),
				{ ImageColor3 = nowSpectating and Color3.fromRGB(220, 220, 220) or Color3.fromRGB(100, 100, 100) }
			)
			:Play()
		tweenService:Create(newPlayer.PlayerInteractions.Spectate.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Color = nowSpectating and activeColor or Color3.fromRGB(60, 60, 60) }):Play()
	end)

	newPlayer.PlayerInteractions.Locate.Interact.MouseButton1Click:Connect(function()
		locatedPlayers[player.Name] = not locatedPlayers[player.Name] or nil
		local nowLocating = locatedPlayers[player.Name] == true

		local highlight = espContainer:FindFirstChild(player.Name)
		if highlight then
			highlight.Enabled = isHighlightEnabledFor(player.Name)
		end

		local activeColor = Color3.fromRGB(0, 152, 111)
		local idleColor = Color3.fromRGB(50, 50, 50)
		local activeStroke = Color3.fromRGB(0, 152, 111)
		local idleStroke = Color3.fromRGB(60, 60, 60)
		local activeIcon = Color3.fromRGB(220, 220, 220)
		local idleIcon = Color3.fromRGB(100, 100, 100)

		tweenService:Create(newPlayer.PlayerInteractions.Locate, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { BackgroundColor3 = nowLocating and activeColor or idleColor }):Play()
		tweenService:Create(newPlayer.PlayerInteractions.Locate.Icon, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { ImageColor3 = nowLocating and activeIcon or idleIcon }):Play()
		tweenService:Create(newPlayer.PlayerInteractions.Locate.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Color = nowLocating and activeStroke or idleStroke }):Play()

		queueNotification(nowLocating and "Now Tracking" or "Stopped Tracking", (nowLocating and "Now tracking " or "Stopped tracking ") .. player.DisplayName .. ".")
	end)
end

local function removePlayer(player)
	if not checkSirius() then
		return
	end

	local entry = playerlistPanel.Interactions.List:FindFirstChild(player.Name)
	if entry then
		entry:Destroy()
	end
end

local function openSettings()
	debounce = true

	settingsPanel.BackgroundTransparency = 1
	settingsPanel.Title.TextTransparency = 1
	settingsPanel.Subtitle.TextTransparency = 1
	settingsPanel.Back.ImageTransparency = 1
	settingsPanel.Shadow.ImageTransparency = 1

	wipeTransparency(settingsPanel.SettingTypes, 1, true)

	settingsPanel.Visible = true
	settingsPanel.UIGradient.Enabled = true
	settingsPanel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	settingsPanel.UIGradient.Color =
		ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0.0470588, 0.0470588, 0.0470588)), ColorSequenceKeypoint.new(1, Color3.new(0.0470588, 0.0470588, 0.0470588)) })
	settingsPanel.UIGradient.Offset = Vector2.new(0, 1.7)
	settingsPanel.SettingTypes.Visible = true
	settingsPanel.SettingLists.Visible = false
	settingsPanel.Size = UDim2.new(0, 550, 0, 340)
	settingsPanel.Title.Position = UDim2.new(0.045, 0, 0.057, 0)

	settingsPanel.Title.Text = "Settings"
	settingsPanel.Subtitle.Text = "Adjust your preferences, set new keybinds, test out new features and more."

	tweenService:Create(settingsPanel, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 613, 0, 384) }):Play()
	tweenService:Create(settingsPanel, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(settingsPanel.Shadow, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
	tweenService:Create(settingsPanel.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
	tweenService:Create(settingsPanel.Subtitle, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()

	task.wait(0.1)

	for _, settingType in ipairs(settingsPanel.SettingTypes:GetChildren()) do
		if settingType.ClassName == "Frame" then
			local gradientRotation = math.random(78, 95)

			tweenService:Create(settingType.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Rotation = gradientRotation }):Play()
			tweenService:Create(settingType.Shadow.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Rotation = gradientRotation }):Play()
			tweenService:Create(settingType.UIStroke.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Rotation = gradientRotation }):Play()
			tweenService:Create(settingType, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
			tweenService:Create(settingType.Shadow, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
			tweenService:Create(settingType.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
			tweenService:Create(settingType.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.2 }):Play()

			task.wait(0.02)
		end
	end

	for _, settingList in ipairs(settingsPanel.SettingLists:GetChildren()) do
		if settingList.ClassName == "ScrollingFrame" then
			for _, setting in ipairs(settingList:GetChildren()) do
				if setting.ClassName == "Frame" then
					setting.Visible = true
				end
			end
		end
	end

	debounce = false
end

local function closeSettings()
	debounce = true

	for _, settingType in ipairs(settingsPanel.SettingTypes:GetChildren()) do
		if settingType.ClassName == "Frame" then
			tweenService:Create(settingType, TweenInfo.new(0.1, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()
			tweenService:Create(settingType.Shadow, TweenInfo.new(0.05, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
			tweenService:Create(settingType.UIStroke, TweenInfo.new(0.05, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
			tweenService:Create(settingType.Title, TweenInfo.new(0.05, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
		end
	end

	tweenService:Create(settingsPanel.Shadow, TweenInfo.new(0.1, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
	tweenService:Create(settingsPanel.Back, TweenInfo.new(0.1, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
	tweenService:Create(settingsPanel.Title, TweenInfo.new(0.1, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()
	tweenService:Create(settingsPanel.Subtitle, TweenInfo.new(0.1, Enum.EasingStyle.Quint), { TextTransparency = 1 }):Play()

	for _, settingList in ipairs(settingsPanel.SettingLists:GetChildren()) do
		if settingList.ClassName == "ScrollingFrame" then
			for _, setting in ipairs(settingList:GetChildren()) do
				if setting.ClassName == "Frame" then
					setting.Visible = false
				end
			end
		end
	end

	tweenService:Create(settingsPanel, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 520, 0, 0) }):Play()
	tweenService:Create(settingsPanel, TweenInfo.new(0.55, Enum.EasingStyle.Quint), { BackgroundTransparency = 1 }):Play()

	task.wait(0.55)

	settingsPanel.Visible = false
	debounce = false
end

-- The whole siriusSettings tree used to be serialised, including Color3 values and the keybind
-- callback functions, which meant the file carried a copy of the UI metadata and silently
-- dropped anything JSONEncode couldn't represent. Only { id = current } is persisted now, so the
-- file is small, stable across releases, and a stale key can't collide with anything.
local function settingsPath()
	return siriusValues.siriusFolder .. "/" .. siriusValues.settingsFile
end

local function saveSettings()
	if not writefile then
		return
	end

	checkFolder()

	local flat = {}
	for _, category in ipairs(siriusSettings) do
		for _, setting in ipairs(category.categorySettings) do
			if setting.current ~= nil then
				flat[setting.id] = setting.current
			end
		end
	end

	local encodeSuccess, encoded = pcall(httpService.JSONEncode, httpService, flat)
	if not encodeSuccess then
		warn("Sirius | Unable to encode settings: " .. tostring(encoded))
		return
	end

	pcall(writefile, settingsPath(), encoded)
end

local function assembleSettings()
	if isfile and readfile and isfile(settingsPath()) then
		local success, stored = pcall(function()
			return httpService:JSONDecode(readfile(settingsPath()))
		end)

		if success and type(stored) == "table" then
			for _, category in ipairs(siriusSettings) do
				for _, setting in ipairs(category.categorySettings) do
					-- Read the flat map, but stay compatible with files written by 1.27 and
					-- earlier, which stored the full nested category tree.
					local value = stored[setting.id]

					if value == nil and stored[1] then
						for _, storedCategory in ipairs(stored) do
							if type(storedCategory) == "table" and type(storedCategory.categorySettings) == "table" then
								for _, storedSetting in ipairs(storedCategory.categorySettings) do
									if storedSetting.id == setting.id then
										value = storedSetting.current
										break
									end
								end
							end
						end
					end

					-- Type-check before applying: a hand-edited or stale file used to be able to
					-- put a string where a boolean belonged and take out the feature reading it.
					if value ~= nil and (setting.current == nil or typeof(value) == typeof(setting.current)) then
						setting.current = value
					end
				end
			end
		else
			warn("Sirius | Settings file was unreadable and has been reset to defaults")
		end
	end

	saveSettings() -- write back, picking up any settings added since the file was created

	settingsPanel.Back.MouseButton1Click:Connect(function()
		tweenService:Create(settingsPanel.Back, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 1 }):Play()
		tweenService:Create(settingsPanel.Back, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.002, 0, 0.052, 0) }):Play()
		tweenService:Create(settingsPanel.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.045, 0, 0.057, 0) }):Play()
		tweenService:Create(settingsPanel.UIGradient, TweenInfo.new(1, Enum.EasingStyle.Exponential), { Offset = Vector2.new(0, 1.3) }):Play()
		settingsPanel.Title.Text = "Settings"
		settingsPanel.Subtitle.Text = "Adjust your preferences, set new keybinds, test out new features and more"
		settingsPanel.SettingTypes.Visible = true
		settingsPanel.SettingLists.Visible = false
	end)

	for _, category in siriusSettings do
		local newCategory = settingsPanel.SettingTypes.Template:Clone()
		newCategory.Name = category.name
		newCategory.Title.Text = string.upper(category.name)
		newCategory.Parent = settingsPanel.SettingTypes
		newCategory.UIGradient.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0.0392157, 0.0392157, 0.0392157)), ColorSequenceKeypoint.new(1, category.color) })

		newCategory.Visible = true

		local hue, sat, val = Color3.toHSV(category.color)

		hue = math.clamp(hue + 0.01, 0, 1)
		sat = math.clamp(sat + 0.1, 0, 1)
		val = math.clamp(val + 0.2, 0, 1)

		local newColor = Color3.fromHSV(hue, sat, val)
		newCategory.UIStroke.UIGradient.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0.117647, 0.117647, 0.117647)), ColorSequenceKeypoint.new(1, newColor) })
		newCategory.Shadow.UIGradient.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0.117647, 0.117647, 0.117647)), ColorSequenceKeypoint.new(1, newColor) })

		local newList = settingsPanel.SettingLists.Template:Clone()
		newList.Name = category.name
		newList.Parent = settingsPanel.SettingLists

		newList.Visible = true

		for _, obj in ipairs(newList:GetChildren()) do
			if obj.Name ~= "Placeholder" and obj.Name ~= "UIListLayout" then
				obj:Destroy()
			end
		end

		newCategory.Interact.MouseButton1Click:Connect(function()
			if settingsPanel.SettingLists:FindFirstChild(category.name) then
				settingsPanel.UIGradient.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(0.0470588, 0.0470588, 0.0470588)), ColorSequenceKeypoint.new(1, category.color) })
				settingsPanel.SettingTypes.Visible = false
				settingsPanel.SettingLists.Visible = true
				settingsPanel.SettingLists.UIPageLayout:JumpTo(settingsPanel.SettingLists[category.name])
				settingsPanel.Subtitle.Text = category.description
				settingsPanel.Back.Visible = true
				settingsPanel.Title.Text = category.name

				local gradientRotation = math.random(78, 95)
				settingsPanel.UIGradient.Rotation = gradientRotation
				tweenService:Create(settingsPanel.UIGradient, TweenInfo.new(0.5, Enum.EasingStyle.Exponential), { Offset = Vector2.new(0, 0.65) }):Play()
				tweenService:Create(settingsPanel.Back, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
				tweenService:Create(settingsPanel.Back, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.041, 0, 0.052, 0) }):Play()
				tweenService:Create(settingsPanel.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Position = UDim2.new(0.091, 0, 0.057, 0) }):Play()
			else
				-- error
				closeSettings()
			end
		end)

		newCategory.MouseEnter:Connect(function()
			tweenService:Create(newCategory.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
			tweenService:Create(newCategory.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.4) }):Play()
			tweenService:Create(newCategory.UIStroke.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.2) }):Play()
			tweenService:Create(newCategory.Shadow.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.2) }):Play()
		end)

		newCategory.MouseLeave:Connect(function()
			tweenService:Create(newCategory.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.2 }):Play()
			tweenService:Create(newCategory.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.65) }):Play()
			tweenService:Create(newCategory.UIStroke.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.4) }):Play()
			tweenService:Create(newCategory.Shadow.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0.4) }):Play()
		end)

		for _, setting in ipairs(category.categorySettings) do
			if not setting.hidden then
				local settingType = setting.settingType
				local minimumLicense = setting.minimumLicense
				local object = nil

				if settingType == "Boolean" then
					local newSwitch = settingsPanel.SettingLists.Template.SwitchTemplate:Clone()
					object = newSwitch
					newSwitch.Name = setting.name
					newSwitch.Parent = newList
					newSwitch.Visible = true
					newSwitch.Title.Text = setting.name

					if setting.current == true then
						newSwitch.Switch.Indicator.Position = UDim2.new(1, -20, 0.5, 0)
						newSwitch.Switch.Indicator.UIStroke.Color = Color3.fromRGB(220, 220, 220)
						newSwitch.Switch.Indicator.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
						newSwitch.Switch.Indicator.BackgroundTransparency = 0.6
					end

					if minimumLicense then
						if (minimumLicense == "Pro" and not Pro) or (minimumLicense == "Essential" and not (Pro or Essential)) then
							newSwitch.Switch.Indicator.Position = UDim2.new(1, -40, 0.5, 0)
							newSwitch.Switch.Indicator.UIStroke.Color = Color3.fromRGB(255, 255, 255)
							newSwitch.Switch.Indicator.BackgroundColor3 = Color3.fromRGB(235, 235, 235)
							newSwitch.Switch.Indicator.BackgroundTransparency = 0.75
						end
					end

					newSwitch.Interact.MouseButton1Click:Connect(function()
						if minimumLicense then
							if (minimumLicense == "Pro" and not Pro) or (minimumLicense == "Essential" and not (Pro or Essential)) then
								queueNotification(
									"This feature is locked",
									"You must be " .. minimumLicense .. " or higher to use " .. setting.name .. ". \n\nUpgrade at https://sirius.menu.",
									4483345875
								)
								return
							end
						end

						setting.current = not setting.current
						saveSettings()
						if setting.current == true then
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Position = UDim2.new(1, -20, 0.5, 0) }):Play()
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = UDim2.new(0, 12, 0, 12) }):Play()
							tweenService
								:Create(newSwitch.Switch.Indicator.UIStroke, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Color = Color3.fromRGB(200, 200, 200) })
								:Play()
							tweenService
								:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.8, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundColor3 = Color3.fromRGB(255, 255, 255) })
								:Play()
							tweenService:Create(newSwitch.Switch.Indicator.UIStroke, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Transparency = 0.5 }):Play()
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.6 }):Play()
							task.wait(0.05)
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = UDim2.new(0, 17, 0, 17) }):Play()
						else
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Position = UDim2.new(1, -40, 0.5, 0) }):Play()
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = UDim2.new(0, 12, 0, 12) }):Play()
							tweenService
								:Create(newSwitch.Switch.Indicator.UIStroke, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Color = Color3.fromRGB(255, 255, 255) })
								:Play()
							tweenService:Create(newSwitch.Switch.Indicator.UIStroke, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Transparency = 0.7 }):Play()
							tweenService
								:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.8, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundColor3 = Color3.fromRGB(235, 235, 235) })
								:Play()
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.75 }):Play()
							task.wait(0.05)
							tweenService:Create(newSwitch.Switch.Indicator, TweenInfo.new(0.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), { Size = UDim2.new(0, 17, 0, 17) }):Play()
						end
					end)
				elseif settingType == "Input" then
					local newInput = settingsPanel.SettingLists.Template.InputTemplate:Clone()
					object = newInput

					newInput.Name = setting.name
					newInput.InputFrame.InputBox.PlaceholderText = setting.placeholder or "input"
					newInput.Parent = newList

					newInput.InputFrame.InputBox.Text = truncateForDisplay(setting.current)

					newInput.Visible = true
					newInput.Title.Text = setting.name
					newInput.InputFrame.InputBox.TextWrapped = false
					newInput.InputFrame.Size = UDim2.new(0, newInput.InputFrame.InputBox.TextBounds.X + 24, 0, 30)

					-- Focusing restores the untruncated value. Previously the box displayed a
					-- shortened "https://discord.com/ap.." and FocusLost wrote whatever was in the
					-- box straight back to the setting, so simply clicking in and out of the field
					-- permanently replaced a webhook URL with its truncated form.
					newInput.InputFrame.InputBox.Focused:Connect(function()
						newInput.InputFrame.InputBox.Text = tostring(setting.current)
					end)

					newInput.InputFrame.InputBox.FocusLost:Connect(function()
						if minimumLicense then
							if (minimumLicense == "Pro" and not Pro) or (minimumLicense == "Essential" and not (Pro or Essential)) then
								queueNotification(
									"This feature is locked",
									"You must be " .. minimumLicense .. " or higher to use " .. setting.name .. ". \n\nUpgrade at https://sirius.menu.",
									4483345875
								)
								newInput.InputFrame.InputBox.Text = truncateForDisplay(setting.current)
								return
							end
						end

						local entered = newInput.InputFrame.InputBox.Text
						if entered ~= nil and entered ~= "" then
							setting.current = entered
							saveSettings()
						end

						newInput.InputFrame.InputBox.Text = truncateForDisplay(setting.current)
					end)

					newInput.InputFrame.InputBox:GetPropertyChangedSignal("Text"):Connect(function()
						tweenService
							:Create(
								newInput.InputFrame,
								TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
								{ Size = UDim2.new(0, newInput.InputFrame.InputBox.TextBounds.X + 24, 0, 30) }
							)
							:Play()
					end)
				elseif settingType == "Number" then
					local newInput = settingsPanel.SettingLists.Template.InputTemplate:Clone()
					object = newInput

					newInput.Name = setting.name
					newInput.InputFrame.InputBox.PlaceholderText = setting.placeholder or "number"
					newInput.Parent = newList

					newInput.InputFrame.InputBox.Text = truncateForDisplay(setting.current)

					newInput.Visible = true
					newInput.Title.Text = setting.name
					newInput.InputFrame.InputBox.TextWrapped = false
					newInput.InputFrame.Size = UDim2.new(0, newInput.InputFrame.InputBox.TextBounds.X + 24, 0, 30)

					newInput.InputFrame.InputBox.Focused:Connect(function()
						newInput.InputFrame.InputBox.Text = tostring(setting.current)
					end)

					newInput.InputFrame.InputBox.FocusLost:Connect(function()
						if minimumLicense then
							if (minimumLicense == "Pro" and not Pro) or (minimumLicense == "Essential" and not (Pro or Essential)) then
								queueNotification(
									"This feature is locked",
									"You must be " .. minimumLicense .. " or higher to use " .. setting.name .. ". \n\nUpgrade at https://sirius.menu.",
									4483345875
								)
								newInput.InputFrame.InputBox.Text = truncateForDisplay(setting.current)
								return
							end
						end

						local inputValue = tonumber(newInput.InputFrame.InputBox.Text)

						if inputValue then
							if setting.values then
								setting.current = math.clamp(inputValue, setting.values[1], setting.values[2])
							else
								setting.current = inputValue
							end
							saveSettings()
						end

						newInput.InputFrame.InputBox.Text = truncateForDisplay(setting.current)
					end)

					newInput.InputFrame.InputBox:GetPropertyChangedSignal("Text"):Connect(function()
						tweenService
							:Create(
								newInput.InputFrame,
								TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
								{ Size = UDim2.new(0, newInput.InputFrame.InputBox.TextBounds.X + 24, 0, 30) }
							)
							:Play()
					end)
				elseif settingType == "Key" then
					local newKeybind = settingsPanel.SettingLists.Template.InputTemplate:Clone()
					object = newKeybind
					newKeybind.Name = setting.name
					newKeybind.InputFrame.InputBox.PlaceholderText = setting.placeholder or "listening.."
					newKeybind.InputFrame.InputBox.Text = setting.current or "No Keybind"
					newKeybind.Parent = newList

					newKeybind.Visible = true
					newKeybind.Title.Text = setting.name
					newKeybind.InputFrame.InputBox.TextWrapped = false
					newKeybind.InputFrame.Size = UDim2.new(0, newKeybind.InputFrame.InputBox.TextBounds.X + 24, 0, 30)

					newKeybind.InputFrame.InputBox.FocusLost:Connect(function()
						local capture = checkingForKey
						local ownsCapture = capture and capture.object == newKeybind
						if ownsCapture then
							checkingForKey = nil
						end

						if minimumLicense then
							if (minimumLicense == "Pro" and not Pro) or (minimumLicense == "Essential" and not (Pro or Essential)) then
								queueNotification(
									"This feature is locked",
									"You must be " .. minimumLicense .. " or higher to use " .. setting.name .. ". \n\nUpgrade at https://sirius.menu.",
									4483345875
								)
								newKeybind.InputFrame.InputBox.Text = setting.current or "No Keybind"
								return
							end
						end

						if newKeybind.InputFrame.InputBox.Text == nil or newKeybind.InputFrame.InputBox.Text == "" then
							setting.current = ownsCapture and capture.previous or setting.current
							newKeybind.InputFrame.InputBox.Text = setting.current or "No Keybind"
						end
					end)

					newKeybind.InputFrame.InputBox.Focused:Connect(function()
						checkingForKey = { data = setting, object = newKeybind, previous = setting.current }
						newKeybind.InputFrame.InputBox.Text = ""
					end)

					newKeybind.InputFrame.InputBox:GetPropertyChangedSignal("Text"):Connect(function()
						tweenService
							:Create(
								newKeybind.InputFrame,
								TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
								{ Size = UDim2.new(0, newKeybind.InputFrame.InputBox.TextBounds.X + 24, 0, 30) }
							)
							:Play()
					end)
				end

				if object then
					if setting.description then
						object.Description.Visible = true
						object.Description.TextWrapped = true
						object.Description.Size = UDim2.new(0, 333, 5, 0)
						object.Description.Size = UDim2.new(0, 333, 0, 999)
						object.Description.Text = setting.description
						object.Description.Size = UDim2.new(0, 333, 0, object.Description.TextBounds.Y + 10)
						object.Size = UDim2.new(0, 558, 0, object.Description.TextBounds.Y + 44)
					end

					if minimumLicense then
						object.LicenseDisplay.Visible = true
						object.Title.Position = UDim2.new(0, 18, 0, 26)
						object.Description.Position = UDim2.new(0, 18, 0, 43)
						object.Size = UDim2.new(0, 558, 0, object.Size.Y.Offset + 13)
						object.LicenseDisplay.Text = string.upper(minimumLicense) .. " FEATURE"
					end

					local objectTouching
					object.MouseEnter:Connect(function()
						objectTouching = true
						tweenService:Create(object.UIStroke, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Transparency = 0.45 }):Play()
						tweenService:Create(object, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.83 }):Play()
					end)

					object.MouseLeave:Connect(function()
						objectTouching = false
						tweenService:Create(object.UIStroke, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Transparency = 0.6 }):Play()
						tweenService:Create(object, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.9 }):Play()
					end)

					if object:FindFirstChild("Interact") then
						object.Interact.MouseButton1Click:Connect(function()
							tweenService:Create(object.UIStroke, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Transparency = 1 }):Play()
							tweenService:Create(object, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.8 }):Play()
							task.wait(0.1)
							if objectTouching then
								tweenService:Create(object.UIStroke, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Transparency = 0.45 }):Play()
								tweenService:Create(object, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.83 }):Play()
							else
								tweenService:Create(object.UIStroke, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Transparency = 0.6 }):Play()
								tweenService:Create(object, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { BackgroundTransparency = 0.9 }):Play()
							end
						end)
					end
				end
			end
		end
	end
end

local function initialiseAntiKick()
	if not settingValue("Client-Based Anti Kick") then
		return
	end
	if not (hookMetamethod and optional(getnamecallmethod)) then
		return
	end

	-- Metamethod hooks can't be undone, so re-running Sirius must not install a second layer
	if env.siriusAntiKickInstalled then
		return
	end
	env.siriusAntiKickInstalled = true

	local hookSuccess, hookError = pcall(function()
		local originalIndex
		local originalNamecall

		originalIndex = hookMetamethod(game, "__index", function(self, method)
			if self == localPlayer and type(method) == "string" and method:lower() == "kick" and settingValue("Client-Based Anti Kick") and checkSirius() then
				queueNotification("Kick Prevented", "Sirius has prevented you from being kicked by the client.", 4400699701)
				return error("Expected ':' not '.' calling member function Kick", 2)
			end
			return originalIndex(self, method)
		end)

		originalNamecall = hookMetamethod(game, "__namecall", function(self, ...)
			if self == localPlayer and getnamecallmethod():lower() == "kick" and settingValue("Client-Based Anti Kick") and checkSirius() then
				queueNotification("Kick Prevented", "Sirius has prevented you from being kicked by the client.", 4400699701)
				return
			end
			return originalNamecall(self, ...)
		end)
	end)

	if not hookSuccess then
		env.siriusAntiKickInstalled = nil
		warn("Sirius | Anti Kick could not be installed on this executor: " .. tostring(hookError))
	end
end

local function boost()
	-- loadWithTimeout so an unreachable CDN can't hang this thread indefinitely
	loadWithTimeout("https://raw.githubusercontent.com/SiriusSoftwareLtd/Sirius/refs/heads/request/boost.lua")
end

local function start()
	if siriusValues.releaseType == "Experimental" then -- Make this more secure.
		if not Pro then
			localPlayer:Kick("This is an experimental release, you must be Pro to run this. \n\nUpgrade at https://sirius.menu/")
			return
		end
	end
	windowFocusChanged(true)

	UI.Enabled = true

	assembleSettings()
	ensureFrameProperties()
	sortActions()
	initialiseAntiKick()
	checkLastVersion()
	task.spawn(boost)

	smartBar.Time.Text = os.date("%H") .. ":" .. os.date("%M")

	toggle.Visible = not settingValue("Hide Toggle Button")

	-- Startup sound: fetchFromCDN now actually returns its payload, so this works again
	if not settingValue("Load Hidden") then
		if settingValue("Startup Sound Effect") and getCustomAsset and isfile then
			task.spawn(function()
				local startupPath = siriusValues.siriusFolder .. "/Assets/startup.wav"

				if not isfile(startupPath) then
					fetchFromCDN("startup.wav", true, "Assets/startup.wav")
				end

				if not isfile(startupPath) then
					return
				end

				local assetSuccess, startupAsset = pcall(getCustomAsset, startupPath)
				if not assetSuccess or not startupAsset then
					return
				end

				local startupSound = Instance.new("Sound")
				startupSound.Parent = UI
				startupSound.SoundId = startupAsset
				startupSound.Name = "startupSound"
				startupSound.Volume = 0.85
				startupSound.PlayOnRemove = true
				startupSound:Destroy()
			end)
		end

		openSmartBar()
	else
		closeSmartBar()
	end

	-- Analytics. loadWithTimeout instead of a bare HttpGet: this sits on the startup path and an
	-- unreachable raw.githubusercontent used to stall it for the full HTTP timeout. Sampled to
	-- roughly 1 in 10 launches, matching Rayfield.
	if math.random(10) == 1 then
		task.spawn(function()
			local Analytics = loadWithTimeout("https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/refs/heads/main/reporter.lua")
			if not Analytics then
				return
			end

			pcall(function()
				local reporter = Analytics.new({
					url = "https://rayfield-collect.sirius-software-ltd.workers.dev",
					token = "e5b910510792f6604f36a3dd4a3be739da07e2b5f0f502acbc4282afbfc2706a",
					product_name = "Sirius",
					category = "Script",
				})

				reporter:windowCreated({
					script_name = "Sirius",
					script_version = siriusValues.siriusVersion,
				})
			end)
		end)
	end

	-- Chat Spy is built on the legacy chat system, which Roblox retired. Rather than appearing
	-- switched on while doing nothing, say so once.
	if settingValue("Chat Spy") and not legacyChatActive then
		task.delay(6, function()
			queueNotification(
				"Chat Spy unavailable",
				"This experience uses Roblox's current chat system, which routes whispers through channels your client never receives. Chat Spy only works on the legacy chat system.",
				4370336704
			)
		end)
	end

	-- Resolved once so the JobId copy button doesn't make a yielding, rate-limitable web call
	-- from inside a click handler
	task.spawn(function()
		local infoSuccess, info = pcall(marketplaceService.GetProductInfo, marketplaceService, placeId)
		placeName = (infoSuccess and info and info.Name) or "this experience"
	end)
end

-- Sirius Events

-- start() reaches out to the executor, the filesystem and the network. A failure in any one of
-- those used to take the whole script down before a single event below was connected.
local startSuccess, startError = pcall(start)
if not startSuccess then
	warn("Sirius | Startup error: " .. tostring(startError))
	pcall(queueNotification, "Sirius had trouble starting", "Some features may be unavailable. Report this at sirius.menu/discord: " .. tostring(startError), 4370336704)
end

toggle.MouseButton1Click:Connect(function()
	if smartBarOpen then
		closeSmartBar()
	else
		openSmartBar()
	end
end)

characterPanel.Interactions.Reset.MouseButton1Click:Connect(function()
	resetSliders()

	characterPanel.Interactions.Reset.Rotation = 360
	queueNotification("Slider Values Reset", "Successfully reset all character panel sliders", 4400696294)
	tweenService:Create(characterPanel.Interactions.Reset, TweenInfo.new(0.5, Enum.EasingStyle.Back), { Rotation = 0 }):Play()
end)

characterPanel.Interactions.Reset.MouseEnter:Connect(function()
	if debounce then
		return
	end
	tweenService:Create(characterPanel.Interactions.Reset, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
end)
characterPanel.Interactions.Reset.MouseLeave:Connect(function()
	if debounce then
		return
	end
	tweenService:Create(characterPanel.Interactions.Reset, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageTransparency = 0.7 }):Play()
end)

local playerSearch = playerlistPanel.Interactions.SearchFrame.SearchBox -- move this up to Variables once finished

playerSearch:GetPropertyChangedSignal("Text"):Connect(function()
	local query = string.lower(playerSearch.Text)

	for _, player in ipairs(playerlistPanel.Interactions.List:GetChildren()) do
		if player.ClassName == "Frame" and player.Name ~= "Placeholder" and player.Name ~= "Template" then
			local displayName = player:FindFirstChild("DisplayName")
			local displayText = displayName and string.lower(displayName.Text) or ""
			if string.find(string.lower(player.Name), query, 1, true) or string.find(displayText, query, 1, true) then
				player.Visible = true
			else
				player.Visible = false
			end
		end
	end

	if #playerSearch.Text == 0 then
		searchingForPlayer = false
		for _, player in ipairs(playerlistPanel.Interactions.List:GetChildren()) do
			if player.ClassName == "Frame" and player.Name ~= "Placeholder" and player.Name ~= "Template" then
				player.Visible = true
			end
		end
	else
		searchingForPlayer = true
	end
end)

characterPanel.Interactions.Serverhop.MouseEnter:Connect(function()
	if debounce then
		return
	end
	tweenService:Create(characterPanel.Interactions.Serverhop, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.5 }):Play()
	tweenService:Create(characterPanel.Interactions.Serverhop.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.1 }):Play()
	tweenService:Create(characterPanel.Interactions.Serverhop.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
end)

characterPanel.Interactions.Serverhop.MouseLeave:Connect(function()
	if debounce then
		return
	end
	tweenService:Create(characterPanel.Interactions.Serverhop, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(characterPanel.Interactions.Serverhop.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.5 }):Play()
	tweenService:Create(characterPanel.Interactions.Serverhop.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
end)

characterPanel.Interactions.Rejoin.MouseEnter:Connect(function()
	if debounce then
		return
	end
	tweenService:Create(characterPanel.Interactions.Rejoin, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.5 }):Play()
	tweenService:Create(characterPanel.Interactions.Rejoin.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.1 }):Play()
	tweenService:Create(characterPanel.Interactions.Rejoin.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
end)

characterPanel.Interactions.Rejoin.MouseLeave:Connect(function()
	if debounce then
		return
	end
	tweenService:Create(characterPanel.Interactions.Rejoin, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
	tweenService:Create(characterPanel.Interactions.Rejoin.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.5 }):Play()
	tweenService:Create(characterPanel.Interactions.Rejoin.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
end)

musicPanel.Close.MouseButton1Click:Connect(function()
	if musicPanel.Visible and not debounce then
		closeMusic()
	end
end)

musicPanel.Add.Interact.MouseButton1Click:Connect(function()
	musicPanel.AddBox.Input:ReleaseFocus()
	addToQueue(musicPanel.AddBox.Input.Text)
end)

musicPanel.Menu.TogglePlaying.MouseButton1Click:Connect(function()
	if currentAudio then
		currentAudio.Playing = not currentAudio.Playing
		musicPanel.Menu.TogglePlaying.ImageRectOffset = currentAudio.Playing and Vector2.new(804, 124) or Vector2.new(764, 244)
	end
end)

musicPanel.Menu.Next.MouseButton1Click:Connect(function()
	if currentAudio then
		if #musicQueue == 0 then
			currentAudio.Playing = false
			currentAudio.SoundId = ""
			return
		end

		if musicPanel.Queue.List:FindFirstChild(tostring(musicQueue[1].instanceName)) then
			musicPanel.Queue.List:FindFirstChild(tostring(musicQueue[1].instanceName)):Destroy()
		end

		musicPanel.Menu.TogglePlaying.ImageRectOffset = currentAudio.Playing and Vector2.new(804, 124) or Vector2.new(764, 244)

		table.remove(musicQueue, 1)

		playNext()
	end
end)

characterPanel.Interactions.Rejoin.Interact.MouseButton1Click:Connect(rejoin)
characterPanel.Interactions.Serverhop.Interact.MouseButton1Click:Connect(serverhop)

homeContainer.Interactions.Server.JobId.Interact.MouseButton1Click:Connect(function()
	if originalSetClipboard then
		-- placeName is resolved once at startup. This used to call GetProductInfo inline, which
		-- yields and throws when rate-limited, from inside a click handler.
		originalSetClipboard([[
-- This script will teleport you to ' ]] .. (placeName or "this experience") .. [['
-- If it doesn't work after a few seconds, try going into the same game, and then run the script to join ]] .. localPlayer.DisplayName .. [['s specific server

game:GetService("TeleportService"):TeleportToPlaceInstance(']] .. placeId .. [[', ']] .. jobId .. [[')]])
		queueNotification("Copied Join Script", "Successfully set clipboard to join script, players can use this script to join your specific server.", 4335479121)
	else
		queueNotification("Unable to copy join script", "Missing setclipboard() function, can't set data to your clipboard.", 4335479658)
	end
end)

homeContainer.Interactions.Discord.Interact.MouseButton1Click:Connect(function()
	if originalSetClipboard then
		originalSetClipboard("https://sirius.menu/discord")
		queueNotification("Discord Invite Copied", "We've set your clipboard to the Sirius discord invite.", 4335479121)
	else
		queueNotification("Unable to copy Discord invite", "Missing setclipboard() function, can't set data to your clipboard.", 4335479658)
	end
end)

for _, button in ipairs(scriptsPanel.Interactions.Selection:GetChildren()) do
	local origsize = button.Size

	button.MouseEnter:Connect(function()
		if not debounce then
			tweenService:Create(button, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
			tweenService:Create(button, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = UDim2.new(0, button.Size.X.Offset - 5, 0, button.Size.Y.Offset - 3) }):Play()
			tweenService:Create(button.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
			tweenService:Create(button.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.1 }):Play()
		end
	end)

	button.MouseLeave:Connect(function()
		if not debounce then
			tweenService:Create(button, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
			tweenService:Create(button, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Size = origsize }):Play()
			tweenService:Create(button.UIStroke, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
			tweenService:Create(button.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
		end
	end)

	button.Interact.MouseButton1Click:Connect(function()
		tweenService:Create(button, TweenInfo.new(0.4, Enum.EasingStyle.Quint), { Size = UDim2.new(0, origsize.X.Offset - 9, 0, origsize.Y.Offset - 6) }):Play()
		task.wait(0.1)
		tweenService:Create(button, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { Size = origsize }):Play()

		if button.Name == "Library" then
			if not scriptSearch.Visible and not debounce then
				openScriptSearch()
			end
		end
		-- run action
	end)
end

smartBar.Buttons.Music.Interact.MouseButton1Click:Connect(function()
	if debounce then
		return
	end
	if musicPanel.Visible then
		closeMusic()
	else
		openMusic()
	end
end)

smartBar.Buttons.Home.Interact.MouseButton1Click:Connect(function()
	if debounce then
		return
	end
	if homeContainer.Visible then
		closeHome()
	else
		openHome()
	end
end)

smartBar.Buttons.Settings.Interact.MouseButton1Click:Connect(function()
	if debounce then
		return
	end
	if settingsPanel.Visible then
		closeSettings()
	else
		openSettings()
	end
end)

for _, button in ipairs(smartBar.Buttons:GetChildren()) do
	if UI:FindFirstChild(button.Name) and button:FindFirstChild("Interact") then
		button.Interact.MouseButton1Click:Connect(function()
			if isPanel(button.Name) then
				if not debounce and UI:FindFirstChild(button.Name).Visible then
					task.spawn(closePanel, button.Name)
				else
					task.spawn(openPanel, button.Name)
				end
			end

			tweenService:Create(button, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 28, 0, 28) }):Play()
			tweenService:Create(button, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.6 }):Play()
			tweenService:Create(button.Icon, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { ImageTransparency = 0.6 }):Play()
			task.wait(0.15)
			tweenService:Create(button, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { Size = UDim2.new(0, 36, 0, 36) }):Play()
			tweenService:Create(button, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
			tweenService:Create(button.Icon, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { ImageTransparency = 0.02 }):Play()
		end)

		button.MouseEnter:Connect(function()
			tweenService:Create(button.UIGradient, TweenInfo.new(1.4, Enum.EasingStyle.Quint), { Rotation = 360 }):Play()
			tweenService:Create(button.UIStroke.UIGradient, TweenInfo.new(1.4, Enum.EasingStyle.Quint), { Rotation = 360 }):Play()
			tweenService:Create(button.UIStroke, TweenInfo.new(0.8, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
			tweenService:Create(button.Icon, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { ImageTransparency = 0 }):Play()
			tweenService:Create(button.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, -0.5) }):Play()
		end)

		button.MouseLeave:Connect(function()
			tweenService:Create(button.UIStroke.UIGradient, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Rotation = 50 }):Play()
			tweenService:Create(button.UIGradient, TweenInfo.new(0.9, Enum.EasingStyle.Quint), { Rotation = 50 }):Play()
			tweenService:Create(button.UIStroke, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Transparency = 0 }):Play()
			tweenService:Create(button.Icon, TweenInfo.new(0.2, Enum.EasingStyle.Quint), { ImageTransparency = 0.05 }):Play()
			tweenService:Create(button.UIGradient, TweenInfo.new(0.7, Enum.EasingStyle.Quint), { Offset = Vector2.new(0, 0) }):Play()
		end)
	end
end

-- Enum.KeyCode[name] throws on an unknown or nil name. A cleared keybind stores nil, so the two
-- unguarded lookups at the bottom of InputBegan used to throw on *every* keypress, taking out
-- all keybinds, the smartBar toggle and ScriptSearch with them.
local function keyCodeFromName(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local success, keyCode = pcall(function()
		return Enum.KeyCode[name]
	end)
	return success and keyCode or nil
end

-- Shared by the grid buttons and the keybinds so both paths animate identically
local function applyActionVisual(action, object)
	if not (action and object) then
		return
	end

	if action.enabled then
		object.Icon.Image = "rbxassetid://" .. action.images[1]
		tweenService:Create(object, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.1 }):Play()
		tweenService:Create(object.UIStroke, TweenInfo.new(0.6, Enum.EasingStyle.Quint), { Transparency = 1 }):Play()
		tweenService:Create(object.Icon, TweenInfo.new(0.45, Enum.EasingStyle.Quint), { ImageTransparency = 0.1 }):Play()
	else
		object.Icon.Image = "rbxassetid://" .. action.images[2]
		tweenService:Create(object, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.55 }):Play()
		tweenService:Create(object.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.4 }):Play()
		tweenService:Create(object.Icon, TweenInfo.new(0.25, Enum.EasingStyle.Quint), { ImageTransparency = 0.5 }):Play()
	end
end

track(userInputService.InputBegan:Connect(function(input, processed)
	if not checkSirius() then
		return
	end

	if checkingForKey then
		local inputType = input.UserInputType.Name
		if inputType ~= "Keyboard" and string.find(inputType, "Gamepad", 1, true) ~= 1 then
			return
		end

		local keyCode = input.KeyCode
		local keyName = keyCode and keyCode.Name
		if keyName and keyName ~= "Unknown" then
			local capture = checkingForKey
			-- Backspace/Delete explicitly clear a bind; losing focus without a key still cancels capture.
			if keyName == "Backspace" or keyName == "Delete" then
				capture.object.InputFrame.InputBox.Text = "No Keybind"
				capture.data.current = nil
			else
				capture.object.InputFrame.InputBox.Text = keyName
				capture.data.current = keyName
			end
			checkingForKey = nil
			capture.object.InputFrame.InputBox:ReleaseFocus()
			saveSettings()
		end

		return
	end

	if processed then
		return
	end

	local inputType = input.UserInputType.Name
	if inputType ~= "Keyboard" and string.find(inputType, "Gamepad", 1, true) ~= 1 then
		return
	end

	for _, category in ipairs(siriusSettings) do
		for _, setting in ipairs(category.categorySettings) do
			if setting.settingType == "Key" and setting.callback and input.KeyCode == keyCodeFromName(setting.current) then
				task.spawn(setting.callback)

				-- Resolved by index rather than by matching the setting name against the action
				-- name; two of them never matched and threw here instead of updating the button.
				local action = setting.actionIndex and siriusValues.actions[setting.actionIndex]
				local object = actionButton(action)

				if action and object then
					applyActionVisual(action, object)

					if action.enabled and action.disableAfter then
						task.delay(action.disableAfter, function()
							action.enabled = false
							applyActionVisual(action, object)
						end)
					end

					if action.enabled and action.rotateWhileEnabled then
						task.spawn(function()
							repeat
								object.Icon.Rotation = 0
								tweenService:Create(object.Icon, TweenInfo.new(0.75, Enum.EasingStyle.Quint), { Rotation = 360 }):Play()
								task.wait(1)
							until not action.enabled or not checkSirius()
							object.Icon.Rotation = 0
						end)
					end
				end
			end
		end
	end

	if input.KeyCode == keyCodeFromName(settingValue("Open ScriptSearch")) and not debounce then
		if scriptSearch.Visible then
			closeScriptSearch()
		else
			openScriptSearch()
		end
	end

	if input.KeyCode == keyCodeFromName(settingValue("Toggle smartBar")) and not debounce then
		if smartBarOpen then
			closeSmartBar()
		else
			openSmartBar()
		end
	end
end))

track(userInputService.InputEnded:Connect(function(input)
	if not checkSirius() then
		return
	end

	-- Touch releases end a drag too; MouseButton1 alone left sliders stuck active on mobile
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		for _, slider in pairs(siriusValues.sliders) do
			slider.active = false

			if characterPanel.Visible and not debounce and slider.object and checkSirius() then
				tweenService:Create(slider.object, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { BackgroundTransparency = 0.8 }):Play()
				tweenService:Create(slider.object.UIStroke, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { Transparency = 0.5 }):Play()
				tweenService:Create(slider.object.Information, TweenInfo.new(0.4, Enum.EasingStyle.Exponential), { TextTransparency = 0.3 }):Play()
			end
		end
	end
end))

track(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
	task.wait(0.5)
	updateSliderPadding()
end))

scriptSearch.SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
	if #scriptSearch.SearchBox.Text > 0 then
		tweenService:Create(scriptSearch.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageColor3 = Color3.fromRGB(255, 255, 255) }):Play()
		tweenService:Create(scriptSearch.SearchBox, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextColor3 = Color3.fromRGB(255, 255, 255) }):Play()
	else
		tweenService:Create(scriptSearch.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageColor3 = Color3.fromRGB(150, 150, 150) }):Play()
		tweenService:Create(scriptSearch.SearchBox, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextColor3 = Color3.fromRGB(150, 150, 150) }):Play()
	end
end)

scriptSearch.SearchBox.FocusLost:Connect(function(enterPressed)
	tweenService:Create(scriptSearch.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageColor3 = Color3.fromRGB(150, 150, 150) }):Play()
	tweenService:Create(scriptSearch.SearchBox, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextColor3 = Color3.fromRGB(150, 150, 150) }):Play()

	if #scriptSearch.SearchBox.Text > 0 then
		if enterPressed then
			-- searchScriptBlox reports its own failures through queueNotification
			pcall(searchScriptBlox, scriptSearch.SearchBox.Text)
		end
	else
		closeScriptSearch()
	end
end)

scriptSearch.SearchBox.Focused:Connect(function()
	if #scriptSearch.SearchBox.Text > 0 then
		tweenService:Create(scriptSearch.Icon, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { ImageColor3 = Color3.fromRGB(255, 255, 255) }):Play()
		tweenService:Create(scriptSearch.SearchBox, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextColor3 = Color3.fromRGB(255, 255, 255) }):Play()
	end
end)

-- Was Mouse.Move, which is deprecated and never fires for touch input - sliders simply didn't
-- work on mobile. InputChanged covers mouse movement and touch drags alike.
track(userInputService.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end

	for _, slider in pairs(siriusValues.sliders) do
		if slider.active then
			updateSlider(slider)
		end
	end
end))

track(userInputService.WindowFocusReleased:Connect(function()
	windowFocusChanged(false)
end))
track(userInputService.WindowFocused:Connect(function()
	windowFocusChanged(true)
end))

for _, player in ipairs(players:GetPlayers()) do
	createPlayer(player)
	createEsp(player)
	player.Chatted:Connect(function(message)
		onChatted(player, message)
	end)
end

track(players.PlayerAdded:Connect(function(player)
	if not checkSirius() then
		return
	end

	createPlayer(player)
	createEsp(player)

	player.Chatted:Connect(function(message)
		onChatted(player, message)
	end)

	if settingValue("Log PlayerAdded and PlayerRemoving") then
		postWebhook(settingValue("Player Added and Removing Webhook URL"), {
			["content"] = player.DisplayName .. " (@" .. player.Name .. ") joined the server.",
			["avatar_url"] = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. player.UserId .. "&width=420&height=420&format=png",
			["username"] = player.DisplayName,
			["allowed_mentions"] = { parse = {} },
		})
	end

	-- GetRoleInGroup used to run on every join in every experience, group-owned or not: it's a
	-- yielding web call, it sat above the friend check, and an error here silently swallowed the
	-- rest of this handler. Now it only runs where a group role can actually exist, off-thread.
	if settingValue("Moderator Detection") and siriusValues.currentCreator == "group" then
		task.spawn(function()
			local roleSuccess, roleFound = pcall(player.GetRoleInGroup, player, creatorId)
			if not roleSuccess or type(roleFound) ~= "string" then
				return
			end

			for _, role in ipairs(siriusValues.administratorRoles) do
				if string.find(string.lower(roleFound), role, 1, true) then
					promptModerator(player, roleFound)
					queueNotification("Administrator Joined", roleFound .. " " .. player.DisplayName .. " has joined your session", 3944670656)
					break -- a role matching two keywords used to fire two prompts and two toasts
				end
			end
		end)
	end

	if settingValue("Friend Notifications") then
		local friendSuccess, isFriend = pcall(localPlayer.IsFriendsWith, localPlayer, player.UserId)
		if friendSuccess and isFriend then
			queueNotification("Friend Joined", "Your friend " .. player.DisplayName .. " has joined your server.", 4370335364)
		end
	end
end))

track(players.PlayerRemoving:Connect(function(player)
	if settingValue("Log PlayerAdded and PlayerRemoving") then
		postWebhook(settingValue("Player Added and Removing Webhook URL"), {
			["content"] = player.DisplayName .. " (@" .. player.Name .. ") left the server.",
			["avatar_url"] = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. player.UserId .. "&width=420&height=420&format=png",
			["username"] = player.DisplayName,
			["allowed_mentions"] = { parse = {} },
		})
	end

	-- Stop spectating someone who just left, otherwise the camera is stuck on a dead subject
	if spectating == player then
		restoreCamera()
	end

	removePlayer(player)
	locatedPlayers[player.Name] = nil

	if espConnections[player] then
		espConnections[player]:Disconnect()
		espConnections[player] = nil
	end

	local highlight = espContainer:FindFirstChild(player.Name)
	if highlight then
		highlight:Destroy()
	end
end))

track(runService.RenderStepped:Connect(function(frame)
	if not checkSirius() then
		return
	end
	local fps = math.round(1 / frame)

	table.insert(siriusValues.frameProfile.fpsQueue, fps)
	siriusValues.frameProfile.totalFPS += fps

	if #siriusValues.frameProfile.fpsQueue > siriusValues.frameProfile.fpsQueueSize then
		siriusValues.frameProfile.totalFPS -= siriusValues.frameProfile.fpsQueue[1]
		table.remove(siriusValues.frameProfile.fpsQueue, 1)
	end
end))

-- Everything from here to the end of the file runs inside runtime().
--
-- Luau allows 200 locals per function scope and the main chunk is one of them. This file
-- declared 207, so `lastSpatialWanted` -- one of the last -- was rejected at compile time
-- with "Out of local registers". loadstring() then returned nil and the caller got
-- "attempt to call a nil value" on line 1, with nothing to say why. Newer Luau reuses
-- registers and slipped under the limit; stricter executors did not, which is the whole of
-- "it works for some people".
--
-- It has to be a function, not a `do` block. A block shares the enclosing function's
-- register file, so scoping this in `do ... end` moves nothing -- that was tried first and
-- changed the count by zero. A function opens its own register file, which takes the chunk
-- to 187 and gives this section a fresh 200 of its own.
--
-- Nothing below is referenced above it, and everything above stays reachable as an upvalue.
local function runtime()
	-- The character's BasePart list is cached and maintained by events rather than rebuilt with
	-- GetDescendants() on every physics step (~60x/sec, whether or not noclip was even on).
	-- noclipDefaults was also keyed by part and never cleared, so it pinned a fresh set of dead part
	-- references on every respawn.
	local characterParts = {}
	local characterPartConnections = {}

	local function clearCharacterPartTracking()
		for _, connection in ipairs(characterPartConnections) do
			connection:Disconnect()
		end
		table.clear(characterPartConnections)
		table.clear(characterParts)
		table.clear(noclipDefaults)
	end

	local function trackCharacterParts(character)
		clearCharacterPartTracking()
		if not character then
			return
		end

		local function add(part)
			if part:IsA("BasePart") then
				characterParts[part] = true
				if noclipDefaults[part] == nil then
					noclipDefaults[part] = part.CanCollide
				end
			end
		end

		for _, descendant in ipairs(character:GetDescendants()) do
			add(descendant)
		end

		table.insert(characterPartConnections, character.DescendantAdded:Connect(add))
		table.insert(
			characterPartConnections,
			character.DescendantRemoving:Connect(function(part)
				characterParts[part] = nil
				noclipDefaults[part] = nil
			end)
		)
	end

	trackCharacterParts(localPlayer.Character)
	track(localPlayer.CharacterAdded:Connect(trackCharacterParts))
	track(localPlayer.CharacterRemoving:Connect(clearCharacterPartTracking))

	local noclipWasActive = false

	track(runService.Stepped:Connect(function()
		if not checkSirius() then
			return
		end

		local noclipActive = siriusValues.actions[1].enabled or siriusValues.actions[6].enabled

		-- Only write CanCollide while noclip is on, plus once on the trailing edge to restore
		if not noclipActive and not noclipWasActive then
			return
		end

		for part in pairs(characterParts) do
			if part.Parent then
				if noclipActive then
					part.CanCollide = false
				else
					local default = noclipDefaults[part]
					part.CanCollide = if default == nil then true else default
				end
			end
		end

		noclipWasActive = noclipActive
	end))

	track(runService.Heartbeat:Connect(function()
		if not checkSirius() then
			return
		end

		local character = localPlayer.Character
		local primaryPart = character and character.PrimaryPart
		if primaryPart then
			local bodyVelocity, bodyGyro = unpack(movers)

			-- Drop cached movers if the old character was destroyed and took them with it.
			-- Setting Parent on a destroyed instance throws, so probe before using.
			if bodyVelocity then
				local alive = pcall(function()
					bodyVelocity.Parent = bodyVelocity.Parent
				end)
				if not alive then
					movers = {}
					bodyVelocity, bodyGyro = nil, nil
				end
			end

			if not bodyVelocity then
				bodyVelocity = Instance.new("BodyVelocity")
				bodyVelocity.MaxForce = Vector3.one * 9e9

				bodyGyro = Instance.new("BodyGyro")
				bodyGyro.MaxTorque = Vector3.one * 9e9
				bodyGyro.P = 9e4

				local bodyAngularVelocity = Instance.new("BodyAngularVelocity")
				bodyAngularVelocity.AngularVelocity = Vector3.yAxis * 9e9
				bodyAngularVelocity.MaxTorque = Vector3.yAxis * 9e9
				bodyAngularVelocity.P = 9e9

				movers = { bodyVelocity, bodyGyro, bodyAngularVelocity }
			end

			-- Fly
			if siriusValues.actions[2].enabled then
				local camCFrame = camera.CFrame
				local velocity = Vector3.zero
				local rotation = camCFrame.Rotation

				if userInputService:IsKeyDown(Enum.KeyCode.W) then
					velocity += camCFrame.LookVector
					rotation *= CFrame.Angles(math.rad(-40), 0, 0)
				end
				if userInputService:IsKeyDown(Enum.KeyCode.S) then
					velocity -= camCFrame.LookVector
					rotation *= CFrame.Angles(math.rad(40), 0, 0)
				end
				if userInputService:IsKeyDown(Enum.KeyCode.D) then
					velocity += camCFrame.RightVector
					rotation *= CFrame.Angles(0, 0, math.rad(-40))
				end
				if userInputService:IsKeyDown(Enum.KeyCode.A) then
					velocity -= camCFrame.RightVector
					rotation *= CFrame.Angles(0, 0, math.rad(40))
				end
				if userInputService:IsKeyDown(Enum.KeyCode.Space) then
					velocity += Vector3.yAxis
				end
				if userInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
					velocity -= Vector3.yAxis
				end

				local tweenInfo = TweenInfo.new(0.5)
				tweenService:Create(bodyVelocity, tweenInfo, { Velocity = velocity * siriusValues.sliders[3].value * 45 }):Play()
				bodyVelocity.Parent = primaryPart

				if not siriusValues.actions[6].enabled then
					tweenService:Create(bodyGyro, tweenInfo, { CFrame = rotation }):Play()
					bodyGyro.Parent = primaryPart
				end
			else
				bodyVelocity.Parent = nil
				bodyGyro.Parent = nil
			end
		end
	end))

	-- Anonymous Client throttle/transition state
	local anonymousTickCounter = 0
	local anonymousWasEnabled = false
	local ANONYMOUS_TICK_INTERVAL = 15 -- run roughly 4x/sec instead of every frame

	track(runService.Heartbeat:Connect(function()
		if not checkSirius() then
			return
		end
		if Pro then
			if settingValue("Spatial Shield") and tonumber(settingValue("Spatial Shield Threshold")) then
				local threshold = tonumber(settingValue("Spatial Shield Threshold"))
				-- iterate backwards so table.remove doesn't skip entries
				for i = #soundInstances, 1, -1 do
					local sound = soundInstances[i]
					if not sound then
						table.remove(soundInstances, i)
					elseif gameSettings.MasterVolume * sound.PlaybackLoudness * sound.Volume >= threshold then
						if sound.Volume > 0.55 then
							suppressedSounds[sound.SoundId] = "S"
							sound.Volume = 0.5
						elseif sound.Volume > 0.2 and sound.Volume < 0.55 then
							suppressedSounds[sound.SoundId] = "S2"
							sound.Volume = 0.1
						elseif sound.Volume < 0.2 then
							suppressedSounds[sound.SoundId] = "Mute"
							sound.Volume = 0
						end
						if soundSuppressionNotificationCooldown == 0 then
							queueNotification("Spatial Shield", "A high-volume audio is being played (" .. sound.Name .. ") and it has been suppressed.", 4483362458)
							soundSuppressionNotificationCooldown = 15
						end
						table.remove(soundInstances, i)
					end
				end
			end

			if soundSuppressionNotificationCooldown > 0 then
				soundSuppressionNotificationCooldown -= 1
			end
		end

		local anonymousEnabled = settingValue("Anonymous Client")

		if anonymousEnabled then
			-- Throttle: do the scan on every Nth heartbeat rather than every frame.
			anonymousTickCounter += 1
			if anonymousTickCounter >= ANONYMOUS_TICK_INTERVAL then
				anonymousTickCounter = 0

				for i = #cachedText, 1, -1 do
					local text = cachedText[i]
					if not text or not text.Parent then
						-- Drop destroyed/orphaned labels so we stop scanning them.
						trackedText[text] = nil
						table.remove(cachedText, i)
					elseif originalTextValues[text] == nil then
						-- Only inspect labels we haven't already anonymized.
						local raw = text.Text
						local lowerText = string.lower(raw)
						if string.find(lowerText, lowerName, 1, true) or string.find(lowerText, lowerDisplayName, 1, true) then
							storeOriginalText(text)
							-- Case-preserving and pattern-safe. The old version lowercased the whole
							-- label, restored only the first character's case, and passed the raw
							-- names to gsub as patterns - so a display name containing -, . or %
							-- either mismatched or errored outright.
							text.Text = replacePlain(replacePlain(raw, lowerName, randomUsername), lowerDisplayName, randomUsername)
						end
					end
				end
			end
		elseif anonymousWasEnabled then
			-- Only undo once on the off-transition, not every frame.
			undoAnonymousChanges()
			table.clear(originalTextValues)
		end

		anonymousWasEnabled = anonymousEnabled
	end))

	-- Descendant tracking.
	--
	-- Two things changed here. Membership is now a hash-set lookup instead of table.find, which was
	-- a linear scan run against every instance the experience ever created - quadratic over a
	-- session on a busy game. And registration is gated on whether a consumer is actually switched
	-- on, so a player with Spatial Shield and Anonymous Client off pays nothing at all.
	local function spatialShieldWanted()
		return Pro and settingValue("Spatial Shield") == true
	end

	local function anonymousWanted()
		return settingValue("Anonymous Client") == true
	end

	local function registerSound(instance)
		local suppression = suppressedSounds[instance.SoundId]
		if suppression then
			instance.Volume = (suppression == "S" and 0.5) or (suppression == "S2" and 0.1) or 0
			return
		end

		if not spatialShieldWanted() then
			return
		end
		if trackedSounds[instance] then
			return
		end

		-- Keyed by SoundId as before, so one entry per distinct asset rather than per instance
		if not cachedIds[instance.SoundId] then
			cachedIds[instance.SoundId] = true
			trackedSounds[instance] = true
			table.insert(soundInstances, instance)
		end
	end

	local function registerText(instance)
		if not anonymousWanted() then
			return
		end
		if trackedText[instance] then
			return
		end

		trackedText[instance] = true
		table.insert(cachedText, instance)
	end

	local function registerDescendant(instance)
		if instance:IsA("Sound") then
			registerSound(instance)
		elseif instance:IsA("TextLabel") or instance:IsA("TextButton") then
			registerText(instance)
		end
	end

	-- The initial sweep walks the entire DataModel, so only do it when something needs the results
	if spatialShieldWanted() or anonymousWanted() then
		task.spawn(function()
			for _, instance in ipairs(game:GetDescendants()) do
				pcall(registerDescendant, instance)
			end
		end)
	end

	descendantAddedConn = track(game.DescendantAdded:Connect(function(instance)
		if not checkSirius() then
			return
		end
		pcall(registerDescendant, instance)
	end))

	track(game.DescendantRemoving:Connect(function(instance)
		trackedSounds[instance] = nil
		trackedText[instance] = nil
	end))

	-- Turning either feature on mid-session backfills what was skipped while it was off
	local descendantSweepPending = false
	local function refreshDescendantTracking()
		if descendantSweepPending then
			return
		end
		descendantSweepPending = true

		task.spawn(function()
			for _, instance in ipairs(game:GetDescendants()) do
				pcall(registerDescendant, instance)
			end
			descendantSweepPending = false
		end)
	end

	-- Teardown. The old exit path only released the ESP folder, the DescendantAdded hook and the
	-- anonymous text; the per-frame connections, the blur, the FPS cap, the muted volume and any
	-- CanCollide overrides were all left behind.
	local function teardown()
		if espContainer then
			espContainer:Destroy()
		end

		if descendantAddedConn then
			descendantAddedConn:Disconnect()
			descendantAddedConn = nil
		end

		for player, conn in pairs(espConnections) do
			conn:Disconnect()
			espConnections[player] = nil
		end

		for _, connection in ipairs(connections) do
			pcall(function()
				connection:Disconnect()
			end)
		end
		table.clear(connections)

		-- Restore CanCollide before dropping the cache. The Stepped handler would normally do this
		-- on the trailing edge, but it has just been disconnected, so nothing else will.
		pcall(function()
			for part in pairs(characterParts) do
				if part.Parent then
					local default = noclipDefaults[part]
					part.CanCollide = if default == nil then true else default
				end
			end
		end)

		clearCharacterPartTracking()
		undoAnonymousChanges()
		table.clear(originalTextValues)

		pcall(restoreCamera)
		pcall(removeReverbs, 0.1)
		pcall(blurSignature, false)

		-- Put back everything Sirius changed globally
		if setFpsCap then
			pcall(setFpsCap, 240)
		end
		pcall(function()
			gameSettings.MasterVolume = oldVolume
		end)
		pcall(function()
			camera.FieldOfView = baseFieldOfView
		end)

		for _, coreUI in ipairs(env.cachedCoreUI or {}) do
			pcall(starterGui.SetCoreGuiEnabled, starterGui, Enum.CoreGuiType[coreUI], true)
		end

		for _, cachedUI in ipairs(env.cachedInGameUI or {}) do
			pcall(function()
				if cachedUI.Parent then
					cachedUI.Enabled = true
				end
			end)
		end
	end

	local lastAnonymousWanted = anonymousWanted()
	local lastSpatialWanted = spatialShieldWanted()

	while task.wait(1) do
		if not checkSirius() then
			teardown()
			break
		end

		-- A single throw in here used to end the loop permanently: no clock, no Home refresh, no
		-- anti-idle, no latency or FPS warnings, and no disconnect detection for the rest of the
		-- session - with the interface still on screen looking perfectly healthy.
		local tickSuccess, tickError = pcall(function()
			smartBar.Time.Text = os.date("%H") .. ":" .. os.date("%M")
			task.spawn(UpdateHome)

			-- Backfill tracking when either consumer is switched on mid-session
			local anonymousNow, spatialNow = anonymousWanted(), spatialShieldWanted()
			if (anonymousNow and not lastAnonymousWanted) or (spatialNow and not lastSpatialWanted) then
				refreshDescendantTracking()
			end
			lastAnonymousWanted, lastSpatialWanted = anonymousNow, spatialNow

			if getConnectionsFor then
				local antiIdle = settingValue("Anti Idle")
				pcall(function()
					for _, connection in getConnectionsFor(localPlayer.Idled) do
						if antiIdle then
							connection:Disable()
						else
							connection:Enable()
						end
					end
				end)
			end

			toggle.Visible = not settingValue("Hide Toggle Button")

			-- Disconnected Check
			-- These were hard indexes. RobloxPromptGui/promptOverlay aren't guaranteed to exist, and a
			-- miss threw straight out of the loop.
			local promptGui = coreGui:FindFirstChild("RobloxPromptGui")
			local promptOverlay = promptGui and promptGui:FindFirstChild("promptOverlay")
			local disconnectedRobloxUI = promptOverlay and promptOverlay:FindFirstChild("ErrorPrompt")

			if disconnectedRobloxUI and not promptedDisconnected then
				local messageArea = disconnectedRobloxUI:FindFirstChild("MessageArea")
				local errorFrame = messageArea and messageArea:FindFirstChild("ErrorFrame")
				local errorMessage = errorFrame and errorFrame:FindFirstChild("ErrorMessage")
				local reasonPrompt = errorMessage and errorMessage.Text or ""

				promptedDisconnected = true
				disconnectedPrompt.Parent = promptGui

				local disconnectType
				local foundString

				for _, preDisconnectType in ipairs(siriusValues.disconnectTypes) do
					for _, typeString in pairs(preDisconnectType[2]) do
						if string.find(reasonPrompt, typeString) then
							disconnectType = preDisconnectType[1]
							foundString = true
							break
						end
					end
				end

				if not foundString then
					disconnectType = "kick"
				end

				wipeTransparency(disconnectedPrompt, 1, true)
				disconnectedPrompt.Visible = true

				if disconnectType == "ban" then
					disconnectedPrompt.Content.Text = "You've been banned, would you like to leave this server?"
					disconnectedPrompt.Action.Text = "Leave"
					disconnectedPrompt.Action.Size = UDim2.new(0, 77, 0, 36) -- use textbounds

					disconnectedPrompt.UIGradient.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)),
						ColorSequenceKeypoint.new(1, Color3.new(0.819608, 0.164706, 0.164706)),
					})
				elseif disconnectType == "kick" then
					disconnectedPrompt.Content.Text = "You've been kicked, would you like to serverhop?"
					disconnectedPrompt.Action.Text = "Serverhop"
					disconnectedPrompt.Action.Size = UDim2.new(0, 114, 0, 36)

					disconnectedPrompt.UIGradient.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)),
						ColorSequenceKeypoint.new(1, Color3.new(0.0862745, 0.596078, 0.835294)),
					})
				elseif disconnectType == "network" then
					disconnectedPrompt.Content.Text = "You've lost connection, would you like to rejoin?"
					disconnectedPrompt.Action.Text = "Rejoin"
					disconnectedPrompt.Action.Size = UDim2.new(0, 82, 0, 36)

					disconnectedPrompt.UIGradient.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)),
						ColorSequenceKeypoint.new(1, Color3.new(0.862745, 0.501961, 0.0862745)),
					})
				end

				tweenService:Create(disconnectedPrompt, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0 }):Play()
				tweenService:Create(disconnectedPrompt.Title, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()
				tweenService:Create(disconnectedPrompt.Content, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0.3 }):Play()
				tweenService:Create(disconnectedPrompt.Action, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { BackgroundTransparency = 0.7 }):Play()
				tweenService:Create(disconnectedPrompt.Action, TweenInfo.new(0.5, Enum.EasingStyle.Quint), { TextTransparency = 0 }):Play()

				disconnectedPrompt.Action.MouseButton1Click:Connect(function()
					if disconnectType == "ban" then
						leaveExperience()
					elseif disconnectType == "kick" then
						task.spawn(serverhop)
					elseif disconnectType == "network" then
						rejoin()
					end
				end)
			end

			if Pro then
				-- all Pro checks here!

				-- Two-Way Adaptive Latency Checks
				if checkHighPing() then
					if siriusValues.pingProfile.pingNotificationCooldown <= 0 then
						if settingValue("Adaptive Latency Warning") then
							queueNotification(
								"High Latency Warning",
								"We've noticed your latency has reached a higher value than usual, you may find that you are lagging or your actions are delayed in-game. Consider checking for any background downloads on your machine.",
								4370305588
							)
							siriusValues.pingProfile.pingNotificationCooldown = 120
						end
					end
				end

				if siriusValues.pingProfile.pingNotificationCooldown > 0 then
					siriusValues.pingProfile.pingNotificationCooldown -= 1
				end

				-- Adaptive frame time checks
				if siriusValues.frameProfile.frameNotificationCooldown <= 0 then
					if #siriusValues.frameProfile.fpsQueue > 0 then
						local avgFPS = siriusValues.frameProfile.totalFPS / #siriusValues.frameProfile.fpsQueue

						if avgFPS < siriusValues.frameProfile.lowFPSThreshold then
							if settingValue("Adaptive Performance Warning") then
								queueNotification(
									"Degraded Performance",
									"We've noticed your client's frames per second have decreased. Consider checking for any background tasks or programs on your machine.",
									4384400106
								)
								siriusValues.frameProfile.frameNotificationCooldown = 120
							end
						end
					end
				end

				if siriusValues.frameProfile.frameNotificationCooldown > 0 then
					siriusValues.frameProfile.frameNotificationCooldown -= 1
				end
			end
		end) -- end of the per-tick pcall

		if not tickSuccess then
			warn("Sirius | Error in the update loop (recovering): " .. tostring(tickError))
		end
	end
end

runtime()


-- Sirius Boosts
-- sirius.menu/privacy | sirius.menu/terms

-- Unsupported Executors
--
-- The arguments here were the wrong way round: string.find(keyword, exec) asks whether the
-- executor's name appears *inside* the blocklist keyword. Keywords are short and executor names
-- are longer, so this never matched and the blocklist never actually blocked anything.
local exec = string.lower(identifyexecutor and identifyexecutor() or 'No Executor')
local unsupported = {'delta', 'cryptic', 'arm64'}

for _, keyword in pairs(unsupported) do
	if string.find(exec, keyword, 1, true) then
		return
	end
end

-- Request
local request = (http and http.request) or http_request or request or (syn and syn.request) or (fluxus and fluxus.request)

-- Studio
local isStudio = game:GetService('RunService'):IsStudio()

-- Hashing
-- Boosts can't do anything without it, so bail out rather than calling a false value per player.
local hasher
if not isStudio then
	local hasherSuccess, hasherResult = pcall(function()
		return loadstring(game:HttpGet("https://sync-api.sirius.menu/v1/lua/hasher"))()["hasher"]
	end)

	if not hasherSuccess or type(hasherResult) ~= "function" then
		return
	end

	hasher = hasherResult
else
	return -- no hasher available in Studio
end

-- Services
local httpService = game:GetService('HttpService')
local players = game:GetService('Players')
local coreGui = isStudio and script.Parent or game:GetService('CoreGui')
local userInputService = game:GetService("UserInputService")

-- GET Boosts
local response

if not request then
	-- test response
	response = [[{"5e1f71a90ce1cb0e1a062bc7e6c19adbddfba27b8b1ed2c822ab44794d245b50":{"boosting_since":1730570726,"color":[256,256,256],"icon":0},"77288fb8e5e4d26f8d5b2536b44fc012c8a95b701a8af4fdb8698b7ef271507c":{"boosting_since":1732069640,"color":[256,256,256],"icon":0},"a550e7328fa7d26f197a032af55760eabed80f33244002922ddf8cd382a51e0c":{"boosting_since":1732032799,"color":[256,256,256],"icon":0},"a60ef2207710c2cbaf612ef12a5468f390760ae76fdf48bc48c9007c57ed11dd":{"boosting_since":1731927879,"color":[256,256,256],"icon":0},"f6ebb30a9913076205e1fc8f674ea04134b3ae2b9f859060a1e72ac1e638170a":{"boosting_since":1731941719,"color":[256,256,256],"icon":0}}]]
else
	local requestSuccess, requestResult = pcall(request, {
		Url = 'https://sync-api.sirius.menu/v1/u',
		Method = "GET",
	})

	if not requestSuccess or type(requestResult) ~= "table" then return end
	response = requestResult.Body
end

-- The pcall result was never checked. On a malformed or empty response `boosts` held the error
-- *string*, and getBooster went straight into pairs() on it - throwing for every player.
local decodeSuccess, boosts = pcall(function() return httpService:JSONDecode(response) end)

if not decodeSuccess or type(boosts) ~= "table" then return end

-- Hash every user id once rather than per lookup, and index the table directly instead of
-- walking every boost entry for each player.
local function getBooster(userId)
	local hashSuccess, hashed = pcall(hasher, tostring(userId))
	if not hashSuccess then return false end

	local properties = boosts[hashed]

	if properties then
		local booster = {}

		if properties.color and not (properties.color[1] > 255 or properties.color[2] > 255 or properties.color[3] > 255) then -- Color higher than 255 means default color value (no changes made)
			booster.color = Color3.fromRGB(properties.color[1], properties.color[2], properties.color[3])
		end

		booster.icon = properties.icon ~= 0 and properties.icon or nil -- Icon 0 means default icon (no changes made)

		return booster
	else
		return false
	end
end

local function findOverlayFrame(target)
	if not target then return nil end
	local frame = target:FindFirstChild("ChildrenFrame")

	if frame then
		local nameFrame = frame:FindFirstChild("NameFrame")

		if nameFrame then
			if userInputService.TouchEnabled then
				return nameFrame
			else
				local bgFrame = nameFrame:FindFirstChild("BGFrame")

				if bgFrame then
					return bgFrame:FindFirstChild("OverlayFrame")
				end
			end
		end
	end	
	return nil
end

local function display(userId, booster)
	local target = coreGui:FindFirstChild("p_" .. tostring(userId), true) or coreGui:FindFirstChild("Player_" .. tostring(userId), true)
	if not target or not booster then return end

	local overlayFrame = findOverlayFrame(target)

	if not overlayFrame then return end

	-- The player list is Roblox's own UI and its shape changes without notice, so every write
	-- here is guarded rather than assumed
	pcall(function()
		overlayFrame.PlayerIcon.Image = 'rbxassetid://' .. (booster.icon or 128645553269928)
		overlayFrame.PlayerIcon.ImageRectOffset = Vector2.zero
		overlayFrame.PlayerIcon.ImageRectSize = Vector2.zero

		local color = booster.color or Color3.fromRGB(255, 138, 250)
		if userInputService.TouchEnabled then
			overlayFrame.PlayerName.TextColor3 = color
		else
			overlayFrame.PlayerName.PlayerName.TextColor3 = color
		end
	end)
end

local function processPlayer(player)
	local booster = getBooster(player.UserId)
	display(player.UserId, booster)
end

local function processAllPlayers()
	for _, player in ipairs(players:GetPlayers()) do
		processPlayer(player)
	end
end

processAllPlayers()
players.PlayerAdded:Connect(processPlayer)

if userInputService.TouchEnabled then
	local provider = coreGui:FindFirstChild("RoactAppExperimentProvider")
	local children = provider and provider:FindFirstChild("Children")
	local bodyBackground = children and children:FindFirstChild("BodyBackground")
	local leaderboardContainer = bodyBackground and bodyBackground:FindFirstChild("ContentFrame")

	if leaderboardContainer then
		leaderboardContainer.ChildAdded:Connect(processAllPlayers)
	end
end


-- Sirius Boosts
-- sirius.menu/privacy | sirius.menu/terms

-- Unsupported Executors

local exec = identifyexecutor and identifyexecutor() or 'No Executor'
local unsupported = {'delta', 'cryptic', 'arm64'}

for _, keyword in pairs(unsupported) do
	if string.find(keyword, string.lower(exec)) then
		return
	end
end

-- Request
local request = (http and http.request) or http_request or request or HttpPost

-- Studio
local isStudio = game:GetService('RunService'):IsStudio()

-- Hashing
local hasher = not isStudio and loadstring(game:HttpGet("https://sync-api.sirius.menu/v1/lua/hasher"))()["hasher"] --or require(script.Parent.ModuleScript)['hasher']

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
	response = request({
		Url = 'https://sync-api.sirius.menu/v1/u',
		Method = "GET",
	}).Body
end

local success, boosts = pcall(function() return httpService:JSONDecode(response) end)

local function getBooster(userId)
	userId = hasher(tostring(userId))
	local properties

	for id, prop in pairs(boosts) do
		if id == userId then
			properties = prop
			break
		end
	end

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

	if overlayFrame then
		overlayFrame.PlayerIcon.Image = 'rbxassetid://' .. (booster and booster.icon or 128645553269928)
		overlayFrame.PlayerIcon.ImageRectOffset = Vector2.zero
		overlayFrame.PlayerIcon.ImageRectSize = Vector2.zero
		if userInputService.TouchEnabled then
			overlayFrame.PlayerName.TextColor3 = booster and booster.color or Color3.fromRGB(255, 138, 250)
		else
			overlayFrame.PlayerName.PlayerName.TextColor3 = booster and booster.color or Color3.fromRGB(255, 138, 250)
		end
	end
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
	local leaderboardContainer = coreGui:FindFirstChild("RoactAppExperimentProvider")
		and coreGui.RoactAppExperimentProvider:FindFirstChild("Children")
		and coreGui.RoactAppExperimentProvider.Children:FindFirstChild("BodyBackground")
		and coreGui.RoactAppExperimentProvider.Children.BodyBackground:FindFirstChild("ContentFrame")

	if leaderboardContainer then
		leaderboardContainer.ChildAdded:Connect(function(child)
			processAllPlayers()
		end)
	end
end

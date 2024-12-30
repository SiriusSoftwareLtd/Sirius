local promptRet = {}

local useStudio

local runService = game:GetService("RunService")
local coreGui = game:GetService('CoreGui')

if runService:IsStudio() then
	useStudio = true
end


function promptRet.create(title, description, primary, secondary, callback)
	local prompt = useStudio and script.Parent:FindFirstChild('Prompt') or game:GetObjects("rbxassetid://97206084643256")[1]

	prompt.Enabled = false

	if gethui then
		prompt.Parent = gethui()
	elseif syn and syn.protect_gui then 
		syn.protect_gui(prompt)
		prompt.Parent = coreGui
	elseif not useStudio and coreGui:FindFirstChild("RobloxGui") then
		prompt.Parent = coreGui:FindFirstChild("RobloxGui")
	elseif not useStudio then
		prompt.Parent = coreGui
	end

	-- Disable other instances of the prompt
	if gethui then
		for _, Interface in ipairs(gethui():GetChildren()) do
			if Interface.Name == prompt.Name and Interface ~= prompt then
				Interface.Enabled = false
				Interface.Name = "Prompt-Old"
			end
		end
	elseif not useStudio then
		for _, Interface in ipairs(coreGui:GetChildren()) do
			if Interface.Name == prompt.Name and Interface ~= prompt then
				Interface.Enabled = false
				Interface.Name = "Prompt-Old"
			end
		end
	end

	-- Set the prompt text
	prompt.Policy.Title.Text = title
	prompt.Policy.Notice.Text = description
	prompt.Policy.Actions.Primary.Title.Text = primary
	prompt.Policy.Actions.Secondary.Title.Text = secondary

	-- Handle the button clicks and trigger the callback
	prompt.Policy.Actions.Primary.Interact.MouseButton1Click:Connect(function()
		prompt.Enabled = false
		if callback then callback(true) end
	end)

	prompt.Policy.Actions.Secondary.Interact.MouseButton1Click:Connect(function()
		prompt.Enabled = false
		if callback then callback(false) end
	end)

	-- Show the prompt
	prompt.Enabled = true
end

return promptRet

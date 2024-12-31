local promptRet = {}

local useStudio

local runService = game:GetService("RunService")
local coreGui = game:GetService('CoreGui')
local fin
local tweenService = game:GetService('TweenService')

if runService:IsStudio() then
	useStudio = true
end

local debounce = false

local function open(prompt)
	debounce = true
	prompt.Policy.Size = UDim2.new(0, 450, 0, 120)

	prompt.Policy.BackgroundTransparency = 1
	prompt.Policy.Shadow.Image.ImageTransparency = 1
	prompt.Policy.Title.TextTransparency = 1
	prompt.Policy.Notice.TextTransparency = 1
	prompt.Policy.Actions.Primary.BackgroundTransparency = 1
	prompt.Policy.Actions.Primary.Shadow.ImageTransparency = 1
	prompt.Policy.Actions.Primary.Title.TextTransparency = 1
	prompt.Policy.Actions.Secondary.Title.TextTransparency = 1
	
	-- Show the prompt
	prompt.Policy.Visible = true
	prompt.Enabled = true
	
	tweenService:Create(prompt.Policy, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {BackgroundTransparency = 0}):Play()
	tweenService:Create(prompt.Policy.Shadow.Image, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {ImageTransparency = 0.6}):Play()

	tweenService:Create(prompt.Policy, TweenInfo.new(0.6, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Size = UDim2.new(0, 520, 0, 150)}):Play()

	task.wait(0.15)

	tweenService:Create(prompt.Policy.Title, TweenInfo.new(0.35, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0}):Play()
	task.wait(0.03)
	tweenService:Create(prompt.Policy.Notice, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0.5}):Play()
	
	task.wait(0.15)

	tweenService:Create(prompt.Policy.Actions.Primary, TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {BackgroundTransparency = 0.3}):Play()
	tweenService:Create(prompt.Policy.Actions.Primary.Title, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0.2}):Play()
	tweenService:Create(prompt.Policy.Actions.Primary.Shadow, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {ImageTransparency = 0.7}):Play()

	task.wait(5)
	
	if not fin then
		tweenService:Create(prompt.Policy.Actions.Secondary.Title, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0.6}):Play()
		debounce = false
	end
end

local function close(prompt)
	debounce = true
	tweenService:Create(prompt.Policy, TweenInfo.new(0.3, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {Size = UDim2.new(0, 430, 0, 110)}):Play()

	tweenService:Create(prompt.Policy.Title, TweenInfo.new(0.35, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 1}):Play()
	tweenService:Create(prompt.Policy.Notice, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 1}):Play()

	tweenService:Create(prompt.Policy.Actions.Secondary.Title, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 1}):Play()

	tweenService:Create(prompt.Policy.Actions.Primary, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {BackgroundTransparency = 1}):Play()
	tweenService:Create(prompt.Policy.Actions.Primary.Title, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 1}):Play()
	tweenService:Create(prompt.Policy.Actions.Primary.Shadow, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {ImageTransparency = 1}):Play()
	
	tweenService:Create(prompt.Policy, TweenInfo.new(0.2, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {BackgroundTransparency = 1}):Play()
	tweenService:Create(prompt.Policy.Shadow.Image, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {ImageTransparency = 1}):Play()
	
	task.wait(1)
	
	prompt:Destroy()
	fin = true
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
		close(prompt)
		if callback then callback(true) end
	end)

	prompt.Policy.Actions.Secondary.Interact.MouseButton1Click:Connect(function()
		close(prompt)
		if callback then callback(false) end
	end)
	
	prompt.Policy.Actions.Primary.Interact.MouseEnter:Connect(function()
		if debounce then return end
		tweenService:Create(prompt.Policy.Actions.Primary, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {BackgroundTransparency = 0}):Play()
		tweenService:Create(prompt.Policy.Actions.Primary.Title, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0}):Play()
		tweenService:Create(prompt.Policy.Actions.Primary.Shadow, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {ImageTransparency = 0.45}):Play()
	end)
	
	prompt.Policy.Actions.Primary.Interact.MouseLeave:Connect(function()
		if debounce then return end
		tweenService:Create(prompt.Policy.Actions.Primary, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {BackgroundTransparency = 0.2}):Play()
		tweenService:Create(prompt.Policy.Actions.Primary.Title, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0.2}):Play()
		tweenService:Create(prompt.Policy.Actions.Primary.Shadow, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {ImageTransparency = 0.7}):Play()
	end)

	prompt.Policy.Actions.Secondary.Interact.MouseEnter:Connect(function()
		if debounce then return end
		tweenService:Create(prompt.Policy.Actions.Secondary.Title, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0.3}):Play()
	end)
	
	prompt.Policy.Actions.Secondary.Interact.MouseLeave:Connect(function()
		if debounce then return end
		tweenService:Create(prompt.Policy.Actions.Secondary.Title, TweenInfo.new(0.4, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {TextTransparency = 0.6}):Play()
	end)
	
	task.wait(0.5)

	task.spawn(open, prompt)
end

return promptRet

-- ----------------------------------------
-- SERVICES
-- ----------------------------------------
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local CoreGui          = game:GetService("CoreGui")
local Lighting         = game:GetService("Lighting")
local Stats            = game:GetService("Stats")
local TeleportService  = game:GetService("TeleportService")
local VirtualUser      = game:GetService("VirtualUser")
local Debris           = game:GetService("Debris")
local TextService      = game:GetService("TextService")

-- ----------------------------------------
-- FIX #1: SAFE LocalPlayer (executor always has it)
-- ----------------------------------------
local LP = Players.LocalPlayer
while not LP do
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	LP = Players.LocalPlayer
end

-- ----------------------------------------
-- SAFE CHARACTER WAIT
-- ----------------------------------------
local Cam = workspace.CurrentCamera
local Char, Hum, HRP

local function waitForCharacter()
	Char = LP.Character
	if not Char or not Char.Parent then
		Char = LP.CharacterAdded:Wait()
	end
	return Char
end

Char = waitForCharacter()
Hum = Char:FindFirstChild("Humanoid") or Char:WaitForChild("Humanoid")
HRP = Char:FindFirstChild("HumanoidRootPart") or Char:WaitForChild("HumanoidRootPart")

-- ----------------------------------------
-- CONFIG
-- ----------------------------------------
local CLIENT_PREFIX = ";"
local SERVER_PREFIX = "!"

local owners    = {"viviwave_2"}
local admins    = {"viviwave_2"}
local tempAdmins = {}
local mods      = {}

local bannedPlayers = {}
local mutedPlayers  = {}
local warnings      = {}
local commandLogs   = {}
local rateLimit     = {}

-- ----------------------------------------
-- CLIENT STATE
-- ----------------------------------------
local CLIENT_PREFIX_LABEL = CLIENT_PREFIX  -- may be changed at runtime
local Connections = {}
local SavedPos    = nil

local State = {
	ws = 16, jp = 50, hh = 2, fov = 70,
	god = false, invis = false, noclip = false,
	fly = false, esp = false, freecam = false, antiafk = false,
}
local ESPObjects = {}

-- ----------------------------------------
-- PERMISSION HELPERS
-- ----------------------------------------
local function inList(list, name)
	if not name then return false end
	local low = name:lower()
	for _, v in ipairs(list) do
		if tostring(v):lower() == low then return true end
	end
	return false
end

local function isOwner(n) return inList(owners, n) end
local function isAdmin(n) return isOwner(n) or inList(admins, n) or inList(tempAdmins, n) end
local function isMod(n)   return isAdmin(n) or inList(mods, n) end
local function isBanned(n) return inList(bannedPlayers, n) end
local function isMuted(n)  return inList(mutedPlayers, n) end

local function checkRateLimit(name)
	local now = tick()
	if not rateLimit[name] or now - rateLimit[name].time > 10 then
		rateLimit[name] = {count = 1, time = now}
		return true
	end
	rateLimit[name].count += 1
	return rateLimit[name].count <= 8
end

-- ----------------------------------------
-- TARGET RESOLVER
-- ----------------------------------------
local function getHRP(plr)
	if plr and plr.Character then
		return plr.Character:FindFirstChild("HumanoidRootPart")
	end
end

local function resolvePlayers(caller, str)
	if not str then return {} end
	str = str:lower():gsub("%s+", "")
	local all = Players:GetPlayers()
	local out = {}

	if str == "me" then
		return {caller}
	elseif str == "all" then
		return all
	elseif str == "others" then
		for _, p in ipairs(all) do
			if p ~= caller then table.insert(out, p) end
		end
	elseif str == "random" then
		local pool = {}
		for _, p in ipairs(all) do
			if p ~= caller then table.insert(pool, p) end
		end
		if #pool > 0 then return {pool[math.random(#pool)]} end
	elseif str == "nearest" then
		local best, bd = nil, math.huge
		local callerHRP = getHRP(caller)
		if callerHRP then
			for _, p in ipairs(all) do
				if p ~= caller then
					local hrp = getHRP(p)
					if hrp then
						local d = (callerHRP.Position - hrp.Position).Magnitude
						if d < bd then bd = d; best = p end
					end
				end
			end
		end
		if best then return {best} end
	elseif str == "admins" then
		for _, p in ipairs(all) do
			if isAdmin(p.Name) then table.insert(out, p) end
		end
	elseif str == "nonadmins" then
		for _, p in ipairs(all) do
			if not isAdmin(p.Name) then table.insert(out, p) end
		end
	else
		for _, p in ipairs(all) do
			if p.Name:lower():find(str, 1, true) or p.DisplayName:lower():find(str, 1, true) then
				table.insert(out, p)
			end
		end
	end
	return out
end

-- ----------------------------------------
-- FIX #2: GUI SETUP � safe CoreGui parenting for all executors
-- ----------------------------------------
local GUI
do
	-- Destroy old instance if re-running the script
	local old = CoreGui:FindFirstChild("IronAdmin") or LP:FindFirstChild("PlayerGui") and LP.PlayerGui:FindFirstChild("IronAdmin")
	if old then old:Destroy() end

	GUI = Instance.new("ScreenGui")
	GUI.Name = "IronAdmin"
	GUI.ResetOnSpawn = false
	GUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	GUI.DisplayOrder = 999

	-- Try executor-specific protect_gui, then CoreGui, then PlayerGui
	local protected = false
	if not protected then
		pcall(function()
			if syn and syn.protect_gui then
				syn.protect_gui(GUI)
				protected = true
			end
		end)
	end
	if not protected then
		pcall(function()
			if protect_gui then
				protect_gui(GUI)
				protected = true
			end
		end)
	end

	local ok = pcall(function() GUI.Parent = CoreGui end)
	if not ok or not GUI.Parent then
		GUI.Parent = LP:WaitForChild("PlayerGui")
	end
end

-- ----------------------------------------
-- NOTIFICATION SYSTEM
-- ----------------------------------------
local NotifyHolder = Instance.new("Frame")
NotifyHolder.Name          = "NotifyHolder"
NotifyHolder.Size          = UDim2.new(0, 290, 1, -10)
NotifyHolder.Position      = UDim2.new(1, -300, 0, 5)
NotifyHolder.BackgroundTransparency = 1
NotifyHolder.Parent        = GUI

local NotifyLayout = Instance.new("UIListLayout")
NotifyLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
NotifyLayout.Padding        = UDim.new(0, 5)
NotifyLayout.Parent         = NotifyHolder

local function notify(title, body, duration)
	title    = tostring(title or "")
	body     = tostring(body  or "")
	duration = duration or 3.5

	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.BackgroundColor3 = Color3.fromRGB(13, 13, 20)
	card.BorderSizePixel  = 0
	card.ClipsDescendants = true
	card.Parent = NotifyHolder
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)

	local accent = Instance.new("Frame")
	accent.Size             = UDim2.new(0, 3, 1, 0)
	accent.BackgroundColor3 = Color3.fromRGB(100, 60, 255)
	accent.BorderSizePixel  = 0
	accent.Parent = card

	local prog = Instance.new("Frame")
	prog.Size             = UDim2.new(1, 0, 0, 2)
	prog.Position         = UDim2.new(0, 0, 1, -2)
	prog.BackgroundColor3 = Color3.fromRGB(100, 60, 255)
	prog.BorderSizePixel  = 0
	prog.Parent = card

	local t = Instance.new("TextLabel")
	t.Text              = title
	t.Font              = Enum.Font.GothamBold
	t.TextSize          = 13
	t.TextColor3        = Color3.fromRGB(255, 255, 255)
	t.BackgroundTransparency = 1
	t.Size              = UDim2.new(1, -14, 0, 18)
	t.Position          = UDim2.new(0, 10, 0, 8)
	t.TextXAlignment    = Enum.TextXAlignment.Left
	t.Parent = card

	local b = Instance.new("TextLabel")
	b.Text              = body
	b.Font              = Enum.Font.Gotham
	b.TextSize          = 11
	b.TextColor3        = Color3.fromRGB(170, 170, 195)
	b.BackgroundTransparency = 1
	b.Size              = UDim2.new(1, -14, 0, 14)
	b.Position          = UDim2.new(0, 10, 0, 28)
	b.TextXAlignment    = Enum.TextXAlignment.Left
	b.TextWrapped       = true
	b.Parent = card

	TweenService:Create(card, TweenInfo.new(0.2, Enum.EasingStyle.Quart), {Size = UDim2.new(1, 0, 0, 54)}):Play()

	task.spawn(function()
		local s = tick()
		while tick() - s < duration and card.Parent do
			prog.Size = UDim2.new(1 - ((tick() - s) / duration), 0, 0, 2)
			task.wait(0.05)
		end
		if not card.Parent then return end
		TweenService:Create(card, TweenInfo.new(0.18), {Size = UDim2.new(1, 0, 0, 0), BackgroundTransparency = 1}):Play()
		task.delay(0.2, function() pcall(function() card:Destroy() end) end)
	end)
end

-- ----------------------------------------
-- TOAST / HINT / MESSAGE
-- ----------------------------------------
local function createToastGui(parent, text, duration, kind)
	if not parent or text == nil then return end
	text     = tostring(text)
	duration = duration or 3
	kind     = kind or "info"

	for _, g in ipairs(parent:GetChildren()) do
		if g:IsA("ScreenGui") and g.Name == "IronToast" then g:Destroy() end
	end

	local colors = {
		info    = Color3.fromRGB(26, 77, 153),
		success = Color3.fromRGB(26, 153, 77),
		warning = Color3.fromRGB(178, 127, 0),
		error   = Color3.fromRGB(153, 26, 26),
	}
	local col = colors[kind] or colors.info

	local gui = Instance.new("ScreenGui")
	gui.Name           = "IronToast"
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.Parent         = parent

	local f = Instance.new("Frame")
	f.Size             = UDim2.new(0, 340, 0, 64)
	f.Position         = UDim2.new(0.5, -170, 1, 0)
	f.BackgroundColor3 = Color3.fromRGB(14, 14, 22)
	f.BorderSizePixel  = 0
	f.Parent = gui
	Instance.new("UICorner", f).CornerRadius = UDim.new(0, 8)

	local bar = Instance.new("Frame")
	bar.Size             = UDim2.new(0, 4, 1, 0)
	bar.BackgroundColor3 = col
	bar.BorderSizePixel  = 0
	bar.Parent = f
	Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 4)

	local lbl = Instance.new("TextLabel")
	lbl.Text             = text
	lbl.Font             = Enum.Font.Gotham
	lbl.TextSize         = 13
	lbl.TextColor3       = Color3.fromRGB(220, 220, 230)
	lbl.BackgroundTransparency = 1
	lbl.Size             = UDim2.new(1, -18, 1, 0)
	lbl.Position         = UDim2.new(0, 14, 0, 0)
	lbl.TextXAlignment   = Enum.TextXAlignment.Left
	lbl.TextWrapped      = true
	lbl.Parent = f

	local prog = Instance.new("Frame")
	prog.Size             = UDim2.new(1, 0, 0, 3)
	prog.Position         = UDim2.new(0, 0, 1, -3)
	prog.BackgroundColor3 = col
	prog.BorderSizePixel  = 0
	prog.Parent = f

	TweenService:Create(f, TweenInfo.new(0.2, Enum.EasingStyle.Quart), {Position = UDim2.new(0.5, -170, 0.88, 0)}):Play()

	task.spawn(function()
		local s = tick()
		while tick() - s < duration and f.Parent do
			prog.Size = UDim2.new(1 - ((tick() - s) / duration), 0, 0, 3)
			task.wait(0.05)
		end
		if not f.Parent then return end
		TweenService:Create(f, TweenInfo.new(0.15), {Position = UDim2.new(0.5, -170, 1, 0)}):Play()
		task.delay(0.2, function() pcall(function() gui:Destroy() end) end)
	end)
	return gui
end

local function createHintGui(parent, text, duration)
	if not parent or text == nil then return end
	text     = tostring(text)
	duration = duration or 4

	for _, g in ipairs(parent:GetChildren()) do
		if g:IsA("ScreenGui") and g.Name == "IronHint" then g:Destroy() end
	end

	local gui = Instance.new("ScreenGui")
	gui.Name           = "IronHint"
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.Parent         = parent

	local f = Instance.new("Frame")
	f.Size             = UDim2.new(0.6, 0, 0, 44)
	f.Position         = UDim2.new(0.2, 0, -0.08, 0)
	f.BackgroundColor3 = Color3.fromRGB(12, 12, 20)
	f.BackgroundTransparency = 0.1
	f.BorderSizePixel  = 2
	f.BorderColor3     = Color3.fromRGB(60, 60, 90)
	f.Parent = gui
	Instance.new("UICorner", f).CornerRadius = UDim.new(0, 7)

	local lbl = Instance.new("TextLabel")
	lbl.Text             = text
	lbl.Font             = Enum.Font.GothamBold
	lbl.TextSize         = 14
	lbl.TextColor3       = Color3.fromRGB(240, 240, 240)
	lbl.BackgroundTransparency = 1
	lbl.Size             = UDim2.new(1, -10, 1, 0)
	lbl.Position         = UDim2.new(0, 10, 0, 0)
	lbl.TextXAlignment   = Enum.TextXAlignment.Left
	lbl.Parent = f

	local pb = Instance.new("Frame")
	pb.Size             = UDim2.new(1, 0, 0, 3)
	pb.Position         = UDim2.new(0, 0, 1, -3)
	pb.BackgroundColor3 = Color3.fromRGB(80, 120, 255)
	pb.BorderSizePixel  = 0
	pb.Parent = f

	TweenService:Create(f, TweenInfo.new(0.2, Enum.EasingStyle.Quart), {Position = UDim2.new(0.2, 0, 0.02, 0)}):Play()

	task.spawn(function()
		local s = tick()
		while tick() - s < duration and f.Parent do
			pb.Size = UDim2.new(1 - ((tick() - s) / duration), 0, 0, 3)
			task.wait(0.05)
		end
		if not f.Parent then return end
		TweenService:Create(f, TweenInfo.new(0.15), {Position = UDim2.new(0.2, 0, -0.08, 0)}):Play()
		task.delay(0.2, function() pcall(function() gui:Destroy() end) end)
	end)
end

local function createMessageGui(parent, title, body, duration, kind)
	if not parent then return end
	title    = tostring(title or "")
	body     = tostring(body  or "")
	duration = duration or 8
	kind     = kind or "info"

	for _, g in ipairs(parent:GetChildren()) do
		if g:IsA("ScreenGui") and g.Name == "IronMessage" then g:Destroy() end
	end

	local colors = {
		info    = Color3.fromRGB(26, 77, 153),
		success = Color3.fromRGB(20, 120, 60),
		warning = Color3.fromRGB(160, 110, 0),
		error   = Color3.fromRGB(140, 30, 30),
	}
	local col = colors[kind] or colors.info

	local gui = Instance.new("ScreenGui")
	gui.Name           = "IronMessage"
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.Parent         = parent

	local overlay = Instance.new("Frame")
	overlay.Size             = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 0.55
	overlay.BorderSizePixel  = 0
	overlay.Parent = gui

	local main = Instance.new("Frame")
	main.Size             = UDim2.new(0, 460, 0, 320)
	main.Position         = UDim2.new(0.5, -230, 0.5, -160)
	main.BackgroundColor3 = Color3.fromRGB(13, 13, 20)
	main.BorderSizePixel  = 0
	main.Parent = gui
	Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)

	local tb = Instance.new("Frame")
	tb.Size             = UDim2.new(1, 0, 0, 44)
	tb.BackgroundColor3 = col
	tb.BorderSizePixel  = 0
	tb.Parent = main
	Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 10)

	local fix = Instance.new("Frame")
	fix.Size             = UDim2.new(1, 0, 0, 10)
	fix.Position         = UDim2.new(0, 0, 1, -10)
	fix.BackgroundColor3 = col
	fix.BorderSizePixel  = 0
	fix.Parent = tb

	local tlbl = Instance.new("TextLabel")
	tlbl.Text             = title
	tlbl.Font             = Enum.Font.GothamBold
	tlbl.TextSize         = 15
	tlbl.TextColor3       = Color3.fromRGB(255, 255, 255)
	tlbl.BackgroundTransparency = 1
	tlbl.Size             = UDim2.new(1, -14, 1, 0)
	tlbl.Position         = UDim2.new(0, 14, 0, 0)
	tlbl.TextXAlignment   = Enum.TextXAlignment.Left
	tlbl.Parent = tb

	local sf = Instance.new("ScrollingFrame")
	sf.Size            = UDim2.new(1, -20, 1, -70)
	sf.Position        = UDim2.new(0, 10, 0, 54)
	sf.BackgroundTransparency = 1
	sf.BorderSizePixel = 0
	sf.ScrollBarThickness = 4
	sf.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 120)
	sf.CanvasSize      = UDim2.new(0, 0, 0, 0)
	sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sf.Parent = main

	local mlbl = Instance.new("TextLabel")
	mlbl.Text             = body
	mlbl.Font             = Enum.Font.Gotham
	mlbl.TextSize         = 13
	mlbl.TextColor3       = Color3.fromRGB(210, 210, 225)
	mlbl.BackgroundTransparency = 1
	mlbl.Size             = UDim2.new(1, 0, 0, 10)
	mlbl.AutomaticSize    = Enum.AutomaticSize.Y
	mlbl.TextXAlignment   = Enum.TextXAlignment.Left
	mlbl.TextYAlignment   = Enum.TextYAlignment.Top
	mlbl.TextWrapped      = true
	mlbl.Parent = sf

	local okBtn = Instance.new("TextButton")
	okBtn.Text             = "OK"
	okBtn.Font             = Enum.Font.GothamBold
	okBtn.TextSize         = 13
	okBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
	okBtn.BackgroundColor3 = col
	okBtn.BorderSizePixel  = 0
	okBtn.Size             = UDim2.new(0, 90, 0, 28)
	okBtn.Position         = UDim2.new(0.5, -45, 1, -38)
	okBtn.Parent = main
	Instance.new("UICorner", okBtn).CornerRadius = UDim.new(0, 6)
	okBtn.MouseButton1Click:Connect(function() pcall(function() gui:Destroy() end) end)

	task.delay(duration, function() pcall(function() if gui.Parent then gui:Destroy() end end) end)
end

local function createAlertGui(parent, title, body, duration, kind)
	createMessageGui(parent, title, body, duration or 6, kind or "warning")
end

local function sendToast(msg, targets, duration, kind)
	msg = tostring(msg or "")
	for _, p in ipairs(targets or {}) do
		local pg = p:FindFirstChild("PlayerGui")
		if pg then pcall(createToastGui, pg, msg, duration, kind) end
	end
end

local function sendHint(msg, targets, duration)
	msg = tostring(msg or "")
	for _, p in ipairs(targets or {}) do
		local pg = p:FindFirstChild("PlayerGui")
		if pg then pcall(createHintGui, pg, msg, duration) end
	end
end

local function sendMessage(title, msg, targets, duration, kind)
	title = tostring(title or "")
	msg   = tostring(msg   or "")
	for _, p in ipairs(targets or {}) do
		local pg = p:FindFirstChild("PlayerGui")
		if pg then pcall(createMessageGui, pg, title, msg, duration, kind) end
	end
end

local function sendAlert(title, msg, targets, kind)
	title = tostring(title or "")
	msg   = tostring(msg   or "")
	for _, p in ipairs(targets or {}) do
		local pg = p:FindFirstChild("PlayerGui")
		if pg then pcall(createAlertGui, pg, title, msg, 6, kind) end
	end
end

-- ----------------------------------------
-- COMMAND BAR GUI
-- ----------------------------------------
local BarHolder = Instance.new("Frame")
BarHolder.Name             = "CmdBar"
BarHolder.Size             = UDim2.new(1, 0, 0, 36)
BarHolder.Position         = UDim2.new(0, 0, 0, -40)
BarHolder.BackgroundColor3 = Color3.fromRGB(9, 9, 15)
BarHolder.BorderSizePixel  = 0
BarHolder.ZIndex           = 10
BarHolder.Parent           = GUI

local BarAccent = Instance.new("Frame")
BarAccent.Size             = UDim2.new(1, 0, 0, 2)
BarAccent.Position         = UDim2.new(0, 0, 1, -2)
BarAccent.BackgroundColor3 = Color3.fromRGB(100, 60, 255)
BarAccent.BorderSizePixel  = 0
BarAccent.Parent           = BarHolder

local PrefixLbl = Instance.new("TextLabel")
PrefixLbl.Text             = CLIENT_PREFIX_LABEL
PrefixLbl.Font             = Enum.Font.GothamBold
PrefixLbl.TextSize         = 16
PrefixLbl.TextColor3       = Color3.fromRGB(100, 60, 255)
PrefixLbl.BackgroundTransparency = 1
PrefixLbl.Size             = UDim2.new(0, 24, 1, 0)
PrefixLbl.Position         = UDim2.new(0, 8, 0, 0)
PrefixLbl.Parent           = BarHolder

local CmdBox = Instance.new("TextBox")
CmdBox.Text              = ""
CmdBox.PlaceholderText   = "enter command  (RightShift to toggle)"
CmdBox.PlaceholderColor3 = Color3.fromRGB(70, 70, 95)
CmdBox.Font              = Enum.Font.Gotham
CmdBox.TextSize          = 14
CmdBox.TextColor3        = Color3.fromRGB(230, 230, 240)
CmdBox.BackgroundTransparency = 1
CmdBox.Size              = UDim2.new(1, -40, 1, 0)
CmdBox.Position          = UDim2.new(0, 36, 0, 0)
CmdBox.TextXAlignment    = Enum.TextXAlignment.Left
CmdBox.ClearTextOnFocus  = false
CmdBox.Parent            = BarHolder

local AcDrop = Instance.new("Frame")
AcDrop.Name             = "AcDrop"
AcDrop.Size             = UDim2.new(1, 0, 0, 0)
AcDrop.Position         = UDim2.new(0, 0, 1, 0)
AcDrop.BackgroundColor3 = Color3.fromRGB(14, 14, 24)
AcDrop.BorderSizePixel  = 0
AcDrop.ClipsDescendants = true
AcDrop.ZIndex           = 11
AcDrop.Parent           = BarHolder

local AcLayout = Instance.new("UIListLayout")
AcLayout.Parent = AcDrop
local AcPad = Instance.new("UIPadding")
AcPad.PaddingLeft  = UDim.new(0, 4)
AcPad.PaddingRight = UDim.new(0, 4)
AcPad.Parent = AcDrop

local barOpen = false
local function setBarOpen(open)
	barOpen = open
	TweenService:Create(BarHolder, TweenInfo.new(0.18, Enum.EasingStyle.Quart),
		{Position = open and UDim2.new(0,0,0,0) or UDim2.new(0,0,0,-40)}):Play()
	if open then
		task.delay(0.05, function() CmdBox:CaptureFocus() end)
	else
		CmdBox:ReleaseFocus()
		AcDrop.Size = UDim2.new(1, 0, 0, 0)
	end
end

UserInputService.InputBegan:Connect(function(inp, gpe)
	if inp.KeyCode == Enum.KeyCode.RightShift and not gpe then
		setBarOpen(not barOpen)
	end
	if inp.KeyCode == Enum.KeyCode.Escape and barOpen then
		setBarOpen(false)
	end
end)

-- ----------------------------------------
-- COMMAND PANEL (;cmds)
-- ----------------------------------------
local Panel = Instance.new("Frame")
Panel.Name             = "CmdPanel"
Panel.Size             = UDim2.new(0, 460, 0, 520)
Panel.Position         = UDim2.new(0.5, -230, 0.5, -260)
Panel.BackgroundColor3 = Color3.fromRGB(10, 10, 17)
Panel.BorderSizePixel  = 0
Panel.Visible          = false
Panel.ZIndex           = 20
Panel.Parent           = GUI
Instance.new("UICorner", Panel).CornerRadius = UDim.new(0, 10)

local PanelTop = Instance.new("Frame")
PanelTop.Size             = UDim2.new(1, 0, 0, 3)
PanelTop.BackgroundColor3 = Color3.fromRGB(100, 60, 255)
PanelTop.BorderSizePixel  = 0
PanelTop.Parent           = Panel

local PTitle = Instance.new("TextLabel")
PTitle.Text             = "?  IronAdmin � All Commands"
PTitle.Font             = Enum.Font.GothamBold
PTitle.TextSize         = 15
PTitle.TextColor3       = Color3.fromRGB(255, 255, 255)
PTitle.BackgroundTransparency = 1
PTitle.Size             = UDim2.new(1, -50, 0, 42)
PTitle.Position         = UDim2.new(0, 14, 0, 4)
PTitle.TextXAlignment   = Enum.TextXAlignment.Left
PTitle.Parent           = Panel

local PClose = Instance.new("TextButton")
PClose.Text             = "?"
PClose.Font             = Enum.Font.GothamBold
PClose.TextSize         = 14
PClose.TextColor3       = Color3.fromRGB(160, 160, 180)
PClose.BackgroundTransparency = 1
PClose.Size             = UDim2.new(0, 36, 0, 36)
PClose.Position         = UDim2.new(1, -40, 0, 6)
PClose.Parent           = Panel
PClose.MouseButton1Click:Connect(function() Panel.Visible = false end)

local PSrch = Instance.new("TextBox")
PSrch.PlaceholderText   = "??  search..."
PSrch.PlaceholderColor3 = Color3.fromRGB(75, 75, 100)
PSrch.Text              = ""
PSrch.Font              = Enum.Font.Gotham
PSrch.TextSize          = 13
PSrch.TextColor3        = Color3.fromRGB(210, 210, 230)
PSrch.BackgroundColor3  = Color3.fromRGB(18, 18, 28)
PSrch.BorderSizePixel   = 0
PSrch.Size              = UDim2.new(1, -20, 0, 32)
PSrch.Position          = UDim2.new(0, 10, 0, 48)
PSrch.ClearTextOnFocus  = false
PSrch.Parent            = Panel
Instance.new("UICorner", PSrch).CornerRadius = UDim.new(0, 7)
local sp2 = Instance.new("UIPadding")
sp2.PaddingLeft = UDim.new(0, 10)
sp2.Parent = PSrch

local TabRow = Instance.new("Frame")
TabRow.Size             = UDim2.new(1, -20, 0, 28)
TabRow.Position         = UDim2.new(0, 10, 0, 86)
TabRow.BackgroundColor3 = Color3.fromRGB(18, 18, 28)
TabRow.BorderSizePixel  = 0
TabRow.Parent           = Panel
Instance.new("UICorner", TabRow).CornerRadius = UDim.new(0, 6)
local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection       = Enum.FillDirection.Horizontal
TabLayout.VerticalAlignment   = Enum.VerticalAlignment.Center
TabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
TabLayout.Padding             = UDim.new(0, 2)
TabLayout.Parent = TabRow

local PList = Instance.new("ScrollingFrame")
PList.Size             = UDim2.new(1, -20, 1, -126)
PList.Position         = UDim2.new(0, 10, 0, 120)
PList.BackgroundTransparency = 1
PList.BorderSizePixel  = 0
PList.ScrollBarThickness = 3
PList.ScrollBarImageColor3 = Color3.fromRGB(100, 60, 255)
PList.CanvasSize       = UDim2.new(0, 0, 0, 0)
PList.AutomaticCanvasSize = Enum.AutomaticSize.Y
PList.Parent           = Panel
Instance.new("UIListLayout", PList).Padding = UDim.new(0, 4)

local pDrag, pDS, pSP = false, nil, nil
PTitle.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		pDrag = true; pDS = i.Position; pSP = Panel.Position
	end
end)
PTitle.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then pDrag = false end
end)
UserInputService.InputChanged:Connect(function(i)
	if pDrag and i.UserInputType == Enum.UserInputType.MouseMovement then
		local d = i.Position - pDS
		Panel.Position = UDim2.new(pSP.X.Scale, pSP.X.Offset + d.X, pSP.Y.Scale, pSP.Y.Offset + d.Y)
	end
end)

-- ----------------------------------------
-- COMMANDS REGISTRY
-- ----------------------------------------
local CMDS = {
	{name="ws",args="<n>",desc="Walk speed",cat="Movement",mode="client"},
	{name="jp",args="<n>",desc="Jump power",cat="Movement",mode="client"},
	{name="hh",args="<n>",desc="Hip height",cat="Movement",mode="client"},
	{name="fov",args="<n>",desc="Field of view",cat="Movement",mode="client"},
	{name="default",args="",desc="Reset ws/jp/hh",cat="Movement",mode="client"},
	{name="fly",args="",desc="Enable fly (WASD+Space/Ctrl)",cat="Movement",mode="client"},
	{name="unfly",args="",desc="Disable fly",cat="Movement",mode="client"},
	{name="noclip",args="",desc="Enable noclip",cat="Movement",mode="client"},
	{name="clip",args="",desc="Disable noclip",cat="Movement",mode="client"},
	{name="tppos",args="<x> <y> <z>",desc="Teleport to coords",cat="Movement",mode="client"},
	{name="goto",args="<player>",desc="Teleport to player",cat="Movement",mode="client"},
	{name="savepos",args="",desc="Save position",cat="Movement",mode="client"},
	{name="loadpos",args="",desc="Load saved position",cat="Movement",mode="client"},
	{name="god",args="",desc="God mode ON",cat="Character",mode="client"},
	{name="ungod",args="",desc="God mode OFF",cat="Character",mode="client"},
	{name="heal",args="[player]",desc="Heal to max HP",cat="Character",mode="client"},
	{name="kill",args="[player]",desc="Kill humanoid",cat="Character",mode="client"},
	{name="respawn",args="",desc="Respawn self",cat="Character",mode="client"},
	{name="refresh",args="",desc="Refresh character",cat="Character",mode="client"},
	{name="sit",args="",desc="Sit",cat="Character",mode="client"},
	{name="invis",args="",desc="Invisible (local)",cat="Character",mode="client"},
	{name="vis",args="",desc="Visible again",cat="Character",mode="client"},
	{name="esp",args="",desc="ESP highlights + info",cat="Visual",mode="client"},
	{name="unesp",args="",desc="Disable ESP",cat="Visual",mode="client"},
	{name="freecam",args="",desc="Free camera",cat="Visual",mode="client"},
	{name="unfreecam",args="",desc="Stop freecam",cat="Visual",mode="client"},
	{name="view",args="<player>",desc="Spectate player",cat="Visual",mode="client"},
	{name="unview",args="",desc="Stop spectating",cat="Visual",mode="client"},
	{name="fullbright",args="",desc="Fullbright lighting",cat="Visual",mode="client"},
	{name="unfullbright",args="",desc="Reset lighting",cat="Visual",mode="client"},
	{name="rejoin",args="",desc="Rejoin server",cat="Server",mode="client"},
	{name="serverhop",args="",desc="Hop to random server",cat="Server",mode="client"},
	{name="antiafk",args="",desc="Anti-AFK",cat="Server",mode="client"},
	{name="players",args="",desc="List players",cat="Info",mode="client"},
	{name="copyname",args="<player>",desc="Copy username to clipboard",cat="Info",mode="client"},
	{name="ping",args="",desc="Show ping",cat="Info",mode="client"},
	{name="fps",args="",desc="Show FPS",cat="Info",mode="client"},
	{name="pos",args="",desc="Show position",cat="Info",mode="client"},
	{name="notify",args="<title>|<msg>",desc="Custom notification",cat="Info",mode="client"},
	{name="cmds",args="",desc="Open command panel",cat="Meta",mode="client"},
	{name="hide",args="",desc="Hide command bar",cat="Meta",mode="client"},
	{name="show",args="",desc="Show command bar",cat="Meta",mode="client"},
	{name="prefix",args="<char>",desc="Change client prefix",cat="Meta",mode="client"},
	{name="unload",args="",desc="Unload IronAdmin",cat="Meta",mode="client"},
	{name="kick",args="<p> [reason]",desc="Kick player",cat="Moderation",mode="server"},
	{name="ban",args="<p> [reason]",desc="Session ban + kick",cat="Moderation",mode="server"},
	{name="unban",args="<p>",desc="Unban player",cat="Moderation",mode="server"},
	{name="mute",args="<p>",desc="Mute player",cat="Moderation",mode="server"},
	{name="unmute",args="<p>",desc="Unmute player",cat="Moderation",mode="server"},
	{name="warn",args="<p> [reason]",desc="Warn (3 = kick)",cat="Moderation",mode="server"},
	{name="warnings",args="",desc="View warnings",cat="Moderation",mode="server"},
	{name="clearwarns",args="<p>",desc="Clear warnings",cat="Moderation",mode="server"},
	{name="freeze",args="<p>",desc="Freeze player",cat="Moderation",mode="server"},
	{name="thaw",args="<p>",desc="Unfreeze player",cat="Moderation",mode="server"},
	{name="jail",args="<p>",desc="Jail player",cat="Moderation",mode="server"},
	{name="unjail",args="",desc="Remove all jails",cat="Moderation",mode="server"},
	{name="promote",args="<p>",desc="Promote to admin",cat="Admin",mode="server"},
	{name="demote",args="<p>",desc="Demote admin",cat="Admin",mode="server"},
	{name="tempadmin",args="<p>",desc="Temporary admin",cat="Admin",mode="server"},
	{name="mod",args="<p>",desc="Make moderator",cat="Admin",mode="server"},
	{name="unmod",args="<p>",desc="Remove moderator",cat="Admin",mode="server"},
	{name="servertp",args="<p1> <p2>",desc="TP p1 to p2",cat="Server",mode="server"},
	{name="bringall",args="",desc="Bring all to you",cat="Server",mode="server"},
	{name="skysend",args="<p>",desc="Send player to sky",cat="Server",mode="server"},
	{name="voidkill",args="<p>",desc="Void a player",cat="Server",mode="server"},
	{name="ff",args="<p>",desc="Force field",cat="Server",mode="server"},
	{name="unff",args="<p>",desc="Remove force field",cat="Server",mode="server"},
	{name="serverfly",args="<p>",desc="Give player fly",cat="Server",mode="server"},
	{name="serverunfly",args="<p>",desc="Remove player fly",cat="Server",mode="server"},
	{name="spin",args="<p>",desc="Spin player",cat="Server",mode="server"},
	{name="unspin",args="<p>",desc="Stop spinning",cat="Server",mode="server"},
	{name="fire",args="<p>",desc="Add fire to player",cat="Server",mode="server"},
	{name="unfire",args="<p>",desc="Remove fire",cat="Server",mode="server"},
	{name="sparkle",args="<p>",desc="Add sparkles",cat="Server",mode="server"},
	{name="unsparkle",args="<p>",desc="Remove sparkles",cat="Server",mode="server"},
	{name="smoke",args="<p>",desc="Add smoke",cat="Server",mode="server"},
	{name="unsmoke",args="<p>",desc="Remove smoke",cat="Server",mode="server"},
	{name="rocket",args="<p>",desc="Launch player upward",cat="Server",mode="server"},
	{name="explode",args="<p>",desc="Explosion at player",cat="Server",mode="server"},
	{name="color",args="<p> <r> <g> <b>",desc="Color player",cat="Server",mode="server"},
	{name="rainbow",args="<p>",desc="Rainbow effect",cat="Server",mode="server"},
	{name="speed",args="<p> <n>",desc="Set player speed",cat="Server",mode="server"},
	{name="jump",args="<p> <n>",desc="Set player jump",cat="Server",mode="server"},
	{name="serverinvis",args="<p>",desc="Make player invisible",cat="Server",mode="server"},
	{name="servervis",args="<p>",desc="Make player visible",cat="Server",mode="server"},
	{name="servergod",args="<p>",desc="God mode (server)",cat="Server",mode="server"},
	{name="serverungod",args="<p>",desc="Remove god (server)",cat="Server",mode="server"},
	{name="serverheal",args="<p>",desc="Heal player",cat="Server",mode="server"},
	{name="serverkill",args="<p>",desc="Kill player",cat="Server",mode="server"},
	{name="message",args="<text>",desc="Message all players",cat="Broadcast",mode="server"},
	{name="hint",args="<text>",desc="Hint bar to all",cat="Broadcast",mode="server"},
	{name="announce",args="<text>",desc="Announcement to all",cat="Broadcast",mode="server"},
	{name="alert",args="<text>",desc="Alert all players",cat="Broadcast",mode="server"},
	{name="time",args="<0-24>",desc="Set time of day",cat="World",mode="server"},
	{name="gravity",args="<n>",desc="Set gravity",cat="World",mode="server"},
	{name="nogravity",args="",desc="Zero gravity",cat="World",mode="server"},
	{name="normalgravity",args="",desc="Reset gravity",cat="World",mode="server"},
	{name="fog",args="<dist>",desc="Set fog distance",cat="World",mode="server"},
	{name="nofog",args="",desc="Remove fog",cat="World",mode="server"},
	{name="brightness",args="<n>",desc="Lighting brightness",cat="World",mode="server"},
	{name="weather",args="<type>",desc="clear/rain/storm/snow/fog",cat="World",mode="server"},
	{name="clear",args="",desc="Clear workspace",cat="World",mode="server"},
	{name="music",args="<id|stop>",desc="Play/stop global music",cat="Media",mode="server"},
	{name="volume",args="<0-10>",desc="Music volume",cat="Media",mode="server"},
	{name="pause",args="",desc="Pause music",cat="Media",mode="server"},
	{name="resume",args="",desc="Resume music",cat="Media",mode="server"},
	{name="stopmusic",args="",desc="Stop all music",cat="Media",mode="server"},
	{name="musiclist",args="",desc="Popular music IDs",cat="Media",mode="server"},
	{name="info",args="",desc="Server info",cat="Info",mode="server"},
	{name="statsplr",args="<p>",desc="Player stats",cat="Info",mode="server"},
	{name="admins",args="",desc="List admins",cat="Info",mode="server"},
	{name="bans",args="",desc="List bans",cat="Info",mode="server"},
	{name="logs",args="",desc="Command logs",cat="Info",mode="server"},
	{name="serverping",args="<p>",desc="Player ping",cat="Info",mode="server"},
	{name="shutdown",args="",desc="Shutdown server",cat="Meta",mode="server"},
	{name="lock",args="",desc="Lock server",cat="Meta",mode="server"},
	{name="party",args="",desc="Spawn party parts",cat="Fun",mode="server"},
}

local CAT_COLORS = {
	Movement   = Color3.fromRGB(80, 140, 255),
	Character  = Color3.fromRGB(80, 220, 120),
	Visual     = Color3.fromRGB(200, 100, 255),
	Server     = Color3.fromRGB(255, 160, 60),
	Moderation = Color3.fromRGB(255, 80, 80),
	Admin      = Color3.fromRGB(255, 200, 40),
	Broadcast  = Color3.fromRGB(60, 210, 210),
	World      = Color3.fromRGB(120, 200, 80),
	Media      = Color3.fromRGB(200, 80, 200),
	Info       = Color3.fromRGB(60, 200, 220),
	Meta       = Color3.fromRGB(170, 170, 180),
	Fun        = Color3.fromRGB(255, 120, 160),
}

local activeTab = "All"
local tabBtns   = {}
local buildPanel  -- forward declaration

local function makePanelTab(name)
	local btn = Instance.new("TextButton")
	btn.Text             = name
	btn.Font             = Enum.Font.GothamBold
	btn.TextSize         = 11
	btn.TextColor3       = Color3.fromRGB(130, 130, 155)
	btn.BackgroundColor3 = Color3.fromRGB(18, 18, 28)
	btn.BorderSizePixel  = 0
	btn.Size             = UDim2.new(0, 70, 0, 24)
	btn.AutoButtonColor  = false
	btn.Parent           = TabRow
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 5)
	tabBtns[name] = btn
	btn.MouseButton1Click:Connect(function()
		activeTab = name
		for n, b in pairs(tabBtns) do
			TweenService:Create(b, TweenInfo.new(0.1), {
				BackgroundColor3 = n == name and Color3.fromRGB(100,60,255) or Color3.fromRGB(18,18,28),
				TextColor3       = n == name and Color3.fromRGB(255,255,255) or Color3.fromRGB(130,130,155),
			}):Play()
		end
		buildPanel(PSrch.Text)
	end)
end

makePanelTab("All")
makePanelTab("Client")
makePanelTab("Server")
TweenService:Create(tabBtns["All"], TweenInfo.new(0), {
	BackgroundColor3 = Color3.fromRGB(100,60,255),
	TextColor3       = Color3.fromRGB(255,255,255),
}):Play()

buildPanel = function(filter)
	for _, c in ipairs(PList:GetChildren()) do
		if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
	end
	local lastCat = nil
	for _, cmd in ipairs(CMDS) do
		local modeOk = activeTab == "All"
			or (activeTab == "Client" and cmd.mode == "client")
			or (activeTab == "Server" and cmd.mode == "server")
		if not modeOk then  continue end
		local query = (cmd.name .. " " .. cmd.desc):lower()
		if filter and filter ~= "" and not query:find(filter:lower(), 1, true) then  continue end
		if cmd.cat ~= lastCat then
			lastCat = cmd.cat
			local cl = Instance.new("TextLabel")
			cl.Text             = (cmd.mode == "server" and "! " or "; ") .. cmd.cat:upper()
			cl.Font             = Enum.Font.GothamBold
			cl.TextSize         = 10
			cl.TextColor3       = CAT_COLORS[cmd.cat] or Color3.fromRGB(150,150,150)
			cl.BackgroundTransparency = 1
			cl.Size             = UDim2.new(1, 0, 0, 20)
			cl.TextXAlignment   = Enum.TextXAlignment.Left
			cl.Parent           = PList
		end
		local row = Instance.new("Frame")
		row.Size             = UDim2.new(1, 0, 0, 30)
		row.BackgroundColor3 = Color3.fromRGB(16, 16, 26)
		row.BorderSizePixel  = 0
		row.Parent           = PList
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
		local dot = Instance.new("Frame")
		dot.Size             = UDim2.new(0, 4, 0, 4)
		dot.Position         = UDim2.new(0, 7, 0.5, -2)
		dot.BackgroundColor3 = CAT_COLORS[cmd.cat] or Color3.fromRGB(150,150,150)
		dot.BorderSizePixel  = 0
		dot.Parent           = row
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		local pfx = cmd.mode == "server" and SERVER_PREFIX or CLIENT_PREFIX_LABEL
		local nl = Instance.new("TextLabel")
		nl.Text           = pfx .. cmd.name .. (cmd.args ~= "" and " " .. cmd.args or "")
		nl.Font           = Enum.Font.GothamBold
		nl.TextSize       = 12
		nl.TextColor3     = cmd.mode == "server" and Color3.fromRGB(255,200,100) or Color3.fromRGB(200,220,255)
		nl.BackgroundTransparency = 1
		nl.Size           = UDim2.new(0.48, 0, 1, 0)
		nl.Position       = UDim2.new(0, 16, 0, 0)
		nl.TextXAlignment = Enum.TextXAlignment.Left
		nl.Parent         = row
		local dl = Instance.new("TextLabel")
		dl.Text           = cmd.desc
		dl.Font           = Enum.Font.Gotham
		dl.TextSize       = 11
		dl.TextColor3     = Color3.fromRGB(130, 130, 150)
		dl.BackgroundTransparency = 1
		dl.Size           = UDim2.new(0.5, 0, 1, 0)
		dl.Position       = UDim2.new(0.48, 0, 0, 0)
		dl.TextXAlignment = Enum.TextXAlignment.Left
		dl.Parent         = row
		local cb = Instance.new("TextButton")
		cb.Text             = ""
		cb.BackgroundTransparency = 1
		cb.Size             = UDim2.new(1, 0, 1, 0)
		cb.Parent           = row
		cb.MouseButton1Click:Connect(function()
			Panel.Visible = false
			setBarOpen(true)
			CmdBox.Text = (cmd.mode == "server" and "!" or "") .. cmd.name .. (cmd.args ~= "" and " " or "")
		end)
		continue
	end
end

PSrch:GetPropertyChangedSignal("Text"):Connect(function() buildPanel(PSrch.Text) end)
buildPanel("")

-- ----------------------------------------
-- AUTOCOMPLETE
-- ----------------------------------------
local function updateAutocomplete(text)
	for _, c in ipairs(AcDrop:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end
	if text == "" then
		AcDrop.Size = UDim2.new(1, 0, 0, 0)
		return
	end
	local isServer = text:sub(1, 1) == "!"
	local bare     = isServer and text:sub(2) or text
	local matches  = {}
	for _, cmd in ipairs(CMDS) do
		local mOk = (isServer and cmd.mode == "server") or (not isServer and cmd.mode == "client")
		if mOk and cmd.name:sub(1, #bare):lower() == bare:lower() then
			table.insert(matches, cmd)
			if #matches >= 6 then break end
		end
	end
	if #matches == 0 then
		AcDrop.Size = UDim2.new(1, 0, 0, 0)
		return
	end
	for _, cmd in ipairs(matches) do
		local btn = Instance.new("TextButton")
		btn.Size             = UDim2.new(1, 0, 0, 24)
		btn.BackgroundTransparency = 1
		btn.Font             = Enum.Font.Gotham
		btn.TextSize         = 13
		btn.TextColor3       = Color3.fromRGB(200, 210, 240)
		btn.Text             = (isServer and "!" or CLIENT_PREFIX_LABEL) .. cmd.name .. " " .. cmd.args
		btn.TextXAlignment   = Enum.TextXAlignment.Left
		btn.ZIndex           = 12
		btn.Parent           = AcDrop
		local ip = Instance.new("UIPadding")
		ip.PaddingLeft = UDim.new(0, 8)
		ip.Parent = btn
		btn.MouseEnter:Connect(function()
			btn.BackgroundTransparency = 0
			btn.BackgroundColor3 = Color3.fromRGB(25, 25, 40)
		end)
		btn.MouseLeave:Connect(function() btn.BackgroundTransparency = 1 end)
		btn.MouseButton1Click:Connect(function()
			CmdBox.Text = cmd.name .. (cmd.args ~= "" and " " or "")
			AcDrop.Size = UDim2.new(1, 0, 0, 0)
			CmdBox:CaptureFocus()
		end)
	end
	AcDrop.Size = UDim2.new(1, 0, 0, #matches * 24 + 4)
end

CmdBox:GetPropertyChangedSignal("Text"):Connect(function()
	updateAutocomplete(CmdBox.Text)
end)

-- ----------------------------------------
-- MOVEMENT PERSISTENCE
-- ----------------------------------------
local function applyMovement()
	local c = LP.Character
	if not c then return end
	local h = c:FindFirstChild("Humanoid")
	if h then
		h.WalkSpeed = State.ws
		h.JumpPower = State.jp
		h.HipHeight = State.hh
	end
	Cam.FieldOfView = State.fov
end

LP.CharacterAdded:Connect(function(c)
	Char = c
	Hum = c:WaitForChild("Humanoid")
	HRP = c:WaitForChild("HumanoidRootPart")
	task.delay(0.5, applyMovement)
	if State.god then
		if Connections.god then Connections.god:Disconnect() end
		Connections.god = RunService.Heartbeat:Connect(function()
			local h = LP.Character and LP.Character:FindFirstChild("Humanoid")
			if h then h.Health = h.MaxHealth end
		end)
	end
end)

-- ----------------------------------------
-- FLY
-- ----------------------------------------
local function startFly()
	State.fly = true
	local c   = LP.Character
	if not c then return end
	local hrp2 = c:FindFirstChild("HumanoidRootPart")
	if not hrp2 then return end
	local bv = Instance.new("BodyVelocity")
	bv.Name      = "IronFlyBV"
	bv.Velocity  = Vector3.zero
	bv.MaxForce  = Vector3.new(1e5, 1e5, 1e5)
	bv.Parent    = hrp2
	local bg = Instance.new("BodyGyro")
	bg.Name      = "IronFlyBG"
	bg.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
	bg.P         = 2e4
	bg.Parent    = hrp2
	local hum2 = c:FindFirstChild("Humanoid")
	if hum2 then hum2.PlatformStand = true end
	if Connections.fly then Connections.fly:Disconnect() end
	Connections.fly = RunService.Heartbeat:Connect(function()
		if not State.fly then
			pcall(function() bv:Destroy() end)
			pcall(function() bg:Destroy() end)
			local h2 = LP.Character and LP.Character:FindFirstChild("Humanoid")
			if h2 then h2.PlatformStand = false end
			if Connections.fly then Connections.fly:Disconnect(); Connections.fly = nil end
			return
		end
		local spd = math.max(State.ws, 16) * 2.5
		local dir = Vector3.zero
		local cf  = Cam.CFrame
		if UserInputService:IsKeyDown(Enum.KeyCode.W)           then dir += cf.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.S)           then dir -= cf.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.A)           then dir -= cf.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.D)           then dir += cf.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space)       then dir += Vector3.new(0,1,0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.new(0,1,0) end
		bv.Velocity = dir.Magnitude > 0 and dir.Unit * spd or Vector3.zero
		bg.CFrame   = cf
	end)
end

local function stopFly()
	State.fly = false
end

-- ----------------------------------------
-- ESP
-- ----------------------------------------
local function buildESP(player)
	if player == LP or ESPObjects[player] then return end
	local hl = Instance.new("Highlight")
	hl.Name              = "IronESP_HL"
	hl.FillColor         = Color3.fromRGB(255, 60, 60)
	hl.OutlineColor      = Color3.fromRGB(255, 255, 255)
	hl.FillTransparency  = 0.55
	hl.DepthMode         = Enum.HighlightDepthMode.AlwaysOnTop
	local bb = Instance.new("BillboardGui")
	bb.Name         = "IronESP_BB"
	bb.Size         = UDim2.new(0, 130, 0, 40)
	bb.StudsOffset  = Vector3.new(0, 3, 0)
	bb.AlwaysOnTop  = true
	local nl = Instance.new("TextLabel")
	nl.Text             = player.Name .. " [" .. player.DisplayName .. "]"
	nl.Font             = Enum.Font.GothamBold
	nl.TextSize         = 12
	nl.TextColor3       = Color3.fromRGB(255, 255, 255)
	nl.BackgroundTransparency = 1
	nl.Size             = UDim2.new(1, 0, 0.5, 0)
	nl.TextStrokeTransparency = 0.4
	nl.Parent = bb
	local dl = Instance.new("TextLabel")
	dl.Font             = Enum.Font.Gotham
	dl.TextSize         = 10
	dl.TextColor3       = Color3.fromRGB(200, 200, 200)
	dl.BackgroundTransparency = 1
	dl.Size             = UDim2.new(1, 0, 0.5, 0)
	dl.Position         = UDim2.new(0, 0, 0.5, 0)
	dl.TextStrokeTransparency = 0.5
	dl.Parent = bb
	local function attach()
		if player.Character then
			hl.Adornee = player.Character
			hl.Parent  = player.Character
			bb.Adornee = player.Character:FindFirstChild("HumanoidRootPart") or player.Character:FindFirstChildOfClass("BasePart")
			bb.Parent  = player.Character
		end
	end
	attach()
	player.CharacterAdded:Connect(attach)
	ESPObjects[player] = {hl = hl, bb = bb, dist = dl}
end

local function removeESP(p)
	if ESPObjects[p] then
		pcall(function() ESPObjects[p].hl:Destroy() end)
		pcall(function() ESPObjects[p].bb:Destroy() end)
		ESPObjects[p] = nil
	end
end

local function enableESP()
	State.esp = true
	for _, p in ipairs(Players:GetPlayers()) do buildESP(p) end
	Connections.esp_add = Players.PlayerAdded:Connect(function(p) if State.esp then buildESP(p) end end)
	Connections.esp_rem = Players.PlayerRemoving:Connect(removeESP)
	Connections.esp_upd = RunService.Heartbeat:Connect(function()
		if not State.esp then return end
		for p, obj in pairs(ESPObjects) do
			if p.Character and HRP then
				local h2 = p.Character:FindFirstChild("HumanoidRootPart")
				if h2 then
					local d  = math.floor((HRP.Position - h2.Position).Magnitude)
					local hm = p.Character:FindFirstChild("Humanoid")
					local hp = hm and math.floor(hm.Health) or "?"
					obj.dist.Text = d .. " studs | HP: " .. hp
				end
			end
		end
	end)
end

local function disableESP()
	State.esp = false
	for _, p in ipairs(Players:GetPlayers()) do removeESP(p) end
	for _, k in ipairs({"esp_add","esp_rem","esp_upd"}) do
		if Connections[k] then Connections[k]:Disconnect(); Connections[k] = nil end
	end
end

-- ----------------------------------------
-- FREECAM
-- ----------------------------------------
local FreecamPart
local function startFreecam()
	State.freecam = true
	FreecamPart = Instance.new("Part")
	FreecamPart.Name        = "IronFreecam"
	FreecamPart.Anchored    = true
	FreecamPart.CanCollide  = false
	FreecamPart.Transparency = 1
	FreecamPart.CFrame      = Cam.CFrame
	FreecamPart.Parent      = workspace
	Cam.CameraType          = Enum.CameraType.Scriptable
	Cam.CameraSubject       = FreecamPart
	if Connections.freecam then Connections.freecam:Disconnect() end
	Connections.freecam = RunService.Heartbeat:Connect(function(dt)
		if not State.freecam then return end
		local dir = Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W)           then dir += Cam.CFrame.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.S)           then dir -= Cam.CFrame.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.A)           then dir -= Cam.CFrame.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.D)           then dir += Cam.CFrame.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.Space)       then dir += Vector3.new(0,1,0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.new(0,1,0) end
		if dir.Magnitude > 0 then
			FreecamPart.CFrame = CFrame.new(FreecamPart.Position + dir.Unit * 50 * dt)
				* (Cam.CFrame - Cam.CFrame.Position)
		end
		Cam.CFrame = CFrame.new(FreecamPart.Position) * (Cam.CFrame - Cam.CFrame.Position)
	end)
end

local function stopFreecam()
	State.freecam = false
	if FreecamPart then FreecamPart:Destroy(); FreecamPart = nil end
	Cam.CameraType = Enum.CameraType.Custom
	if LP.Character then Cam.CameraSubject = LP.Character:FindFirstChild("Humanoid") end
	if Connections.freecam then Connections.freecam:Disconnect(); Connections.freecam = nil end
end

-- ----------------------------------------
-- NOCLIP LOOP
-- ----------------------------------------
Connections.noclip = RunService.Stepped:Connect(function()
	if State.noclip and LP.Character then
		for _, p in ipairs(LP.Character:GetDescendants()) do
			if p:IsA("BasePart") then p.CanCollide = false end
		end
	end
end)

-- ----------------------------------------
-- GOD
-- ----------------------------------------
local function enableGod()
	State.god = true
	if Connections.god then Connections.god:Disconnect() end
	Connections.god = RunService.Heartbeat:Connect(function()
		local h = LP.Character and LP.Character:FindFirstChild("Humanoid")
		if h then h.Health = h.MaxHealth end
	end)
end

local function disableGod()
	State.god = false
	if Connections.god then Connections.god:Disconnect(); Connections.god = nil end
end

-- ----------------------------------------
-- ANTI-AFK
-- ----------------------------------------
local function enableAntiAfk()
	if State.antiafk then return end
	State.antiafk = true
	LP.Idled:Connect(function()
		if not State.antiafk then return end
		VirtualUser:Button2Down(Vector2.new(0,0), CFrame.new())
		task.wait(0.1)
		VirtualUser:Button2Up(Vector2.new(0,0), CFrame.new())
	end)
	notify("Anti-AFK", "Enabled.")
end

-- ----------------------------------------
-- SERVER HOP
-- ----------------------------------------
local function serverHop()
	notify("ServerHop", "Querying server list...", 4)
	task.spawn(function()
		local pid = game.PlaceId
		local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(pid)
		local ok, res = pcall(HttpService.GetAsync, HttpService, url)
		if not ok then notify("ServerHop", "HTTP request failed.", 3); return end
		local data    = HttpService:JSONDecode(res)
		local servers = {}
		for _, s in ipairs(data.data or {}) do
			if s.playing < s.maxPlayers then table.insert(servers, s.id) end
		end
		if #servers == 0 then notify("ServerHop", "No open servers found.", 3); return end
		local chosen = servers[math.random(#servers)]
		notify("ServerHop", "Joining " .. chosen:sub(1,8) .. "...", 3)
		task.delay(1, function() TeleportService:TeleportToPlaceInstance(pid, chosen, LP) end)
	end)
end

-- ----------------------------------------
-- CLIENT COMMAND EXECUTOR
-- ----------------------------------------
local function execClient(raw)
	raw = raw:match("^%s*(.-)%s*$")
	if raw == "" then return end
	local parts = {}
	for w in raw:gmatch("%S+") do table.insert(parts, w) end
	local cmd  = parts[1] and parts[1]:lower() or ""
	local args = {}
	for i = 2, #parts do table.insert(args, parts[i]) end

	-- FIX #4: ignore if accidentally routed a server command here
	if cmd:sub(1,1) == SERVER_PREFIX then return end

	if cmd == "ws" or cmd == "walkspeed" then
		State.ws = tonumber(args[1]) or 16
		local h = LP.Character and LP.Character:FindFirstChild("Humanoid")
		if h then h.WalkSpeed = State.ws end
		notify("WalkSpeed", "? " .. State.ws)
	elseif cmd == "jp" or cmd == "jumppower" then
		State.jp = tonumber(args[1]) or 50
		local h = LP.Character and LP.Character:FindFirstChild("Humanoid")
		if h then h.JumpPower = State.jp end
		notify("JumpPower", "? " .. State.jp)
	elseif cmd == "hh" or cmd == "hipheight" then
		State.hh = tonumber(args[1]) or 2
		local h = LP.Character and LP.Character:FindFirstChild("Humanoid")
		if h then h.HipHeight = State.hh end
		notify("HipHeight", "? " .. State.hh)
	elseif cmd == "fov" then
		State.fov = math.clamp(tonumber(args[1]) or 70, 30, 120)
		Cam.FieldOfView = State.fov
		notify("FOV", "? " .. State.fov)
	elseif cmd == "default" then
		State.ws = 16; State.jp = 50; State.hh = 2; State.fov = 70
		applyMovement()
		notify("Default", "Movement values reset.")
	elseif cmd == "fly" then
		startFly()
		notify("Fly", "Enabled � WASD + Space/Ctrl")
	elseif cmd == "unfly" then
		stopFly()
		notify("Fly", "Disabled.")
	elseif cmd == "noclip" then
		State.noclip = true
		notify("Noclip", "Enabled � ;clip to stop")
	elseif cmd == "clip" then
		State.noclip = false
		notify("Noclip", "Disabled.")
	elseif cmd == "tppos" then
		local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
		if x and y and z and HRP then
			HRP.CFrame = CFrame.new(x, y, z)
			notify("TpPos", x..","..y..","..z)
		else
			notify("TpPos", "Usage: tppos x y z")
		end
	elseif cmd == "goto" then
		local t = resolvePlayers(LP, args[1])
		if #t > 0 and t[1].Character then
			local h2 = t[1].Character:FindFirstChild("HumanoidRootPart")
			if h2 and HRP then HRP.CFrame = h2.CFrame + Vector3.new(0,4,0); notify("Goto","? "..t[1].Name) end
		else notify("Goto","Player not found.") end
	elseif cmd == "savepos" then
		if HRP then SavedPos = HRP.CFrame; notify("SavePos","Saved.") end
	elseif cmd == "loadpos" then
		if SavedPos and HRP then HRP.CFrame = SavedPos; notify("LoadPos","Restored.")
		else notify("LoadPos","No saved position.") end
	elseif cmd == "god" then
		enableGod(); notify("God","ON")
	elseif cmd == "ungod" then
		disableGod(); notify("God","OFF")
	elseif cmd == "heal" then
		local t = #args > 0 and resolvePlayers(LP, args[1]) or {LP}
		for _, p in ipairs(t) do
			local h = p.Character and p.Character:FindFirstChild("Humanoid")
			if h then h.Health = h.MaxHealth end
		end
		notify("Heal","Healed "..#t.." target(s).")
	elseif cmd == "kill" then
		local t = #args > 0 and resolvePlayers(LP, args[1]) or {LP}
		for _, p in ipairs(t) do
			local h = p.Character and p.Character:FindFirstChild("Humanoid")
			if h then h.Health = 0 end
		end
		notify("Kill","Killed "..#t.." target(s).")
	elseif cmd == "respawn" then
		LP:LoadCharacter(); notify("Respawn","Respawning...")
	elseif cmd == "refresh" then
		local cf = HRP and HRP.CFrame
		LP:LoadCharacter()
		if cf then
			LP.CharacterAdded:Wait()
			task.wait(0.2)
			local nh = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
			if nh then nh.CFrame = cf end
		end
		notify("Refresh","Done.")
	elseif cmd == "sit" then
		local h = LP.Character and LP.Character:FindFirstChild("Humanoid")
		if h then h.Sit = true end
		notify("Sit","Sitting.")
	elseif cmd == "invis" then
		State.invis = true
		if LP.Character then
			for _, p in ipairs(LP.Character:GetDescendants()) do
				if p:IsA("BasePart") or p:IsA("Decal") then p.Transparency = 1 end
			end
		end
		notify("Invis","Invisible (local).")
	elseif cmd == "vis" then
		State.invis = false
		if LP.Character then
			for _, p in ipairs(LP.Character:GetDescendants()) do
				if p:IsA("BasePart") then
					p.Transparency = p.Name == "HumanoidRootPart" and 1 or 0
				elseif p:IsA("Decal") then
					p.Transparency = 0
				end
			end
		end
		notify("Vis","Visible.")
	elseif cmd == "esp" then
		enableESP(); notify("ESP","Highlights + info ON.")
	elseif cmd == "unesp" then
		disableESP(); notify("ESP","OFF.")
	elseif cmd == "freecam" then
		startFreecam(); notify("Freecam","ON � WASD+Space/Ctrl")
	elseif cmd == "unfreecam" then
		stopFreecam(); notify("Freecam","OFF.")
	elseif cmd == "view" then
		local t = resolvePlayers(LP, args[1])
		if #t > 0 and t[1].Character then
			local h = t[1].Character:FindFirstChild("Humanoid")
			if h then Cam.CameraSubject = h; notify("View","Spectating "..t[1].Name) end
		else notify("View","Player not found.") end
	elseif cmd == "unview" then
		local h = LP.Character and LP.Character:FindFirstChild("Humanoid")
		if h then Cam.CameraSubject = h end
		notify("Unview","Camera restored.")
	elseif cmd == "fullbright" then
		Lighting.Brightness = 10; Lighting.ClockTime = 14
		Lighting.FogEnd = 1e6; Lighting.GlobalShadows = false
		Lighting.Ambient = Color3.fromRGB(255,255,255)
		notify("Fullbright","ON.")
	elseif cmd == "unfullbright" then
		Lighting.Brightness = 1; Lighting.ClockTime = 14
		Lighting.GlobalShadows = true
		Lighting.Ambient = Color3.fromRGB(127,127,127)
		Lighting.FogEnd = 1e6
		notify("Fullbright","OFF.")
	elseif cmd == "rejoin" then
		notify("Rejoin","Rejoining...",2)
		task.delay(1, function() TeleportService:Teleport(game.PlaceId, LP) end)
	elseif cmd == "serverhop" then
		serverHop()
	elseif cmd == "antiafk" then
		enableAntiAfk()
	elseif cmd == "players" then
		local lst = {}
		for _, p in ipairs(Players:GetPlayers()) do
			local tag = isOwner(p.Name) and " [Owner]" or isAdmin(p.Name) and " [Admin]" or ""
			table.insert(lst, p.Name..tag)
		end
		notify("Players ("..#lst..")", table.concat(lst,", "), 7)
	elseif cmd == "copyname" then
		local t = resolvePlayers(LP, args[1])
		if #t > 0 then
			pcall(setclipboard, t[1].Name)
			notify("CopyName", t[1].Name.." copied!")
		else notify("CopyName","Not found.") end
	elseif cmd == "ping" then
		local ok, v = pcall(function()
			return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
		end)
		notify("Ping", ok and (math.floor(v).." ms") or "N/A")
	elseif cmd == "fps" then
		-- FIX #5: non-blocking FPS measure
		task.spawn(function()
			local frames, start = 0, tick()
			for _ = 1, 10 do
				RunService.Heartbeat:Wait()
				frames += 1
			end
			notify("FPS", math.floor(frames / (tick()-start)).." fps")
		end)
	elseif cmd == "pos" then
		if HRP then
			local p = HRP.Position
			notify("Position",("X:%.1f  Y:%.1f  Z:%.1f"):format(p.X,p.Y,p.Z))
		end
	elseif cmd == "notify" then
		local j = table.concat(args," ")
		local t2, b2 = j:match("^(.-)%s*|%s*(.+)$")
		if t2 then notify(t2,b2,6) else notify("Notify",j,5) end
	elseif cmd == "cmds" then
		buildPanel(""); PSrch.Text = ""; Panel.Visible = true
	elseif cmd == "hide" then
		BarHolder.Visible = false
		notify("IronAdmin","Bar hidden. ;show to restore.",4)
	elseif cmd == "show" then
		BarHolder.Visible = true
		notify("IronAdmin","Bar shown.")
	elseif cmd == "prefix" then
		-- FIX #3: update CLIENT_PREFIX_LABEL used by chat hook too
		if args[1] and #args[1] == 1 then
			CLIENT_PREFIX_LABEL = args[1]
			PrefixLbl.Text = args[1]
			notify("Prefix","Changed to: "..args[1])
		else notify("Prefix","Usage: prefix <char>") end
	elseif cmd == "unload" then
		notify("IronAdmin","Unloading...",2)
		task.delay(0.5, function()
			for _, c in pairs(Connections) do pcall(function() c:Disconnect() end) end
			disableESP(); stopFly(); stopFreecam()
			GUI:Destroy()
		end)
	else
		notify("Unknown", cmd.." � type ;cmds for list", 3)
	end
end

-- ----------------------------------------
-- SERVER COMMAND EXECUTOR
-- ----------------------------------------
local serverLocked = false
local playerLockConn

local function execServer(plr, raw)
	raw = raw:match("^%s*(.-)%s*$")
	if raw == "" then return end
	if not isAdmin(plr.Name) then
		sendToast("No permission.", {plr}, 3, "error"); return
	end
	if not checkRateLimit(plr.Name) then
		sendToast("Rate limit � slow down.", {plr}, 3, "warning"); return
	end
	local parts = {}
	for w in raw:gmatch("%S+") do table.insert(parts, w) end
	local cmd  = parts[1] and parts[1]:lower() or ""
	local args = {}
	for i = 2, #parts do table.insert(args, parts[i]) end

	table.insert(commandLogs, {player=plr.Name, cmd=cmd, args=args, time=os.date("%H:%M:%S")})
	if #commandLogs > 200 then table.remove(commandLogs,1) end

	local me  = {plr}
	local all = Players:GetPlayers()

	if cmd == "kick" then
		if #args < 1 then sendToast("!kick <player> [reason]",me,3,"error"); return end
		local reason = table.concat(args," ",2); if reason=="" then reason="Kicked by "..plr.Name end
		for _, t in ipairs(resolvePlayers(plr,args[1])) do
			if not isOwner(t.Name) then t:Kick(reason); sendToast("Kicked "..t.Name,me,3,"success")
			else sendToast("Cannot kick owner.",me,3,"warning") end
		end
	elseif cmd == "ban" then
		if #args < 1 then sendToast("!ban <player> [reason]",me,3,"error"); return end
		local reason = table.concat(args," ",2); if reason=="" then reason="Banned by "..plr.Name end
		for _, t in ipairs(resolvePlayers(plr,args[1])) do
			if not isOwner(t.Name) then
				table.insert(bannedPlayers,t.Name)
				t:Kick("Banned: "..reason)
				sendToast("Banned "..t.Name,me,3,"success")
			end
		end
	elseif cmd == "unban" then
		if #args < 1 then sendToast("!unban <player>",me,3,"error"); return end
		local low = args[1]:lower()
		for i, n in ipairs(bannedPlayers) do
			if n:lower() == low then table.remove(bannedPlayers,i); sendToast("Unbanned "..args[1],me,3,"success"); return end
		end
		sendToast("Not in ban list.",me,3,"warning")
	elseif cmd == "mute" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			if not isOwner(t.Name) then
				table.insert(mutedPlayers,t.Name)
				sendHint("You've been muted by "..plr.Name,{t},5)
				sendToast("Muted "..t.Name,me,3,"success")
			end
		end
	elseif cmd == "unmute" then
		local low = (args[1] or ""):lower()
		for i, n in ipairs(mutedPlayers) do
			if n:lower() == low then table.remove(mutedPlayers,i); sendToast("Unmuted "..args[1],me,3,"success"); return end
		end
		sendToast("Not muted.",me,3,"warning")
	elseif cmd == "warn" then
		if #args < 1 then sendToast("!warn <player> [reason]",me,3,"error"); return end
		local reason = table.concat(args," ",2); if reason=="" then reason="No reason" end
		for _, t in ipairs(resolvePlayers(plr,args[1])) do
			warnings[t.Name] = (warnings[t.Name] or 0) + 1
			sendAlert("WARNING","Warned by "..plr.Name.."\nReason: "..reason.."\nWarnings: "..warnings[t.Name].."/3",{t},"warning")
			sendToast("Warned "..t.Name.." ("..warnings[t.Name].."/3)",me,3,"warning")
			if warnings[t.Name] >= 3 then t:Kick("3 warnings reached."); warnings[t.Name]=nil end
		end
	elseif cmd == "warnings" then
		local s = "Warnings:\n"
		for n, c in pairs(warnings) do s = s..n..": "..c.."/3\n" end
		sendMessage("Warnings",s,me,8)
	elseif cmd == "clearwarns" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			warnings[t.Name] = nil; sendToast("Cleared warns for "..t.Name,me,3,"success")
		end
	elseif cmd == "freeze" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "all")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetChildren()) do
					if p:IsA("BasePart") then p.Anchored = true end
				end
				sendToast("Frozen "..t.Name,me,3,"success")
			end
		end
	elseif cmd == "thaw" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "all")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetChildren()) do
					if p:IsA("BasePart") then p.Anchored = false end
				end
				sendToast("Thawed "..t.Name,me,3,"success")
			end
		end
	elseif cmd == "jail" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			if t.Character and t.Character:FindFirstChild("HumanoidRootPart") then
				local pos = t.Character.HumanoidRootPart.Position
				local cage = Instance.new("Part")
				cage.Name        = "IronJail_"..t.Name
				cage.Size        = Vector3.new(10,10,10)
				cage.Position    = pos + Vector3.new(0,5,0)
				cage.Anchored    = true
				cage.CanCollide  = true
				cage.Transparency = 0.5
				cage.BrickColor  = BrickColor.new("Bright blue")
				cage.Parent      = workspace
				t.Character.HumanoidRootPart.CFrame = CFrame.new(pos + Vector3.new(0,5,0))
				sendToast("Jailed "..t.Name,me,3,"success")
			end
		end
	elseif cmd == "unjail" then
		for _, o in ipairs(workspace:GetChildren()) do
			if o.Name:find("IronJail_") then o:Destroy() end
		end
		sendToast("All jails removed.",me,3,"success")
	elseif cmd == "promote" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			if not isAdmin(t.Name) then
				table.insert(admins,t.Name)
				sendMessage("Promoted","You are now Admin! Given by "..plr.Name,{t},5,"success")
				sendToast("Promoted "..t.Name,me,3,"success")
			end
		end
	elseif cmd == "demote" then
		local low = (args[1] or ""):lower()
		for i, n in ipairs(admins) do
			if n:lower() == low then table.remove(admins,i); sendToast("Demoted "..args[1],me,3,"success"); return end
		end
		sendToast("Not in admin list.",me,3,"warning")
	elseif cmd == "tempadmin" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			if not isAdmin(t.Name) then table.insert(tempAdmins,t.Name); sendToast("TempAdmin ? "..t.Name,me,3,"success") end
		end
	elseif cmd == "mod" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			if not isMod(t.Name) then table.insert(mods,t.Name); sendToast("Made "..t.Name.." mod",me,3,"success") end
		end
	elseif cmd == "unmod" then
		local low = (args[1] or ""):lower()
		for i, n in ipairs(mods) do
			if n:lower() == low then table.remove(mods,i); sendToast("Unmodded "..args[1],me,3,"success"); return end
		end
		sendToast("Not in mod list.",me,3,"warning")
	elseif cmd == "servertp" then
		if #args < 2 then sendToast("!servertp <p1> <p2>",me,3,"error"); return end
		local src = resolvePlayers(plr,args[1])
		local dst = resolvePlayers(plr,args[2])[1]
		if not dst or not dst.Character then sendToast("Destination not found.",me,3,"error"); return end
		local dh = dst.Character:FindFirstChild("HumanoidRootPart")
		for _, t in ipairs(src) do
			if t.Character and t.Character:FindFirstChild("HumanoidRootPart") then
				t.Character.HumanoidRootPart.CFrame = dh.CFrame + Vector3.new(0,3,0)
				sendToast("TP'd "..t.Name.." ? "..dst.Name,me,3,"success")
			end
		end
	elseif cmd == "bringall" then
		if plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") then
			for _, t in ipairs(Players:GetPlayers()) do
				if t ~= plr and t.Character and t.Character:FindFirstChild("HumanoidRootPart") then
					t.Character.HumanoidRootPart.CFrame = plr.Character.HumanoidRootPart.CFrame
						+ Vector3.new(math.random(-3,3),0,math.random(-3,3))
				end
			end
			sendToast("Brought all players.",me,3,"success")
		end
	elseif cmd == "skysend" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			if t.Character and t.Character:FindFirstChild("HumanoidRootPart") then
				t.Character.HumanoidRootPart.CFrame += Vector3.new(0,600,0)
				sendToast("Sent "..t.Name.." to sky",me,3,"success")
			end
		end
	elseif cmd == "voidkill" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "")) do
			if t.Character and t.Character:FindFirstChild("HumanoidRootPart") then
				t.Character.HumanoidRootPart.CFrame = CFrame.new(0,-1000,0)
			end
		end
		sendToast("Void sent.",me,3,"success")
	elseif cmd == "ff" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then Instance.new("ForceField").Parent = t.Character end
		end
		sendToast("ForceField added.",me,3,"success")
	elseif cmd == "unff" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, f in ipairs(t.Character:GetChildren()) do
					if f:IsA("ForceField") then f:Destroy() end
				end
			end
		end
		sendToast("ForceField removed.",me,3,"success")
	elseif cmd == "serverfly" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local ch = t.Character
			local hr = ch and ch:FindFirstChild("HumanoidRootPart")
			local hm = ch and ch:FindFirstChildOfClass("Humanoid")
			if hr and hm and not hr:FindFirstChild("SrvFlyBV") then
				hm.PlatformStand = true
				local bv = Instance.new("BodyVelocity")
				bv.Name="SrvFlyBV"; bv.MaxForce=Vector3.new(1e5,1e5,1e5); bv.Velocity=Vector3.zero; bv.Parent=hr
				local bg = Instance.new("BodyGyro")
				bg.Name="SrvFlyBG"; bg.MaxTorque=Vector3.new(1e5,1e5,1e5); bg.P=9e4; bg.CFrame=hr.CFrame; bg.Parent=hr
				task.spawn(function()
					while bv.Parent and hm.Health > 0 do
						bg.CFrame = Cam.CFrame
						bv.Velocity = Cam.CFrame.LookVector * 50
						task.wait()
					end
				end)
				sendToast(t.Name.." is flying",me,3,"success")
			end
		end
	elseif cmd == "serverunfly" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local hr = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
			if hr then
				local bv = hr:FindFirstChild("SrvFlyBV"); if bv then bv:Destroy() end
				local bg = hr:FindFirstChild("SrvFlyBG"); if bg then bg:Destroy() end
			end
			local hm = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
			if hm then hm.PlatformStand = false end
		end
		sendToast("Fly removed.",me,3,"success")
	elseif cmd == "spin" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local hr = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
			if hr then
				local bav = Instance.new("BodyAngularVelocity")
				bav.AngularVelocity=Vector3.new(0,20,0); bav.MaxTorque=Vector3.new(0,1e9,0); bav.Parent=hr
			end
		end
		sendToast("Spinning!",me,3,"success")
	elseif cmd == "unspin" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local hr = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
			if hr then
				for _, o in ipairs(hr:GetChildren()) do
					if o:IsA("BodyAngularVelocity") then o:Destroy() end
				end
			end
		end
		sendToast("Stopped spinning.",me,3,"success")
	elseif cmd == "fire" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetChildren()) do
					if p:IsA("BasePart") then Instance.new("Fire").Parent = p end
				end
			end
		end
		sendToast("Fire added.",me,3,"success")
	elseif cmd == "unfire" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetDescendants()) do
					if p:IsA("Fire") then p:Destroy() end
				end
			end
		end
		sendToast("Fire removed.",me,3,"success")
	elseif cmd == "sparkle" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetChildren()) do
					if p:IsA("BasePart") then Instance.new("Sparkles").Parent = p end
				end
			end
		end
		sendToast("Sparkles added.",me,3,"success")
	elseif cmd == "unsparkle" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetDescendants()) do
					if p:IsA("Sparkles") then p:Destroy() end
				end
			end
		end
		sendToast("Sparkles removed.",me,3,"success")
	elseif cmd == "smoke" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetChildren()) do
					if p:IsA("BasePart") then Instance.new("Smoke").Parent = p end
				end
			end
		end
		sendToast("Smoke added.",me,3,"success")
	elseif cmd == "unsmoke" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetDescendants()) do
					if p:IsA("Smoke") then p:Destroy() end
				end
			end
		end
		sendToast("Smoke removed.",me,3,"success")
	elseif cmd == "rocket" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local hr = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
			if hr then
				local bv = Instance.new("BodyVelocity")
				bv.Velocity=Vector3.new(0,120,0); bv.MaxForce=Vector3.new(0,1e9,0); bv.Parent=hr
				Debris:AddItem(bv,0.6)
			end
		end
		sendToast("Launched!",me,3,"success")
	elseif cmd == "explode" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local hr = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
			if hr then
				local ex = Instance.new("Explosion")
				ex.Position=hr.Position; ex.BlastPressure=0; ex.Parent=workspace
			end
		end
		sendToast("Boom!",me,3,"success")
	elseif cmd == "color" then
		if #args < 4 then sendToast("!color <p> <r> <g> <b>",me,3,"error"); return end
		local r,g,b = tonumber(args[2]),tonumber(args[3]),tonumber(args[4])
		if not r then sendToast("Invalid RGB.",me,3,"error"); return end
		local col = Color3.fromRGB(r,g,b)
		for _, t in ipairs(resolvePlayers(plr,args[1])) do
			if t.Character then
				for _, p in ipairs(t.Character:GetChildren()) do
					if p:IsA("BasePart") then p.BrickColor = BrickColor.new(col) end
				end
			end
		end
		sendToast("Colored.",me,3,"success")
	elseif cmd == "rainbow" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				task.spawn(function()
					while t and t.Character and t.Parent do
						for _, p in ipairs(t.Character:GetChildren()) do
							if p:IsA("BasePart") then
								p.BrickColor = BrickColor.new(Color3.fromHSV(tick()%5/5,1,1))
							end
						end
						task.wait(0.1)
					end
				end)
			end
		end
		sendToast("Rainbow!",me,3,"success")
	elseif cmd == "speed" then
		if #args < 2 then sendToast("!speed <p> <n>",me,3,"error"); return end
		local n = tonumber(args[2])
		for _, t in ipairs(resolvePlayers(plr,args[1])) do
			local h = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
			if h then h.WalkSpeed = n end
		end
		sendToast("Speed ? "..tostring(n),me,3,"success")
	elseif cmd == "jump" then
		if #args < 2 then sendToast("!jump <p> <n>",me,3,"error"); return end
		local n = tonumber(args[2])
		for _, t in ipairs(resolvePlayers(plr,args[1])) do
			local h = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
			if h then h.JumpPower = n end
		end
		sendToast("JumpPower ? "..tostring(n),me,3,"success")
	elseif cmd == "serverinvis" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetDescendants()) do
					if p:IsA("BasePart") or p:IsA("Decal") then p.Transparency = 1 end
				end
			end
		end
		sendToast("Invisible.",me,3,"success")
	elseif cmd == "servervis" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			if t.Character then
				for _, p in ipairs(t.Character:GetDescendants()) do
					if p:IsA("BasePart") then
						p.Transparency = p.Name=="HumanoidRootPart" and 1 or 0
					elseif p:IsA("Decal") then
						p.Transparency = 0
					end
				end
			end
		end
		sendToast("Visible.",me,3,"success")
	elseif cmd == "servergod" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local h = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
			if h then h.MaxHealth=math.huge; h.Health=math.huge end
		end
		sendToast("God ON.",me,3,"success")
	elseif cmd == "serverungod" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local h = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
			if h then h.MaxHealth=100; h.Health=100 end
		end
		sendToast("God OFF.",me,3,"success")
	elseif cmd == "serverheal" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local h = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
			if h then h.Health = h.MaxHealth end
		end
		sendToast("Healed.",me,3,"success")
	elseif cmd == "serverkill" then
		for _, t in ipairs(resolvePlayers(plr,args[1] or "me")) do
			local h = t.Character and t.Character:FindFirstChildOfClass("Humanoid")
			if h then h.Health = 0 end
		end
		sendToast("Killed.",me,3,"success")
	elseif cmd == "message" then
		if #args < 1 then sendToast("!message <text>",me,3,"error"); return end
		sendMessage("From "..plr.Name, table.concat(args," "), all, 8, "info")
		sendToast("Message sent.",me,3,"success")
	elseif cmd == "hint" then
		if #args < 1 then sendToast("!hint <text>",me,3,"error"); return end
		sendHint(table.concat(args," "), all, 5)
		sendToast("Hint sent.",me,3,"success")
	elseif cmd == "announce" then
		if #args < 1 then sendToast("!announce <text>",me,3,"error"); return end
		sendMessage("ANNOUNCEMENT", table.concat(args," "), all, 12, "warning")
		sendToast("Announced.",me,3,"success")
	elseif cmd == "alert" then
		if #args < 1 then sendToast("!alert <text>",me,3,"error"); return end
		sendAlert("ALERT", table.concat(args," "), all, "error")
		sendToast("Alert sent.",me,3,"success")
	elseif cmd == "time" then
		local h = tonumber(args[1])
		if h and h>=0 and h<=24 then Lighting.ClockTime=h; sendToast("Time ? "..h..":00",me,3,"success")
		else sendToast("0�24 only.",me,3,"error") end
	elseif cmd == "gravity" then
		local g = tonumber(args[1])
		if g then workspace.Gravity=g; sendToast("Gravity ? "..g,me,3,"success")
		else sendToast("Invalid.",me,3,"error") end
	elseif cmd == "nogravity" then
		workspace.Gravity = 0; sendToast("Gravity OFF.",me,3,"success")
	elseif cmd == "normalgravity" then
		workspace.Gravity = 196.2; sendToast("Gravity reset.",me,3,"success")
	elseif cmd == "fog" then
		local d = tonumber(args[1])
		if d then Lighting.FogEnd=d; sendToast("Fog ? "..d,me,3,"success")
		else sendToast("Invalid.",me,3,"error") end
	elseif cmd == "nofog" then
		Lighting.FogEnd=1e6; sendToast("Fog removed.",me,3,"success")
	elseif cmd == "brightness" then
		local b = tonumber(args[1])
		if b then Lighting.Brightness=b; sendToast("Brightness ? "..b,me,3,"success")
		else sendToast("Invalid.",me,3,"error") end
	elseif cmd == "weather" then
		local wt = {clear={fe=1e6,br=1},rain={fe=500,br=0.7},storm={fe=300,br=0.5},snow={fe=800,br=0.9},fog={fe=100,br=0.8}}
		local w = wt[args[1] and args[1]:lower() or ""]
		if w then
			Lighting.FogEnd=w.fe; Lighting.Brightness=w.br
			sendToast("Weather: "..(args[1] or ""):upper(),me,3,"success")
		else sendToast("Types: clear rain storm snow fog",me,3,"error") end
	elseif cmd == "clear" then
		local n = 0
		for _, o in ipairs(workspace:GetChildren()) do
			if not o:IsA("Terrain") and not o:IsA("Camera") and o~=LP.Character then
				o:Destroy(); n+=1
			end
		end
		sendToast("Cleared "..n.." objects.",me,3,"success")
	elseif cmd == "music" then
		if not args[1] then sendToast("!music <id|stop>",me,3,"error"); return end
		if args[1]:lower()=="stop" then
			for _, s in ipairs(workspace:GetDescendants()) do
				if s:IsA("Sound") and s.Name=="IronMusic" then s:Stop(); s:Destroy() end
			end
			sendToast("Music stopped.",me,3,"success")
		else
			local id = tonumber(args[1])
			if not id then sendToast("Invalid ID.",me,3,"error"); return end
			for _, s in ipairs(workspace:GetDescendants()) do
				if s:IsA("Sound") and s.Name=="IronMusic" then s:Stop(); s:Destroy() end
			end
			local snd = Instance.new("Sound")
			snd.Name="IronMusic"; snd.SoundId="rbxassetid://"..id
			snd.Volume=0.5; snd.Looped=true; snd.Parent=workspace
			snd:Play()
			sendToast("Playing "..id,me,3,"success")
		end
	elseif cmd == "volume" then
		local v = tonumber(args[1])
		if v then
			for _, s in ipairs(workspace:GetDescendants()) do
				if s:IsA("Sound") and s.Name=="IronMusic" then s.Volume=v end
			end
			sendToast("Volume ? "..v,me,3,"success")
		end
	elseif cmd == "pause" then
		for _, s in ipairs(workspace:GetDescendants()) do
			if s:IsA("Sound") and s.Name=="IronMusic" then s:Pause() end
		end
		sendToast("Paused.",me,3,"success")
	elseif cmd == "resume" then
		for _, s in ipairs(workspace:GetDescendants()) do
			if s:IsA("Sound") and s.Name=="IronMusic" then s:Play() end
		end
		sendToast("Resumed.",me,3,"success")
	elseif cmd == "stopmusic" then
		for _, s in ipairs(workspace:GetDescendants()) do
			if s:IsA("Sound") and s.Name=="IronMusic" then s:Stop(); s:Destroy() end
		end
		sendToast("Music stopped.",me,3,"success")
	elseif cmd == "musiclist" then
		sendMessage("Music IDs",
			"142376088 - Megalovania\n27697743 - Never Gonna Give You Up\n"..
				"184793429 - Wii Theme\n91163979 - Tokyo Drift\n45987644 - Nyan Cat\n"..
				"32957590 - Giorno's Theme\n184792875 - Mario Bros\n"..
				"Usage: !music <id>  �  !music stop", me, 15)
	elseif cmd == "info" then
		sendMessage("Server Info",
			"Game: "..game.Name.."\nPlaceID: "..game.PlaceId..
				"\nPlayers: "..Players.NumPlayers.."/"..Players.MaxPlayers..
				"\nGravity: "..workspace.Gravity..
				"\nTime: "..os.date("%H:%M:%S"), me, 10)
	elseif cmd == "statsplr" then
		local t = resolvePlayers(plr,args[1] or "me")[1]
		if t and t.Character then
			local h = t.Character:FindFirstChildOfClass("Humanoid")
			sendMessage("Stats: "..t.Name,
				"UID: "..t.UserId.."\nAge: "..t.AccountAge.." days\n"..
					(h and "HP: "..math.floor(h.Health).."/"..math.floor(h.MaxHealth)..
						"\nSpeed: "..h.WalkSpeed.."\nJump: "..h.JumpPower or ""), me, 8)
		end
	elseif cmd == "admins" then
		sendMessage("Admins",
			"Owners: "..table.concat(owners,", ")..
				"\nAdmins: "..table.concat(admins,", ")..
				"\nTemp: "..table.concat(tempAdmins,", ")..
				"\nMods: "..table.concat(mods,", "), me, 10)
	elseif cmd == "bans" then
		sendMessage("Bans", #bannedPlayers>0 and table.concat(bannedPlayers,"\n") or "No bans.", me, 8)
	elseif cmd == "logs" then
		local s = ""
		for i = math.max(1,#commandLogs-9), #commandLogs do
			local l = commandLogs[i]
			s = s.."["..l.time.."] "..l.player..": !"..l.cmd.." "..table.concat(l.args," ").."\n"
		end
		sendMessage("Logs", s=="" and "No logs." or s, me, 15)
	elseif cmd == "serverping" then
		local t = resolvePlayers(plr,args[1] or "me")[1]
		if t then
			local ok, v = pcall(function() return math.floor(t:GetNetworkPing()*1000) end)
			sendToast(t.Name.." ping: "..(ok and v or "?").."ms", me, 4, "info")
		end
	elseif cmd == "shutdown" then
		sendAlert("SHUTDOWN","Server shutting down in 5 seconds!\nBy: "..plr.Name, all, "error")
		task.delay(5, function()
			for _, p in ipairs(Players:GetPlayers()) do p:Kick("Server shutdown by "..plr.Name) end
		end)
	elseif cmd == "lock" then
		serverLocked = true
		if playerLockConn then playerLockConn:Disconnect() end
		playerLockConn = Players.PlayerAdded:Connect(function(np)
			if serverLocked then np:Kick("Server is locked.") end
		end)
		sendHint("Server locked by "..plr.Name, all, 5)
		sendToast("Server locked.",me,3,"success")
	elseif cmd == "party" then
		for _ = 1, 50 do
			local p = Instance.new("Part")
			p.Size        = Vector3.new(2,2,2)
			p.Position    = Vector3.new(math.random(-50,50),math.random(10,50),math.random(-50,50))
			p.BrickColor  = BrickColor.Random()
			p.Anchored    = false
			p.Parent      = workspace
			Debris:AddItem(p,30)
		end
		sendToast("Party time! ??",me,3,"success")
	else
		sendToast("Unknown: !"..cmd, me, 3, "warning")
	end
end

-- ----------------------------------------
-- FIX #3: CHAT HOOK � use current CLIENT_PREFIX_LABEL at call time
-- ----------------------------------------
LP.Chatted:Connect(function(msg)
	msg = msg:match("^%s*(.-)%s*$")
	if msg == "" then return end

	if msg:sub(1, #SERVER_PREFIX) == SERVER_PREFIX then
		if isMuted(LP.Name) then notify("Muted","You are muted."); return end
		execServer(LP, msg:sub(#SERVER_PREFIX + 1))
	elseif msg:sub(1, #CLIENT_PREFIX_LABEL) == CLIENT_PREFIX_LABEL then
		-- CLIENT_PREFIX_LABEL is read fresh each time, so ;prefix changes work
		execClient(msg:sub(#CLIENT_PREFIX_LABEL + 1))
	end
end)

-- Command bar enter
CmdBox.FocusLost:Connect(function(enter)
	if not enter then return end
	local txt = CmdBox.Text:match("^%s*(.-)%s*$")
	CmdBox.Text = ""
	setBarOpen(false)
	AcDrop.Size = UDim2.new(1, 0, 0, 0)
	if txt == "" then return end
	if txt:sub(1,1) == SERVER_PREFIX then
		execServer(LP, txt:sub(2))
	else
		execClient(txt)
	end
end)

-- ----------------------------------------
-- STARTUP
-- ----------------------------------------
applyMovement()
buildPanel("")
notify("IronAdmin v1", "Loaded!  RightShift = bar  |  ;cmds = panel  |  !cmd = server", 6)

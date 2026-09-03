--[[
	Animal Hospital - Stage 4: the shift HUD and the results screen.

	LocalScript. Draws the sanity bar, the shift clock and the score, and puts
	up the end-of-shift screen with a "Заново" button. It decides nothing:
	every number comes from ShiftState on the server, and the button only asks
	(ShiftRestart) - the server starts the new shift.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named "ShiftHud"
		-> paste this file in.

	The clock ticks down locally between server updates so it reads smoothly;
	every ShiftUpdate (about four a second) snaps it back to the server's
	value, so the display can drift by at most a quarter second and never
	disagrees with the actual end of the shift.

	The results screen needs a real cursor, which first person deliberately
	takes away. It sets the "UiFocus" attribute on the LocalPlayer while it is
	up; FirstPersonCamera watches that attribute and releases the mouse. Enter
	and R do the same thing as the button, for anyone who would rather not
	reach for the mouse at all.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("AnimalHospital")
local ShiftStarted = remotes:WaitForChild("ShiftStarted")
local ShiftUpdate = remotes:WaitForChild("ShiftUpdate")
local ShiftEnded = remotes:WaitForChild("ShiftEnded")
local ShiftRestart = remotes:WaitForChild("ShiftRestart")

local UI_FOCUS_ATTRIBUTE = "UiFocus"

local COLORS = {
	panel = Color3.fromRGB(24, 26, 30),
	track = Color3.fromRGB(46, 49, 56),
	text = Color3.fromRGB(235, 237, 240),
	muted = Color3.fromRGB(150, 155, 163),
	good = Color3.fromRGB(96, 196, 128),
	warn = Color3.fromRGB(224, 180, 96),
	bad = Color3.fromRGB(214, 96, 96),
	accent = Color3.fromRGB(92, 140, 214),
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local shift = {
	running = false,
	sanity = 100,
	maxSanity = 100,
	score = 0,
	timeLeft = 0,
	draining = false,
}

--------------------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------------------

local function corner(parent, radius)
	local instance = Instance.new("UICorner")
	instance.CornerRadius = UDim.new(0, radius or 8)
	instance.Parent = parent
	return instance
end

local function label(parent, text, size, position, font, textSize, color)
	local instance = Instance.new("TextLabel")
	instance.Size = size
	instance.Position = position
	instance.BackgroundTransparency = 1
	instance.Font = font or Enum.Font.Gotham
	instance.TextSize = textSize or 14
	instance.TextColor3 = color or COLORS.text
	instance.TextXAlignment = Enum.TextXAlignment.Left
	instance.Text = text
	instance.Parent = parent
	return instance
end

--------------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------------

local screen = Instance.new("ScreenGui")
screen.Name = "ShiftUI"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 5
screen.Parent = player:WaitForChild("PlayerGui")

local hud = Instance.new("Frame")
hud.Name = "Hud"
hud.Size = UDim2.fromOffset(286, 92)
hud.Position = UDim2.fromOffset(18, 18)
hud.BackgroundColor3 = COLORS.panel
hud.BackgroundTransparency = 0.1
hud.BorderSizePixel = 0
hud.Visible = false
hud.Parent = screen
corner(hud, 10)

label(hud, "РАССУДОК", UDim2.new(0, 120, 0, 16), UDim2.fromOffset(14, 10), Enum.Font.GothamBold, 12, COLORS.muted)
local sanityValue = label(hud, "100", UDim2.new(0, 80, 0, 16), UDim2.fromOffset(192, 10), Enum.Font.GothamBold, 12)
sanityValue.TextXAlignment = Enum.TextXAlignment.Right

local track = Instance.new("Frame")
track.Size = UDim2.fromOffset(258, 12)
track.Position = UDim2.fromOffset(14, 30)
track.BackgroundColor3 = COLORS.track
track.BorderSizePixel = 0
track.Parent = hud
corner(track, 6)

local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(1, 1)
fill.BackgroundColor3 = COLORS.good
fill.BorderSizePixel = 0
fill.Parent = track
corner(fill, 6)

local timeLabel = label(hud, "5:00", UDim2.new(0, 120, 0, 22), UDim2.fromOffset(14, 50), Enum.Font.GothamBold, 20)
local scoreLabel = label(hud, "Очки: 0", UDim2.new(0, 120, 0, 22), UDim2.fromOffset(152, 52), Enum.Font.Gotham, 14, COLORS.muted)
scoreLabel.TextXAlignment = Enum.TextXAlignment.Right

local drainLabel =
	label(hud, "", UDim2.new(1, -28, 0, 14), UDim2.fromOffset(14, 74), Enum.Font.Gotham, 12, COLORS.bad)

--------------------------------------------------------------------------------
-- Results screen
--------------------------------------------------------------------------------

local results = Instance.new("Frame")
results.Name = "Results"
results.Size = UDim2.fromScale(1, 1)
results.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
results.BackgroundTransparency = 0.35
results.BorderSizePixel = 0
results.Visible = false
results.Parent = screen

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(420, 468)
panel.Position = UDim2.new(0.5, -210, 0.5, -234)
panel.BackgroundColor3 = COLORS.panel
panel.BorderSizePixel = 0
panel.Parent = results
corner(panel, 14)

local resultTitle = label(panel, "", UDim2.new(1, -40, 0, 30), UDim2.fromOffset(20, 24), Enum.Font.GothamBold, 24)
resultTitle.TextXAlignment = Enum.TextXAlignment.Center

local resultSubtitle =
	label(panel, "", UDim2.new(1, -40, 0, 20), UDim2.fromOffset(20, 58), Enum.Font.Gotham, 14, COLORS.muted)
resultSubtitle.TextXAlignment = Enum.TextXAlignment.Center

-- One row per statistic, laid out top to bottom. Built once and refilled, so
-- the panel never has to be rebuilt between shifts.
local ROWS = {
	{ key = "score", title = "Очки" },
	{ key = "correct", title = "Верных решений" },
	{ key = "wrong", title = "Ошибок" },
	{ key = "timeouts", title = "Ушли без решения" },
	{ key = "admitted", title = "Впущено" },
	{ key = "rejected", title = "Отклонено" },
	{ key = "cured", title = "Вылечено" },
	{ key = "died", title = "Потеряно" },
	{ key = "incidents", title = "Аномалий в палате" },
	{ key = "coffee", title = "Выпито кофе" },
	{ key = "sanity", title = "Рассудок в конце" },
}

local rowValues = {}
for index, row in ipairs(ROWS) do
	local y = 96 + (index - 1) * 24
	label(panel, row.title, UDim2.new(0, 240, 0, 20), UDim2.fromOffset(28, y), Enum.Font.Gotham, 14, COLORS.muted)
	local value = label(panel, "0", UDim2.new(0, 120, 0, 20), UDim2.fromOffset(272, y), Enum.Font.GothamBold, 14)
	value.TextXAlignment = Enum.TextXAlignment.Right
	rowValues[row.key] = value
end

local restartButton = Instance.new("TextButton")
restartButton.Size = UDim2.fromOffset(220, 44)
restartButton.Position = UDim2.new(0.5, -110, 1, -76)
restartButton.BackgroundColor3 = COLORS.accent
restartButton.BorderSizePixel = 0
restartButton.Font = Enum.Font.GothamBold
restartButton.TextSize = 16
restartButton.TextColor3 = COLORS.text
restartButton.Text = "Заново"
restartButton.AutoButtonColor = true
restartButton.Parent = panel
corner(restartButton, 10)

local hintRestart = label(
	panel,
	"или Enter / R",
	UDim2.new(1, -40, 0, 16),
	UDim2.fromOffset(20, 440),
	Enum.Font.Gotham,
	12,
	COLORS.muted
)
hintRestart.TextXAlignment = Enum.TextXAlignment.Center

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

local function formatClock(seconds)
	local whole = math.max(0, math.floor(seconds))
	return ("%d:%02d"):format(math.floor(whole / 60), whole % 60)
end

local function sanityColor(fraction)
	if fraction > 0.5 then
		return COLORS.good
	elseif fraction > 0.25 then
		return COLORS.warn
	end
	return COLORS.bad
end

local function renderHud()
	local fraction = shift.maxSanity > 0 and math.clamp(shift.sanity / shift.maxSanity, 0, 1) or 0
	fill.Size = UDim2.fromScale(fraction, 1)
	fill.BackgroundColor3 = sanityColor(fraction)
	sanityValue.Text = ("%d"):format(math.floor(shift.sanity + 0.5))
	sanityValue.TextColor3 = sanityColor(fraction)
	timeLabel.Text = formatClock(shift.timeLeft)
	scoreLabel.Text = ("Очки: %d"):format(shift.score)
	drainLabel.Text = shift.draining and "Пациент ждёт решения: -1 рассудка в секунду" or ""
end

local function setUiFocus(focused)
	player:SetAttribute(UI_FOCUS_ATTRIBUTE, focused)
end

local function hideResults()
	if not results.Visible then
		return
	end
	results.Visible = false
	setUiFocus(false)
end

local function showResults(result)
	resultTitle.Text = result.outcome == "win" and "СМЕНА ОТРАБОТАНА" or "СМЕНА ПРОВАЛЕНА"
	resultTitle.TextColor3 = result.outcome == "win" and COLORS.good or COLORS.bad
	resultSubtitle.Text = result.outcome == "win"
			and ("Вы продержались все %s."):format(formatClock(result.shiftSeconds))
		or ("Рассудок кончился на %s смены."):format(formatClock(result.survived))

	local stats = result.stats or {}
	for key, value in pairs(rowValues) do
		if key == "score" then
			value.Text = tostring(result.score or 0)
		elseif key == "sanity" then
			value.Text = ("%d / %d"):format(math.floor((result.sanity or 0) + 0.5), result.maxSanity or 100)
		else
			value.Text = tostring(stats[key] or 0)
		end
	end

	results.Visible = true
	setUiFocus(true)
end

local function requestRestart()
	if not results.Visible then
		return
	end
	-- Hide immediately so a second press cannot queue a second shift; the
	-- server ignores restarts while a shift is running anyway, but the screen
	-- should not sit there looking unpressed.
	hideResults()
	ShiftRestart:FireServer()
end

restartButton.MouseButton1Click:Connect(requestRestart)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not results.Visible then
		return
	end
	if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.R then
		requestRestart()
	end
end)

-- Between server updates the clock keeps running locally, so it does not tick
-- in visible quarter-second jumps.
RunService.Heartbeat:Connect(function(dt)
	if shift.running and shift.timeLeft > 0 then
		shift.timeLeft = math.max(0, shift.timeLeft - dt)
		timeLabel.Text = formatClock(shift.timeLeft)
	end
end)

--------------------------------------------------------------------------------
-- Server events
--------------------------------------------------------------------------------

local function applySnapshot(snapshot)
	shift.running = snapshot.running
	shift.sanity = snapshot.sanity
	shift.maxSanity = snapshot.maxSanity
	shift.score = snapshot.score
	shift.timeLeft = snapshot.timeLeft
	shift.draining = snapshot.draining == true
	hud.Visible = true
	renderHud()
end

ShiftStarted.OnClientEvent:Connect(function(snapshot)
	hideResults()
	applySnapshot(snapshot)
end)

ShiftUpdate.OnClientEvent:Connect(applySnapshot)

ShiftEnded.OnClientEvent:Connect(function(result)
	shift.running = false
	shift.timeLeft = 0
	shift.sanity = result.sanity
	shift.score = result.score
	shift.draining = false
	renderHud()
	showResults(result)
end)

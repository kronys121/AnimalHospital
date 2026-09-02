--[[
	Animal Hospital - the reception HUD.

	LocalScript. A small heads-up card for whoever is at the counter (name,
	species, a photographed/not status line) plus the decision result banner
	and the treatment log. It does not decide anything: registration itself
	happens in the world now (camera, photo, computer, printer, the reject
	button, handing the card to the patient), all ProximityPrompts driven and
	validated by ShiftServer.server.lua. This script only reflects state back
	to the player - there is no admit/reject/photo button here anymore.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named
		"ReceptionClient" -> paste this file in.

	This script knows nothing about who is an anomaly. The server sends only
	a name and species while a patient is waiting, and reveals the truth in
	DecisionResult only after the round is over.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("AnimalHospital")
local PatientArrived = remotes:WaitForChild("PatientArrived")
local PatientLeft = remotes:WaitForChild("PatientLeft")
local PhotoTaken = remotes:WaitForChild("PhotoTaken")
local DecisionResult = remotes:WaitForChild("DecisionResult")
local RoomOutcome = remotes:WaitForChild("RoomOutcome")
local Feedback = remotes:WaitForChild("Feedback")

-- How close the player has to be to the patient for the card to show, so it
-- reads as "the patient currently at the counter", not "any patient".
local COUNTER_RANGE = 22

local COLORS = {
	panel = Color3.fromRGB(24, 26, 30),
	text = Color3.fromRGB(235, 237, 240),
	muted = Color3.fromRGB(150, 155, 163),
	good = Color3.fromRGB(96, 196, 128),
	bad = Color3.fromRGB(214, 96, 96),
	warn = Color3.fromRGB(224, 180, 96),
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local current = nil -- { info = {...}, model = Model }

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local screen = Instance.new("ScreenGui")
screen.Name = "ReceptionUI"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = player:WaitForChild("PlayerGui")

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

-- Patient info card
local card = Instance.new("Frame")
card.Name = "Card"
card.Size = UDim2.fromOffset(300, 190)
card.Position = UDim2.new(1, -320, 0.5, -95)
card.BackgroundColor3 = COLORS.panel
card.BorderSizePixel = 0
card.Visible = false
card.Parent = screen
corner(card, 10)

label(card, "У СТОЙКИ", UDim2.new(1, -24, 0, 20), UDim2.fromOffset(16, 12), Enum.Font.GothamBold, 15)
local nameLabel = label(card, "", UDim2.new(1, -32, 0, 22), UDim2.fromOffset(16, 38), Enum.Font.GothamBold, 16)
local speciesLabel =
	label(card, "", UDim2.new(1, -32, 0, 18), UDim2.fromOffset(16, 60), Enum.Font.Gotham, 13, COLORS.muted)
local photoStatusLabel =
	label(card, "", UDim2.new(1, -32, 0, 18), UDim2.fromOffset(16, 82), Enum.Font.Gotham, 13, COLORS.warn)

local hintLabel = label(
	card,
	"Сфотографируйте пациента камерой на столе, оформите карточку на компьютере, заберите её в принтере и отдайте пациенту. Отклонить можно кнопкой на столе.",
	UDim2.new(1, -32, 0, 78),
	UDim2.fromOffset(16, 104),
	Enum.Font.Gotham,
	12,
	COLORS.muted
)
hintLabel.TextWrapped = true

-- Result banner
local banner = Instance.new("Frame")
banner.Size = UDim2.fromOffset(440, 66)
banner.Position = UDim2.new(0.5, -220, 0, 24)
banner.BackgroundColor3 = COLORS.panel
banner.BorderSizePixel = 0
banner.Visible = false
banner.Parent = screen
corner(banner, 10)

local bannerTitle = label(banner, "", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 10), Enum.Font.GothamBold, 16)
bannerTitle.TextXAlignment = Enum.TextXAlignment.Center
local bannerBody = label(banner, "", UDim2.new(1, -24, 0, 30), UDim2.fromOffset(12, 32), Enum.Font.Gotham, 13, COLORS.muted)
bannerBody.TextXAlignment = Enum.TextXAlignment.Center
bannerBody.TextWrapped = true

-- Feedback toast (e.g. "Сначала сфотографируйте пациента.")
local toast = Instance.new("Frame")
toast.Size = UDim2.fromOffset(360, 44)
toast.Position = UDim2.new(0.5, -180, 0, 98)
toast.BackgroundColor3 = COLORS.panel
toast.BorderSizePixel = 0
toast.Visible = false
toast.Parent = screen
corner(toast, 8)
local toastLabel = label(toast, "", UDim2.new(1, -20, 1, 0), UDim2.fromOffset(10, 0), Enum.Font.Gotham, 13, COLORS.warn)
toastLabel.TextXAlignment = Enum.TextXAlignment.Center
toastLabel.TextWrapped = true

-- Treatment log
local logLabel = label(screen, "", UDim2.fromOffset(460, 22), UDim2.new(0, 18, 1, -40), Enum.Font.Gotham, 13, COLORS.muted)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function showBanner(correct, text)
	bannerTitle.Text = correct and "ВЕРНО" or "ОШИБКА"
	bannerTitle.TextColor3 = correct and COLORS.good or COLORS.bad
	bannerBody.Text = text
	banner.Visible = true
	task.delay(5, function()
		banner.Visible = false
	end)
end

local function distanceToPatient()
	if not current or not current.model or not current.model.Parent then
		return math.huge
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return math.huge
	end
	return (root.Position - current.model:GetPivot().Position).Magnitude
end

RunService.Heartbeat:Connect(function()
	card.Visible = current ~= nil and distanceToPatient() <= COUNTER_RANGE
end)

--------------------------------------------------------------------------------
-- Server events
--------------------------------------------------------------------------------

PatientArrived.OnClientEvent:Connect(function(info, model)
	current = { info = info, model = model }
	nameLabel.Text = info.name
	speciesLabel.Text = ("Вид: %s"):format(info.speciesLabel)
	photoStatusLabel.Text = "Фото: не сделано"
end)

PatientLeft.OnClientEvent:Connect(function(patientId)
	if current and current.info.id == patientId then
		current = nil
		card.Visible = false
	end
end)

PhotoTaken.OnClientEvent:Connect(function(patientId)
	if current and current.info.id == patientId then
		photoStatusLabel.Text = "Фото: сделано"
		photoStatusLabel.TextColor3 = COLORS.good
	end
end)

DecisionResult.OnClientEvent:Connect(function(result)
	local verdict
	if result.decision == "timeout" then
		verdict = ("%s ушёл сам, не дождавшись решения."):format(result.patientName)
	elseif result.isAnomaly then
		verdict = ("%s - аномалия (%s)."):format(result.patientName, result.traits)
	else
		verdict = ("%s - обычный пациент."):format(result.patientName)
	end
	showBanner(result.correct, verdict)
end)

RoomOutcome.OnClientEvent:Connect(function(outcome)
	local word = outcome.status == "cured" and "вылечен" or "потерян"
	if outcome.status == "failed" then
		word = "не обработан (сбой кабинета)"
	end
	logLabel.Text = ("%s: %s в кабинете %s"):format(outcome.patientName, word, outcome.roomName)
	task.delay(8, function()
		if logLabel.Text:find(outcome.patientName, 1, true) then
			logLabel.Text = ""
		end
	end)
end)

Feedback.OnClientEvent:Connect(function(text)
	toastLabel.Text = text
	toast.Visible = true
	task.delay(3, function()
		if toastLabel.Text == text then
			toast.Visible = false
		end
	end)
end)

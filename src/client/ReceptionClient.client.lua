--[[
	Animal Hospital - Stage 2/3: the reception UI.

	LocalScript. Draws the registration card for whoever is standing at the
	counter: a photo panel, the patient's details, and the admit / reject
	buttons.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named
		"ReceptionClient" -> paste this file in.

	The photo is a ViewportFrame holding a frozen clone of the patient model.
	That is what makes photographing worth doing: body traits (too many teeth)
	stay in the picture and can be studied at leisure, while behaviour traits
	(twitching, a wrong voice) never appear in a still and can only be caught
	by watching the patient at the counter. Neither the camera nor standing and
	staring is enough on its own.

	This script knows nothing about who is an anomaly. The server sends only a
	name and species before the decision, and checks the answer itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("AnimalHospital")
local PatientArrived = remotes:WaitForChild("PatientArrived")
local PatientLeft = remotes:WaitForChild("PatientLeft")
local SubmitDecision = remotes:WaitForChild("SubmitDecision")
local DecisionResult = remotes:WaitForChild("DecisionResult")
local RoomOutcome = remotes:WaitForChild("RoomOutcome")

-- How close the player has to be to the patient for the card to open, so
-- registration happens at the counter rather than from across the building.
local COUNTER_RANGE = 22

local COLORS = {
	panel = Color3.fromRGB(24, 26, 30),
	panelLight = Color3.fromRGB(38, 41, 47),
	text = Color3.fromRGB(235, 237, 240),
	muted = Color3.fromRGB(150, 155, 163),
	admit = Color3.fromRGB(58, 140, 82),
	reject = Color3.fromRGB(163, 62, 62),
	camera = Color3.fromRGB(70, 96, 150),
	good = Color3.fromRGB(96, 196, 128),
	bad = Color3.fromRGB(214, 96, 96),
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local current = nil -- { info = {...}, model = Model }
local hasPhoto = false
local decisionSent = false

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

local function button(parent, text, size, position, color)
	local instance = Instance.new("TextButton")
	instance.Size = size
	instance.Position = position
	instance.BackgroundColor3 = color
	instance.BorderSizePixel = 0
	instance.AutoButtonColor = true
	instance.Font = Enum.Font.GothamBold
	instance.TextSize = 14
	instance.TextColor3 = COLORS.text
	instance.Text = text
	instance.Parent = parent
	corner(instance, 6)
	return instance
end

-- Registration card
local card = Instance.new("Frame")
card.Name = "Card"
card.Size = UDim2.fromOffset(320, 430)
card.Position = UDim2.new(1, -340, 0.5, -215)
card.BackgroundColor3 = COLORS.panel
card.BorderSizePixel = 0
card.Visible = false
card.Parent = screen
corner(card, 10)

label(card, "РЕГИСТРАЦИЯ", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(16, 14), Enum.Font.GothamBold, 16)

local photoFrame = Instance.new("Frame")
photoFrame.Size = UDim2.new(1, -32, 0, 200)
photoFrame.Position = UDim2.fromOffset(16, 44)
photoFrame.BackgroundColor3 = COLORS.panelLight
photoFrame.BorderSizePixel = 0
photoFrame.ClipsDescendants = true
photoFrame.Parent = card
corner(photoFrame, 8)

local viewport = Instance.new("ViewportFrame")
viewport.Size = UDim2.fromScale(1, 1)
viewport.BackgroundTransparency = 1
viewport.Ambient = Color3.fromRGB(190, 190, 195)
viewport.LightColor = Color3.fromRGB(255, 255, 255)
viewport.LightDirection = Vector3.new(-0.3, -1, -0.6)
viewport.Visible = false
viewport.Parent = photoFrame

local photoPlaceholder = label(
	photoFrame,
	"Фото не сделано",
	UDim2.fromScale(1, 1),
	UDim2.fromScale(0, 0),
	Enum.Font.Gotham,
	14,
	COLORS.muted
)
photoPlaceholder.TextXAlignment = Enum.TextXAlignment.Center

local photoButton = button(card, "СФОТОГРАФИРОВАТЬ", UDim2.new(1, -32, 0, 32), UDim2.fromOffset(16, 254), COLORS.camera)

local nameLabel = label(card, "", UDim2.new(1, -32, 0, 22), UDim2.fromOffset(16, 296), Enum.Font.GothamBold, 16)
local speciesLabel =
	label(card, "", UDim2.new(1, -32, 0, 18), UDim2.fromOffset(16, 318), Enum.Font.Gotham, 13, COLORS.muted)

local hintLabel = label(
	card,
	"Сфотографируйте пациента и посмотрите на снимок. Не всё видно на фото - понаблюдайте за ним у стойки.",
	UDim2.new(1, -32, 0, 46),
	UDim2.fromOffset(16, 340),
	Enum.Font.Gotham,
	12,
	COLORS.muted
)
hintLabel.TextWrapped = true

local admitButton = button(card, "ВПУСТИТЬ", UDim2.new(0.5, -20, 0, 34), UDim2.fromOffset(16, 386), COLORS.admit)
local rejectButton = button(card, "ОТКЛОНИТЬ", UDim2.new(0.5, -20, 0, 34), UDim2.new(0.5, 4, 0, 386), COLORS.reject)

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

-- Treatment log
local logLabel = label(screen, "", UDim2.fromOffset(460, 22), UDim2.new(0, 18, 1, -40), Enum.Font.Gotham, 13, COLORS.muted)

--------------------------------------------------------------------------------
-- Photo
--------------------------------------------------------------------------------

local function clearPhoto()
	hasPhoto = false
	viewport:ClearAllChildren()
	viewport.Visible = false
	photoPlaceholder.Visible = true
	photoButton.Text = "СФОТОГРАФИРОВАТЬ"
end

local function takePhoto()
	if not current or not current.model or not current.model.Parent then
		return
	end

	viewport:ClearAllChildren()

	local camera = Instance.new("Camera")
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local clone = current.model:Clone()
	-- The name tag and the speech bubble are UI, not the animal. Leaving them
	-- in would put the patient's line in the photo, which would hand the
	-- player the wrongVoice trait for free.
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			descendant:Destroy()
		end
	end
	clone.Parent = viewport

	-- Frame the animal from its own front, whichever way it happens to be
	-- facing at the counter.
	local pivot = clone:GetPivot()
	local _, size = clone:GetBoundingBox()
	local distance = math.max(size.X, size.Y, size.Z) * 1.9
	local target = pivot.Position + Vector3.new(0, size.Y * 0.12, 0)
	local eye = target + pivot.LookVector * distance + pivot.RightVector * (distance * 0.28) + Vector3.new(0, size.Y * 0.18, 0)
	camera.CFrame = CFrame.lookAt(eye, target)

	hasPhoto = true
	viewport.Visible = true
	photoPlaceholder.Visible = false
	photoButton.Text = "ПЕРЕСНЯТЬ"
end

--------------------------------------------------------------------------------
-- Card
--------------------------------------------------------------------------------

local function setButtonsEnabled(enabled)
	admitButton.Active = enabled
	rejectButton.Active = enabled
	admitButton.AutoButtonColor = enabled
	rejectButton.AutoButtonColor = enabled
	admitButton.BackgroundColor3 = enabled and COLORS.admit or COLORS.panelLight
	rejectButton.BackgroundColor3 = enabled and COLORS.reject or COLORS.panelLight
end

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

photoButton.Activated:Connect(takePhoto)

local function submit(decision)
	if not current or decisionSent then
		return
	end
	decisionSent = true
	setButtonsEnabled(false)
	SubmitDecision:FireServer(current.info.id, decision)
end

admitButton.Activated:Connect(function()
	submit("admit")
end)
rejectButton.Activated:Connect(function()
	submit("reject")
end)

--------------------------------------------------------------------------------
-- Server events
--------------------------------------------------------------------------------

PatientArrived.OnClientEvent:Connect(function(info, model)
	current = { info = info, model = model }
	decisionSent = false
	clearPhoto()
	setButtonsEnabled(true)
	nameLabel.Text = info.name
	speciesLabel.Text = ("Вид: %s"):format(info.speciesLabel)
end)

PatientLeft.OnClientEvent:Connect(function(patientId)
	if current and current.info.id == patientId then
		current = nil
		card.Visible = false
		clearPhoto()
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

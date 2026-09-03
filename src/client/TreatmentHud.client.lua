--[[
	Animal Hospital - ward readout.

	LocalScript. Shows what a ward is waiting for: a patient to be examined,
	then the medicine the scan called for, with the countdown that goes with
	each. Without it the deadlines enforced in TreatmentRooms.server.lua are
	invisible, and the player has no reason to know the scanner is the first
	thing to reach for.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named
		"TreatmentHud" -> paste this file in.

	Purely a readout: the server enforces the actual deadlines. The diagnosis
	is also written on the ward's own monitor, which is the primary place to
	read it - this banner is there for the player who is still walking in.
	If the server says time is up, this label is a couple of tenths of a
	second late finding out, not the authority.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("AnimalHospital")
local RoomExamStarted = remotes:WaitForChild("RoomExamStarted")
local RoomDiagnosis = remotes:WaitForChild("RoomDiagnosis")
local RoomChoiceStarted = remotes:WaitForChild("RoomChoiceStarted")
local RoomChoiceEnded = remotes:WaitForChild("RoomChoiceEnded")

local COLORS = {
	panel = Color3.fromRGB(24, 26, 30),
	text = Color3.fromRGB(235, 237, 240),
	muted = Color3.fromRGB(150, 155, 163),
	warn = Color3.fromRGB(224, 180, 96),
}

local screen = Instance.new("ScreenGui")
screen.Name = "TreatmentHud"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(380, 74)
panel.Position = UDim2.new(0.5, -190, 0, 96)
panel.BackgroundColor3 = COLORS.panel
panel.BackgroundTransparency = 0.15
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = screen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 26)
title.Position = UDim2.fromOffset(10, 8)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.TextColor3 = COLORS.text
title.Text = ""
title.Parent = panel

local detail = Instance.new("TextLabel")
detail.Size = UDim2.new(1, -20, 0, 32)
detail.Position = UDim2.fromOffset(10, 34)
detail.BackgroundTransparency = 1
detail.Font = Enum.Font.Gotham
detail.TextSize = 14
detail.TextColor3 = COLORS.muted
detail.TextWrapped = true
detail.Text = ""
detail.Parent = panel

-- One ward at a time is shown: the player can only be in one of them.
local active = nil -- { roomId, roomName, phase, deadline, medicine }

local function show(roomId, roomName, phase, seconds, medicine)
	active = {
		roomId = roomId,
		roomName = roomName,
		phase = phase,
		deadline = os.clock() + seconds,
		medicine = medicine,
	}
	panel.Visible = true
end

local function clear(roomId)
	if active and (roomId == nil or active.roomId == roomId) then
		active = nil
		panel.Visible = false
	end
end

RoomExamStarted.OnClientEvent:Connect(function(roomId, roomName, seconds)
	show(roomId, roomName, "exam", seconds)
end)

RoomDiagnosis.OnClientEvent:Connect(function(info)
	if active and active.roomId ~= info.roomId then
		return
	end
	-- Keep whatever deadline is running; only the wording changes until the
	-- choice window starts and replaces it.
	if active then
		active.phase = "diagnosed"
		active.medicine = info.medicine
		active.illness = info.illness
	end
end)

RoomChoiceStarted.OnClientEvent:Connect(function(roomId, roomName, seconds, medicine)
	show(roomId, roomName, "choice", seconds, medicine)
end)

RoomChoiceEnded.OnClientEvent:Connect(clear)

RunService.RenderStepped:Connect(function()
	if not active then
		return
	end

	local remaining = math.max(0, active.deadline - os.clock())
	if active.phase == "choice" then
		title.Text = ("%s: %d с"):format(active.roomName, math.ceil(remaining))
		title.TextColor3 = COLORS.warn
		detail.Text = ("Нажмите препарат: %s"):format(active.medicine or "по монитору")
	elseif active.phase == "diagnosed" then
		title.Text = active.roomName
		title.TextColor3 = COLORS.text
		detail.Text = ("%s. Препарат: %s"):format(active.illness or "Диагноз готов", active.medicine or "по монитору")
	else
		title.Text = ("%s: %d с"):format(active.roomName, math.ceil(remaining))
		title.TextColor3 = COLORS.text
		detail.Text = "Пациент на кровати. Обследуйте его сканером у койки."
	end

	if remaining <= 0 and active.phase ~= "diagnosed" then
		clear()
	end
end)

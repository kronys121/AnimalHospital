--[[
	Animal Hospital - treatment machine countdown.

	LocalScript. Shows a countdown while a treatment room's medicine machine
	is waiting on a choice. Without this the 15-second window from
	TreatmentRooms.server.lua is invisible - the roadmap calls out the timer
	as part of what makes the room's mechanic work, so the player needs to
	see it.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named
		"TreatmentHud" -> paste this file in.

	Purely a readout: the server enforces the actual deadline in
	TreatmentRooms.server.lua. If it says time is up, this label is a couple
	of tenths of a second late finding out, not the authority.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("AnimalHospital")
local RoomChoiceStarted = remotes:WaitForChild("RoomChoiceStarted")
local RoomChoiceEnded = remotes:WaitForChild("RoomChoiceEnded")

local screen = Instance.new("ScreenGui")
screen.Name = "TreatmentHud"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(280, 60)
label.Position = UDim2.new(0.5, -140, 0, 24)
label.BackgroundColor3 = Color3.fromRGB(24, 26, 30)
label.BackgroundTransparency = 0.15
label.BorderSizePixel = 0
label.Font = Enum.Font.GothamBold
label.TextSize = 22
label.TextColor3 = Color3.fromRGB(235, 237, 240)
label.Text = ""
label.Visible = false
label.Parent = screen

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = label

local activeRoomId = nil
local activeRoomName = nil
local deadline = nil

RoomChoiceStarted.OnClientEvent:Connect(function(roomId, roomName, seconds)
	activeRoomId = roomId
	activeRoomName = roomName
	deadline = os.clock() + seconds
	label.Visible = true
end)

RoomChoiceEnded.OnClientEvent:Connect(function(roomId)
	if roomId == activeRoomId then
		activeRoomId = nil
		activeRoomName = nil
		deadline = nil
		label.Visible = false
	end
end)

RunService.RenderStepped:Connect(function()
	if not deadline then
		return
	end
	local remaining = math.max(0, deadline - os.clock())
	label.Text = ("%s: выберите препарат (%d с)"):format(activeRoomName, math.ceil(remaining))
	if remaining <= 0 then
		label.Visible = false
		deadline = nil
	end
end)

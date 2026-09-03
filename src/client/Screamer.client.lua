--[[
	Animal Hospital - the incident (roadmap stage 6, screamer stub).

	LocalScript. Plays what happens when an anomaly that the player admitted
	is lying in a ward: the lights go, the screen floods red, and the camera
	shakes. No monster model and no sound file yet - those are later stages -
	but the moment exists and it costs the player sanity, which is what makes
	admitting an anomaly a mistake you feel rather than a number you read.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named "Screamer"
		-> paste this file in.

	The shake cannot be applied here: FirstPersonCamera writes the camera
	CFrame every frame and would overwrite anything this script did. Instead
	this sets the "CameraShake" attribute on the LocalPlayer (0 to 1) and the
	camera adds the offset itself - the same arrangement as "UiFocus" for the
	results screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("AnimalHospital")
local Screamer = remotes:WaitForChild("Screamer")

local SHAKE_ATTRIBUTE = "CameraShake"

local FLASH_SECONDS = 0.12
local HOLD_SECONDS = 0.9
local FADE_SECONDS = 1.6

local screen = Instance.new("ScreenGui")
screen.Name = "ScreamerUI"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 20
screen.Parent = player:WaitForChild("PlayerGui")

local flash = Instance.new("Frame")
flash.Name = "Flash"
flash.Size = UDim2.fromScale(1, 1)
flash.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
flash.BackgroundTransparency = 1
flash.BorderSizePixel = 0
flash.Visible = false
flash.Parent = screen

local caption = Instance.new("TextLabel")
caption.Size = UDim2.new(1, 0, 0, 60)
caption.Position = UDim2.new(0, 0, 0.5, -30)
caption.BackgroundTransparency = 1
caption.Font = Enum.Font.GothamBold
caption.TextSize = 30
caption.TextColor3 = Color3.fromRGB(255, 210, 210)
caption.TextTransparency = 1
caption.Text = ""
caption.Parent = flash

-- One incident at a time: a second one arriving mid-play restarts the effect
-- rather than stacking two fades on top of each other.
local playing = 0

local function play(info)
	playing = playing + 1
	local token = playing

	caption.Text = ("%s. %s"):format(info.roomName or "Палата", info.patientName or "")
	flash.Visible = true

	-- Black, then red, then a slow fade back. Driven from Heartbeat rather
	-- than TweenService so the whole thing lives in one readable timeline.
	local started = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if token ~= playing then
			connection:Disconnect()
			return
		end

		local elapsed = os.clock() - started
		if elapsed < FLASH_SECONDS then
			flash.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			flash.BackgroundTransparency = 0
			caption.TextTransparency = 1
			player:SetAttribute(SHAKE_ATTRIBUTE, 1)
		elseif elapsed < FLASH_SECONDS + HOLD_SECONDS then
			flash.BackgroundColor3 = Color3.fromRGB(90, 0, 0)
			flash.BackgroundTransparency = 0.25
			caption.TextTransparency = 0
			player:SetAttribute(SHAKE_ATTRIBUTE, 1)
		elseif elapsed < FLASH_SECONDS + HOLD_SECONDS + FADE_SECONDS then
			local t = (elapsed - FLASH_SECONDS - HOLD_SECONDS) / FADE_SECONDS
			flash.BackgroundColor3 = Color3.fromRGB(90, 0, 0)
			flash.BackgroundTransparency = 0.25 + t * 0.75
			caption.TextTransparency = t
			player:SetAttribute(SHAKE_ATTRIBUTE, 1 - t)
		else
			flash.Visible = false
			flash.BackgroundTransparency = 1
			caption.TextTransparency = 1
			player:SetAttribute(SHAKE_ATTRIBUTE, 0)
			connection:Disconnect()
		end
	end)
end

Screamer.OnClientEvent:Connect(play)

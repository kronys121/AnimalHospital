--[[
	Animal Hospital - first-person view.

	LocalScript. Fully custom first-person camera: Roblox's own camera is
	switched off (CameraType = Scriptable) and the view is driven from raw
	mouse deltas instead.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named
		"FirstPersonCamera" -> paste this file in.

	Why not CameraMode.LockFirstPerson: the default ProximityPrompt UI is a
	clickable interface element. As soon as one is on screen under the
	(locked, invisible) cursor, Roblox's own camera script treats the mouse
	as belonging to the UI and stops turning the camera - the reported
	"mouse freezes over the action prompt, fine everywhere else". Two things
	fix it together:

	1. prompt.ClickablePrompt = false on every prompt as it is shown, so the
	   prompt stops being a mouse target at all. E still triggers it.
	2. Reading rotation from UserInputService.InputChanged deltas and writing
	   the camera CFrame ourselves, so nothing in the default camera pipeline
	   can decide to skip a frame.

	Screens that do need a real cursor (the end-of-shift results screen and
	its "заново" button) set the attribute "UiFocus" on the LocalPlayer while
	they are up. While it is true the mouse is released and shown and mouse
	movement stops turning the camera; the view itself stays exactly where it
	was, so clearing the attribute drops the player straight back in without
	a jump. Any later screen can reuse the same attribute - nothing here
	knows what the UI is.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local SENSITIVITY = 0.005
local MIN_PITCH = math.rad(-75)
local MAX_PITCH = math.rad(75)
local EYE_OFFSET = Vector3.new(0, 0.5, 0)

local yaw = 0
local pitch = 0

local UI_FOCUS_ATTRIBUTE = "UiFocus"

-- 0 to 1, set by Screamer.client.lua. This script owns the camera CFrame
-- outright, so anything that wants to move the view has to ask for it here
-- rather than writing the camera itself - a second writer would just be
-- overwritten on the next frame.
local SHAKE_ATTRIBUTE = "CameraShake"
local SHAKE_ANGLE = math.rad(4)

local shakeRandom = Random.new()

local function uiFocused()
	return player:GetAttribute(UI_FOCUS_ATTRIBUTE) == true
end

local function shakeAmount()
	local value = player:GetAttribute(SHAKE_ATTRIBUTE)
	if type(value) ~= "number" or value <= 0 then
		return 0
	end
	return math.clamp(value, 0, 1)
end

-- 1. Отключаем перехват мыши у всех кнопок действий.
ProximityPromptService.PromptShown:Connect(function(prompt)
	prompt.ClickablePrompt = false
end)

-- 2. Вращение камеры мышью (не блокируется интерфейсом).
UserInputService.InputChanged:Connect(function(input, _gameProcessed)
	if uiFocused() then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		yaw = yaw - input.Delta.X * SENSITIVITY
		pitch = math.clamp(pitch - input.Delta.Y * SENSITIVITY, MIN_PITCH, MAX_PITCH)
	end
end)

-- 3. Прячем собственное тело, иначе оно закрывает обзор изнутри.
local HIDDEN_PARTS = {
	Head = true,
	-- R6
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
	-- R15
	UpperTorso = true,
	LowerTorso = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
}

local function hideInstance(instance)
	if instance:IsA("BasePart") and HIDDEN_PARTS[instance.Name] then
		instance.LocalTransparencyModifier = 1
		instance:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
			instance.LocalTransparencyModifier = 1
		end)
	elseif instance:IsA("Decal") then
		instance.LocalTransparencyModifier = 1
		instance:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
			instance.LocalTransparencyModifier = 1
		end)
	end
end

local function hideCharacter(character)
	for _, descendant in ipairs(character:GetDescendants()) do
		hideInstance(descendant)
	end
	character.DescendantAdded:Connect(hideInstance)
end

local function onCharacter(character)
	hideCharacter(character)

	-- Стартовое направление берем с самого персонажа, чтобы после спавна
	-- камера не разворачивалась рывком.
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if root then
		local _, spawnYaw = root.CFrame:ToOrientation()
		yaw = spawnYaw
		pitch = 0
	end
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)

-- 4. Сама камера. Приоритет Camera.Value - значит наш код выполняется
-- вместо стандартного камерного шага, а не после него.
RunService:BindToRenderStep("FirstPersonCameraStep", Enum.RenderPriority.Camera.Value, function()
	local character = player.Character
	if not character then
		return
	end

	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not head or not root then
		return
	end

	camera = workspace.CurrentCamera
	if not camera then
		return
	end

	camera.CameraType = Enum.CameraType.Scriptable

	if uiFocused() then
		-- Hand the mouse back to the interface, but keep drawing the camera
		-- from the same yaw/pitch so the view does not move while a panel is
		-- open.
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end

	-- Тело поворачивается только вокруг вертикальной оси, камера - и вверх/вниз.
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)

	local eyePosition = head.Position + EYE_OFFSET
	local view = CFrame.new(eyePosition) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)

	local shake = shakeAmount()
	if shake > 0 then
		local amplitude = SHAKE_ANGLE * shake
		view = view
			* CFrame.Angles(
				shakeRandom:NextNumber(-amplitude, amplitude),
				shakeRandom:NextNumber(-amplitude, amplitude),
				shakeRandom:NextNumber(-amplitude, amplitude)
			)
	end

	camera.CFrame = view
end)

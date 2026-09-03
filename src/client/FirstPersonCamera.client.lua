-- src/client/FirstPersonCamera.client.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Полностью отключаем видимость курсора мыши
UserInputService.MouseIconEnabled = false

-- Настройки обзора и чувствительности
local SENSITIVITY = 0.0025
local MIN_PITCH = -math.rad(80) -- взгляд вниз
local MAX_PITCH = math.rad(80)  -- взгляд вверх
local EYE_OFFSET = Vector3.new(0, 0.25, 0) -- смещение камеры на уровень глаз

local yaw = 0
local pitch = 0

-- Список всех стандартных частей тела персонажа (R6 и R15) для скрытия
local BODY_PART_NAMES = {
	Head = true,
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
	HumanoidRootPart = true,
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

-- 1. Отключаем перехват мыши у всех кнопок действий
ProximityPromptService.PromptShown:Connect(function(prompt)
	prompt.ClickablePrompt = false
end)

-- 2. Вращение камеры мышью (не блокируется интерфейсом)
UserInputService.InputChanged:Connect(function(input, _gameProcessed)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		yaw = yaw - input.Delta.X * SENSITIVITY
		pitch = math.clamp(pitch - input.Delta.Y * SENSITIVITY, MIN_PITCH, MAX_PITCH)
	end
end)

-- 3. Возврат курсора в центр экрана и повторное скрытие при клике
UserInputService.InputBegan:Connect(function(input, _gameProcessed)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end)

-- Функция проверки: нужно ли скрыть эту часть персонажа
local function shouldHidePart(instance)
	if not instance:IsA("BasePart") then
		return false
	end

	-- Скрываем аксессуары: волосы, шапки, очки и прочие украшения
	if instance:FindFirstAncestorOfClass("Accessory") then
		return true
	end

	-- Скрываем тело персонажа: руки, торс, голову, ноги
	if BODY_PART_NAMES[instance.Name] then
		return true
	end

	-- Если это предмет в руках (PickupSystem / Tool), оставляем видимым
	return false
end

local function applyTransparency(instance)
	if shouldHidePart(instance) then
		instance.LocalTransparencyModifier = 1
		instance:GetPropertyChangedSignal("LocalTransparencyModifier"):Connect(function()
			instance.LocalTransparencyModifier = 1
		end)
	elseif instance:IsA("Decal") and instance.Parent and instance.Parent.Name == "Head" then
		-- Скрываем лицо на голове
		instance.Transparency = 1
		instance:GetPropertyChangedSignal("Transparency"):Connect(function()
			instance.Transparency = 1
		end)
	end
end

-- 4. Настройка персонажа при спавне
local function setupCharacter(character)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if root then
		local _, yAngle, _ = root.CFrame:ToOrientation()
		yaw = yAngle
		pitch = 0
	end

	-- Скрываем части тела и волосы
	for _, desc in character:GetDescendants() do
		applyTransparency(desc)
	end

	-- Если волосы/аксессуары прогружаются с задержкой, скрываем их при добавлении
	character.DescendantAdded:Connect(applyTransparency)
end

if player.Character then
	setupCharacter(player.Character)
end
player.CharacterAdded:Connect(setupCharacter)

-- 5. Позиционирование камеры и принудительное скрытие курсора каждый кадр
RunService:BindToRenderStep("FirstPersonCameraStep", Enum.RenderPriority.Camera.Value, function()
	local character = player.Character
	if not character then return end

	local head = character:FindFirstChild("Head")
	local root = character:FindFirstChild("HumanoidRootPart")

	if head and root then
		camera.CameraType = Enum.CameraType.Scriptable
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

		-- Гарантируем, что стрелочка не появится снова
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
		end

		-- Поворачиваем персонажа вслед за взглядом по горизонтали
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)

		-- Камера на уровне глаз с учётом наклона вверх/вниз
		local eyePosition = head.Position + EYE_OFFSET
		camera.CFrame = CFrame.new(eyePosition) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
	end
end)
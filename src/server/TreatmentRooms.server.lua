--[[
	Animal Hospital - treatment rooms: the medicine machine.

	Server Script. Wires the three MedicineButton parts BuildHospital placed
	in each of the four treatment rooms into RoomRegistry.
	Prompts are disabled initially and only activate when a patient
	has completed their physical examination on the exam table.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RoomRegistry = require(Shared:WaitForChild("RoomRegistry"))

local CHOICE_SECONDS = 15

local function ensureRemote(name)
	local folder = ReplicatedStorage:FindFirstChild("AnimalHospital")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "AnimalHospital"
		folder.Parent = ReplicatedStorage
	end
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = folder
	return event
end

local roomChoiceStarted = ensureRemote("RoomChoiceStarted")
local roomChoiceEnded = ensureRemote("RoomChoiceEnded")

local function findButtons(roomId)
	local model = RoomRegistry.getModel(roomId)
	if not model then
		return nil
	end
	local buttons = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant.Name == "MedicineButton" and descendant:GetAttribute("RoomId") == roomId then
			table.insert(buttons, descendant)
		end
	end
	if #buttons == 0 then
		return nil
	end
	return buttons
end

-- Handler закрывается поверх кнопок комнаты: включается только после осмотра
local function makeHandler(roomId, buttons)
	return function(patient, room)
		-- Включаем кнопки автомата только сейчас
		for _, button in ipairs(buttons) do
			local prompt = button:FindFirstChild("MedicinePrompt")
			if prompt then
				prompt.ClickablePrompt = false
				prompt.Enabled = true
			end
		end

		roomChoiceStarted:FireAllClients(roomId, room.name, CHOICE_SECONDS)

		local chosen = nil
		local connections = {}
		for _, button in ipairs(buttons) do
			local prompt = button:FindFirstChild("MedicinePrompt")
			if prompt then
				local medicineId = button:GetAttribute("MedicineId")
				table.insert(
					connections,
					prompt.Triggered:Connect(function(_player)
						if chosen == nil then
							chosen = medicineId
						end
					end)
				)
			end
		end

		local deadline = os.clock() + CHOICE_SECONDS
		while chosen == nil and os.clock() < deadline do
			task.wait(0.1)
		end

		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end

		-- Выключаем кнопки обратно после завершения выбора
		for _, button in ipairs(buttons) do
			local prompt = button:FindFirstChild("MedicinePrompt")
			if prompt then
				prompt.Enabled = false
			end
		end

		roomChoiceEnded:FireAllClients(roomId)

		local cured = chosen ~= nil and chosen == patient.correctMedicine
		return {
			status = cured and RoomRegistry.Outcome.Cured or RoomRegistry.Outcome.Died,
			medicineChosen = chosen,
		}
	end
end

local function main()
	local hospital
	local deadline = os.clock() + 30
	repeat
		local candidate = Workspace:FindFirstChild("Hospital")
		if candidate and candidate:GetAttribute("Ready") then
			hospital = candidate
		else
			task.wait(0.1)
		end
	until hospital or os.clock() > deadline

	if not hospital then
		warn("[TreatmentRooms] Workspace.Hospital never became Ready - is BuildHospital running?")
		return
	end

	local wired = {}
	for _, roomId in ipairs(RoomRegistry.getIds()) do
		local buttons = findButtons(roomId)
		if buttons then
			-- Кнопки изначально выключены до прихода и осмотра пациента
			for _, button in ipairs(buttons) do
				local prompt = button:FindFirstChild("MedicinePrompt")
				if prompt then
					prompt.ClickablePrompt = false
					prompt.Enabled = false
				end
			end

			RoomRegistry.setHandler(roomId, makeHandler(roomId, buttons))
			table.insert(wired, roomId)
		else
			warn(("[TreatmentRooms] %s has no MedicineButton parts - leaving it as a stub"):format(roomId))
		end
	end

	print(("[TreatmentRooms] medicine machine wired for: %s"):format(table.concat(wired, ", ")))
end

main()
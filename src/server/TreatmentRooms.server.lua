--[[
	Animal Hospital - treatment rooms: the medicine machine.

	Server Script. Wires the three MedicineButton parts BuildHospital placed
	in each of the four treatment rooms into RoomRegistry, replacing that
	room's stub with a real (if identical, for now) minigame: three buttons,
	a 15-second choice window, right medicine cures, wrong or no answer in
	time loses the patient. This is the roadmap's stage 5 Basic Medical
	pattern, generalized to all four rooms at once rather than to Basic
	Medical alone - the reference pattern (timer + choice + outcome) is
	applied everywhere immediately instead of copied room by room, since the
	brief asked for "already being able to treat them", not for Basic
	Medical specifically.

	Later stages can still give any one room its own distinct minigame by
	calling RoomRegistry.setHandler(roomId, ...) again - that call always
	wins, this script only sets the starting handler.

	Where to put it:
		ServerScriptService -> Script (Server) -> paste this file in,
		alongside BuildHospital and ShiftServer.

	Needs:
		Workspace.Hospital (BuildHospital.server.lua)
		ReplicatedStorage.Shared.RoomRegistry
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RoomRegistry = require(Shared:WaitForChild("RoomRegistry"))

local CHOICE_SECONDS = 15

-- Same ReplicatedStorage.AnimalHospital folder ShiftServer creates; reused
-- here (not recreated) so the client only ever deals with one remotes
-- folder regardless of which server script happened to create it first.
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

-- Returns a RoomRegistry handler closed over this room's three buttons.
local function makeHandler(roomId, buttons)
	return function(patient, room)
		for _, button in ipairs(buttons) do
			local prompt = button:FindFirstChild("MedicinePrompt")
			if prompt then
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
						-- First press within the window wins; later presses in
						-- the same window (from the same or another player) are
						-- ignored rather than overwriting the outcome.
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
			RoomRegistry.setHandler(roomId, makeHandler(roomId, buttons))
			table.insert(wired, roomId)
		else
			warn(("[TreatmentRooms] %s has no MedicineButton parts - leaving it as a stub"):format(roomId))
		end
	end

	print(("[TreatmentRooms] medicine machine wired for: %s"):format(table.concat(wired, ", ")))
end

main()

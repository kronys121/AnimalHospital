--[[
	Animal Hospital - treatment rooms: examine, then treat.

	Server Script. Turns each of the four wards from a stub into a real
	minigame, in two steps that have to happen in order:

		1. Examine. The patient is lying on the bed; the scanner beside it
		   lights up its prompt. Running the scan takes a few seconds and
		   writes the diagnosis and the medicine that treats it onto the ward
		   monitor.
		2. Treat. Only now do the three medicine buttons switch on, with 15
		   seconds to press the one the monitor named.

	Before this the buttons were live immediately and nothing in the world said
	which of the three was right, so treatment was a one-in-three guess. The
	illness lives in PatientData, the medicine is derived from it, and the scan
	is the only thing that reveals either - so the answer is always knowable and
	never guessable.

	An anomaly that the player admitted is not treated at all: it is taken to a
	ward, it lies down, and then the incident happens (RoomRegistry.Outcome
	.Incident, the Screamer remote, a heavy sanity cost in ShiftState). This is
	the roadmap's stage 6 screamer, minus the monster model.

	Later stages can still give any one room its own distinct minigame by
	calling RoomRegistry.setHandler(roomId, ...) again - that call always
	wins, this script only sets the starting handler.

	Where to put it:
		ServerScriptService -> Script (Server) -> paste this file in,
		alongside BuildHospital and ShiftServer.

	Needs:
		Workspace.Hospital (BuildHospital.server.lua)
		ReplicatedStorage.Shared.RoomRegistry
		ReplicatedStorage.Shared.PatientData
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RoomRegistry = require(Shared:WaitForChild("RoomRegistry"))
local PatientData = require(Shared:WaitForChild("PatientData"))

-- How long the scanner runs before the diagnosis appears.
local SCAN_SECONDS = 3

-- How long the player has to press the right medicine once the monitor names
-- it. Only starts after the scan: the clock is on acting, not on finding out.
local CHOICE_SECONDS = 15

-- How long a patient will lie there unexamined before it is too late. Without
-- it a player who never comes to the ward would hold the room forever.
local EXAM_SECONDS = 45

-- How long an admitted anomaly lies still before the incident.
local INCIDENT_DELAY = 4

local IDLE_SCREEN_TEXT = "ПАЦИЕНТ НЕ ОБСЛЕДОВАН"

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
local roomExamStarted = ensureRemote("RoomExamStarted")
local roomDiagnosis = ensureRemote("RoomDiagnosis")
local screamer = ensureRemote("Screamer")

--------------------------------------------------------------------------------
-- Finding a room's equipment
--------------------------------------------------------------------------------

local function findByName(model, name)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant.Name == name then
			return descendant
		end
	end
	return nil
end

local function findEquipment(roomId)
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

	local scanner = findByName(model, "Scanner")
	local scanPrompt = scanner and scanner:FindFirstChild("ScanPrompt")
	if not scanPrompt then
		return nil
	end

	local screen = findByName(model, "DiagnosisScreen")
	local screenLabel
	if screen then
		local gui = screen:FindFirstChildOfClass("SurfaceGui")
		screenLabel = gui and gui:FindFirstChild("Text")
	end

	return {
		buttons = buttons,
		scanPrompt = scanPrompt,
		lamp = findByName(model, "ScannerLamp"),
		screenLabel = screenLabel,
	}
end

--------------------------------------------------------------------------------
-- Small helpers over a room's equipment
--------------------------------------------------------------------------------

local function setButtonPrompts(equipment, enabled)
	for _, button in ipairs(equipment.buttons) do
		local prompt = button:FindFirstChild("MedicinePrompt")
		if prompt then
			prompt.Enabled = enabled
		end
	end
end

local function setScreen(equipment, text, color)
	if equipment.screenLabel then
		equipment.screenLabel.Text = text
		if color then
			equipment.screenLabel.TextColor3 = color
		end
	end
end

local function setLamp(equipment, color)
	if equipment.lamp then
		equipment.lamp.Color = color
	end
end

local LAMP_IDLE = Color3.fromRGB(120, 200, 240)
local LAMP_BUSY = Color3.fromRGB(240, 200, 90)
local LAMP_ALARM = Color3.fromRGB(230, 70, 70)

local SCREEN_NORMAL = Color3.fromRGB(150, 220, 255)
local SCREEN_ALARM = Color3.fromRGB(255, 120, 120)

-- Waits until `predicate()` returns a value or the deadline passes. Returns
-- what the predicate returned, or nil on timeout.
local function waitFor(seconds, predicate)
	local deadline = os.clock() + seconds
	while os.clock() < deadline do
		local value = predicate()
		if value ~= nil then
			return value
		end
		task.wait(0.1)
	end
	return nil
end

--------------------------------------------------------------------------------
-- The two things that can happen in a ward
--------------------------------------------------------------------------------

-- An admitted anomaly. No scan, no medicine: it lies down, holds still for a
-- moment, and then whatever it is stops pretending.
local function runIncident(roomId, room, patient, equipment)
	setButtonPrompts(equipment, false)
	equipment.scanPrompt.Enabled = false
	setScreen(equipment, "ПАЦИЕНТ НА ОСМОТРЕ...", SCREEN_NORMAL)

	task.wait(INCIDENT_DELAY)

	setLamp(equipment, LAMP_ALARM)
	setScreen(equipment, "!!! ТРЕВОГА !!!\nПАЛАТА " .. room.name, SCREEN_ALARM)
	screamer:FireAllClients({
		roomId = roomId,
		roomName = room.name,
		patientName = patient.name,
	})

	task.wait(2.5)
	setLamp(equipment, LAMP_IDLE)
	setScreen(equipment, IDLE_SCREEN_TEXT, SCREEN_NORMAL)

	return { status = RoomRegistry.Outcome.Incident }
end

-- A real patient: examine, read the monitor, press the matching button.
local function runTreatment(roomId, room, patient, equipment)
	local illnessLabel = patient.illnessLabel or "Не определено"
	local finding = patient.illnessFinding or ""
	local medicineLabel = PatientData.MedicineLabels[patient.correctMedicine] or patient.correctMedicine

	----------------------------------------------------------------------------
	-- 1. Examine
	----------------------------------------------------------------------------

	setButtonPrompts(equipment, false)
	setScreen(equipment, IDLE_SCREEN_TEXT, SCREEN_NORMAL)
	setLamp(equipment, LAMP_IDLE)
	equipment.scanPrompt.Enabled = true
	roomExamStarted:FireAllClients(roomId, room.name, EXAM_SECONDS)

	local scanning = false
	local scanConnection = equipment.scanPrompt.Triggered:Connect(function(_player)
		scanning = true
	end)

	local started = waitFor(EXAM_SECONDS, function()
		return scanning or nil
	end)
	scanConnection:Disconnect()
	equipment.scanPrompt.Enabled = false

	if not started then
		-- Nobody came. The patient was never examined, so nothing could have
		-- been treated.
		setScreen(equipment, "ПАЦИЕНТ НЕ ДОЖДАЛСЯ", SCREEN_ALARM)
		task.wait(2)
		setScreen(equipment, IDLE_SCREEN_TEXT, SCREEN_NORMAL)
		return { status = RoomRegistry.Outcome.Died, examined = false }
	end

	setLamp(equipment, LAMP_BUSY)
	setScreen(equipment, "СКАНИРОВАНИЕ...", SCREEN_NORMAL)
	task.wait(SCAN_SECONDS)

	-- This is the whole point of the stage: the answer is now written on a
	-- screen in the room, not hidden on the server.
	setLamp(equipment, LAMP_IDLE)
	setScreen(equipment, ("ДИАГНОЗ: %s\n%s\nПРЕПАРАТ: %s"):format(illnessLabel, finding, medicineLabel), SCREEN_NORMAL)
	roomDiagnosis:FireAllClients({
		roomId = roomId,
		roomName = room.name,
		patientName = patient.name,
		illness = illnessLabel,
		finding = finding,
		medicine = medicineLabel,
	})

	----------------------------------------------------------------------------
	-- 2. Treat
	----------------------------------------------------------------------------

	setButtonPrompts(equipment, true)
	roomChoiceStarted:FireAllClients(roomId, room.name, CHOICE_SECONDS, medicineLabel)

	local chosen = nil
	local connections = {}
	for _, button in ipairs(equipment.buttons) do
		local prompt = button:FindFirstChild("MedicinePrompt")
		if prompt then
			local medicineId = button:GetAttribute("MedicineId")
			table.insert(
				connections,
				prompt.Triggered:Connect(function(_player)
					-- First press within the window wins; later presses in the
					-- same window (from the same or another player) are ignored
					-- rather than overwriting the outcome.
					if chosen == nil then
						chosen = medicineId
					end
				end)
			)
		end
	end

	waitFor(CHOICE_SECONDS, function()
		return chosen
	end)

	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	setButtonPrompts(equipment, false)
	roomChoiceEnded:FireAllClients(roomId)

	local cured = chosen ~= nil and chosen == patient.correctMedicine
	setScreen(equipment, cured and "ПАЦИЕНТ ВЫЛЕЧЕН" or "ПАЦИЕНТ ПОТЕРЯН", cured and SCREEN_NORMAL or SCREEN_ALARM)
	task.wait(2)
	setScreen(equipment, IDLE_SCREEN_TEXT, SCREEN_NORMAL)

	return {
		status = cured and RoomRegistry.Outcome.Cured or RoomRegistry.Outcome.Died,
		medicineChosen = chosen,
		examined = true,
	}
end

-- Returns a RoomRegistry handler closed over this room's equipment.
local function makeHandler(roomId, equipment)
	return function(patient, room)
		if patient and patient.isAnomaly then
			return runIncident(roomId, room, patient, equipment)
		end
		return runTreatment(roomId, room, patient, equipment)
	end
end

--------------------------------------------------------------------------------

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
		local equipment = findEquipment(roomId)
		if equipment then
			RoomRegistry.setHandler(roomId, makeHandler(roomId, equipment))
			table.insert(wired, roomId)
		else
			warn(
				("[TreatmentRooms] %s is missing its scanner or medicine buttons - leaving it as a stub"):format(
					roomId
				)
			)
		end
	end

	print(("[TreatmentRooms] examine-then-treat wired for: %s"):format(table.concat(wired, ", ")))
end

main()

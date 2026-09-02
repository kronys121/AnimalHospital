--[[
	Animal Hospital - Stage 1: RoomRegistry.

	The single place that knows which treatment rooms exist and what happens
	when a patient is sent into one. Everything else (reception, shift loop,
	minigames) talks to rooms only through this module, so a room can be
	switched from a stub to a real minigame without touching any other code.

	Where to put it:
		ReplicatedStorage -> Folder named "Shared" -> ModuleScript named
		"RoomRegistry" -> paste this file in.

	Only the four treatment rooms live here. Lobby, Reception, Corridor and
	BreakRoom are places in the world, not rooms a patient gets routed to, so
	they are deliberately absent.

	Stub rooms: a room with isImplemented = false treats the patient with a
	random outcome after STUB_TREATMENT_SECONDS, so the patient loop never
	hangs waiting on a minigame that does not exist yet.

	Swapping a stub for a real minigame (stage 5 onwards):

		RoomRegistry.setHandler("BasicMedical", function(patient, room)
			-- run the minigame, yield as long as it needs
			return { status = RoomRegistry.Outcome.Cured }
		end)

	setHandler also flips isImplemented to true. Nothing else changes.
]]

local Workspace = game:GetService("Workspace")

local RoomRegistry = {}

-- How long a stub room pretends to treat a patient before returning a result.
local STUB_TREATMENT_SECONDS = 5
-- Chance a stub room cures the patient rather than losing them.
local STUB_CURE_CHANCE = 0.7

-- Own generator so stub outcomes do not disturb math.random elsewhere.
local rng = Random.new()

RoomRegistry.Outcome = {
	Cured = "cured",
	Died = "died",
	-- Returned when a handler errors or returns something unusable. It means
	-- "the room is broken", not "the patient lost", and is always logged.
	Failed = "failed",
}

RoomRegistry.STUB_TREATMENT_SECONDS = STUB_TREATMENT_SECONDS

--------------------------------------------------------------------------------
-- Rooms
--------------------------------------------------------------------------------

local function stubTreatment(roomId)
	return function(_patient, _room)
		task.wait(STUB_TREATMENT_SECONDS)
		local cured = rng:NextNumber() < STUB_CURE_CHANCE
		return {
			status = cured and RoomRegistry.Outcome.Cured or RoomRegistry.Outcome.Died,
			fromStub = true,
		}
	end
end

-- Fixed order for anything that iterates rooms; pairs() order is not stable
-- and a shift that visits rooms in a different order every run is not
-- reproducible when something goes wrong.
local ORDERED_IDS = { "BasicMedical", "XRay", "HeartMonitor", "Surgery" }

local Rooms = {
	BasicMedical = { name = "Basic Medical / DNA", roomNumber = 1, isImplemented = false },
	XRay = { name = "X-Ray", roomNumber = 2, isImplemented = false },
	HeartMonitor = { name = "Heart Monitor", roomNumber = 7, isImplemented = false },
	Surgery = { name = "Surgery", roomNumber = 8, isImplemented = false },
}

-- Which patient each room is currently busy with. Kept out of the Rooms table
-- so that table stays purely declarative.
local occupancy = {}

-- A patient value of nil is still valid (stage 2 has not defined patients
-- yet), so occupancy stores this sentinel rather than the patient itself when
-- there is nothing to store.
local ANONYMOUS_PATIENT = {}

for _, roomId in ipairs(ORDERED_IDS) do
	local room = Rooms[roomId]
	assert(room, ("ORDERED_IDS lists %q but Rooms has no such entry"):format(roomId))
	room.id = roomId
	if not room.onPatientEnter then
		room.onPatientEnter = stubTreatment(roomId)
	end
end

for roomId in pairs(Rooms) do
	assert(Rooms[roomId].id, ("Rooms has %q but ORDERED_IDS does not list it"):format(roomId))
end

--------------------------------------------------------------------------------
-- Lookups
--------------------------------------------------------------------------------

function RoomRegistry.get(roomId)
	return Rooms[roomId]
end

function RoomRegistry.getIds()
	local ids = {}
	for index, roomId in ipairs(ORDERED_IDS) do
		ids[index] = roomId
	end
	return ids
end

-- Rooms in ORDERED_IDS order. The room tables themselves are shared, not
-- copied: callers read them, and write only through setHandler.
function RoomRegistry.getRooms()
	local list = {}
	for index, roomId in ipairs(ORDERED_IDS) do
		list[index] = Rooms[roomId]
	end
	return list
end

function RoomRegistry.isFree(roomId)
	return Rooms[roomId] ~= nil and occupancy[roomId] == nil
end

-- Picks a room to send a patient to. Skips busy rooms by default, so two
-- patients are never routed into the same room at once.
function RoomRegistry.pickRandomRoom(includeBusy)
	local candidates = {}
	for _, roomId in ipairs(ORDERED_IDS) do
		if includeBusy or occupancy[roomId] == nil then
			table.insert(candidates, roomId)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

--------------------------------------------------------------------------------
-- World geometry (built by BuildHospital.server.lua)
--------------------------------------------------------------------------------

-- Models are matched on the RoomId attribute rather than the instance name,
-- so renaming a model in Studio cannot silently break routing.
function RoomRegistry.getModel(roomId)
	local hospital = Workspace:FindFirstChild("Hospital")
	local folder = hospital and hospital:FindFirstChild("Rooms")
	if not folder then
		return nil
	end
	for _, child in ipairs(folder:GetChildren()) do
		if child:GetAttribute("RoomId") == roomId then
			return child
		end
	end
	return nil
end

function RoomRegistry.getEntryPoint(roomId)
	local model = RoomRegistry.getModel(roomId)
	return model and model:FindFirstChild("EntryPoint")
end

function RoomRegistry.getInteractionZone(roomId)
	local model = RoomRegistry.getModel(roomId)
	return model and model:FindFirstChild("InteractionZone")
end

--------------------------------------------------------------------------------
-- Routing
--------------------------------------------------------------------------------

local function normalizeOutcome(roomId, ok, result)
	if not ok then
		warn(("[RoomRegistry] %s handler errored: %s"):format(roomId, tostring(result)))
		return { roomId = roomId, status = RoomRegistry.Outcome.Failed }
	end
	if type(result) ~= "table" or result.status == nil then
		warn(("[RoomRegistry] %s handler returned no outcome table with a status field"):format(roomId))
		return { roomId = roomId, status = RoomRegistry.Outcome.Failed }
	end
	result.roomId = result.roomId or roomId
	return result
end

-- Sends a patient into a room. Returns false without calling onComplete if the
-- room is unknown or already busy, so the caller can pick somewhere else.
--
-- The handler runs on its own thread and may yield for as long as it likes;
-- onComplete(outcome, patient) fires when it finishes. The room is released
-- before onComplete runs, so a slow or failing callback never wedges it.
function RoomRegistry.sendPatient(roomId, patient, onComplete)
	local room = Rooms[roomId]
	if not room then
		warn(("[RoomRegistry] unknown room %q"):format(tostring(roomId)))
		return false
	end
	if occupancy[roomId] ~= nil then
		return false
	end

	occupancy[roomId] = patient == nil and ANONYMOUS_PATIENT or patient

	task.spawn(function()
		local ok, result = pcall(room.onPatientEnter, patient, room)
		occupancy[roomId] = nil
		local outcome = normalizeOutcome(roomId, ok, result)
		if onComplete then
			onComplete(outcome, patient)
		end
	end)

	return true
end

-- Replaces a room's stub with a real minigame. This is the whole point of the
-- registry: stage 5 calls it for BasicMedical, stage 8 for XRay, and so on,
-- without any other file changing.
function RoomRegistry.setHandler(roomId, handler)
	local room = Rooms[roomId]
	assert(room, ("[RoomRegistry] unknown room %q"):format(tostring(roomId)))
	assert(type(handler) == "function", "[RoomRegistry] handler must be a function")
	room.onPatientEnter = handler
	room.isImplemented = true
	return room
end

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

function RoomRegistry.describe()
	local lines = { "RoomRegistry:" }
	for _, roomId in ipairs(ORDERED_IDS) do
		local room = Rooms[roomId]
		table.insert(
			lines,
			("  %-13s room %-2s  %-11s  model %-7s  %s"):format(
				roomId,
				tostring(room.roomNumber),
				room.isImplemented and "implemented" or "stub",
				RoomRegistry.getModel(roomId) and "found" or "MISSING",
				occupancy[roomId] ~= nil and "busy" or "free"
			)
		)
	end
	return table.concat(lines, "\n")
end

-- Sends one dummy patient into every room at once. Every room should report
-- back after STUB_TREATMENT_SECONDS with a random outcome, and the four runs
-- should not interfere with each other.
function RoomRegistry.runSelfTest()
	print(RoomRegistry.describe())
	for _, roomId in ipairs(ORDERED_IDS) do
		local started = RoomRegistry.sendPatient(roomId, { name = "TestPatient" }, function(outcome)
			print(("[RoomRegistry] %s -> %s"):format(outcome.roomId, outcome.status))
		end)
		if not started then
			warn(("[RoomRegistry] could not send a patient to %s"):format(roomId))
		end
	end
end

return RoomRegistry

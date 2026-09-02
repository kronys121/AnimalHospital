--[[
	Animal Hospital - Stage 2/3: the reception loop.

	Server Script. Brings patients in one at a time, walks them to the
	reception counter, waits for the player's decision, checks it, and routes
	admitted patients into a treatment room through RoomRegistry.

	Where to put it:
		ServerScriptService -> Script (Server) -> paste this file in.

	Needs, and waits for:
		Workspace.Hospital                          (BuildHospital.server.lua)
		ReplicatedStorage.Shared.RoomRegistry
		ReplicatedStorage.Shared.PatientData

	Creates ReplicatedStorage.AnimalHospital with the RemoteEvents the
	reception UI listens to, so there is nothing to wire up by hand.

	Patients are anchored models moved with PivotTo along waypoints derived
	from the markers BuildHospital places. No Humanoid and no physics: a
	patient can never get stuck on geometry, fall over, or wander off, which
	matters more than convincing walk animation at this stage.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RoomRegistry = require(Shared:WaitForChild("RoomRegistry"))
local PatientData = require(Shared:WaitForChild("PatientData"))

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local WALK_SPEED = 9
local NEXT_PATIENT_DELAY = 3

-- Placeholder only. Stage 4 brings the real shift timer and the -1/sec idle
-- penalty; until then this just stops a forgotten patient from parking at the
-- counter forever and stalling the loop during a test session.
local DECISION_TIMEOUT = 90

-- How long to keep trying for a free treatment room before giving up and
-- sending an admitted patient home.
local ROOM_WAIT_TIMEOUT = 20

local TWITCH_MIN_GAP, TWITCH_MAX_GAP = 2.0, 4.5
local SPEAK_MIN_GAP, SPEAK_MAX_GAP = 4.0, 7.0
local SPEAK_DURATION = 2.5

local rng = Random.new()

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local function ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild("AnimalHospital")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "AnimalHospital"
		folder.Parent = ReplicatedStorage
	end

	local function remote(name)
		local existing = folder:FindFirstChild(name)
		if existing then
			return existing
		end
		local event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = folder
		return event
	end

	return {
		PatientArrived = remote("PatientArrived"),
		PatientLeft = remote("PatientLeft"),
		SubmitDecision = remote("SubmitDecision"),
		DecisionResult = remote("DecisionResult"),
		RoomOutcome = remote("RoomOutcome"),
	}
end

local remotes = ensureRemotes()

-- Remembered so a player joining mid-patient still gets a registration card
-- instead of an empty screen until the next arrival.
local atCounter = nil

--------------------------------------------------------------------------------
-- World anchors
--------------------------------------------------------------------------------

local function findDescendant(root, name)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name then
			return descendant
		end
	end
	return nil
end

-- Everything below is read off the geometry rather than hardcoded, so moving
-- a room in BuildHospital's ROOMS table moves the patients with it.
local world = {}

local function resolveWorld()
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
		return false, "Workspace.Hospital never became Ready - is BuildHospital running?"
	end

	local rooms = hospital:FindFirstChild("Rooms")
	local corridor = hospital:FindFirstChild("Corridor")
	if not rooms or not corridor then
		return false, "Hospital is missing Rooms or Corridor"
	end

	local lobby = rooms:FindFirstChild("Lobby")
	local reception = rooms:FindFirstChild("Reception")
	if not lobby or not reception then
		return false, "Hospital is missing the Lobby or Reception model"
	end

	local spawnMarker = findDescendant(lobby, "PatientSpawn")
	local receptionEntry = findDescendant(reception, "EntryPoint")
	local desk = findDescendant(reception, "ReceptionDesk")
	local corridorEntry = findDescendant(corridor, "EntryPoint")
	local lobbyFloor = findDescendant(lobby, "Floor")
	if not (spawnMarker and receptionEntry and desk and corridorEntry and lobbyFloor) then
		return false, "Hospital is missing one of PatientSpawn / EntryPoint / ReceptionDesk / Floor"
	end

	world.floorY = lobbyFloor.Position.Y + lobbyFloor.Size.Y / 2
	world.lobbyX = spawnMarker.Position.X
	world.spawnZ = spawnMarker.Position.Z
	world.receptionZ = receptionEntry.Position.Z
	world.receptionEntryX = receptionEntry.Position.X
	world.corridorZ = corridorEntry.Position.Z
	-- Patients queue on the lobby side of the counter, facing the window.
	world.counterX = desk.Position.X + desk.Size.X / 2 + 3
	return true
end

--------------------------------------------------------------------------------
-- Patient model
--------------------------------------------------------------------------------
-- An upright, blocky animal about 6 studs tall. The height is not arbitrary:
-- the reception counter is 3 studs with glass above it, so a patient's head
-- has to sit above 3 studs or the player cannot see the animal they are meant
-- to be inspecting.

local BODY = {
	legHeight = 1.8,
	bodyY = 3.0,
	headY = 5.0,
}

local function newPart(name, parent, size, position, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildPatientModel(patient)
	local species = PatientData.getSpecies(patient.speciesId)
	local scale = species.scale
	local skin = species.color
	local darker = Color3.new(skin.R * 0.75, skin.G * 0.75, skin.B * 0.75)

	local model = Instance.new("Model")
	model.Name = ("Patient_%d"):format(patient.id)

	-- Local space: feet at Y = 0, the animal faces -Z, which is the direction
	-- CFrame.lookAt points a part's front at.
	local function place(name, size, offset, color, material)
		return newPart(name, model, size * scale, offset * scale, color, material)
	end

	local body = place("Body", Vector3.new(2.2, 2.4, 1.6), Vector3.new(0, BODY.bodyY, 0), skin)
	place("LegLeft", Vector3.new(0.6, BODY.legHeight, 0.6), Vector3.new(-0.6, BODY.legHeight / 2, 0), darker)
	place("LegRight", Vector3.new(0.6, BODY.legHeight, 0.6), Vector3.new(0.6, BODY.legHeight / 2, 0), darker)
	place("ArmLeft", Vector3.new(0.5, 1.4, 0.5), Vector3.new(-1.35, 3.2, 0), darker)
	place("ArmRight", Vector3.new(0.5, 1.4, 0.5), Vector3.new(1.35, 3.2, 0), darker)
	place("Tail", Vector3.new(0.35, 0.35, 0.9), Vector3.new(0, 2.6, 1.15), darker)

	local head = place("Head", Vector3.new(1.8, 1.6, 1.6), Vector3.new(0, BODY.headY, 0), skin)
	place("Snout", Vector3.new(0.9, 0.6, 0.8), Vector3.new(0, BODY.headY - 0.15, -1.2), darker)
	place("EyeLeft", Vector3.new(0.28, 0.28, 0.2), Vector3.new(-0.45, BODY.headY + 0.35, -0.85), Color3.fromRGB(20, 20, 24))
	place("EyeRight", Vector3.new(0.28, 0.28, 0.2), Vector3.new(0.45, BODY.headY + 0.35, -0.85), Color3.fromRGB(20, 20, 24))

	local earHeight = species.longEars and 1.8 or 0.9
	place("EarLeft", Vector3.new(0.45, earHeight, 0.25), Vector3.new(-0.55, BODY.headY + 0.8 + earHeight / 2, 0), skin)
	place("EarRight", Vector3.new(0.45, earHeight, 0.25), Vector3.new(0.55, BODY.headY + 0.8 + earHeight / 2, 0), skin)

	-- Teeth are the tooManyTeeth trait's whole tell, and the one anomaly a
	-- photo can freeze and prove.
	local toothColor = Color3.fromRGB(245, 245, 235)
	if PatientData.hasTrait(patient, "tooManyTeeth") then
		local count = 8
		for index = 1, count do
			local t = (index - 1) / (count - 1) - 0.5
			local length = 0.5 + rng:NextNumber() * 0.35
			place(
				"Tooth",
				Vector3.new(0.22, length, 0.2),
				Vector3.new(t * 1.3, BODY.headY - 0.45 - length / 2, -1.35),
				toothColor
			)
		end
	else
		place("Tooth", Vector3.new(0.18, 0.28, 0.15), Vector3.new(-0.18, BODY.headY - 0.55, -1.4), toothColor)
		place("Tooth", Vector3.new(0.18, 0.28, 0.15), Vector3.new(0.18, BODY.headY - 0.55, -1.4), toothColor)
	end

	model.PrimaryPart = body

	local nameTag = Instance.new("BillboardGui")
	nameTag.Name = "NameTag"
	nameTag.Size = UDim2.fromScale(8, 1.2)
	nameTag.StudsOffsetWorldSpace = Vector3.new(0, 2.6 * scale, 0)
	nameTag.AlwaysOnTop = false
	nameTag.Adornee = head
	nameTag.Parent = head

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Text"
	nameLabel.Size = UDim2.fromScale(1, 1)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextStrokeTransparency = 0.4
	nameLabel.Text = patient.name
	nameLabel.Parent = nameTag

	local bubble = Instance.new("BillboardGui")
	bubble.Name = "SpeechBubble"
	bubble.Size = UDim2.fromScale(12, 2)
	bubble.StudsOffsetWorldSpace = Vector3.new(0, 4.2 * scale, 0)
	bubble.AlwaysOnTop = false
	bubble.Adornee = head
	bubble.Enabled = false
	bubble.Parent = head

	local bubbleLabel = Instance.new("TextLabel")
	bubbleLabel.Name = "Text"
	bubbleLabel.Size = UDim2.fromScale(1, 1)
	bubbleLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	bubbleLabel.BackgroundTransparency = 0.25
	bubbleLabel.Font = Enum.Font.Gotham
	bubbleLabel.TextScaled = true
	bubbleLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
	bubbleLabel.Text = ""
	bubbleLabel.Parent = bubble

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = bubbleLabel

	return model, BODY.bodyY * scale
end

--------------------------------------------------------------------------------
-- Movement
--------------------------------------------------------------------------------

local function walkPath(actor, waypoints)
	local model = actor.model
	local walked = 0
	for _, target in ipairs(waypoints) do
		while model.Parent do
			local pivot = model:GetPivot()
			local flat = Vector3.new(target.X - pivot.Position.X, 0, target.Z - pivot.Position.Z)
			local distance = flat.Magnitude
			if distance < 0.4 then
				break
			end
			local dt = RunService.Heartbeat:Wait()
			local direction = flat.Unit
			local step = math.min(WALK_SPEED * dt, distance)
			walked = walked + step
			-- A small bob sells the walk without needing a rig or animations.
			local bob = math.abs(math.sin(walked * 1.6)) * 0.12
			local position = Vector3.new(
				pivot.Position.X + direction.X * step,
				actor.baseY + bob,
				pivot.Position.Z + direction.Z * step
			)
			model:PivotTo(CFrame.lookAt(position, position + direction))
		end
	end
	if model.Parent then
		-- Land exactly on the walking height, keeping the facing from the last step.
		local pivot = model:GetPivot()
		model:PivotTo((pivot - pivot.Position) + Vector3.new(pivot.Position.X, actor.baseY, pivot.Position.Z))
	end
end

local function faceDirection(actor, direction)
	local model = actor.model
	if not model.Parent or direction.Magnitude < 1e-3 then
		return
	end
	local position = model:GetPivot().Position
	model:PivotTo(CFrame.lookAt(position, position + direction.Unit))
end

--------------------------------------------------------------------------------
-- Idle behaviour: the live-only anomaly tells
--------------------------------------------------------------------------------

local function startIdleBehaviour(actor)
	actor.idle = true

	if PatientData.hasTrait(actor.data, "twitching") then
		task.spawn(function()
			while actor.idle and actor.model.Parent do
				task.wait(rng:NextNumber(TWITCH_MIN_GAP, TWITCH_MAX_GAP))
				if not (actor.idle and actor.model.Parent) then
					break
				end
				local rest = actor.model:GetPivot()
				local jerk = rest
					* CFrame.Angles(0, rng:NextNumber(-0.5, 0.5), rng:NextNumber(-0.22, 0.22))
					+ Vector3.new(0, rng:NextNumber(0, 0.25), 0)
				actor.model:PivotTo(jerk)
				task.wait(0.12)
				if actor.model.Parent then
					actor.model:PivotTo(rest)
				end
			end
		end)
	end

	task.spawn(function()
		local bubble = findDescendant(actor.model, "SpeechBubble")
		if not bubble then
			return
		end
		local label = bubble:FindFirstChild("Text")
		while actor.idle and actor.model.Parent do
			task.wait(rng:NextNumber(SPEAK_MIN_GAP, SPEAK_MAX_GAP))
			if not (actor.idle and actor.model.Parent) then
				break
			end
			local line, distorted = PatientData.pickLine(actor.data)
			label.Text = line
			label.TextColor3 = distorted and Color3.fromRGB(255, 150, 150) or Color3.fromRGB(240, 240, 240)
			bubble.Enabled = true
			task.wait(SPEAK_DURATION)
			bubble.Enabled = false
		end
		bubble.Enabled = false
	end)
end

local function stopIdleBehaviour(actor)
	actor.idle = false
	local bubble = findDescendant(actor.model, "SpeechBubble")
	if bubble then
		bubble.Enabled = false
	end
end

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

local function point(x, z)
	return Vector3.new(x, world.floorY, z)
end

local function pathToCounter()
	return {
		point(world.lobbyX, world.spawnZ - 6),
		point(world.lobbyX, world.receptionZ),
		point(world.receptionEntryX, world.receptionZ),
		point(world.counterX, world.receptionZ),
	}
end

local function pathOutFromCounter()
	return {
		point(world.receptionEntryX, world.receptionZ),
		point(world.lobbyX, world.receptionZ),
		point(world.lobbyX, world.spawnZ),
		point(world.lobbyX, world.spawnZ + 5),
	}
end

local function pathCounterToRoom(entryPart)
	return {
		point(world.receptionEntryX, world.receptionZ),
		point(world.lobbyX, world.receptionZ),
		point(world.lobbyX, world.corridorZ),
		point(entryPart.Position.X, world.corridorZ),
		point(entryPart.Position.X, entryPart.Position.Z),
	}
end

local function pathRoomToExit(entryPart)
	return {
		point(entryPart.Position.X, world.corridorZ),
		point(world.lobbyX, world.corridorZ),
		point(world.lobbyX, world.receptionZ),
		point(world.lobbyX, world.spawnZ),
		point(world.lobbyX, world.spawnZ + 5),
	}
end

--------------------------------------------------------------------------------
-- Decisions
--------------------------------------------------------------------------------

local awaitingPatientId = nil
local submitted = nil

remotes.SubmitDecision.OnServerEvent:Connect(function(_player, patientId, decision)
	-- Never trust the client: only the patient currently at the counter, only
	-- the two valid decisions, and only the first one that arrives.
	if type(patientId) ~= "number" then
		return
	end
	if decision ~= "admit" and decision ~= "reject" then
		return
	end
	if patientId ~= awaitingPatientId or submitted ~= nil then
		return
	end
	submitted = decision
end)

local function waitForDecision(patientId)
	awaitingPatientId = patientId
	submitted = nil

	local deadline = os.clock() + DECISION_TIMEOUT
	while submitted == nil and os.clock() < deadline do
		task.wait(0.1)
	end

	awaitingPatientId = nil
	local decision = submitted or "timeout"
	submitted = nil
	return decision
end

--------------------------------------------------------------------------------
-- Treatment
--------------------------------------------------------------------------------

local function despawn(actor)
	if actor.model then
		actor.model:Destroy()
	end
end

local function claimRoom()
	local deadline = os.clock() + ROOM_WAIT_TIMEOUT
	while os.clock() < deadline do
		local roomId = RoomRegistry.pickRandomRoom()
		if roomId then
			return roomId
		end
		task.wait(1)
	end
	return nil
end

-- Runs on its own thread so the next patient can walk up to the counter while
-- this one is still being treated.
local function escortToTreatment(actor)
	local roomId = claimRoom()
	if not roomId then
		warn(("[Shift] no free room for %s, sending them home"):format(actor.data.name))
		walkPath(actor, pathOutFromCounter())
		despawn(actor)
		return
	end

	local entryPart = RoomRegistry.getEntryPoint(roomId)
	if not entryPart then
		warn(("[Shift] room %s has no EntryPoint"):format(roomId))
		walkPath(actor, pathOutFromCounter())
		despawn(actor)
		return
	end

	walkPath(actor, pathCounterToRoom(entryPart))
	faceDirection(actor, Vector3.new(0, 0, world.corridorZ - entryPart.Position.Z))

	local room = RoomRegistry.get(roomId)
	local sent = RoomRegistry.sendPatient(roomId, actor.data, function(outcome)
		remotes.RoomOutcome:FireAllClients({
			patientId = actor.data.id,
			patientName = actor.data.name,
			roomId = roomId,
			roomName = room.name,
			status = outcome.status,
		})
		print(("[Shift] %s in %s -> %s"):format(actor.data.name, roomId, outcome.status))

		if outcome.status == RoomRegistry.Outcome.Cured then
			walkPath(actor, pathRoomToExit(entryPart))
		else
			task.wait(1.5)
		end
		despawn(actor)
	end)

	if not sent then
		-- claimRoom saw the room free a moment ago and something took it since.
		warn(("[Shift] %s was taken before %s could enter"):format(roomId, actor.data.name))
		walkPath(actor, pathRoomToExit(entryPart))
		despawn(actor)
	end
end

--------------------------------------------------------------------------------
-- Shift loop
--------------------------------------------------------------------------------

local function serveOnePatient()
	local patient = PatientData.generate()
	local model, pivotHeight = buildPatientModel(patient)

	local actor = {
		data = patient,
		model = model,
		baseY = world.floorY + pivotHeight,
		idle = false,
	}

	model:PivotTo(CFrame.new(point(world.lobbyX, world.spawnZ) + Vector3.new(0, pivotHeight, 0)))
	model.Parent = Workspace

	print(
		("[Shift] %s arrives (%s)"):format(
			patient.name,
			patient.isAnomaly and ("АНОМАЛИЯ: " .. PatientData.describeTraits(patient)) or "обычный"
		)
	)

	walkPath(actor, pathToCounter())
	faceDirection(actor, Vector3.new(-1, 0, 0))
	startIdleBehaviour(actor)

	atCounter = { public = PatientData.toPublic(patient), model = model }
	remotes.PatientArrived:FireAllClients(atCounter.public, atCounter.model)

	local decision = waitForDecision(patient.id)
	atCounter = nil
	stopIdleBehaviour(actor)

	local correct = PatientData.isDecisionCorrect(patient, decision)
	local admitted = decision == "admit"

	-- The round is over, so the answer can safely go to the client now: this
	-- is what makes the result panel teach the player anything.
	remotes.DecisionResult:FireAllClients({
		patientId = patient.id,
		patientName = patient.name,
		decision = decision,
		correct = correct,
		isAnomaly = patient.isAnomaly,
		traits = PatientData.describeTraits(patient),
	})
	remotes.PatientLeft:FireAllClients(patient.id)

	if admitted and not patient.isAnomaly then
		task.spawn(escortToTreatment, actor)
	else
		-- Admitting an anomaly is where stage 6 puts the screamer. For now the
		-- creature simply turns around and leaves.
		task.spawn(function()
			walkPath(actor, pathOutFromCounter())
			despawn(actor)
		end)
	end
end

Players.PlayerAdded:Connect(function(player)
	if atCounter then
		remotes.PatientArrived:FireClient(player, atCounter.public, atCounter.model)
	end
end)

local function main()
	local ok, err = resolveWorld()
	if not ok then
		warn(("[Shift] %s"):format(err))
		return
	end

	print("[Shift] reception open")
	while true do
		local ran, problem = pcall(serveOnePatient)
		if not ran then
			warn(("[Shift] patient failed: %s"):format(tostring(problem)))
		end
		task.wait(NEXT_PATIENT_DELAY)
	end
end

main()

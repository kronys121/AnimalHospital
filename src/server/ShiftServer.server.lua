--[[
	Animal Hospital - Stage 2/3/4: the reception loop.

	Server Script. Brings patients in one at a time, walks them to the
	reception counter, runs the physical registration flow, routes admitted
	patients into a treatment room through RoomRegistry, and reports every
	outcome to ShiftState so it lands on the sanity bar.

	Where to put it:
		ServerScriptService -> Script (Server) -> paste this file in,
		alongside PickupSystem and ShiftState (sibling ModuleScripts it
		requires).

	Needs, and waits for:
		Workspace.Hospital                          (BuildHospital.server.lua)
		ReplicatedStorage.Shared.RoomRegistry
		ReplicatedStorage.Shared.PatientData

	Since stage 4 the loop is a round, not an endless queue: patients only
	arrive while ShiftState says the shift is running, and when it ends the
	floor is cleared and the loop idles until somebody starts a new shift
	from the results screen.

	Creates ReplicatedStorage.AnimalHospital with the RemoteEvents the
	reception UI listens to, so there is nothing to wire up by hand.

	Patients are anchored models moved with PivotTo along waypoints derived
	from the markers BuildHospital places. No Humanoid and no physics: a
	patient can never get stuck on geometry, fall over, or wander off, which
	matters more than convincing walk animation at this stage.

	Registration is physical, not a UI button: photograph the patient with
	the desk camera (the photo appears on the desk, pickable and placeable
	back down), take the photo's information to the computer, collect the
	printed card from the printer, and hand it to the patient to admit them.
	Rejecting needs none of that - it is a button right on the counter.
	Every step is a ProximityPrompt, checked and driven server-side; the
	client has no say in any of it beyond standing close enough to trigger
	one.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RoomRegistry = require(Shared:WaitForChild("RoomRegistry"))
local PatientData = require(Shared:WaitForChild("PatientData"))
local PickupSystem = require(script.Parent:WaitForChild("PickupSystem"))
local ShiftState = require(script.Parent:WaitForChild("ShiftState"))

--------------------------------------------------------------------------------
-- Tuning
--------------------------------------------------------------------------------

local WALK_SPEED = 9
local NEXT_PATIENT_DELAY = 3

-- Hard ceiling on how long one patient may stand at the counter undecided.
-- Since stage 4 the real pressure is ShiftState's idle drain, not this; it
-- only stops a forgotten patient from parking forever and stalling the queue
-- for the rest of the shift.
local DECISION_TIMEOUT = 45

-- How long to keep trying for a free treatment room before giving up and
-- sending an admitted patient home.
local ROOM_WAIT_TIMEOUT = 20

local TWITCH_MIN_GAP, TWITCH_MAX_GAP = 2.0, 4.5
local SPEAK_MIN_GAP, SPEAK_MAX_GAP = 4.0, 7.0
local SPEAK_DURATION = 2.5

-- How long the computer takes to file the card before the printer will hand
-- it over. Long enough to read as "processing", short enough not to stall
-- the queue.
local CARD_PRINT_SECONDS = 2

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
		PhotoTaken = remote("PhotoTaken"),
		DecisionResult = remote("DecisionResult"),
		RoomOutcome = remote("RoomOutcome"),
		Feedback = remote("Feedback"),
	}
end

local remotes = ensureRemotes()

-- Remembered so a player joining mid-patient still gets a registration card
-- instead of an empty screen until the next arrival.
local atCounter = nil

-- Every patient currently inside the building, whichever thread is moving
-- them. Ending a shift has to be able to clear the floor in one go, and a
-- patient can be anywhere between the street door and a treatment room.
local liveActors = {}

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
	local camera = findDescendant(reception, "ReceptionCamera")
	local photoTray = findDescendant(reception, "PhotoTray")
	local computerDesk = findDescendant(reception, "ComputerDesk")
	local printer = findDescendant(reception, "Printer")
	local cardTray = findDescendant(reception, "CardTray")
	local rejectButton = findDescendant(reception, "RejectButton")
	local coffeeMachine = findDescendant(reception, "CoffeeMachine")
	if
		not (
			spawnMarker
			and receptionEntry
			and desk
			and corridorEntry
			and lobbyFloor
			and camera
			and photoTray
			and computerDesk
			and printer
			and cardTray
			and rejectButton
			and coffeeMachine
		)
	then
		return false,
			"Hospital is missing one of PatientSpawn / EntryPoint / ReceptionDesk / Floor / "
				.. "ReceptionCamera / PhotoTray / ComputerDesk / Printer / CardTray / RejectButton / "
				.. "CoffeeMachine"
	end

	world.floorY = lobbyFloor.Position.Y + lobbyFloor.Size.Y / 2
	world.lobbyX = spawnMarker.Position.X
	world.spawnZ = spawnMarker.Position.Z
	world.receptionZ = receptionEntry.Position.Z
	world.receptionEntryX = receptionEntry.Position.X
	world.corridorZ = corridorEntry.Position.Z
	-- Patients queue on the lobby side of the counter, facing the window.
	world.counterX = desk.Position.X + desk.Size.X / 2 + 3

	world.cameraPrompt = camera:FindFirstChild("PhotoPrompt")
	world.photoHome = photoTray.CFrame
	-- The tray itself, not just where it is: the "put it back" prompt hangs on
	-- the tray rather than on the item in your hands (see wirePickup).
	world.photoTray = photoTray
	world.computerPrompt = computerDesk:FindFirstChild("ComputerPrompt")
	world.printerPrompt = printer:FindFirstChild("PrinterPrompt")
	world.cardHome = cardTray.CFrame
	world.cardTray = cardTray
	world.rejectPrompt = rejectButton:FindFirstChild("RejectPrompt")
	world.coffeePrompt = coffeeMachine:FindFirstChild("CoffeePrompt")
	if
		not (
			world.cameraPrompt
			and world.computerPrompt
			and world.printerPrompt
			and world.rejectPrompt
			and world.coffeePrompt
		)
	then
		return false, "Reception furniture is missing one of its ProximityPrompts"
	end

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

-- Lays the patient on a bed part.
--
-- The model is built standing, feet at local Y = 0, facing local -Z, with its
-- PrimaryPart (and therefore its pivot) at the body's centre, BODY.bodyY *
-- scale above the feet. Tipping it a quarter turn about its own X axis puts
-- it on its back, face up: after the tip the model's local +Z (its back) is
-- what points at the sky, so the half-thickness that has to clear the
-- mattress is the body's DEPTH, not its height - that is the 0.8 * scale
-- below, and getting it wrong is exactly what makes a patient hover over the
-- bed instead of lying on it. The head, at local +Y, swings to local +Z,
-- which is behind the model, so the model is aimed AWAY from where its head
-- should end up.
local LIE_HALF_DEPTH = 0.8

local function lieOnBed(actor, bed, headDirection)
	local model = actor.model
	if not model.Parent then
		return
	end

	local scale = actor.scale or 1
	local top = bed.Position.Y + bed.Size.Y / 2
	local restAt = Vector3.new(bed.Position.X, top + LIE_HALF_DEPTH * scale, bed.Position.Z)
	local flat = Vector3.new(headDirection.X, 0, headDirection.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, 1)
	end

	model:PivotTo(CFrame.lookAt(restAt, restAt - flat.Unit) * CFrame.Angles(math.pi / 2, 0, 0))
	actor.onBed = true
end

-- Puts a patient that was lying down back on its feet before it walks
-- anywhere: walkPath would otherwise carry the tipped rotation into the first
-- step, and a patient that never has to move again would stay tipped forever.
local function standUp(actor, position)
	local model = actor.model
	if not model.Parent then
		return
	end
	model:PivotTo(CFrame.new(Vector3.new(position.X, actor.baseY, position.Z)))
	actor.onBed = false
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
-- Registration flow: camera -> photo -> computer -> printer -> card -> patient
--------------------------------------------------------------------------------
-- Admitting a patient is a small chain of world interactions rather than a UI
-- button; rejecting stays a single button on the counter, since it needs
-- none of the paperwork. `session` is the patient currently at the counter;
-- everything here reads and writes it, and the prompt handlers below are
-- connected once (the furniture is static) and just check it on every press.

local awaitingPatientId = nil
local submitted = nil
local session = nil

-- Physical items, created once in setupRegistrationFlow and reused for every
-- patient (reset between them) rather than spawned fresh each time.
local photoItem, cardItem

local function sendFeedback(player, text)
	remotes.Feedback:FireClient(player, text)
end

-- The photo/card parts are flat and thin (built to lie on the desk, shown on
-- their Top face), but PickupSystem holds an item in front of the player's
-- Head with no extra rotation, so while held it faces whichever way the
-- player happens to be looking, not necessarily up. Rather than guess that
-- rotation, buildPhotoItem/buildCardItem put the same display on three faces
-- (Top, Front, Back), so one of them faces the camera in both poses. These
-- helpers loop over every SurfaceGui on the part rather than assuming one.

-- Same framing technique the client's old photo preview used: aim from the
-- model's own LookVector so the animal faces the shot whichever way it
-- happens to be standing.
local function renderPhoto(part, patientModel)
	for _, gui in ipairs(part:GetChildren()) do
		if gui:IsA("SurfaceGui") then
			local viewport = gui:FindFirstChildOfClass("ViewportFrame")
			if viewport then
				viewport:ClearAllChildren()
				local camera = Instance.new("Camera")
				camera.Parent = viewport
				viewport.CurrentCamera = camera

				local clone = patientModel:Clone()
				for _, descendant in ipairs(clone:GetDescendants()) do
					if descendant:IsA("BillboardGui") then
						descendant:Destroy()
					end
				end
				clone.Parent = viewport

				local pivot = clone:GetPivot()
				local _, size = clone:GetBoundingBox()
				local distance = math.max(size.X, size.Y, size.Z) * 1.9
				local target = pivot.Position + Vector3.new(0, size.Y * 0.12, 0)
				local eye = target
					+ pivot.LookVector * distance
					+ pivot.RightVector * (distance * 0.28)
					+ Vector3.new(0, size.Y * 0.18, 0)
				camera.CFrame = CFrame.lookAt(eye, target)
			end
		end
	end
end

local function clearPhoto()
	for _, gui in ipairs(photoItem:GetChildren()) do
		if gui:IsA("SurfaceGui") then
			local viewport = gui:FindFirstChildOfClass("ViewportFrame")
			if viewport then
				viewport:ClearAllChildren()
			end
		end
	end
end

local function setCardText(text)
	for _, gui in ipairs(cardItem:GetChildren()) do
		if gui:IsA("SurfaceGui") then
			local label = gui:FindFirstChild("Text")
			if label then
				label.Text = text
			end
		end
	end
end

-- Reset before each new patient: force both items back to the desk (even if
-- someone is mid-carry) so a leftover photo or card from the last patient
-- never bleeds into the next one's flow.
local function resetRegistration(patient, model)
	session = { patient = patient, model = model, photographed = false, cardPrinting = false, cardPrinted = false }

	PickupSystem.placeDown(photoItem)
	clearPhoto()
	PickupSystem.setAvailable(photoItem, false)

	PickupSystem.placeDown(cardItem)
	cardItem.Transparency = 1
	cardItem.CanCollide = false
	PickupSystem.setAvailable(cardItem, false)
end

local function clearSession()
	session = nil
end

-- Called when a shift ends: send everyone home immediately and put the desk
-- back the way it started, so the next shift begins on an empty floor rather
-- than inheriting half-registered leftovers.
local function clearFloor()
	for actor in pairs(liveActors) do
		liveActors[actor] = nil
		actor.idle = false
		if actor.model then
			actor.model:Destroy()
		end
	end

	if atCounter then
		remotes.PatientLeft:FireAllClients(atCounter.public.id)
		atCounter = nil
	end
	clearSession()

	if photoItem then
		PickupSystem.placeDown(photoItem)
		clearPhoto()
		PickupSystem.setAvailable(photoItem, false)
	end
	if cardItem then
		PickupSystem.placeDown(cardItem)
		cardItem.Transparency = 1
		PickupSystem.setAvailable(cardItem, false)
	end
end

-- Attaches the "hand over the card" prompt to this patient specifically -
-- each patient is a fresh model, so this runs once per arrival rather than
-- being set up in setupRegistrationFlow with the static furniture.
local function attachHandoverPrompt(actor)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HandoverPrompt"
	prompt.ActionText = "Отдать карточку"
	prompt.ObjectText = actor.data.name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	-- Same reason as every other prompt in the build: a clickable prompt
	-- steals the mouse in first person.
	prompt.ClickablePrompt = false
	prompt.Parent = actor.model.PrimaryPart

	prompt.Triggered:Connect(function(player)
		if not session or session.patient.id ~= actor.data.id or submitted ~= nil then
			return
		end
		if not PickupSystem.isHeldBy(cardItem, player) then
			sendFeedback(player, "Сначала возьмите карточку из принтера.")
			return
		end
		submitted = "admit"
	end)
end

local function waitForDecision(patientId)
	awaitingPatientId = patientId
	submitted = nil

	local generation = ShiftState.getGeneration()
	local deadline = os.clock() + DECISION_TIMEOUT
	while submitted == nil and os.clock() < deadline do
		-- The shift can end under this patient (the clock ran out, or sanity
		-- hit zero). "aborted" is not a decision and must not score.
		if not ShiftState.isRunning() or ShiftState.getGeneration() ~= generation then
			awaitingPatientId = nil
			submitted = nil
			return "aborted"
		end
		task.wait(0.1)
	end

	awaitingPatientId = nil
	local decision = submitted or "timeout"
	submitted = nil
	return decision
end

-- Connected once; the furniture and its prompts persist across patients, so
-- this only needs wiring up a single time in setupRegistrationFlow.
local function connectRegistrationPrompts()
	world.cameraPrompt.Triggered:Connect(function(player)
		if not session then
			return
		end
		renderPhoto(photoItem, session.model)
		session.photographed = true
		PickupSystem.setAvailable(photoItem, true)
		remotes.PhotoTaken:FireAllClients(session.patient.id)
	end)

	world.computerPrompt.Triggered:Connect(function(player)
		if not session then
			return
		end
		if not session.photographed then
			sendFeedback(player, "Сначала сфотографируйте пациента.")
			return
		end
		if session.cardPrinting or session.cardPrinted then
			sendFeedback(player, "Карточка уже оформляется.")
			return
		end
		session.cardPrinting = true
		local thisSession = session
		task.delay(CARD_PRINT_SECONDS, function()
			if session == thisSession then
				session.cardPrinting = false
				session.cardPrinted = true
			end
		end)
	end)

	world.printerPrompt.Triggered:Connect(function(player)
		if not session then
			return
		end
		if not session.cardPrinted then
			sendFeedback(player, session.cardPrinting and "Карточка ещё печатается." or "Сначала оформите карточку на компьютере.")
			return
		end
		if cardItem.Transparency == 0 then
			return -- already collected from the printer
		end
		setCardText(session.patient.name)
		cardItem.Transparency = 0
		cardItem.CanCollide = false
		PickupSystem.setAvailable(cardItem, true)
	end)

	world.rejectPrompt.Triggered:Connect(function(_player)
		if not session or submitted ~= nil then
			return
		end
		submitted = "reject"
	end)

	-- Coffee is the one thing that puts sanity back, and it is deliberately
	-- not at the counter: the walk is the price. ShiftState owns the number
	-- and the cooldown.
	world.coffeePrompt.Triggered:Connect(function(player)
		local poured, secondsLeft = ShiftState.drinkCoffee()
		if poured then
			sendFeedback(player, "Кофе. Стало полегче.")
		elseif secondsLeft > 0 then
			sendFeedback(player, ("Кофе ещё варится: %d с."):format(secondsLeft))
		end
	end)
end

-- The two carryable items share this pickup/place wiring: a Pickup prompt on
-- the item, and a Place prompt on the tray the item belongs to.
--
-- The place prompt used to live on the item as well, and that was a bug the
-- player felt rather than saw: a carried item floats about 1.6 studs in front
-- of the head, so its prompt is always the nearest one in the world and
-- always wins E - including when the player is standing in front of a patient
-- trying to hand the card over, or at the computer, or at the printer. Putting
-- it on the tray means "put it back on the desk" is offered where the desk is,
-- and nothing competes with the prompt the player is actually looking at.
--
-- PickupSystem.register is handed both prompts and keeps exactly one of them
-- enabled from then on - this file never touches ProximityPrompt.Enabled on
-- either of them again, since doing that from two places (a caller poking
-- .Enabled directly *and* PickupSystem reacting to hold state) is exactly
-- what let both prompts end up enabled together before.
local function wirePickup(part, homeCFrame, trayPart, placeText)
	local pickupPrompt = Instance.new("ProximityPrompt")
	pickupPrompt.Name = "PickupPrompt"
	pickupPrompt.ActionText = "Взять"
	pickupPrompt.HoldDuration = 0
	pickupPrompt.MaxActivationDistance = 8
	pickupPrompt.RequiresLineOfSight = false
	pickupPrompt.ClickablePrompt = false
	pickupPrompt.Parent = part

	local placePrompt = Instance.new("ProximityPrompt")
	placePrompt.Name = "PlacePrompt"
	placePrompt.ActionText = placeText or "Положить на стол"
	placePrompt.HoldDuration = 0
	placePrompt.MaxActivationDistance = 8
	placePrompt.RequiresLineOfSight = false
	placePrompt.ClickablePrompt = false
	placePrompt.Parent = trayPart

	PickupSystem.register(part, homeCFrame, { pickup = pickupPrompt, place = placePrompt })

	pickupPrompt.Triggered:Connect(function(player)
		PickupSystem.pickUp(part, player)
	end)
	placePrompt.Triggered:Connect(function(player)
		if PickupSystem.isHeldBy(part, player) then
			PickupSystem.placeDown(part)
		end
	end)
end

-- Top: visible resting flat on the desk. Front/Back: whichever one ends up
-- facing the player is visible while held, since a held item inherits the
-- holder's Head orientation with no extra rotation applied (see the note
-- above renderPhoto) - putting the same content on both sides means it does
-- not matter which one that turns out to be.
local DISPLAY_FACES = { Enum.NormalId.Top, Enum.NormalId.Front, Enum.NormalId.Back }

local function addDisplayFace(part, face)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Display"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Parent = part
	return gui
end

local function buildPhotoItem()
	local part = Instance.new("Part")
	part.Name = "Photo"
	part.Size = Vector3.new(2, 0.1, 2.6)
	part.CFrame = world.photoHome
	part.Anchored = true
	part.CanCollide = false
	part.Color = Color3.fromRGB(250, 250, 245)
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = Workspace

	for _, face in ipairs(DISPLAY_FACES) do
		local gui = addDisplayFace(part, face)
		local viewport = Instance.new("ViewportFrame")
		viewport.Size = UDim2.fromScale(1, 1)
		viewport.BackgroundColor3 = Color3.fromRGB(30, 30, 34)
		viewport.Parent = gui
	end

	wirePickup(part, world.photoHome, world.photoTray, "Положить фото")
	PickupSystem.setAvailable(part, false)
	return part
end

local function buildCardItem()
	local part = Instance.new("Part")
	part.Name = "PatientCard"
	part.Size = Vector3.new(1.6, 0.1, 1)
	part.CFrame = world.cardHome
	part.Anchored = true
	part.CanCollide = false
	part.Color = Color3.fromRGB(250, 250, 245)
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 1
	part.Parent = Workspace

	for _, face in ipairs(DISPLAY_FACES) do
		local gui = addDisplayFace(part, face)
		local label = Instance.new("TextLabel")
		label.Name = "Text"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(20, 20, 24)
		label.Text = ""
		label.Parent = gui
	end

	wirePickup(part, world.cardHome, world.cardTray, "Положить карточку")
	PickupSystem.setAvailable(part, false)
	return part
end

local function setupRegistrationFlow()
	photoItem = buildPhotoItem()
	cardItem = buildCardItem()
	connectRegistrationPrompts()
end

--------------------------------------------------------------------------------
-- Treatment
--------------------------------------------------------------------------------

local function despawn(actor)
	liveActors[actor] = nil
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
	local generation = ShiftState.getGeneration()
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
	if not actor.model.Parent then
		despawn(actor)
		return
	end
	faceDirection(actor, Vector3.new(0, 0, world.corridorZ - entryPart.Position.Z))

	-- Onto the bed. Everything that happens in a ward - the scan, the
	-- medicine, and whatever an anomaly does - happens to a patient lying
	-- down, so this is not decoration: the room handler starts only once the
	-- patient is actually on the bed.
	local roomModel = RoomRegistry.getModel(roomId)
	local bed = roomModel and findDescendant(roomModel, "PatientBed")
	local approach = nil
	if bed then
		local toDoor = entryPart.Position - bed.Position
		toDoor = Vector3.new(toDoor.X, 0, toDoor.Z)
		if toDoor.Magnitude > 1e-3 then
			toDoor = toDoor.Unit
		else
			toDoor = Vector3.new(0, 0, 1)
		end
		approach = bed.Position + toDoor * 4
		walkPath(actor, { point(approach.X, approach.Z) })
		if not actor.model.Parent then
			despawn(actor)
			return
		end
		-- Head at the far end of the bed, away from the door.
		lieOnBed(actor, bed, -toDoor)
	else
		warn(("[Shift] room %s has no PatientBed - patient stays on its feet"):format(roomId))
	end

	local room = RoomRegistry.get(roomId)
	local sent = RoomRegistry.sendPatient(roomId, actor.data, function(outcome)
		-- A room minigame started in the previous shift can still finish after
		-- that shift ended; its result belongs to the shift it began in.
		if not ShiftState.isRunning() or ShiftState.getGeneration() ~= generation then
			despawn(actor)
			return
		end

		remotes.RoomOutcome:FireAllClients({
			patientId = actor.data.id,
			patientName = actor.data.name,
			roomId = roomId,
			roomName = room.name,
			status = outcome.status,
		})
		ShiftState.applyRoomOutcome(outcome.status)
		print(("[Shift] %s in %s -> %s"):format(actor.data.name, roomId, outcome.status))

		if outcome.status == RoomRegistry.Outcome.Cured then
			-- Off the bed first: walkPath would otherwise start the walk home
			-- from the lying pose.
			standUp(actor, approach or actor.model:GetPivot().Position)
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

	local species = PatientData.getSpecies(patient.speciesId)
	local actor = {
		data = patient,
		model = model,
		baseY = world.floorY + pivotHeight,
		-- Needed to lay this patient on a bed: every dimension of the model is
		-- multiplied by its species scale, including the body depth that
		-- decides how high above the mattress the pivot has to sit.
		scale = species and species.scale or 1,
		idle = false,
		onBed = false,
	}
	liveActors[actor] = true

	model:PivotTo(CFrame.new(point(world.lobbyX, world.spawnZ) + Vector3.new(0, pivotHeight, 0)))
	model.Parent = Workspace

	print(
		("[Shift] %s arrives (%s)"):format(
			patient.name,
			patient.isAnomaly and ("АНОМАЛИЯ: " .. PatientData.describeTraits(patient)) or "обычный"
		)
	)

	walkPath(actor, pathToCounter())
	if not model.Parent then
		-- The shift ended while this one was still walking in; clearFloor
		-- destroyed the model out from under the walk.
		despawn(actor)
		return
	end
	faceDirection(actor, Vector3.new(-1, 0, 0))
	startIdleBehaviour(actor)
	attachHandoverPrompt(actor)

	atCounter = { public = PatientData.toPublic(patient), model = model }
	remotes.PatientArrived:FireAllClients(atCounter.public, atCounter.model)
	resetRegistration(patient, model)

	-- Sanity drains while a patient stands here undecided (after a grace
	-- period - see ShiftState). Doing the paperwork is not idling; the drain
	-- stops the moment the decision lands, whichever way it went.
	ShiftState.setIdle(true)
	local decision = waitForDecision(patient.id)
	ShiftState.setIdle(false)

	atCounter = nil
	clearSession()
	stopIdleBehaviour(actor)

	if decision == "aborted" then
		-- The shift ended while this patient was waiting; clearFloor has
		-- already sent them home, and nothing about them counts.
		despawn(actor)
		return
	end

	local correct = PatientData.isDecisionCorrect(patient, decision)
	local admitted = decision == "admit"

	ShiftState.applyDecision(decision, correct)

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

	if not ShiftState.isRunning() then
		-- That decision was the one that ended the shift. clearFloor is
		-- already emptying the building; do not start a treatment run into a
		-- shift that is over.
		despawn(actor)
		return
	end

	if admitted then
		-- Anomalies go to a ward exactly like anyone else the player admitted.
		-- That is the point: the mistake is not punished at the counter with a
		-- creature politely leaving, it walks past you into the hospital and
		-- lies down in a bed, and the room decides what happens next.
		task.spawn(escortToTreatment, actor)
	else
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
	setupRegistrationFlow()

	ShiftState.onEnded(clearFloor)

	print("[Shift] reception open")
	ShiftState.start()

	while true do
		if ShiftState.isRunning() then
			local ran, problem = pcall(serveOnePatient)
			if not ran then
				warn(("[Shift] patient failed: %s"):format(tostring(problem)))
			end
			task.wait(NEXT_PATIENT_DELAY)
		else
			-- Between shifts: the results screen is up and the floor is
			-- empty. Nothing to do until somebody presses "заново".
			task.wait(0.25)
		end
	end
end

main()

--[[
	Animal Hospital - Stage 0: hospital shell.

	Server Script. Runs by itself when the game starts and builds the whole
	hospital geometry (entrance, lobby, reception, corridor, four exam rooms,
	break room) under Workspace.Hospital. Stage 0 is scene only: no gameplay
	logic here.

	Where to put it:
		ServerScriptService -> Script (Server) -> paste this file in.
		Nothing else to do, just press Play.

	After building it runs the stage 1 room check, if
	ReplicatedStorage.Shared.RoomRegistry exists. Without that module the
	build still works and the check is skipped with a warning.

	The hospital is rebuilt on every server start, so editing it by hand in
	Studio is pointless: change the ROOMS table below instead.

	Floor plan is a T: the street entrance and Lobby sit south of the main
	corridor and form the stem of the T; the corridor is the crossbar, with
	exam rooms and the break room flanking it left and right. Patients walk
	in from the south, see Reception on their left as they cross the Lobby,
	then continue straight ahead into the corridor junction, where rooms
	branch left and right.

	Structure produced (every room is identical in shape, so stage 1
	RoomRegistry can walk them generically):

		Workspace.Hospital
			Corridor            Model  (Structure, EntryPoint)
			Rooms               Folder
				Lobby           Model  (Structure, EntryPoint, InteractionZone, RoomLabel, chairs, PatientSpawn)
				Reception       Model  (Structure, EntryPoint, InteractionZone, RoomLabel, desk, PlayerSpawn)
				BasicMedical    Model  (Structure, EntryPoint, InteractionZone, RoomLabel)
				XRay            Model
				HeartMonitor    Model
				Surgery         Model
				BreakRoom       Model

	Each room model carries attributes: RoomId, DisplayName, RoomNumber (optional).
]]

local Workspace = game:GetService("Workspace")

--------------------------------------------------------------------------------
-- Dimensions
--------------------------------------------------------------------------------

local WALL_HEIGHT = 16
local WALL_THICKNESS = 1
local FLOOR_THICKNESS = 1
local CEILING_THICKNESS = 1
local DOOR_HEIGHT = 10

-- Height of the hospital's floor surface above the world origin.
-- Studio's Baseplate is 512 x 20 x 512 at (0, -10, 0), so its top face sits
-- exactly on Y = 0; flat-terrain templates do the same. A floor whose top
-- face is also on Y = 0 gives two large coplanar surfaces fighting for the
-- same depth, which is what makes the whole floor flicker. Lifting the
-- building clear of Y = 0 removes the coincidence whatever the ground is.
-- EntranceStep bridges the resulting step at the front door.
local BASE_Y = 2

-- Small vertical gap between the floor and any flat decorative marker sitting
-- on it (EntryPoint, InteractionZone, PatientSpawn, the player spawn pad).
-- Same z-fighting problem one level down: without it the marker's bottom face
-- and the floor's top face occupy the exact same plane.
local MARKER_LIFT = 0.1

local CORRIDOR_HALF_WIDTH = 11
local CORRIDOR_X_MIN = -129
local CORRIDOR_X_MAX = 129

local FLOOR_COLOR = Color3.fromRGB(198, 198, 196)
local CORRIDOR_FLOOR_COLOR = Color3.fromRGB(172, 180, 180)
local WALL_COLOR = Color3.fromRGB(163, 168, 173)
local CEILING_COLOR = Color3.fromRGB(222, 222, 220)

--------------------------------------------------------------------------------
-- Room table
--------------------------------------------------------------------------------
-- `doors` lists every doorway a room's walls need. Each entry is
-- { side, width, center = 0, owns = true }. `side` is the wall the door sits
-- in; `center` offsets it along that wall (0 = centred); `owns = true` means
-- this room builds that wall (with the doorway cut into it); `owns = false`
-- means a neighbour (another room, or the corridor) builds it instead, so
-- this room must not touch that wall at all and create overlapping geometry.
--
-- `signSide` picks which wall carries the RoomLabel signboard; rooms with no
-- side worth labelling (none here) can omit it.

local ROOMS = {
	{
		id = "Lobby",
		name = "Lobby",
		signText = "ENTRANCE",
		center = Vector3.new(0, 0, 26),
		sizeX = 30,
		sizeZ = 30,
		doors = {
			{ side = "South", width = 12, owns = true }, -- street entrance
			{ side = "West", width = 16, owns = false }, -- into Reception; Reception builds this wall
			{ side = "North", width = 22, owns = false }, -- into the corridor junction; corridor builds this wall
		},
		signSide = "South",
		accent = Color3.fromRGB(120, 130, 140),
		entryPoint = Vector3.new(0, 0, 37),
		interactionCenter = Vector3.new(0, 0, 26),
		interactionSizeX = 26,
		interactionSizeZ = 26,
	},
	{
		id = "Reception",
		name = "Reception",
		signText = "RECEPTION",
		center = Vector3.new(-43, 0, 26),
		sizeX = 56,
		sizeZ = 30,
		doors = {
			{ side = "East", width = 16, owns = true }, -- into the Lobby
		},
		signSide = "East",
		accent = Color3.fromRGB(86, 148, 200),
		interactionCenter = Vector3.new(-20, 0, 26),
		interactionSizeX = 10,
		interactionSizeZ = 22,
	},
	{
		id = "BasicMedical",
		name = "Basic Medical / DNA",
		signText = "ROOM 1\nBASIC MEDICAL / DNA",
		roomNumber = 1,
		center = Vector3.new(-96, 0, -26),
		sizeX = 34,
		sizeZ = 30,
		doors = {
			{ side = "South", width = 16, owns = false }, -- corridor builds this wall
		},
		signSide = "South",
		accent = Color3.fromRGB(90, 180, 120),
	},
	{
		id = "XRay",
		name = "X-Ray",
		signText = "ROOM 2\nX-RAY",
		roomNumber = 2,
		center = Vector3.new(-96, 0, 26),
		sizeX = 34,
		sizeZ = 30,
		doors = {
			{ side = "North", width = 16, owns = false },
		},
		signSide = "North",
		accent = Color3.fromRGB(120, 140, 210),
	},
	{
		id = "HeartMonitor",
		name = "Heart Monitor",
		signText = "ROOM 7\nHEART MONITOR",
		roomNumber = 7,
		center = Vector3.new(96, 0, -26),
		sizeX = 34,
		sizeZ = 30,
		doors = {
			{ side = "South", width = 16, owns = false },
		},
		signSide = "South",
		accent = Color3.fromRGB(210, 100, 110),
	},
	{
		id = "Surgery",
		name = "Surgery",
		signText = "ROOM 8\nSURGERY",
		roomNumber = 8,
		center = Vector3.new(96, 0, 26),
		sizeX = 34,
		sizeZ = 30,
		doors = {
			{ side = "North", width = 16, owns = false },
		},
		signSide = "North",
		accent = Color3.fromRGB(200, 160, 90),
	},
	{
		id = "BreakRoom",
		name = "Break Room",
		signText = "BREAK ROOM\n/ SHOP",
		center = Vector3.new(146, 0, 0),
		sizeX = 34,
		sizeZ = 34,
		doors = {
			{ side = "West", width = 18, owns = true },
		},
		signSide = "West",
		accent = Color3.fromRGB(150, 120, 190),
	},
}

-- Outward normal of each wall, pointing away from the room centre.
local OUTWARD = {
	North = Vector3.new(0, 0, -1),
	South = Vector3.new(0, 0, 1),
	East = Vector3.new(1, 0, 0),
	West = Vector3.new(-1, 0, 0),
}

-- Yaw that turns a part's Front face (local -Z) towards the outside of that wall.
local SIGN_YAW = {
	North = 0,
	South = math.pi,
	East = -math.pi / 2,
	West = math.pi / 2,
}

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

local function newPart(name, parent, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function wallSegmentAlongX(parent, x1, x2, z, yBottom, yTop, name)
	local length = x2 - x1
	local height = yTop - yBottom
	if length <= 0.05 or height <= 0.05 then
		return nil
	end
	return newPart(
		name,
		parent,
		Vector3.new(length, height, WALL_THICKNESS),
		CFrame.new((x1 + x2) / 2, BASE_Y + yBottom + height / 2, z),
		WALL_COLOR,
		Enum.Material.Concrete
	)
end

local function wallSegmentAlongZ(parent, z1, z2, x, yBottom, yTop, name)
	local length = z2 - z1
	local height = yTop - yBottom
	if length <= 0.05 or height <= 0.05 then
		return nil
	end
	return newPart(
		name,
		parent,
		Vector3.new(WALL_THICKNESS, height, length),
		CFrame.new(x, BASE_Y + yBottom + height / 2, (z1 + z2) / 2),
		WALL_COLOR,
		Enum.Material.Concrete
	)
end

local function sortedGaps(gaps)
	local copy = {}
	for index, gap in ipairs(gaps or {}) do
		copy[index] = gap
	end
	table.sort(copy, function(a, b)
		return a.center < b.center
	end)
	return copy
end

-- Wall running along the X axis at a fixed Z, with doorways cut out of it.
local function buildWallAlongX(parent, z, xMin, xMax, gaps)
	local cursor = xMin
	for _, gap in ipairs(sortedGaps(gaps)) do
		local gapStart = gap.center - gap.width / 2
		local gapEnd = gap.center + gap.width / 2
		wallSegmentAlongX(parent, cursor, gapStart, z, 0, WALL_HEIGHT, "Wall")
		wallSegmentAlongX(parent, gapStart, gapEnd, z, DOOR_HEIGHT, WALL_HEIGHT, "Lintel")
		cursor = gapEnd
	end
	wallSegmentAlongX(parent, cursor, xMax, z, 0, WALL_HEIGHT, "Wall")
end

-- Wall running along the Z axis at a fixed X, with doorways cut out of it.
local function buildWallAlongZ(parent, x, zMin, zMax, gaps)
	local cursor = zMin
	for _, gap in ipairs(sortedGaps(gaps)) do
		local gapStart = gap.center - gap.width / 2
		local gapEnd = gap.center + gap.width / 2
		wallSegmentAlongZ(parent, cursor, gapStart, x, 0, WALL_HEIGHT, "Wall")
		wallSegmentAlongZ(parent, gapStart, gapEnd, x, DOOR_HEIGHT, WALL_HEIGHT, "Lintel")
		cursor = gapEnd
	end
	wallSegmentAlongZ(parent, cursor, zMax, x, 0, WALL_HEIGHT, "Wall")
end

local function buildFloor(parent, center, sizeX, sizeZ, color)
	return newPart(
		"Floor",
		parent,
		Vector3.new(sizeX, FLOOR_THICKNESS, sizeZ),
		CFrame.new(center.X, BASE_Y - FLOOR_THICKNESS / 2, center.Z),
		color,
		Enum.Material.SmoothPlastic
	)
end

local function buildCeiling(parent, center, sizeX, sizeZ)
	return newPart(
		"Ceiling",
		parent,
		Vector3.new(sizeX, CEILING_THICKNESS, sizeZ),
		CFrame.new(center.X, BASE_Y + WALL_HEIGHT + CEILING_THICKNESS / 2, center.Z),
		CEILING_COLOR,
		Enum.Material.SmoothPlastic
	)
end

local function buildMarker(name, parent, position, sizeX, sizeZ, height, color, transparency)
	local part = newPart(
		name,
		parent,
		Vector3.new(sizeX, height, sizeZ),
		CFrame.new(position.X, BASE_Y + position.Y + MARKER_LIFT + height / 2, position.Z),
		color,
		Enum.Material.SmoothPlastic
	)
	part.CanCollide = false
	part.CastShadow = false
	part.Transparency = transparency
	return part
end

local function buildSign(parent, room, side)
	local halfX = room.sizeX / 2
	local halfZ = room.sizeZ / 2
	local outward = OUTWARD[side]
	local isAlongZ = (side == "East" or side == "West")
	local wallOffset = isAlongZ and halfX or halfZ
	local surface = room.center + outward * (wallOffset + WALL_THICKNESS / 2 + 0.3)

	local sign = newPart(
		"RoomLabel",
		parent,
		Vector3.new(10, 3, 0.4),
		CFrame.new(surface.X, BASE_Y + (DOOR_HEIGHT + WALL_HEIGHT) / 2, surface.Z) * CFrame.Angles(0, SIGN_YAW[side], 0),
		room.accent,
		Enum.Material.SmoothPlastic
	)
	sign.CanCollide = false
	sign.CanQuery = false

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Display"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Parent = sign

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Text = room.signText
	label.Parent = gui

	return sign
end

--------------------------------------------------------------------------------
-- Lobby furniture
--------------------------------------------------------------------------------
-- One row of chairs along the east wall, facing the Reception door across
-- the room. The centre of the Lobby, from the street entrance (south) to the
-- corridor junction (north), stays clear for foot traffic.

local function buildLobbyFurniture(parent, room)
	local chairColor = Color3.fromRGB(196, 168, 120)
	local seatHeight = 1.2
	local backHeight = 3
	local seatX = 10
	local backX = 11.5
	local rowZs = { 17, 23, 29, 35 }

	for _, z in ipairs(rowZs) do
		newPart(
			"ChairSeat",
			parent,
			Vector3.new(3, seatHeight, 3),
			CFrame.new(seatX, BASE_Y + seatHeight / 2, z),
			chairColor,
			Enum.Material.Fabric
		)
		newPart(
			"ChairBack",
			parent,
			Vector3.new(0.5, backHeight, 3),
			CFrame.new(backX, BASE_Y + backHeight / 2, z),
			chairColor,
			Enum.Material.Fabric
		)
	end

	buildMarker("PatientSpawn", parent, Vector3.new(0, 0, 37), 4, 4, 0.4, room.accent, 0.5)

	-- The building sits BASE_Y above the ground, so the street entrance needs
	-- an intermediate step: ground -> step -> floor, one stud at a time, which
	-- a default humanoid walks over without jumping.
	local doorHalfWidth = 6
	newPart(
		"EntranceStep",
		parent,
		Vector3.new(doorHalfWidth * 2 + 4, 1, 5),
		CFrame.new(0, BASE_Y - 1.5, 43.5),
		FLOOR_COLOR,
		Enum.Material.SmoothPlastic
	)
end

--------------------------------------------------------------------------------
-- Reception furniture
--------------------------------------------------------------------------------
-- No glass window: the counter is open so the player and the patient can see
-- and hear each other directly, which the registration workflow depends on.
-- Along the west wall, away from the queue: a camera on the counter for
-- photographing the patient, a computer desk to file the card, and a printer
-- to collect it. Gaps at both ends of the counter let the player walk around
-- it towards the corridor door.

local function newPrompt(parent, name, actionText, objectText, maxDistance)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.ObjectText = objectText or ""
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = maxDistance or 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	return prompt
end

local function buildReceptionFurniture(parent, room)
	local deskX = -24
	local deskZ = room.center.Z

	local desk = newPart(
		"ReceptionDesk",
		parent,
		Vector3.new(2, 3, 20),
		CFrame.new(deskX, BASE_Y + 1.5, deskZ),
		Color3.fromRGB(120, 96, 74),
		Enum.Material.Wood
	)

	-- Desk-top height, for props that sit on the counter rather than the floor.
	local deskTopY = 3

	-- Camera sits on the counter. ShiftServer/RegistrationFlow enables the
	-- prompt only while a patient is waiting at the counter.
	local camera = newPart(
		"ReceptionCamera",
		parent,
		Vector3.new(1.2, 1, 1.2),
		CFrame.new(deskX, BASE_Y + deskTopY + 0.5, deskZ - 4),
		Color3.fromRGB(40, 42, 46),
		Enum.Material.Metal
	)
	camera.CanCollide = false
	newPrompt(camera, "PhotoPrompt", "Сфотографировать", "Камера", 8)

	-- Where the developed photo appears after a shot, and where it goes back
	-- to when the player places it down again. Sits on the counter, not the
	-- floor, so the Y offset is the desk top height, not 0.
	buildMarker(
		"PhotoTray",
		parent,
		Vector3.new(deskX, deskTopY, deskZ - 1),
		2,
		2,
		0.05,
		Color3.fromRGB(235, 235, 230),
		0.3
	)

	-- Computer desk top height, for the monitor standing on it. Declared
	-- before its first use: a local declared further down would leave the
	-- reference above resolving to a nil global instead.
	local computerDeskTopY = 2.4

	-- Not collidable: the player has to stand right up against these to reach
	-- their prompts, and a solid box there is exactly what makes a first-person
	-- character's camera judder against the collision instead of settling.
	local computerDesk = newPart(
		"ComputerDesk",
		parent,
		Vector3.new(3, 2.4, 3),
		CFrame.new(-38, BASE_Y + computerDeskTopY / 2, deskZ - 6),
		Color3.fromRGB(120, 96, 74),
		Enum.Material.Wood
	)
	computerDesk.CanCollide = false
	local computerMonitor = newPart(
		"ComputerMonitor",
		parent,
		Vector3.new(1.8, 1.4, 0.2),
		CFrame.new(-38, BASE_Y + computerDeskTopY + 0.7, deskZ - 6 - 1.2),
		Color3.fromRGB(20, 20, 24),
		Enum.Material.SmoothPlastic
	)
	computerMonitor.CanCollide = false
	newPrompt(computerDesk, "ComputerPrompt", "Оформить карточку", "Компьютер", 8)

	local printer = newPart(
		"Printer",
		parent,
		Vector3.new(2.4, 1.6, 2),
		CFrame.new(-38, BASE_Y + 1.8, deskZ + 6),
		Color3.fromRGB(220, 220, 216),
		Enum.Material.SmoothPlastic
	)
	printer.CanCollide = false
	newPrompt(printer, "PrinterPrompt", "Забрать карточку", "Принтер", 8)
	-- Sits on top of the printer (Y = printer centre 1.8 + half its 1.6
	-- thickness = 2.6), not on the floor.
	buildMarker(
		"CardTray",
		parent,
		Vector3.new(-38, 2.6, deskZ + 6),
		1.6,
		1,
		0.05,
		Color3.fromRGB(235, 235, 230),
		0.3
	)

	-- Reject sits on the counter itself, always reachable while a patient is
	-- waiting; unlike admitting it needs no photo or printed card.
	local rejectButton = newPart(
		"RejectButton",
		parent,
		Vector3.new(1, 1, 1),
		CFrame.new(deskX, BASE_Y + deskTopY + 0.5, deskZ + 4),
		Color3.fromRGB(163, 62, 62),
		Enum.Material.Neon
	)
	rejectButton.CanCollide = false
	newPrompt(rejectButton, "RejectPrompt", "Отклонить", "Пациент", 8)

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "PlayerSpawn"
	spawnLocation.Size = Vector3.new(6, 1, 6)
	spawnLocation.CFrame = CFrame.new(-58, BASE_Y + 0.5 + MARKER_LIFT, deskZ)
	spawnLocation.Anchored = true
	spawnLocation.CanCollide = true
	spawnLocation.Transparency = 1
	spawnLocation.Neutral = true
	spawnLocation.Parent = parent

	return desk
end

--------------------------------------------------------------------------------
-- Treatment room equipment
--------------------------------------------------------------------------------
-- Every treatment room gets the same medicine machine (three buttons, one per
-- PatientData medicine) plus one themed prop so the four rooms still read as
-- different places. The machine is the generalized version of the roadmap's
-- stage 5 Basic Medical pattern (3 buttons, a timer, right/wrong), applied to
-- all four rooms at once rather than to Basic Medical alone: stages 8/11/12
-- can later replace any one room's handler with something more specific
-- through RoomRegistry.setHandler without touching this geometry.

local TREATMENT_ROOM_IDS = { BasicMedical = true, XRay = true, HeartMonitor = true, Surgery = true }

local MEDICINE_IDS = { "MedicineA", "MedicineB", "MedicineC" }
local MEDICINE_LABELS = { MedicineA = "A", MedicineB = "B", MedicineC = "C" }
local MEDICINE_COLORS = {
	MedicineA = Color3.fromRGB(90, 170, 210),
	MedicineB = Color3.fromRGB(210, 170, 90),
	MedicineC = Color3.fromRGB(170, 90, 210),
}

-- Point `distance` studs from the room's centre, opposite its (single) door.
local function backOfRoom(room, distance)
	local outward = OUTWARD[room.doors[1].side]
	return room.center - outward * distance
end

local function buildTreatmentMachine(parent, room)
	local outward = OUTWARD[room.doors[1].side]
	local machineCenter = backOfRoom(room, 8)

	-- Not collidable, same reason as the reception desk-top equipment: the
	-- buttons sit only 2 studs off its face, so a solid cabinet there is what
	-- a first-person character's camera would judder against while reaching
	-- for them.
	local cabinet = newPart(
		"TreatmentCabinet",
		parent,
		Vector3.new(8, 6, 2.5),
		CFrame.new(machineCenter.X, BASE_Y + 3, machineCenter.Z),
		Color3.fromRGB(210, 214, 218),
		Enum.Material.Metal
	)
	cabinet.CanCollide = false

	-- Buttons sit clear of the cabinet's front face (half-depth 1.25) plus
	-- their own half-depth (0.3), with a small margin, towards the door so a
	-- player walking in from the entry can reach them without circling round.
	local buttonCenter = machineCenter + outward * 2
	local buttonOffsets = { -2.4, 0, 2.4 }
	for index, medicineId in ipairs(MEDICINE_IDS) do
		local button = newPart(
			"MedicineButton",
			parent,
			Vector3.new(1.6, 1.6, 0.6),
			CFrame.new(buttonCenter.X + buttonOffsets[index], BASE_Y + 3, buttonCenter.Z),
			MEDICINE_COLORS[medicineId],
			Enum.Material.Neon
		)
		button.CanCollide = false
		button:SetAttribute("RoomId", room.id)
		button:SetAttribute("MedicineId", medicineId)

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "MedicinePrompt"
		prompt.ActionText = "Препарат " .. MEDICINE_LABELS[medicineId]
		prompt.ObjectText = room.name
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 8
		prompt.RequiresLineOfSight = false
		-- Off by default: TreatmentRooms.server.lua enables all three only
		-- while that room has a patient waiting on a choice.
		prompt.Enabled = false
		prompt.Parent = button
	end
end

-- One simple themed prop per room, standing between the door and the
-- machine, so each room still looks like what its sign says even though the
-- interactive part (the medicine machine) is identical for now. All are
-- decorative and not collidable: none needs to be a real physical obstacle,
-- and being solid only risks the same close-range camera judder as the
-- equipment above, since the player walks right past them on the way in.
local function newDecor(name, parent, size, cframe, color, material)
	local part = newPart(name, parent, size, cframe, color, material)
	part.CanCollide = false
	return part
end

local function buildRoomProp(parent, room)
	if room.id == "BasicMedical" then
		newDecor(
			"ExamTable",
			parent,
			Vector3.new(2, 2.4, 5),
			CFrame.new(room.center.X, BASE_Y + 1.2, room.center.Z),
			Color3.fromRGB(225, 228, 230),
			Enum.Material.SmoothPlastic
		)
	elseif room.id == "XRay" then
		newDecor(
			"XRayArm",
			parent,
			Vector3.new(1, 6, 1),
			CFrame.new(room.center.X - 3, BASE_Y + 3, room.center.Z),
			Color3.fromRGB(180, 184, 190),
			Enum.Material.Metal
		)
		newDecor(
			"XRayPanel",
			parent,
			Vector3.new(3, 3, 0.4),
			CFrame.new(room.center.X - 3, BASE_Y + 6.2, room.center.Z),
			Color3.fromRGB(40, 42, 46),
			Enum.Material.Metal
		)
	elseif room.id == "HeartMonitor" then
		newDecor(
			"MonitorBed",
			parent,
			Vector3.new(2.4, 1.6, 5.5),
			CFrame.new(room.center.X, BASE_Y + 0.8, room.center.Z),
			Color3.fromRGB(225, 228, 230),
			Enum.Material.SmoothPlastic
		)
		newDecor(
			"MonitorScreen",
			parent,
			Vector3.new(1.6, 1.4, 0.3),
			CFrame.new(room.center.X + 2.4, BASE_Y + 4, room.center.Z - 2),
			Color3.fromRGB(30, 60, 40),
			Enum.Material.Neon
		)
	elseif room.id == "Surgery" then
		newDecor(
			"SurgeryTable",
			parent,
			Vector3.new(2.4, 2, 5.5),
			CFrame.new(room.center.X, BASE_Y + 1, room.center.Z),
			Color3.fromRGB(210, 214, 218),
			Enum.Material.Metal
		)
		newDecor(
			"SurgeryLamp",
			parent,
			Vector3.new(2, 0.6, 2),
			CFrame.new(room.center.X, BASE_Y + WALL_HEIGHT - 1.5, room.center.Z),
			Color3.fromRGB(245, 245, 235),
			Enum.Material.Neon
		)
	end
end

--------------------------------------------------------------------------------
-- Rooms and corridor
--------------------------------------------------------------------------------

local function doorsOnSide(room, side)
	local matches = {}
	for _, door in ipairs(room.doors) do
		if door.side == side then
			table.insert(matches, door)
		end
	end
	return matches
end

-- Gaps this room must cut into the given wall, plus whether the room must
-- skip that wall entirely because a neighbour owns it instead.
local function wallPlan(room, side, axisCenter)
	local doors = doorsOnSide(room, side)
	if #doors == 0 then
		return nil, false
	end
	local gaps = {}
	local skip = false
	for _, door in ipairs(doors) do
		if door.owns == false then
			skip = true
		else
			table.insert(gaps, { center = axisCenter + (door.center or 0), width = door.width })
		end
	end
	if skip then
		return nil, true
	end
	return gaps, false
end

-- A room with exactly one doorway gets its EntryPoint placed just inside
-- that door automatically; rooms with more than one (Lobby) name their
-- EntryPoint explicitly since "just inside the door" is ambiguous.
local function defaultEntryPoint(room)
	if #room.doors == 1 then
		local side = room.doors[1].side
		local halfX = room.sizeX / 2
		local halfZ = room.sizeZ / 2
		local outward = OUTWARD[side]
		local isAlongZ = (side == "East" or side == "West")
		local inset = (isAlongZ and halfX or halfZ) - 4
		return room.center + outward * inset
	end
	return room.center
end

local function buildRoom(parent, room)
	local model = Instance.new("Model")
	model.Name = room.id
	model.Parent = parent

	local structure = Instance.new("Folder")
	structure.Name = "Structure"
	structure.Parent = model

	local halfX = room.sizeX / 2
	local halfZ = room.sizeZ / 2
	local xMin, xMax = room.center.X - halfX, room.center.X + halfX
	local zMin, zMax = room.center.Z - halfZ, room.center.Z + halfZ

	local floor = buildFloor(structure, room.center, room.sizeX, room.sizeZ, FLOOR_COLOR)
	buildCeiling(structure, room.center, room.sizeX, room.sizeZ)

	local northGaps, northSkip = wallPlan(room, "North", room.center.X)
	if not northSkip then
		buildWallAlongX(structure, zMin, xMin, xMax, northGaps)
	end
	local southGaps, southSkip = wallPlan(room, "South", room.center.X)
	if not southSkip then
		buildWallAlongX(structure, zMax, xMin, xMax, southGaps)
	end
	local westGaps, westSkip = wallPlan(room, "West", room.center.Z)
	if not westSkip then
		buildWallAlongZ(structure, xMin, zMin, zMax, westGaps)
	end
	local eastGaps, eastSkip = wallPlan(room, "East", room.center.Z)
	if not eastSkip then
		buildWallAlongZ(structure, xMax, zMin, zMax, eastGaps)
	end

	local entryPosition = room.entryPoint or defaultEntryPoint(room)
	buildMarker("EntryPoint", model, entryPosition, 4, 4, 0.4, Color3.fromRGB(85, 220, 120), 0.5)

	local zoneCenter = room.interactionCenter or room.center
	buildMarker(
		"InteractionZone",
		model,
		zoneCenter,
		room.interactionSizeX or 12,
		room.interactionSizeZ or 12,
		8,
		room.accent,
		0.85
	)

	if room.signSide then
		buildSign(model, room, room.signSide)
	end

	if room.id == "Lobby" then
		buildLobbyFurniture(structure, room)
	elseif room.id == "Reception" then
		buildReceptionFurniture(structure, room)
	elseif TREATMENT_ROOM_IDS[room.id] then
		buildTreatmentMachine(structure, room)
		buildRoomProp(structure, room)
	end

	model.PrimaryPart = floor
	model:SetAttribute("RoomId", room.id)
	model:SetAttribute("DisplayName", room.name)
	if room.roomNumber then
		model:SetAttribute("RoomNumber", room.roomNumber)
	end

	return model
end

local function buildCorridor(parent)
	local model = Instance.new("Model")
	model.Name = "Corridor"
	model.Parent = parent

	local structure = Instance.new("Folder")
	structure.Name = "Structure"
	structure.Parent = model

	local length = CORRIDOR_X_MAX - CORRIDOR_X_MIN
	local center = Vector3.new((CORRIDOR_X_MIN + CORRIDOR_X_MAX) / 2, 0, 0)

	local floor = buildFloor(structure, center, length, CORRIDOR_HALF_WIDTH * 2, CORRIDOR_FLOOR_COLOR)
	buildCeiling(structure, center, length, CORRIDOR_HALF_WIDTH * 2)

	-- Doorways of the rooms that sit along the corridor (including the Lobby,
	-- which joins from the south to form the T junction). The corridor owns
	-- these walls so the shared plane is never built twice.
	local northGaps, southGaps = {}, {}
	for _, room in ipairs(ROOMS) do
		for _, door in ipairs(room.doors) do
			if door.owns == false then
				local gap = { center = room.center.X + (door.center or 0), width = door.width }
				if door.side == "South" then
					table.insert(northGaps, gap)
				elseif door.side == "North" then
					table.insert(southGaps, gap)
				end
			end
		end
	end

	buildWallAlongX(structure, -CORRIDOR_HALF_WIDTH, CORRIDOR_X_MIN, CORRIDOR_X_MAX, northGaps)
	buildWallAlongX(structure, CORRIDOR_HALF_WIDTH, CORRIDOR_X_MIN, CORRIDOR_X_MAX, southGaps)

	-- The west end is a dead end (nothing sits there), so the corridor caps
	-- it itself. The east end is capped by BreakRoom's own wall instead.
	wallSegmentAlongZ(structure, -CORRIDOR_HALF_WIDTH, CORRIDOR_HALF_WIDTH, CORRIDOR_X_MIN, 0, WALL_HEIGHT, "Wall")

	buildMarker("EntryPoint", model, Vector3.new(0, 0, 0), 4, 4, 0.4, Color3.fromRGB(85, 220, 120), 0.5)

	model.PrimaryPart = floor
	model:SetAttribute("RoomId", "Corridor")
	model:SetAttribute("DisplayName", "Corridor")
	return model
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

-- Studio's Baseplate template ships with its own SpawnLocation. Left in place
-- it competes with the reception spawn, so it goes away with the old build.
local function removeStraySpawns()
	for _, instance in ipairs(Workspace:GetChildren()) do
		if instance:IsA("SpawnLocation") then
			instance:Destroy()
		end
	end
end

local function build()
	local existing = Workspace:FindFirstChild("Hospital")
	if existing then
		existing:Destroy()
	end
	removeStraySpawns()

	local hospital = Instance.new("Model")
	hospital.Name = "Hospital"
	hospital:SetAttribute("LayoutVersion", 4)
	hospital.Parent = Workspace

	buildCorridor(hospital)

	local rooms = Instance.new("Folder")
	rooms.Name = "Rooms"
	rooms.Parent = hospital

	local built = {}
	for _, room in ipairs(ROOMS) do
		buildRoom(rooms, room)
		table.insert(built, room.id)
	end

	-- Set last: ShiftServer waits on this attribute rather than on the model
	-- itself, which appears in Workspace before its rooms are filled in.
	hospital:SetAttribute("Ready", true)

	print(("[Stage 0] Hospital built. Rooms: %s"):format(table.concat(built, ", ")))
	return hospital
end

--------------------------------------------------------------------------------
-- Stage 1 check
--------------------------------------------------------------------------------

-- Sends one dummy patient into every registered room and prints the results.
-- Off since stage 2: ShiftServer routes real patients now, and the dummies
-- would occupy all four rooms for the first five seconds of the shift. Set it
-- back to true to check the registry wiring on its own.
local RUN_ROOM_REGISTRY_CHECK = false

local function runRoomRegistryCheck()
	if not RUN_ROOM_REGISTRY_CHECK then
		return
	end

	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local moduleScript = shared and shared:FindFirstChild("RoomRegistry")
	if not moduleScript then
		warn("[Stage 1] ReplicatedStorage.Shared.RoomRegistry not found - skipping the room check.")
		return
	end

	local ok, registry = pcall(require, moduleScript)
	if not ok then
		warn(("[Stage 1] RoomRegistry failed to load: %s"):format(tostring(registry)))
		return
	end

	registry.runSelfTest()
end

build()
runRoomRegistryCheck()

--[[
	Animal Hospital - Stage 0: hospital shell.

	Server Script. Runs by itself when the game starts and builds the whole
	hospital geometry (reception, corridor, four exam rooms, break room)
	under Workspace.Hospital. Stage 0 is scene only: no gameplay logic here.

	Where to put it:
		ServerScriptService -> Script (Server) -> paste this file in.
		Nothing else to do, just press Play.

	The hospital is rebuilt on every server start, so editing it by hand in
	Studio is pointless: change the ROOMS table below instead.

	Structure produced (every room is identical in shape, so stage 1
	RoomRegistry can walk them generically):

		Workspace.Hospital
			Corridor            Model  (Structure, EntryPoint)
			Rooms               Folder
				Reception       Model  (Structure, EntryPoint, InteractionZone, RoomLabel, ...)
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

local WALL_HEIGHT = 14
local WALL_THICKNESS = 1
local FLOOR_THICKNESS = 1
local CEILING_THICKNESS = 1
local DOOR_HEIGHT = 9

local CORRIDOR_HALF_WIDTH = 6
local CORRIDOR_X_MIN = -10
local CORRIDOR_X_MAX = 70

local FLOOR_COLOR = Color3.fromRGB(198, 198, 196)
local CORRIDOR_FLOOR_COLOR = Color3.fromRGB(172, 180, 180)
local WALL_COLOR = Color3.fromRGB(163, 168, 173)
local CEILING_COLOR = Color3.fromRGB(222, 222, 220)

--------------------------------------------------------------------------------
-- Room table
--------------------------------------------------------------------------------
-- doorSide is the wall of the room that opens onto the corridor.
-- ownsDoorWall = false means the corridor builds that wall (with the doorway),
-- so the room must not build it again and create overlapping geometry.

local ROOMS = {
	{
		id = "Reception",
		name = "Reception",
		signText = "RECEPTION",
		center = Vector3.new(-22, 0, 0),
		sizeX = 24,
		sizeZ = 20,
		doorSide = "East",
		doorWidth = 12,
		ownsDoorWall = true,
		accent = Color3.fromRGB(86, 148, 200),
		entryPoint = Vector3.new(-29, 0, 0),
		interactionCenter = Vector3.new(-26, 0, 0),
		interactionSizeX = 8,
		interactionSizeZ = 18,
	},
	{
		id = "BasicMedical",
		name = "Basic Medical / DNA",
		signText = "ROOM 1\nBASIC MEDICAL / DNA",
		roomNumber = 1,
		center = Vector3.new(8, 0, -16),
		sizeX = 24,
		sizeZ = 20,
		doorSide = "South",
		doorWidth = 10,
		ownsDoorWall = false,
		accent = Color3.fromRGB(90, 180, 120),
	},
	{
		id = "XRay",
		name = "X-Ray",
		signText = "ROOM 2\nX-RAY",
		roomNumber = 2,
		center = Vector3.new(8, 0, 16),
		sizeX = 24,
		sizeZ = 20,
		doorSide = "North",
		doorWidth = 10,
		ownsDoorWall = false,
		accent = Color3.fromRGB(120, 140, 210),
	},
	{
		id = "HeartMonitor",
		name = "Heart Monitor",
		signText = "ROOM 7\nHEART MONITOR",
		roomNumber = 7,
		center = Vector3.new(44, 0, -16),
		sizeX = 24,
		sizeZ = 20,
		doorSide = "South",
		doorWidth = 10,
		ownsDoorWall = false,
		accent = Color3.fromRGB(210, 100, 110),
	},
	{
		id = "Surgery",
		name = "Surgery",
		signText = "ROOM 8\nSURGERY",
		roomNumber = 8,
		center = Vector3.new(44, 0, 16),
		sizeX = 24,
		sizeZ = 20,
		doorSide = "North",
		doorWidth = 10,
		ownsDoorWall = false,
		accent = Color3.fromRGB(200, 160, 90),
	},
	{
		id = "BreakRoom",
		name = "Break Room",
		signText = "BREAK ROOM\n/ SHOP",
		center = Vector3.new(82, 0, 0),
		sizeX = 24,
		sizeZ = 24,
		doorSide = "West",
		doorWidth = 12,
		ownsDoorWall = true,
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

-- Yaw that turns a part's Front face (local -Z) towards the corridor.
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
		CFrame.new((x1 + x2) / 2, yBottom + height / 2, z),
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
		CFrame.new(x, yBottom + height / 2, (z1 + z2) / 2),
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
		CFrame.new(center.X, -FLOOR_THICKNESS / 2, center.Z),
		color,
		Enum.Material.SmoothPlastic
	)
end

local function buildCeiling(parent, center, sizeX, sizeZ)
	return newPart(
		"Ceiling",
		parent,
		Vector3.new(sizeX, CEILING_THICKNESS, sizeZ),
		CFrame.new(center.X, WALL_HEIGHT + CEILING_THICKNESS / 2, center.Z),
		CEILING_COLOR,
		Enum.Material.SmoothPlastic
	)
end

local function buildMarker(name, parent, position, sizeX, sizeZ, height, color, transparency)
	local part = newPart(
		name,
		parent,
		Vector3.new(sizeX, height, sizeZ),
		CFrame.new(position.X, position.Y + height / 2, position.Z),
		color,
		Enum.Material.SmoothPlastic
	)
	part.CanCollide = false
	part.CastShadow = false
	part.Transparency = transparency
	return part
end

local function buildSign(parent, room)
	local halfX = room.sizeX / 2
	local halfZ = room.sizeZ / 2
	local outward = OUTWARD[room.doorSide]
	local isAlongZ = (room.doorSide == "East" or room.doorSide == "West")
	local wallOffset = isAlongZ and halfX or halfZ
	local surface = room.center + outward * (wallOffset + WALL_THICKNESS / 2 + 0.3)

	local sign = newPart(
		"RoomLabel",
		parent,
		Vector3.new(10, 3, 0.4),
		CFrame.new(surface.X, (DOOR_HEIGHT + WALL_HEIGHT) / 2, surface.Z)
			* CFrame.Angles(0, SIGN_YAW[room.doorSide], 0),
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
-- Reception furniture
--------------------------------------------------------------------------------
-- The counter splits the reception in two: patients wait west of it,
-- the player works east of it, next to the corridor. Gaps at both ends of the
-- counter let an admitted patient walk through towards the corridor.

local function buildReceptionFurniture(parent, room)
	local deskX = -26

	local desk = newPart(
		"ReceptionDesk",
		parent,
		Vector3.new(2, 4, 16),
		CFrame.new(deskX, 2, 0),
		Color3.fromRGB(120, 96, 74),
		Enum.Material.Wood
	)

	local window = newPart(
		"ReceptionWindow",
		parent,
		Vector3.new(2, 5, 16),
		CFrame.new(deskX, 6.5, 0),
		Color3.fromRGB(200, 225, 235),
		Enum.Material.Glass
	)
	window.Transparency = 0.6

	newPart(
		"ReceptionWindowFrame",
		parent,
		Vector3.new(2, WALL_HEIGHT - DOOR_HEIGHT, 16),
		CFrame.new(deskX, (DOOR_HEIGHT + WALL_HEIGHT) / 2, 0),
		WALL_COLOR,
		Enum.Material.Concrete
	)

	buildMarker("PatientSpawn", parent, Vector3.new(-31, 0, 0), 4, 4, 0.4, room.accent, 0.5)

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "PlayerSpawn"
	spawnLocation.Size = Vector3.new(6, 1, 6)
	spawnLocation.CFrame = CFrame.new(-16, 0.5, 0)
	spawnLocation.Anchored = true
	spawnLocation.CanCollide = true
	spawnLocation.Transparency = 1
	spawnLocation.Neutral = true
	spawnLocation.Parent = parent

	return desk
end

--------------------------------------------------------------------------------
-- Rooms and corridor
--------------------------------------------------------------------------------

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

	-- The room cuts a doorway only into the wall it owns. For the four exam
	-- rooms the door wall belongs to the corridor, so the room skips it.
	local function gapsFor(side, axisCenter)
		if room.doorSide ~= side then
			return nil
		end
		return { { center = axisCenter, width = room.doorWidth } }
	end

	local function skip(side)
		return room.doorSide == side and not room.ownsDoorWall
	end

	if not skip("North") then
		buildWallAlongX(structure, zMin, xMin, xMax, gapsFor("North", room.center.X))
	end
	if not skip("South") then
		buildWallAlongX(structure, zMax, xMin, xMax, gapsFor("South", room.center.X))
	end
	if not skip("West") then
		buildWallAlongZ(structure, xMin, zMin, zMax, gapsFor("West", room.center.Z))
	end
	if not skip("East") then
		buildWallAlongZ(structure, xMax, zMin, zMax, gapsFor("East", room.center.Z))
	end

	local outward = OUTWARD[room.doorSide]
	local isAlongZ = (room.doorSide == "East" or room.doorSide == "West")
	local inset = (isAlongZ and halfX or halfZ) - 4
	local entryPosition = room.entryPoint or (room.center + outward * inset)
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

	buildSign(model, room)

	if room.id == "Reception" then
		buildReceptionFurniture(structure, room)
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

	-- Doorways of the rooms that sit along the corridor. The corridor owns
	-- these walls so the shared plane is never built twice.
	local northGaps, southGaps = {}, {}
	for _, room in ipairs(ROOMS) do
		if not room.ownsDoorWall then
			local gap = { center = room.center.X, width = room.doorWidth }
			if room.doorSide == "South" then
				table.insert(northGaps, gap)
			elseif room.doorSide == "North" then
				table.insert(southGaps, gap)
			end
		end
	end

	buildWallAlongX(structure, -CORRIDOR_HALF_WIDTH, CORRIDOR_X_MIN, CORRIDOR_X_MAX, northGaps)
	buildWallAlongX(structure, CORRIDOR_HALF_WIDTH, CORRIDOR_X_MIN, CORRIDOR_X_MAX, southGaps)

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
	hospital:SetAttribute("LayoutVersion", 1)
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

	print(("[Stage 0] Hospital built. Rooms: %s"):format(table.concat(built, ", ")))
	return hospital
end

build()

--[[
	Animal Hospital - PickupSystem.

	Server-authoritative "pick it up, carry it, put it back" for small world
	items: the developed photo, the printed patient card. A ModuleScript, not
	a Script - other server scripts require it and register items with it.

	Where to put it:
		ServerScriptService -> ModuleScript named "PickupSystem" -> paste this
		file in, alongside the other server scripts (they find it as a
		sibling via script.Parent).

	How an item is carried: the part is Anchored, so nothing here uses
	physics or welds. While held, a Heartbeat loop sets the part's CFrame to
	a fixed offset in front of the holder's Head every frame. Because this
	runs on the server and CFrame is set directly (not via velocity), it
	replicates to every client the normal way - other players see it too,
	not just the holder. This is what lets the client side of holding an
	item be nothing: no LocalScript involvement at all, the part just moves.

	One holder at a time per item. A second player trying to pick up an
	already-held item is refused. There is no reach/line-of-sight check here;
	callers are expected to gate pickup behind a ProximityPrompt, which
	already enforces distance.
]]

local RunService = game:GetService("RunService")

local PickupSystem = {}

-- Offset from the holder's Head, in the head's own local space: forward and
-- slightly down, roughly where a first-person "look at what's in your hands"
-- pose would put it.
local HOLD_OFFSET = CFrame.new(0, -0.6, -1.6)

-- item -> { part, homeCFrame, holder = Player? }
local registry = {}

-- Registers a part as pickable. homeCFrame is where it snaps back to on
-- release and where it starts. Safe to call again for the same part (e.g. to
-- reset its home position); this does not move the part or clear who holds
-- it.
function PickupSystem.register(part, homeCFrame)
	local entry = registry[part]
	if entry then
		entry.homeCFrame = homeCFrame
	else
		registry[part] = { part = part, homeCFrame = homeCFrame, holder = nil }
	end
end

function PickupSystem.unregister(part)
	registry[part] = nil
end

function PickupSystem.isHeld(part)
	local entry = registry[part]
	return entry ~= nil and entry.holder ~= nil
end

function PickupSystem.getHolder(part)
	local entry = registry[part]
	return entry and entry.holder
end

-- True if `player` is currently holding this exact part. What the "hand it
-- over" and "place it down" prompts check before acting.
function PickupSystem.isHeldBy(part, player)
	local entry = registry[part]
	return entry ~= nil and entry.holder == player
end

-- Returns true on success. Fails if the part is not registered, already
-- held (by anyone), or the player has no character to hold it in front of.
function PickupSystem.pickUp(part, player)
	local entry = registry[part]
	if not entry or entry.holder ~= nil then
		return false
	end
	local character = player.Character
	if not character or not character:FindFirstChild("Head") then
		return false
	end
	entry.holder = player
	return true
end

-- Snaps the item back to its home position and clears the holder. Safe to
-- call on an item nobody is holding (a no-op).
function PickupSystem.placeDown(part)
	local entry = registry[part]
	if not entry then
		return
	end
	entry.holder = nil
	part.CFrame = entry.homeCFrame
end

-- If `player` is holding anything, places it down. Used when a player leaves
-- mid-hold so an item does not stay stuck floating where they logged out.
function PickupSystem.releaseFromPlayer(player)
	for _, entry in pairs(registry) do
		if entry.holder == player then
			entry.holder = nil
			entry.part.CFrame = entry.homeCFrame
		end
	end
end

RunService.Heartbeat:Connect(function()
	for _, entry in pairs(registry) do
		local holder = entry.holder
		if holder then
			local character = holder.Character
			local head = character and character:FindFirstChild("Head")
			if head then
				entry.part.CFrame = head.CFrame * HOLD_OFFSET
			else
				-- Holder's character is gone (died, left) without going
				-- through releaseFromPlayer; drop the item where it is
				-- rather than leave it stuck to a CFrame that never updates.
				entry.holder = nil
			end
		end
	end
end)

return PickupSystem

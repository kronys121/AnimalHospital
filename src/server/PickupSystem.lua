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

	Prompt state is managed here, not by callers. Passing a `{pickup=, place=}`
	pair to register() means this module keeps exactly one of the two enabled
	at a time (Pickup while free, Place while held) and keeps that in sync
	across every path that changes holder or availability - pickUp, placeDown,
	setAvailable, and a player disconnecting mid-hold. A caller that instead
	pokes ProximityPrompt.Enabled directly can drift out of sync with the
	actual holder state (this happened once: both prompts sat enabled
	together, so "Взять" and "Положить на стол" competed for the same key and
	pickup looked like it did nothing).
]]

local RunService = game:GetService("RunService")

local PickupSystem = {}

-- Offset from the holder's Head, in the head's own local space: forward and
-- slightly down, roughly where a first-person "look at what's in your hands"
-- pose would put it.
local HOLD_OFFSET = CFrame.new(0, -0.6, -1.6)

-- item -> { part, homeCFrame, holder = Player?, prompts = {pickup, place}?, available }
local registry = {}

-- Keeps exactly one of the pair enabled, based on current holder/available
-- state. available defaults to true, so items with no such concept (nobody
-- ever calls setAvailable on them) just follow held/unheld normally.
local function refreshPrompts(entry)
	if not entry.prompts then
		return
	end
	local held = entry.holder ~= nil
	local available = entry.available ~= false
	entry.prompts.pickup.Enabled = available and not held
	entry.prompts.place.Enabled = held
end

-- Registers a part as pickable. homeCFrame is where it snaps back to on
-- release and where it starts. `prompts` (optional) is {pickup, place} -
-- passing it hands this module ownership of both prompts' Enabled state from
-- here on; omit it if the caller wants to manage prompts itself. Safe to call
-- again for the same part (e.g. to reset its home position); this does not
-- move the part or clear who holds it.
function PickupSystem.register(part, homeCFrame, prompts)
	local entry = registry[part]
	if entry then
		entry.homeCFrame = homeCFrame
		if prompts then
			entry.prompts = prompts
		end
	else
		entry = { part = part, homeCFrame = homeCFrame, holder = nil, prompts = prompts, available = true }
		registry[part] = entry
	end
	refreshPrompts(entry)
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

-- Marks whether the item can be picked up at all right now (independent of
-- who holds it) - e.g. the photo before a shot has been taken, or the card
-- before the printer has produced one. Held state always wins: an item stays
-- placeable while held even if marked unavailable mid-hold.
function PickupSystem.setAvailable(part, available)
	local entry = registry[part]
	if not entry then
		return
	end
	entry.available = available
	refreshPrompts(entry)
end

-- Returns true on success. Fails if the part is not registered, already
-- held (by anyone), marked unavailable, or the player has no character to
-- hold it in front of.
function PickupSystem.pickUp(part, player)
	local entry = registry[part]
	if not entry or entry.holder ~= nil or entry.available == false then
		return false
	end
	local character = player.Character
	if not character or not character:FindFirstChild("Head") then
		return false
	end
	entry.holder = player
	refreshPrompts(entry)
	return true
end

-- Snaps the item back to its home position and clears the holder. Safe to
-- call on an item nobody is holding (a no-op place, but still resyncs
-- prompts in case they had drifted).
function PickupSystem.placeDown(part)
	local entry = registry[part]
	if not entry then
		return
	end
	entry.holder = nil
	part.CFrame = entry.homeCFrame
	refreshPrompts(entry)
end

-- If `player` is holding anything, places it down. Used when a player leaves
-- mid-hold so an item does not stay stuck floating where they logged out.
function PickupSystem.releaseFromPlayer(player)
	for _, entry in pairs(registry) do
		if entry.holder == player then
			entry.holder = nil
			entry.part.CFrame = entry.homeCFrame
			refreshPrompts(entry)
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
				refreshPrompts(entry)
			end
		end
	end
end)

return PickupSystem

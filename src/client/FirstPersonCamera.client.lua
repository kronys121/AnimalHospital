--[[
	Animal Hospital - first-person view.

	LocalScript. Locks the camera to first person for the whole session, per
	the brief asking for a first-person view of the hospital.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named
		"FirstPersonCamera" -> paste this file in.

	CameraMode.LockFirstPerson switches to Roblox's own first-person camera
	(not a custom rig) and stops the player scrolling back out to third
	person. On its own that is NOT full FPS mouselook, though: the mouse
	cursor stays free (visible, click-to-interact) unless MouseBehavior is
	also set to LockCenter.

	IMPORTANT: only assign MouseBehavior when it is not already LockCenter.
	The first version of this script reassigned it unconditionally every
	RenderStepped frame, and that made things worse, not better: reassigning
	MouseBehavior to the SAME value it already holds still re-arms the lock
	from the engine's point of view, which resets whatever it uses internally
	to track "how far has the mouse moved since the lock was established" -
	so every single frame's rotation was being thrown away before the camera
	script could consume it. That reads as exactly what it was reported as:
	the camera stuck fast, worst right where a ProximityPrompt is on screen
	(which is exactly when something else - Roblox's own camera module -
	is most likely to be touching MouseBehavior itself, so this script's
	unconditional reassignment fought it on every one of those frames too).
	Setting it only on an actual change avoids resetting that state when
	nothing needs correcting, while still reclaiming the lock the moment
	something else releases it.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer

local function applyFirstPerson()
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

applyFirstPerson()

-- CameraMode is reset to the default on respawn, so it has to be reapplied
-- every time a new character (and camera) appears - the shift begins with
-- one spawn, but nothing here assumes that stays true forever.
player.CharacterAdded:Connect(applyFirstPerson)

-- Checked every frame, but only ever WRITES MouseBehavior/MouseIconEnabled
-- when they have actually drifted from what first person wants - see the
-- note above for why an unconditional write, even to the same value, breaks
-- mouselook. Skipped entirely while Roblox's own Esc menu is open
-- (GuiService.MenuIsOpen): that menu needs a free, visible cursor to click
-- its own buttons.
RunService.RenderStepped:Connect(function()
	if GuiService.MenuIsOpen then
		return
	end
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
	if UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = false
	end
end)

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

	Two rounds of fixes already went into the block below - both are still
	needed, they fix different things:

	1. Only assign MouseBehavior when it is not already LockCenter, not
	   unconditionally every frame. Reassigning it to the value it already
	   holds still re-arms the lock as far as the engine is concerned, which
	   resets whatever it uses internally to track mouse movement since the
	   lock was established - doing that 60+ times a second means every
	   frame's rotation gets thrown away before the camera script can read
	   it. That is a stuck camera everywhere, not just near UI.

	2. Clear GuiService.SelectedObject whenever something sets it. Roblox
	   tracks a "currently selected" GuiObject for gamepad/keyboard UI
	   navigation, and ProximityPrompt participates in that system - once its
	   on-screen prompt becomes the selected object (which happens exactly
	   when the, invisible but still logically positioned, locked cursor sits
	   over it, i.e. when the player is looking straight at whatever the
	   prompt is on), Roblox's own camera handling treats that as "the player
	   is now interacting with a UI control" and stops turning the camera
	   from mouse movement - exactly the reported "freezes over the prompt,
	   fine everywhere else". This has nothing to do with MouseBehavior and
	   the first fix could not have touched it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
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

-- Checked every frame, but only ever WRITES when something has actually
-- drifted from what first person wants - see fix 1 above for why an
-- unconditional write, even to the same value, breaks mouselook. All of it
-- is skipped while Roblox's own Esc menu is open (GuiService.MenuIsOpen):
-- that menu needs a free, visible, selectable cursor to work at all.
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
	if GuiService.SelectedObject ~= nil then
		GuiService.SelectedObject = nil
	end
end)
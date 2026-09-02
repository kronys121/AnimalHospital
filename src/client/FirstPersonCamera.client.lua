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
	also set to LockCenter - without that, moving the mouse does nothing to
	the camera at all, which reads as "the mouse is stuck/frozen", and the
	cursor never disappears. This shipped once (CameraMode set, MouseBehavior
	never touched), so this script re-asserts LockCenter every frame rather
	than once: some other system freeing the mouse (a ProximityPrompt's UI,
	Roblox's own GuiService reacting to a GuiObject) would otherwise win
	silently and there would be no way to tell from here that it had.
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

-- Keeps the mouse locked to the centre of the screen (hidden cursor, every
-- mouse move rotates the camera) for as long as this is running, i.e. the
-- whole shift. Re-set every frame instead of once: if anything else resets
-- MouseBehavior back to Default, this claims it back on the very next frame
-- rather than leaving the player stuck with a free, visible cursor and no
-- way to look around.
--
-- Skipped while Roblox's own Esc menu is open (GuiService.MenuIsOpen): that
-- menu needs a free, visible cursor to click its own buttons, and fighting
-- it every frame would make it unusable.
RunService.RenderStepped:Connect(function()
	if GuiService.MenuIsOpen then
		return
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false
end)

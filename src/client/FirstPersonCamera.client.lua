--[[
	Animal Hospital - first-person view.

	LocalScript. Locks the camera to first person for the whole session, per
	the brief asking for a first-person view of the hospital.

	Where to put it:
		StarterPlayer -> StarterPlayerScripts -> LocalScript named
		"FirstPersonCamera" -> paste this file in.

	CameraMode.LockFirstPerson does the actual work: Roblox's own first-person
	camera, not a custom rig. It also disables scrolling back out to third
	person, which is the point - a player who could scroll out would not
	really be playing in first person.
]]

local Players = game:GetService("Players")

local player = Players.LocalPlayer

local function applyFirstPerson()
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

applyFirstPerson()

-- CameraMode is reset to the default on respawn, so it has to be reapplied
-- every time a new character (and camera) appears - the shift begins with
-- one spawn, but nothing here assumes that stays true forever.
player.CharacterAdded:Connect(applyFirstPerson)

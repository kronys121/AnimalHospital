--[[
	Animal Hospital - Stage 4: sanity, the shift timer and the end of a shift.

	ModuleScript. The single owner of everything that makes a shift a round
	rather than an endless loop: sanity 0-100, a score, a five-minute clock,
	and the win/lose decision. Server-side only - clients receive a read-only
	snapshot and may only ask to start a new shift.

	Where to put it:
		ServerScriptService -> ModuleScript named "ShiftState" -> paste this
		file in, alongside ShiftServer and PickupSystem.

	Why a module and not part of ShiftServer: two different scripts already
	produce consequences (ShiftServer for reception decisions, TreatmentRooms
	through the room outcome that comes back to ShiftServer), and a shift can
	end at any moment from either the clock or the sanity bar. Keeping the
	numbers, the clock and the end condition in one place means there is
	exactly one thing that can declare a shift over, and exactly one shape of
	payload the HUD has to understand.

	One shift is shared by everybody on the server. This is a co-op hospital,
	not a per-player instance: the bar the players see is the same bar.

	Remotes (created in ReplicatedStorage.AnimalHospital, same folder the
	other scripts use):
		ShiftStarted  server -> client  a new shift began, with its limits
		ShiftUpdate   server -> client  sanity / score / time left, ~4 per sec
		ShiftEnded    server -> client  outcome plus the end-of-shift summary
		ShiftRestart  client -> server  the "заново" button on the results screen
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ShiftState = {}

--------------------------------------------------------------------------------
-- Tuning (roadmap stage 4)
--------------------------------------------------------------------------------

local SHIFT_SECONDS = 300 -- пять минут
local MAX_SANITY = 100

local SANITY_CORRECT = 5
local SANITY_WRONG = -15
local SANITY_IDLE_PER_SECOND = -1

-- The roadmap's -1/sec assumed a reception where admitting is one button
-- press. Ours is physical (photograph, computer, printer, hand the card
-- over), so the paperwork itself takes tens of seconds and a raw -1/sec
-- would make the shift unwinnable by patient six. The drain therefore only
-- starts after this many seconds with the patient at the counter: doing the
-- work is free, dithering is not. Lower it to 0 for the literal roadmap
-- rule.
local IDLE_GRACE_SECONDS = 12

-- Stage 5's numbers for the room that already works. Cheaper than a decision
-- either way: what happens in the room is the machine's fault as much as the
-- player's, and a lost patient should not cost the same as letting an
-- anomaly walk in.
local SANITY_CURED = 3
local SANITY_DIED = -8

local SCORE_CORRECT = 10
local SCORE_CURED = 15

-- How often the full snapshot goes out. The timer is smooth on the client
-- because the HUD counts down locally between updates; these are the
-- corrections, not the clock itself.
local BROADCAST_INTERVAL = 0.25

ShiftState.SHIFT_SECONDS = SHIFT_SECONDS
ShiftState.MAX_SANITY = MAX_SANITY

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local function ensureRemote(name)
	local folder = ReplicatedStorage:FindFirstChild("AnimalHospital")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "AnimalHospital"
		folder.Parent = ReplicatedStorage
	end
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = folder
	return event
end

local shiftStarted = ensureRemote("ShiftStarted")
local shiftUpdate = ensureRemote("ShiftUpdate")
local shiftEnded = ensureRemote("ShiftEnded")
local shiftRestart = ensureRemote("ShiftRestart")

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function newStats()
	return {
		admitted = 0,
		rejected = 0,
		correct = 0,
		wrong = 0,
		timeouts = 0,
		cured = 0,
		died = 0,
	}
end

local state = {
	running = false,
	sanity = MAX_SANITY,
	score = 0,
	timeLeft = SHIFT_SECONDS,
	idle = false,
	idleSince = nil,
	draining = false,
	-- Bumped on every start. Anything that survived the previous shift (a
	-- patient mid-walk, a queued callback) can compare against it and bail
	-- out instead of writing into the new one.
	generation = 0,
	stats = newStats(),
	lastResult = nil,
}

local endedListeners = {}
local startedListeners = {}

--------------------------------------------------------------------------------
-- Snapshots
--------------------------------------------------------------------------------

local function snapshot()
	return {
		running = state.running,
		sanity = state.sanity,
		maxSanity = MAX_SANITY,
		score = state.score,
		timeLeft = state.timeLeft,
		shiftSeconds = SHIFT_SECONDS,
		generation = state.generation,
		draining = state.draining,
	}
end

function ShiftState.getSnapshot()
	return snapshot()
end

function ShiftState.getLastResult()
	return state.lastResult
end

local function broadcast()
	shiftUpdate:FireAllClients(snapshot())
end

--------------------------------------------------------------------------------
-- Ending a shift
--------------------------------------------------------------------------------

local function summary(outcome)
	return {
		outcome = outcome, -- "win" | "lose"
		sanity = state.sanity,
		maxSanity = MAX_SANITY,
		score = state.score,
		generation = state.generation,
		survived = SHIFT_SECONDS - state.timeLeft,
		shiftSeconds = SHIFT_SECONDS,
		stats = {
			admitted = state.stats.admitted,
			rejected = state.stats.rejected,
			correct = state.stats.correct,
			wrong = state.stats.wrong,
			timeouts = state.stats.timeouts,
			cured = state.stats.cured,
			died = state.stats.died,
		},
	}
end

local function finish(outcome)
	if not state.running then
		return
	end
	state.running = false
	state.idle = false
	state.idleSince = nil
	state.draining = false

	local result = summary(outcome)
	state.lastResult = result

	print(
		("[Shift] смена окончена (%s): sanity %d, очки %d, верных %d, ошибок %d"):format(
			outcome,
			math.floor(state.sanity + 0.5),
			state.score,
			state.stats.correct,
			state.stats.wrong
		)
	)

	broadcast()
	shiftEnded:FireAllClients(result)

	-- Listeners clean the world up (despawn whoever is still walking). Run
	-- each on its own thread under pcall so one broken listener cannot leave
	-- the shift half-ended.
	for _, listener in ipairs(endedListeners) do
		task.spawn(function()
			local ok, err = pcall(listener, result)
			if not ok then
				warn(("[Shift] ended listener failed: %s"):format(tostring(err)))
			end
		end)
	end
end

function ShiftState.onEnded(listener)
	table.insert(endedListeners, listener)
end

function ShiftState.onStarted(listener)
	table.insert(startedListeners, listener)
end

--------------------------------------------------------------------------------
-- Starting a shift
--------------------------------------------------------------------------------

function ShiftState.start()
	state.generation = state.generation + 1
	state.running = true
	state.sanity = MAX_SANITY
	state.score = 0
	state.timeLeft = SHIFT_SECONDS
	state.idle = false
	state.idleSince = nil
	state.draining = false
	state.stats = newStats()
	state.lastResult = nil

	print(("[Shift] смена #%d началась: %d секунд, sanity %d"):format(state.generation, SHIFT_SECONDS, MAX_SANITY))

	shiftStarted:FireAllClients(snapshot())
	broadcast()

	for _, listener in ipairs(startedListeners) do
		task.spawn(function()
			local ok, err = pcall(listener, state.generation)
			if not ok then
				warn(("[Shift] started listener failed: %s"):format(tostring(err)))
			end
		end)
	end
end

function ShiftState.isRunning()
	return state.running
end

function ShiftState.getGeneration()
	return state.generation
end

--------------------------------------------------------------------------------
-- Consequences
--------------------------------------------------------------------------------

-- Every change to sanity goes through here, including the per-second idle
-- drain, so the "sanity hit zero" check exists exactly once.
function ShiftState.adjustSanity(delta)
	if not state.running or delta == 0 then
		return state.sanity
	end

	state.sanity = math.clamp(state.sanity + delta, 0, MAX_SANITY)
	if state.sanity <= 0 then
		finish("lose")
	end
	return state.sanity
end

function ShiftState.addScore(points)
	if not state.running or points == 0 then
		return
	end
	state.score = state.score + points
end

function ShiftState.bumpStat(name, by)
	if state.stats[name] == nil then
		return
	end
	state.stats[name] = state.stats[name] + (by or 1)
end

-- Called by ShiftServer around the decision wait: true while a patient is
-- standing at the counter with nothing decided about them, which is what
-- "простой на ресепшене" means. Not "the player is standing still" - walking
-- to the printer is work, not idling.
function ShiftState.setIdle(idle)
	if idle then
		if not state.idle then
			state.idleSince = os.clock()
		end
		state.idle = true
	else
		state.idle = false
		state.idleSince = nil
		state.draining = false
	end
end

function ShiftState.isIdle()
	return state.idle
end

-- The reception decision, in one call, so the caller does not have to know
-- which stat goes with which number.
function ShiftState.applyDecision(decision, correct)
	if not state.running then
		return
	end

	if decision == "timeout" then
		-- Not a decision: the per-second idle drain has already charged for
		-- every second of it, and charging the wrong-answer penalty on top
		-- would bill the same mistake twice.
		ShiftState.bumpStat("timeouts")
		return
	end

	if decision == "admit" then
		ShiftState.bumpStat("admitted")
	elseif decision == "reject" then
		ShiftState.bumpStat("rejected")
	end

	if correct then
		ShiftState.bumpStat("correct")
		ShiftState.addScore(SCORE_CORRECT)
		ShiftState.adjustSanity(SANITY_CORRECT)
	else
		ShiftState.bumpStat("wrong")
		ShiftState.adjustSanity(SANITY_WRONG)
	end
end

function ShiftState.applyRoomOutcome(status)
	if not state.running then
		return
	end

	if status == "cured" then
		ShiftState.bumpStat("cured")
		ShiftState.addScore(SCORE_CURED)
		ShiftState.adjustSanity(SANITY_CURED)
	elseif status == "died" then
		ShiftState.bumpStat("died")
		ShiftState.adjustSanity(SANITY_DIED)
	end
	-- "failed" is a broken room, not a lost patient: no sanity either way.
end

--------------------------------------------------------------------------------
-- The clock
--------------------------------------------------------------------------------

local sinceBroadcast = 0

RunService.Heartbeat:Connect(function(dt)
	if not state.running then
		return
	end

	local draining = state.idle
		and state.idleSince ~= nil
		and (os.clock() - state.idleSince) >= IDLE_GRACE_SECONDS
	if draining ~= state.draining then
		state.draining = draining
		broadcast()
	end

	if draining then
		ShiftState.adjustSanity(SANITY_IDLE_PER_SECOND * dt)
		-- adjustSanity may have ended the shift on this very tick.
		if not state.running then
			return
		end
	end

	state.timeLeft = state.timeLeft - dt
	if state.timeLeft <= 0 then
		state.timeLeft = 0
		finish("win")
		return
	end

	sinceBroadcast = sinceBroadcast + dt
	if sinceBroadcast >= BROADCAST_INTERVAL then
		sinceBroadcast = 0
		broadcast()
	end
end)

--------------------------------------------------------------------------------
-- Client requests
--------------------------------------------------------------------------------

-- The only thing a client may ask for, and only when the shift is actually
-- over. Anything else about the shift is decided here.
shiftRestart.OnServerEvent:Connect(function(player)
	if state.running then
		return
	end
	print(("[Shift] %s начинает новую смену"):format(player.Name))
	ShiftState.start()
end)

-- A player who joins mid-shift (or mid-results-screen) gets the same picture
-- as everybody else instead of an empty HUD.
Players.PlayerAdded:Connect(function(player)
	shiftStarted:FireClient(player, snapshot())
	shiftUpdate:FireClient(player, snapshot())
	if not state.running and state.lastResult then
		shiftEnded:FireClient(player, state.lastResult)
	end
end)

return ShiftState

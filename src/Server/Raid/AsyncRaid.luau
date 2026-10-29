--!strict
--[[
	AsyncRaid (owner: raid agent): async raids on offline dens, inside pooled pocket dens (P1.3a).
	RaidService starts it; the rules are pure, in RaidRules ("Async raids in pocket dens").

	Start  Net.Requests.StartRaid (targetUserId, revengeRaidId?) -> RaidStart? Net.Limits.StartRaid,
	       one call at a time. Reads the defender's snapshot and presence, then
	       RaidRules.canStartAsync: kill switch (this file's only flag read), raider loaded with a den
	       and not raiding or carrying live, blocks both ways (the raider's reported list and the
	       snapshot's: the GetRaidTargets filter is not trusted), owner not online (a player here, or
	       fresh presence: raided live instead, D-043), the revenge id is a token in the raider's
	       own profile against this target, RaidRules.canRaid, something on the pads. Then the
	       defender's raid lock, a pooled pocket, and the raider is moved in. When this server
	       holds the defender's profile (Studio test dens) its loss count and shield are used.
	Raid   10 times a second: timer (Config.Raid.durationSeconds), RaidRules.pocketStep, traps,
	       guards. Walk speed = base x carrySpeedMultiplier(weight) x trap slow, set here, with the
	       raider's speed coil (Gear.speeds: the budget allows the coil until its grace ends).
	Gear   (P2.10, Raid/Gear.luau) gearContext(player) tells Gear about the raid; guards step
	       through GearRules.pocketGuardStep with the raider's smoke and decoy.
	Grab   Net.Requests.GrabCritter (raidId, critterUid), or a pad's prompt: RaidRules.canGrabAsync
	       against the raid's own snapshot copy and layout, server positions. One carry at a time.
	       Too fast or too high while carrying, or a Trapdoor: the critter goes back to its pad.
	End    Escaped (gate while carrying), Timeout, Tagged, Retreat (gate with nothing), Left (left
	       the game, died, left the pocket), Error. Every end releases the pocket and the raid lock,
	       sends the raider home and pushes Net.Pushes.RaidEnded with `reason`. An escape first
	       hands the raid to api.onEscape (RaidService.onAsyncEscape -> EscrowService), on its own
	       thread, and the push carries its real outcome (moved, pending, or nothing moved). The
	       lock is released after escrow answers.
	       StartRaid fails closed when presence cannot be read, and honours the shield of an
	       escape this server just completed until the den's next snapshot carries it.
	Log    Net.Requests.GetRaidLog -> a copy of the player's own raid log, and asks DataService to
	       mark it seen (markRaidLogSeen, data's, called once it exists). Player attribute
	       RaidLogSeenAt = the profile's raidLogSeenAt when it loaded. Display only.
	Replay The raider's position at Replay.HZ (5 Hz, from the 10 Hz tick) plus Grab, Drop, Trap,
	       Tag, Escape and Timeout events (Shared/Replay recorder, P1.4b). At every end the replay
	       goes to ReplayStore.save, which never yields or errors; every recorder call is pcall'd,
	       so a replay failure can never change a raid or its result.
	Never writes a profile.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local CritterCatalog = require(Shared.CritterCatalog)
local Escrow = require(Shared.Escrow)
local Net = require(Shared.Net)
local RaidRules = require(Shared.RaidRules)
local Replay = require(Shared.Replay)
local Types = require(Shared.Types)
local Services = script.Parent.Parent.Services
local DataService = require(Services.DataService) :: any
local DenWorldService = require(Services.DenWorldService) :: any
local MatchmakingService = require(Services.MatchmakingService) :: any
local SnapshotService = require(Services.SnapshotService) :: any
local Pocket = require(script.Parent.Pocket)
local Gear = require(script.Parent.Gear)
local GearRules = require(Shared.GearRules)
local ReplayStore = require(script.Parent.ReplayStore)

type DenSnapshot = Types.DenSnapshot
type PocketT = Pocket.Pocket

-- What RaidService.onAsyncEscape gets: everything server-tracked, nothing from the client.
export type Escape = {
	raidId: string,
	raiderUserId: number,
	defenderUserId: number,
	critterUid: string,
	speciesId: string,
	glowRequested: number, -- RaidRules.lootGlow of the raid's snapshot
	isRevenge: boolean,
	revengeRaidId: string?,
	snapshotPower: number, -- the snapshot's power: the band MatchmakingService.noteRaided updates
}

export type Api = {
	rootOf: (Player) -> BasePart?,
	isCarryingLive: (Player) -> boolean,
	raidEnded: RemoteEvent,
	remotes: Folder,
	onEscape: (Escape) -> RaidRules.EscapeOutcome, -- yields while escrow runs
}

type Carry = { uid: string, padIndex: number, speciesId: string, weight: Types.Weight, budget: number }
type Raid = {
	raidId: string,
	player: Player,
	defenderUserId: number,
	snapshot: DenSnapshot, -- server copy from the start; the only source of grabbable critters
	layout: RaidRules.PocketLayout,
	revengeRaidId: string?,
	endsAt: number, -- workspace:GetServerTimeNow()
	pocket: PocketT,
	carry: Carry?,
	guards: { RaidRules.GuardState },
	trapReadyAt: { [number]: number },
	slow: number,
	slowUntil: number,
	alertUntil: number,
	lastPos: Vector3,
	lastAt: number,
	settleUntil: number, -- os.clock(): no bounds check while the move into the pocket lands
	ended: boolean,
	replay: Replay.Recorder?, -- nil once saved, or if the recorder could not start
}

local TICK = 0.1
local SETTLE_SECONDS = 1.5
local LIMIT_WINDOW_SECONDS = 10

local AsyncRaid = {}

local api: Api
local raids: { [Player]: Raid } = {}
local starting: { [Player]: true } = {}
local windows: { [Player]: { [string]: { start: number, count: number } } } = {}
local recentShields: { [number]: number } = {} -- defender userId -> shieldUntil (os.time())

local function debugLog(message: string)
	if RunService:IsStudio() then
		print(`[AsyncRaid] {message}`)
	end
end

local function allow(player: Player, name: string): boolean
	local limit = (Net.Limits :: any)[name] or Net.Limits.default
	local now = os.clock()
	local perPlayer = windows[player] or {}
	windows[player] = perPlayer
	local window = perPlayer[name]
	if not window or now - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = now, count = 0 }
		perPlayer[name] = window
	end
	window.count += 1
	return window.count <= limit
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

-- Sets the raider's walk speed (carry weight, speed coil, any trap slow) and returns the speed the
-- movement budget allows: the coil's until its grace ends (P2.10).
local function applyWalkSpeed(raid: Raid): number
	local carry = raid.carry
	local speed = StarterPlayer.CharacterWalkSpeed
	if carry then
		speed = RaidRules.carryWalkSpeed(speed, carry.weight)
	end
	local set, allowed = Gear.speeds(raid.player, speed, carry ~= nil)
	if workspace:GetServerTimeNow() < raid.slowUntil then
		set *= raid.slow
		allowed *= raid.slow
	end
	local humanoid = humanoidOf(raid.player)
	if humanoid then
		humanoid.WalkSpeed = set
	end
	return allowed
end

-- Replay (P1.4b): recording may never affect the raid, so every call is guarded.
local function recordFrame(raid: Raid, now: number, pos: Vector3)
	local rec = raid.replay
	if rec then
		pcall(Replay.recordFrame, rec, now, pos.X, pos.Y, pos.Z)
	end
end

local function recordEvent(raid: Raid, kind: Replay.EventKind, arg: string?)
	local rec = raid.replay
	if rec then
		pcall(Replay.recordEvent, rec, workspace:GetServerTimeNow(), kind, arg)
	end
end

local lastReplay = "" -- Studio test hook only: what the last save handed to ReplayStore

-- Hands the replay to ReplayStore.save (its own thread, pcall'd, only warns). Never yields.
local function saveReplay(raid: Raid)
	local rec = raid.replay
	raid.replay = nil
	if rec == nil then
		return
	end
	local ok, err = pcall(function()
		local data = Replay.encode(rec)
		ReplayStore.save(raid.raidId, raid.player.UserId, raid.defenderUserId, rec.startedAt, data)
		if RunService:IsStudio() then
			lastReplay = `raid {raid.raidId}: {#data} bytes, {rec.frames} frames, {#rec.events} events`
		end
	end)
	if not ok then
		warn(`[AsyncRaid] replay for raid {raid.raidId} not saved: {err}`)
	end
end

local function dropCarry(raid: Raid, why: string)
	local carry = raid.carry
	raid.carry = nil
	raid.player:SetAttribute("CarryingUid", "")
	raid.player:SetAttribute("CarryingSpecies", "")
	if carry then
		Pocket.returnCritter(raid.pocket, carry.padIndex)
		debugLog(`{raid.player.Name} dropped {carry.speciesId} ({why})`)
		if not raid.ended then
			recordEvent(raid, "Drop", why)
		end
	end
end

local function sendHome(player: Player)
	local plot = DenWorldService.getPlot(player)
	local character = player.Character
	if plot and character and character.Parent then
		character:PivotTo(DenWorldService.getSpawnCFrame(plot))
	end
end

-- An escape's shield, before the den's next snapshot carries it: an offline debit changes the
-- saved profile, not the snapshot, so StartRaid here also honours what this server just did.
local function rememberShield(defenderUserId: number, shieldUntil: number)
	local now = os.time()
	for userId, untilAt in recentShields do
		if untilAt <= now then
			recentShields[userId] = nil
		end
	end
	if shieldUntil > now then
		recentShields[defenderUserId] = math.max(recentShields[defenderUserId] or 0, shieldUntil)
	end
end

local function endRaid(raid: Raid, reason: string)
	if raid.ended then
		return
	end
	raid.ended = true
	local player = raid.player
	if raids[player] == raid then
		raids[player] = nil
	end
	local carry = raid.carry
	local escaped = reason == "Escaped" and carry ~= nil
	local final = RaidRules.replayEndEvent(reason)
	if final then
		recordEvent(raid, final, nil)
	end
	saveReplay(raid)
	-- World first, each step guarded: the lock release below must always run.
	local cleaned, cleanError = pcall(function()
		dropCarry(raid, reason)
		local humanoid = humanoidOf(player)
		if humanoid then
			humanoid.WalkSpeed = StarterPlayer.CharacterWalkSpeed
		end
		if player.Parent then
			sendHome(player)
		end
	end)
	if not cleaned then
		warn(`[AsyncRaid] cleanup after raid {raid.raidId} failed: {cleanError}`)
	end
	local released, releaseError = pcall(Pocket.release, raid.pocket)
	if not released then
		warn(`[AsyncRaid] pocket {raid.pocket.slot} release failed: {releaseError}`)
	end
	task.spawn(function()
		local outcome: RaidRules.EscapeOutcome? = nil
		if escaped and carry then
			local ok, result = pcall(api.onEscape, {
				raidId = raid.raidId,
				raiderUserId = player.UserId,
				defenderUserId = raid.defenderUserId,
				critterUid = carry.uid,
				speciesId = carry.speciesId,
				glowRequested = RaidRules.lootGlow(raid.snapshot, raid.revengeRaidId ~= nil),
				isRevenge = raid.revengeRaidId ~= nil,
				revengeRaidId = raid.revengeRaidId,
				snapshotPower = raid.snapshot.power,
			})
			if ok then
				outcome = result
				rememberShield(raid.defenderUserId, result.shieldUntil)
			else
				-- Escrow may still have the raid (the raider's Open_ index): never claim "nothing".
				warn(`[AsyncRaid] onAsyncEscape for raid {raid.raidId} failed: {result}`)
				local inFlight = RaidRules.asyncEscapeOutcome("InFlight", nil, carry.speciesId, 0, os.time())
				outcome = inFlight
				rememberShield(raid.defenderUserId, inFlight.shieldUntil) -- before the lock releases
			end
		end
		pcall(MatchmakingService.releaseLock, raid.defenderUserId, raid.raidId)
		debugLog(`raid {raid.raidId} on {raid.defenderUserId} ended: {reason}`)
		if player.Parent then
			local payload: Net.RaidEnd = {
				raidId = raid.raidId,
				escaped = outcome ~= nil and outcome.escaped,
				speciesId = if outcome then outcome.speciesId elseif carry then carry.speciesId else nil,
				glow = if outcome then outcome.glow else 0,
				reason = reason,
				pending = if outcome and outcome.pending then true else nil,
			}
			pcall(api.raidEnded.FireClient, api.raidEnded, player, payload)
		end
	end)
end

local function grab(player: Player, raidId: any, critterUid: any)
	local raid = raids[player]
	if not raid or raid.ended or raidId ~= raid.raidId then
		return
	end
	local root = api.rootOf(player)
	local padIndex = if type(critterUid) == "string" then raid.layout.uids[critterUid] else nil
	local pad = if padIndex then raid.pocket.pads[padIndex] else nil
	local distance = if root and pad then (root.Position - pad.Position).Magnitude else math.huge
	local now = workspace:GetServerTimeNow()
	local ok, reason, critter =
		RaidRules.canGrabAsync(raid.snapshot, raid.layout, critterUid, raid.carry ~= nil, distance, now, raid.endsAt)
	local species = if critter then CritterCatalog.get(critter.speciesId) else nil
	if not (ok and critter and species and root and padIndex) then
		debugLog(`grab refused for {player.Name}: {reason or "unknown species"}`)
		return
	end
	raid.carry = {
		uid = critter.uid,
		padIndex = padIndex,
		speciesId = species.id,
		weight = species.weight,
		budget = RaidRules.carryStartBudget(),
	}
	raid.lastPos, raid.lastAt = root.Position, os.clock()
	Pocket.attachCritter(raid.pocket, padIndex, root)
	recordEvent(raid, "Grab", species.id)
	player:SetAttribute("CarryingUid", critter.uid)
	player:SetAttribute("CarryingSpecies", species.id)
	applyWalkSpeed(raid)
	debugLog(`{player.Name} grabbed {species.id} from pocket pad {padIndex}`)
end

local function stepRaid(raid: Raid)
	local player = raid.player
	local root = api.rootOf(player)
	if player.Parent == nil or not root then
		return endRaid(raid, "Left")
	end
	local now = workspace:GetServerTimeNow()
	if now >= raid.endsAt then
		return endRaid(raid, "Timeout")
	end
	local clock = os.clock()
	local dt = clock - raid.lastAt
	local pos = root.Position
	local delta = pos - raid.lastPos
	local x, z, height = Pocket.toLocal(raid.pocket, pos)
	local carry = raid.carry
	local outcome, budget = RaidRules.pocketStep({
		x = x,
		z = z,
		height = height,
		moved = Vector3.new(delta.X, 0, delta.Z).Magnitude,
		dt = dt,
		walkSpeed = applyWalkSpeed(raid),
		budget = if carry then carry.budget else 0,
		carrying = carry ~= nil,
	})
	raid.lastPos, raid.lastAt = pos, clock
	if outcome ~= "OutOfBounds" then -- not while the move into the pocket lands
		recordFrame(raid, now, pos)
	end
	if carry then
		carry.budget = budget
	end
	if outcome == "OutOfBounds" and clock >= raid.settleUntil then
		return endRaid(raid, "Left")
	elseif outcome == "AtGate" then
		return endRaid(raid, if carry then "Escaped" else "Retreat")
	elseif (outcome == "TooFast" or outcome == "TooHigh") and carry then
		dropCarry(raid, outcome) -- the critter goes back to its pad; the raid goes on
	end
	for i, trap in raid.layout.traps do
		if now >= (raid.trapReadyAt[i] or 0) and RaidRules.trapHit(trap, x, z) then
			raid.trapReadyAt[i] = now + RaidRules.Pocket.trapRearmSeconds
			local effect = RaidRules.trapEffect(trap.kind, trap.level)
			if effect.seconds > 0 then
				raid.slow, raid.slowUntil = effect.slow, now + effect.seconds
			end
			raid.alertUntil = math.max(raid.alertUntil, now + effect.alertSeconds)
			debugLog(`{player.Name} hit a {trap.kind}`)
			recordEvent(raid, "Trap", trap.kind)
			if effect.sendBack then
				dropCarry(raid, trap.kind)
				local spawn = Pocket.world(raid.pocket, raid.layout.spawn.x, raid.layout.spawn.z, 3)
				local character = player.Character :: Model
				character:PivotTo(CFrame.lookAt(spawn, spawn - Vector3.zAxis))
				raid.lastPos = spawn
				return
			end
		end
	end
	local alerted = now < raid.alertUntil
	-- Gear (P2.10): smoke hides the raider from guards, a decoy draws them off.
	local hidden = Gear.pocketHidden(player, raid.raidId, x, z)
	local decoy = Gear.pocketDecoy(player, raid.raidId)
	local here = { x = x, z = z }
	for i, guard in raid.guards do
		local tagged, reached =
			GearRules.pocketGuardStep(guard, raid.layout.guardRoutes[i], here, hidden, decoy, dt, alerted)
		Pocket.moveGuard(raid.pocket, i, guard.x, guard.z)
		if reached then
			Gear.popDecoy(player)
			decoy = nil
		end
		if tagged then
			return endRaid(raid, "Tagged")
		end
	end
	applyWalkSpeed(raid)
end

-- After the lock is held: re-check what the yields may have changed, then build and enter.
local function enterPocket(
	player: Player,
	raidId: string,
	snapshot: DenSnapshot,
	revengeRaidId: string?
): (Net.RaidStart?, string?)
	local root = api.rootOf(player)
	local character = player.Character
	if player.Parent == nil or not root or not character or raids[player] or api.isCarryingLive(player) then
		return nil, RaidRules.Reason.RaiderNotReady
	end
	if DenWorldService.getPlot(player) == nil or DataService.getProfile(player.UserId) == nil then
		return nil, RaidRules.Reason.RaiderNotReady
	end
	-- The owner may have joined this server during the lock call: raided live instead (D-043).
	if Players:GetPlayerByUserId(snapshot.userId) ~= nil then
		return nil, RaidRules.Reason.DefenderOnline
	end
	local pocket = Pocket.acquire()
	if not pocket then
		debugLog(`no free pocket for {player.Name}`)
		return nil, RaidRules.Reason.NoPocket
	end
	local ok, result = pcall(function(): Net.RaidStart
		local layout = RaidRules.pocketLayout(snapshot)
		local view = RaidRules.pocketView(snapshot)
		local species: { [number]: string } = {}
		for _, row in view do
			species[row.padIndex] = row.speciesId
		end
		Pocket.dress(pocket, layout, species)
		local critters: { Net.PocketCritter } = {}
		for _, row in view do
			table.insert(critters, {
				uid = row.uid,
				speciesId = row.speciesId,
				mutation = row.mutation,
				padIndex = row.padIndex,
				position = pocket.pads[row.padIndex].Position,
			})
		end
		local guards: { RaidRules.GuardState } = {}
		for i, route in layout.guardRoutes do
			guards[i] = RaidRules.newGuard(route)
			Pocket.moveGuard(pocket, i, guards[i].x, guards[i].z)
		end
		local spawn = Pocket.world(pocket, layout.spawn.x, layout.spawn.z, 3)
		character:PivotTo(CFrame.lookAt(spawn, spawn - Vector3.zAxis))
		local startedAt = workspace:GetServerTimeNow()
		local origin = pocket.origin
		local recOk, rec = pcall(Replay.newRecorder, startedAt, origin.X, origin.Y, origin.Z)
		local raid: Raid = {
			raidId = raidId,
			player = player,
			defenderUserId = snapshot.userId,
			snapshot = snapshot,
			layout = layout,
			revengeRaidId = revengeRaidId,
			endsAt = startedAt + Config.Raid.durationSeconds,
			replay = if recOk then rec else nil,
			pocket = pocket,
			carry = nil,
			guards = guards,
			trapReadyAt = {},
			slow = 1,
			slowUntil = 0,
			alertUntil = 0,
			lastPos = spawn,
			lastAt = os.clock(),
			settleUntil = os.clock() + SETTLE_SECONDS,
			ended = false,
		}
		raids[player] = raid
		recordFrame(raid, startedAt, spawn)
		player:SetAttribute("CarryingUid", "")
		player:SetAttribute("CarryingSpecies", "")
		return {
			raidId = raidId,
			targetUserId = snapshot.userId,
			endsAt = raid.endsAt,
			gatePosition = Pocket.world(pocket, layout.gate.x, layout.gate.z, 3),
			critters = critters,
			isRevenge = revengeRaidId ~= nil,
		}
	end)
	if not ok then
		raids[player] = nil
		pcall(Pocket.release, pocket)
		pcall(sendHome, player) -- the raider may already be standing in the pocket
		error(result)
	end
	return result, nil
end

local function startRaid(player: Player, targetUserId: number, revengeRaidId: string?): (Net.RaidStart?, string?)
	local isRevenge = revengeRaidId ~= nil
	local flagsAllow = (Escrow.canStartTransfer(Config.Flags, "Async", isRevenge))
	if not flagsAllow then
		return nil, RaidRules.Reason.SwitchedOff
	end
	local found = SnapshotService.get(targetUserId) -- yields
	-- Fail closed: an owner we cannot place may be online, and is raided live instead (D-043).
	-- A second result of false is a failed read (matchmaking handoff: getPresence returns it).
	local presenceRead, presence, presenceOk = pcall(MatchmakingService.getPresence, targetUserId) -- yields
	if not presenceRead or presenceOk == false then
		return nil, RaidRules.Reason.PresenceUnknown
	end
	local now = os.time()
	local snapshot: DenSnapshot? = if type(found) == "table" then table.clone(found) else nil
	if snapshot then
		snapshot.shieldUntil = math.max(snapshot.shieldUntil, recentShields[targetUserId] or 0)
	end
	local losses = 0
	local defender = DataService.getProfile(targetUserId) -- only a Studio test den is ever here
	if defender and snapshot then
		losses = RaidRules.lossesToday(defender, now)
		snapshot.shieldUntil = math.max(snapshot.shieldUntil, defender.shieldUntil)
	end
	local ok, reason = RaidRules.canStartAsync({
		flagsAllow = flagsAllow,
		raider = DataService.getProfile(player.UserId), -- read after the yields
		hasDen = DenWorldService.getPlot(player) ~= nil,
		busy = raids[player] ~= nil or api.isCarryingLive(player),
		targetUserId = targetUserId,
		snapshot = snapshot,
		raiderBlocked = SnapshotService.blockedBy(player.UserId),
		defenderOnline = Players:GetPlayerByUserId(targetUserId) ~= nil
			or RaidRules.presenceFresh(if presence then presence.at else nil, now),
		defenderLossesToday = losses,
		revengeRaidId = revengeRaidId,
		now = now,
	})
	if not ok or snapshot == nil then
		return nil, reason
	end
	local raidId = HttpService:GenerateGUID(false)
	local locked, why = MatchmakingService.acquireLock(targetUserId, player.UserId, raidId) -- yields
	if not locked then
		return nil, if why == "Locked" then RaidRules.Reason.Locked else why
	end
	local entered, result, refusal = pcall(enterPocket, player, raidId, snapshot, revengeRaidId)
	if not entered or result == nil then
		pcall(MatchmakingService.releaseLock, targetUserId, raidId)
		if not entered then
			warn(`[AsyncRaid] could not start raid {raidId}: {result}`)
		end
		return nil, if entered then refusal else "Error"
	end
	debugLog(`{player.Name} started raid {raidId} on {targetUserId}{if isRevenge then " (revenge)" else ""}`)
	return result, nil
end

local function onStartRaid(player: Player, targetUserId: any, revengeRaidId: any): Net.RaidStart?
	if not allow(player, "StartRaid") or starting[player] then
		return nil
	end
	local idOk = type(targetUserId) == "number"
		and targetUserId == targetUserId
		and targetUserId % 1 == 0
		and math.abs(targetUserId) < 2 ^ 53
	local revengeOk = revengeRaidId == nil
		or (type(revengeRaidId) == "string" and #revengeRaidId > 0 and #revengeRaidId <= Config.Escrow.maxRaidIdLength)
	if not (idOk and revengeOk) then
		return nil
	end
	starting[player] = true
	local ok, result, reason = pcall(startRaid, player, targetUserId, revengeRaidId)
	starting[player] = nil
	if not ok then
		warn(`[AsyncRaid] StartRaid for {player.UserId} failed: {result}`)
		return nil
	end
	if result == nil then
		debugLog(`StartRaid refused for {player.Name} on {targetUserId}: {reason}`)
	end
	return result
end

local function onGetRaidLog(player: Player): { Types.RaidLogEntry }
	local profile = if allow(player, "GetRaidLog") then DataService.getProfile(player.UserId) else nil
	if profile == nil then
		return {}
	end
	local list = {}
	for i, entry in profile.raidLog do
		list[i] = table.clone(entry)
	end
	local mark = DataService.markRaidLogSeen -- data's (handoff); the attribute stays at the load value
	if type(mark) == "function" then
		pcall(mark, player.UserId, os.time())
	end
	return list
end

-- Studio only: start a raid without the UI. Same path as StartRaid minus the rate limit.
local function testHook(command: string, targetUserId: any, revengeRaidId: any): string
	local player = Players:GetPlayers()[1]
	if not player then
		return "no player"
	end
	if command == "start" then
		local result, reason = startRaid(player, tonumber(targetUserId) or -1_000_101, revengeRaidId)
		if not result then
			return `refused: {reason}`
		end
		return `raid {result.raidId}: {#result.critters} critter(s), ends in {Config.Raid.durationSeconds} s`
	elseif command == "status" then
		local raid = raids[player]
		if not raid then
			return "not raiding"
		end
		local left = math.ceil(raid.endsAt - workspace:GetServerTimeNow())
		local carrying = if raid.carry then raid.carry.speciesId else "nothing"
		return `raid {raid.raidId} on {raid.defenderUserId}: {left} s left, carrying {carrying}, {#raid.guards} guard(s), {#raid.layout.traps} trap(s)`
	elseif command == "gate" then
		local raid = raids[player]
		local character = player.Character
		if raid and character then
			local gate = Pocket.world(raid.pocket, raid.layout.gate.x, raid.layout.gate.z, 3)
			character:PivotTo(CFrame.new(gate))
			return "teleported to the gate (a carried critter must drop: TooFast)"
		end
		return "not raiding"
	elseif command == "replay" then
		return if lastReplay == "" then "no replay saved yet" else lastReplay
	end
	return `unknown command {command}`
end

-- What Raid/Gear.luau needs to know about a player's pocket raid (P2.10); nil = not in one.
function AsyncRaid.gearContext(player: Player): Gear.AsyncContext?
	local raid = raids[player]
	if raid == nil or raid.ended then
		return nil
	end
	return {
		raidId = raid.raidId,
		pocket = raid.pocket,
		carrying = raid.carry ~= nil,
		trapped = workspace:GetServerTimeNow() < raid.slowUntil and raid.slow < 1,
	}
end

function AsyncRaid.start(injected: Api)
	api = injected
	local remotes = injected.remotes
	local startRemote = Instance.new("RemoteFunction")
	startRemote.Name = Net.Requests.StartRaid
	startRemote.OnServerInvoke = onStartRaid
	startRemote.Parent = remotes
	local grabRemote = Instance.new("RemoteEvent")
	grabRemote.Name = Net.Requests.GrabCritter
	grabRemote.OnServerEvent:Connect(function(player: Player, raidId: any, critterUid: any)
		if allow(player, "GrabCritter") then
			grab(player, raidId, critterUid)
		end
	end)
	grabRemote.Parent = remotes
	local logRemote = Instance.new("RemoteFunction")
	logRemote.Name = Net.Requests.GetRaidLog
	logRemote.OnServerInvoke = onGetRaidLog
	logRemote.Parent = remotes

	Pocket.onPrompt(function(player: Player, pocket: PocketT, padIndex: number)
		local raid = raids[player]
		if raid and raid.pocket == pocket and allow(player, "GrabCritter") then
			for uid, index in raid.layout.uids do
				if index == padIndex then
					grab(player, raid.raidId, uid)
				end
			end
		end
	end)
	DataService.onProfileLoaded(function(player: Player, profile: Types.PlayerProfile)
		player:SetAttribute("RaidLogSeenAt", RaidRules.raidLogSeenAt(profile))
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		local raid = raids[player]
		if raid then
			endRaid(raid, "Left")
		end
		windows[player] = nil
	end)
	game:BindToClose(function()
		for _, raid in raids do
			pcall(MatchmakingService.releaseLock, raid.defenderUserId, raid.raidId)
		end
	end)
	local clock = 0
	RunService.Heartbeat:Connect(function(dt: number)
		clock += dt
		if clock < TICK then
			return
		end
		clock = 0
		for _, raid in raids do
			local ok, err = pcall(stepRaid, raid)
			if not ok then
				warn(`[AsyncRaid] raid {raid.raidId} step failed: {err}`)
				endRaid(raid, "Error")
			end
		end
	end)
	if RunService:IsStudio() then
		local bindable = Instance.new("BindableFunction")
		bindable.Name = "AsyncRaidTestHook"
		bindable.OnInvoke = function(command: string, a: any, b: any): string
			local ok, result = pcall(testHook, command, a, b)
			return if ok then result else `error: {result}`
		end
		bindable.Parent = ServerStorage
	end
end

return AsyncRaid

--!strict
--[[
	Gear (owner: raid agent): raider gear in the shared world ("Live") and in async pocket raids
	("Async"), P2.10. Started by RaidService. The rules are pure, in Shared/GearRules.luau; this file
	feeds them server state and applies the result. The client only asks.

	  UseGear  Net.Requests.UseGear (gearId, target?) -> GearUseResult, Net.Limits.UseGear per 10 s.
	           Level from the player's own loaded profile (Profile.gearLevel, read only), cooldowns
	           and async charges from this file's memory, carrying and trap state from RaidService /
	           AsyncRaid, then GearRules.canUse. The cooldown (and a charge) is spent only when the
	           effect really happened; a refused grapple costs nothing.
	  GetGear  Net.Requests.GetGear () -> { GearSlot }, for the HUD.
	  Push     Net.Pushes.GearUsed (GearEvent) for effects: to every player for the shared world,
	           to the raider alone for a pocket.

	Effects (GearRules has the reasons):
	  grapple    target = the client's aim point. Server checks: GearRules.checkGrapple on the aim
	             point and again on the landing, a raycast from the root part to the aim point (line
	             of sight) and one down under it (ground), the pocket floor (async), and never into a
	             den whose Lockdown would push the raider out (Lockdown.blocks, live). Then the server
	             moves the character (PivotTo). Never while carrying, so no carry's movement budget
	             or street check ever sees a grapple.
	  smoke      A cloud at the root part. Live: RaidService asks liveTagRange for each carrier.
	             Async: AsyncRaid asks pocketHidden for the guards.
	  decoy      A dummy running ahead of the raider. Live: popped by any other player within
	             Config.LiveRaid.tagRange. Async: AsyncRaid asks pocketDecoy for the guards and calls
	             popDecoy when one reaches it.
	  speedCoil  A walk speed factor. RaidService (live carry) and AsyncRaid (pocket) ask speeds();
	             for everyone else this file sets the humanoid's WalkSpeed while a coil runs.
	  lockpick   Live only. A server-timed pick at the nearest den's border (GearRules.canStartPick,
	             then pickStep 10 times a second); when done, Lockdown.grantPass.

	Budget: at most one smoke cloud (1 part) and one decoy (1 part, 2 while carrying) per player at
	a time (every cooldown outlasts its effect: GearRules spec), all in workspace.GearEffects,
	CanCollide/CanQuery/CanTouch off, destroyed when they end or the player leaves.

	Never writes a profile and never reads an attribute (RaidServiceSource spec). Cooldowns and
	charges are server memory: leaving the server clears them.

	Studio only: ServerStorage.GearTestHook (BindableFunction), for playtests before the Glow
	purchase ships (economy handoff). In server memory only, never a profile:
	  level <0-5>          every player's gear reads as this level ("level off" = the profile's)
	  use <gearId> [x y z] the first player uses it; the grapple aims at (x, y, z), or 16 studs
	                       ahead when no point is given
	  reset                clear every cooldown and charge
	  status               the first player's cooldowns, charges and running effects
]]

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local GearRules = require(Shared.GearRules)
local Net = require(Shared.Net)
local Plots = require(Shared.Plots)
local Profile = require(Shared.Profile)
local RaidRules = require(Shared.RaidRules)
local Types = require(Shared.Types)
local Services = script.Parent.Parent.Services
local DataService = require(Services.DataService) :: any
local DenWorldService = require(Services.DenWorldService) :: any
local Lockdown = require(script.Parent.Lockdown)
local Pocket = require(script.Parent.Pocket)

type GearId = Types.GearId
type PocketT = Pocket.Pocket

-- What AsyncRaid tells this file about a player's pocket raid (nil = not in one).
export type AsyncContext = {
	raidId: string,
	pocket: PocketT,
	carrying: boolean,
	trapped: boolean, -- a trap's slow is on
}

export type Api = {
	remotes: Folder,
	rootOf: (Player) -> BasePart?,
	liveAllowed: () -> boolean, -- RaidService's kill switch check (raids on)
	isCarryingLive: (Player) -> boolean,
	asyncOf: (Player) -> AsyncContext?,
	ownerRootOf: (plot: number) -> BasePart?, -- the den owner's root part, nil = none
}

type Effect = { part: BasePart, raidId: string? } -- raidId set for a pocket effect
type SmokeFx = Effect & { cloud: GearRules.Cloud }
type DecoyFx = Effect & { decoy: GearRules.Decoy, y: number, pocket: PocketT?, critter: BasePart? }
type State = {
	readyAt: { [string]: number },
	charges: { [string]: number },
	chargesRaidId: string?, -- the async raid `charges` belong to
	coil: GearRules.Coil?,
	pick: GearRules.Pick?,
	smoke: SmokeFx?,
	decoy: DecoyFx?,
}

local TICK = 0.1
local LIMIT_WINDOW_SECONDS = 10
local LANDING_HEIGHT = 3 -- root part above the ground it lands on
local GROUND_PROBE = 12 -- studs below the aim point the ground must be
local SMOKE_COLOR = Color3.fromRGB(150, 150, 170)
local DECOY_COLOR = Color3.fromRGB(120, 110, 200)
local DECOY_CRITTER_COLOR = Color3.fromRGB(255, 220, 120)
local GRAPPLE_BACKOFF = 1.5 -- studs short of the aim point, so a wall aim never lands inside it
local POCKET_BOUND = RaidRules.Pocket.size / 2 - 2 -- a pocket decoy stays this close to the centre

local Gear = {}

local api: Api
local states: { [Player]: State } = {}
local windows: { [Player]: { [string]: { start: number, count: number } } } = {}
local gearUsed: RemoteEvent
local effects: Folder
-- Studio only (GearTestHook): every gear reads as this level. nil = the profile's level.
local studioLevel: number? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function debugLog(message: string)
	if RunService:IsStudio() then
		print(`[Gear] {message}`)
	end
end

local function stateOf(player: Player): State
	local state = states[player]
	if not state then
		state = { readyAt = {}, charges = {}, chargesRaidId = nil, coil = nil, pick = nil, smoke = nil, decoy = nil }
		states[player] = state
	end
	return state
end

local function allow(player: Player, name: string): boolean
	local limit = (Net.Limits :: any)[name] or Net.Limits.default
	local clock = os.clock()
	local perPlayer = windows[player] or {}
	windows[player] = perPlayer
	local window = perPlayer[name]
	if not window or clock - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = clock, count = 0 }
		perPlayer[name] = window
	end
	window.count += 1
	return window.count <= limit
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function push(player: Player, event: Net.GearEvent, pocketOnly: boolean)
	if pocketOnly then
		gearUsed:FireClient(player, event)
	else
		gearUsed:FireAllClients(event)
	end
end

local function effectPart(name: string, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function clearSmoke(state: State)
	local fx = state.smoke
	state.smoke = nil
	if fx then
		fx.part:Destroy()
	end
end

local function clearDecoy(player: Player, state: State, early: boolean)
	local fx = state.decoy
	state.decoy = nil
	if fx then
		fx.part:Destroy()
		if early then
			push(player, { userId = player.UserId, gearId = "decoy", state = "Ended", at = now() }, fx.raidId ~= nil)
		end
	end
end

local function endPick(player: Player, state: State, outcome: "Done" | "Interrupted", reason: string?)
	local pick = state.pick
	state.pick = nil
	if pick then
		push(player, {
			userId = player.UserId,
			gearId = "lockpick",
			state = outcome,
			at = now(),
			plot = pick.plot,
			reason = reason,
		}, false)
		debugLog(`{player.Name} lockpick on den {pick.plot}: {outcome}{if reason then ` ({reason})` else ""}`)
	end
end

-- The player's level of one gear item: their own profile's (read only), or the Studio override.
local function levelOf(profile: Types.PlayerProfile, gearId: GearId): number
	if studioLevel ~= nil and RunService:IsStudio() then
		return studioLevel
	end
	return Profile.gearLevel(profile, gearId)
end

-- Async charges are per raid: a new raid id refills them from the profile's levels.
local function chargesFor(state: State, ctx: AsyncContext?, profile: Types.PlayerProfile)
	if ctx == nil or state.chargesRaidId == ctx.raidId then
		return
	end
	state.chargesRaidId = ctx.raidId
	for _, id in Profile.GEAR_IDS do
		state.charges[id] = GearRules.asyncCharges(id, levelOf(profile, id))
	end
end

-- Effects ---------------------------------------------------------------------------------------

type Use = {
	player: Player,
	state: State,
	level: number,
	target: any,
	ctx: AsyncContext?,
	root: BasePart,
	at: number,
}

local function excludeList(): { Instance }
	local list: { Instance } = { effects }
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(list, other.Character)
		end
	end
	return list
end

local function grapple(u: Use): (boolean, string?)
	if typeof(u.target) ~= "Vector3" then
		return false, GearRules.Reason.BadRequest
	end
	local target: Vector3 = u.target
	local from = u.root.Position
	local ok, reason = GearRules.checkGrapple(
		u.level,
		{ x = from.X, y = from.Y, z = from.Z },
		{ x = target.X, y = target.Y, z = target.Z }
	)
	if not ok then
		return false, reason
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeList()
	local toTarget = target - from
	local blocked = workspace:Raycast(from, toTarget, params)
	if blocked and (blocked.Position - from).Magnitude < toTarget.Magnitude - 1 then
		return false, GearRules.Reason.NoLineOfSight
	end
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	local probe = target - flat.Unit * GRAPPLE_BACKOFF + Vector3.new(0, 1, 0)
	local ground = workspace:Raycast(probe, Vector3.new(0, -GROUND_PROBE, 0), params)
	if not ground then
		return false, GearRules.Reason.NoLineOfSight -- nothing to stand on
	end
	local landing = ground.Position + Vector3.new(0, LANDING_HEIGHT, 0)
	ok, reason = GearRules.checkGrapple(
		u.level,
		{ x = from.X, y = from.Y, z = from.Z },
		{ x = landing.X, y = landing.Y, z = landing.Z }
	)
	if not ok then
		return false, reason
	end
	local ctx = u.ctx
	if ctx then
		local x, z = Pocket.toLocal(ctx.pocket, landing)
		if not GearRules.pocketLandingOk(x, z) then
			return false, GearRules.Reason.OutOfBounds
		end
	else
		local plot = DenWorldService.plotAt(landing)
		if plot and Lockdown.blocks(u.player, plot) then
			return false, GearRules.Reason.LockdownBlocked
		end
	end
	local character = u.player.Character
	if not character then
		return false, GearRules.Reason.NotReady
	end
	character:PivotTo(CFrame.new(landing) * u.root.CFrame.Rotation)
	push(u.player, {
		userId = u.player.UserId,
		gearId = "grapple",
		state = "Used",
		at = u.at,
		from = from,
		position = landing,
	}, ctx ~= nil)
	return true, nil
end

local function smoke(u: Use): (boolean, string?)
	local pos = u.root.Position
	local ctx = u.ctx
	local x, z = pos.X, pos.Z
	if ctx then
		x, z = Pocket.toLocal(ctx.pocket, pos)
	end
	local cloud = GearRules.newSmoke(u.level, x, z, u.at)
	clearSmoke(u.state)
	local part = effectPart("Smoke", SMOKE_COLOR)
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * cloud.radius * 2
	part.Transparency = 0.35
	part.Material = Enum.Material.SmoothPlastic
	part.CFrame = CFrame.new(pos)
	part.Parent = effects
	u.state.smoke = { part = part, raidId = if ctx then ctx.raidId else nil, cloud = cloud }
	push(u.player, {
		userId = u.player.UserId,
		gearId = "smoke",
		state = "Used",
		at = u.at,
		endsAt = cloud.endsAt,
		position = pos,
		radius = cloud.radius,
	}, ctx ~= nil)
	return true, nil
end

local function decoy(u: Use): (boolean, string?)
	local pos = u.root.Position
	local look = u.root.CFrame.LookVector
	local ctx = u.ctx
	local x, z = pos.X, pos.Z
	if ctx then
		x, z = Pocket.toLocal(ctx.pocket, pos)
	end
	local d = GearRules.newDecoy(u.level, x, z, look.X, look.Z, u.at)
	clearDecoy(u.player, u.state, false)
	local part = effectPart("Decoy", DECOY_COLOR)
	part.Size = Vector3.new(2, 5, 1)
	part.Material = Enum.Material.SmoothPlastic
	part.CFrame = CFrame.lookAt(pos, pos + Vector3.new(d.dirX, 0, d.dirZ))
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(140, 28)
	tag.StudsOffset = Vector3.new(0, 3.5, 0)
	tag.MaxDistance = 60
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Text = u.player.DisplayName
	label.Parent = tag
	tag.Parent = part
	-- A carrier's decoy carries a critter too (display only).
	local critter: BasePart? = nil
	local carrying = if ctx then ctx.carrying else api.isCarryingLive(u.player)
	if carrying then
		local ball = effectPart("DecoyCritter", DECOY_CRITTER_COLOR)
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.one * 2
		ball.Material = Enum.Material.Neon
		ball.CFrame = part.CFrame * CFrame.new(0, 4, 0)
		ball.Parent = part
		critter = ball
	end
	part.Parent = effects
	u.state.decoy = {
		part = part,
		raidId = if ctx then ctx.raidId else nil,
		decoy = d,
		y = pos.Y,
		pocket = if ctx then ctx.pocket else nil,
		critter = critter,
	}
	push(u.player, {
		userId = u.player.UserId,
		gearId = "decoy",
		state = "Used",
		at = u.at,
		endsAt = d.endsAt,
		position = pos,
		direction = Vector3.new(d.dirX, 0, d.dirZ),
	}, ctx ~= nil)
	return true, nil
end

local function speedCoil(u: Use): (boolean, string?)
	local coil = GearRules.newCoil(u.level, u.at)
	u.state.coil = coil
	push(u.player, {
		userId = u.player.UserId,
		gearId = "speedCoil",
		state = "Used",
		at = u.at,
		endsAt = coil.endsAt,
	}, u.ctx ~= nil)
	return true, nil
end

-- The den whose border is nearest to (x, z), and how far.
local function nearestDen(x: number, z: number): (number, number)
	local best, bestDistance = 1, math.huge
	for plot = 1, Plots.Layout.plotCount do
		local d = GearRules.borderDistance(plot, x, z)
		if d < bestDistance then
			best, bestDistance = plot, d
		end
	end
	return best, bestDistance
end

local function lockpick(u: Use): (boolean, string?)
	local pos = u.root.Position
	local plot, distance = nearestDen(pos.X, pos.Z)
	local ownerUserId, lockdown = Lockdown.current(plot)
	if ownerUserId == nil or lockdown == nil then
		return false, GearRules.Reason.NoLockdown
	end
	local ok, reason = GearRules.canStartPick({
		lockdown = lockdown,
		now = u.at,
		isOwner = ownerUserId == u.player.UserId,
		inside = DenWorldService.plotAt(pos) == plot,
		borderDistance = distance,
		pass = Lockdown.passOf(u.player),
		ownerUserId = ownerUserId,
	})
	if not ok then
		return false, reason
	end
	local pick = GearRules.newPick(u.level, plot, ownerUserId, lockdown, pos.X, pos.Z, u.at)
	u.state.pick = pick
	push(u.player, {
		userId = u.player.UserId,
		gearId = "lockpick",
		state = "Used",
		at = u.at,
		endsAt = pick.doneAt,
		position = pos,
		plot = plot,
	}, false)
	return true, nil
end

local EFFECTS: { [string]: (Use) -> (boolean, string?) } = {
	grapple = grapple,
	smoke = smoke,
	decoy = decoy,
	speedCoil = speedCoil,
	lockpick = lockpick,
}

-- Requests --------------------------------------------------------------------------------------

-- A refusal, with the gear's cooldown and (in a pocket raid) its charges when the id is known.
local function refuse(reason: string?, state: State?, gearId: GearId?, ctx: AsyncContext?): Net.GearUseResult
	local readyAt = if state and gearId then state.readyAt[gearId] else nil
	local charges = if state and gearId and ctx then state.charges[gearId] else nil
	return { ok = false, reason = reason, readyAt = readyAt, charges = charges }
end

local function useGear(player: Player, gearId: any, target: any): Net.GearUseResult
	local profile = DataService.getProfile(player.UserId)
	local root = api.rootOf(player)
	if profile == nil or root == nil then
		return refuse(GearRules.Reason.NotReady, nil, nil, nil)
	end
	if not api.liveAllowed() then
		return refuse(GearRules.Reason.SwitchedOff, nil, nil, nil)
	end
	local state = stateOf(player)
	local ctx = api.asyncOf(player)
	chargesFor(state, ctx, profile)
	local at = now()
	local valid = GearRules.isGearId(gearId)
	local level = if valid then levelOf(profile, gearId) else 0
	local ok, reason = GearRules.canUse({
		gearId = gearId,
		level = level,
		kind = if ctx then "Async" else "Live",
		now = at,
		readyAt = if valid then state.readyAt[gearId] else nil,
		charges = if ctx and valid then state.charges[gearId] else nil,
		carrying = if ctx then ctx.carrying else api.isCarryingLive(player),
		trapped = if ctx then ctx.trapped else false,
		picking = state.pick ~= nil,
	})
	if not ok then
		return refuse(reason, state, if valid then gearId else nil, ctx)
	end
	local id: GearId = gearId
	local applied, why =
		EFFECTS[id]({ player = player, state = state, level = level, target = target, ctx = ctx, root = root, at = at })
	if not applied then
		debugLog(`{player.Name} {id} refused: {why}`)
		return refuse(why, state, id, ctx)
	end
	state.readyAt[id] = GearRules.readyAfter(id, level, at)
	if ctx then
		state.charges[id] -= 1
	end
	debugLog(`{player.Name} used {id} (level {level}{if ctx then ", pocket" else ""})`)
	return {
		ok = true,
		readyAt = state.readyAt[id],
		charges = if ctx then state.charges[id] else nil,
	}
end

local function getGear(player: Player): { Net.GearSlot }
	local profile = DataService.getProfile(player.UserId)
	if profile == nil then
		return {}
	end
	local state = stateOf(player)
	local ctx = api.asyncOf(player)
	chargesFor(state, ctx, profile)
	local rows: { Net.GearSlot } = {}
	for _, id in Profile.GEAR_IDS do
		table.insert(rows, {
			id = id,
			level = levelOf(profile, id),
			readyAt = state.readyAt[id] or 0,
			charges = if ctx then state.charges[id] else nil,
			liveOnly = GearRules.LIVE_ONLY[id] == true,
		})
	end
	return rows
end

-- Queries for RaidService and AsyncRaid ---------------------------------------------------------

--[[
	Walk speeds with the player's speed coil. `current` is the speed without gear (base walking or
	the carry speed). Returns the speed to set on the humanoid now, and the speed the movement
	budget must allow (the coil's until GearRules' grace after it ends).
]]
function Gear.speeds(player: Player, current: number, carrying: boolean): (number, number)
	local state = states[player]
	local coil = if state then state.coil else nil
	local base = StarterPlayer.CharacterWalkSpeed
	local t = now()
	return GearRules.walkSpeed(base, current, carrying, GearRules.coilFactor(coil, t)),
		GearRules.walkSpeed(base, current, carrying, GearRules.coilAllowedFactor(coil, t))
end

-- How close a den owner must come to tag a live carrier standing at `position`: smoke shrinks it.
function Gear.liveTagRange(position: Vector3): number
	local clouds: { GearRules.Cloud } = {}
	for _, state in states do
		local fx = state.smoke
		if fx and fx.raidId == nil then
			table.insert(clouds, fx.cloud)
		end
	end
	return GearRules.carrierTagRange(GearRules.inSmoke(clouds, position.X, position.Z, now()))
end

-- Is this raider (pocket-local x, z) inside their own smoke in this raid?
function Gear.pocketHidden(player: Player, raidId: string, x: number, z: number): boolean
	local state = states[player]
	local fx = if state then state.smoke else nil
	return fx ~= nil and fx.raidId == raidId and GearRules.inSmoke({ fx.cloud }, x, z, now())
end

-- The raider's running decoy in this raid, pocket-local, or nil.
function Gear.pocketDecoy(player: Player, raidId: string): GearRules.Point?
	local state = states[player]
	local fx = if state then state.decoy else nil
	local t = now()
	if fx == nil or fx.raidId ~= raidId or not GearRules.decoyActive(fx.decoy, t) then
		return nil
	end
	return GearRules.decoyAt(fx.decoy, t, POCKET_BOUND)
end

-- A guard reached the raider's decoy.
function Gear.popDecoy(player: Player)
	local state = states[player]
	if state then
		clearDecoy(player, state, true)
	end
end

-- Tick ------------------------------------------------------------------------------------------

local function stepDecoy(player: Player, state: State, t: number)
	local fx = state.decoy
	if fx == nil then
		return
	end
	local ctx = api.asyncOf(player)
	local pocketGone = fx.raidId ~= nil and (ctx == nil or ctx.raidId ~= fx.raidId)
	if not GearRules.decoyActive(fx.decoy, t) or pocketGone then
		clearDecoy(player, state, false)
		return
	end
	local pocket = fx.pocket
	local p = GearRules.decoyAt(fx.decoy, t, if pocket then POCKET_BOUND else nil)
	local world = if pocket then Pocket.world(pocket, p.x, p.z, fx.y - pocket.origin.Y) else Vector3.new(p.x, fx.y, p.z)
	fx.part.CFrame = CFrame.lookAt(world, world + Vector3.new(fx.decoy.dirX, 0, fx.decoy.dirZ))
	if fx.critter then
		fx.critter.CFrame = fx.part.CFrame * CFrame.new(0, 4, 0)
	end
	if pocket == nil then
		for _, other in Players:GetPlayers() do
			local root = if other ~= player then api.rootOf(other) else nil
			if root then
				local gap = root.Position - world
				if Vector3.new(gap.X, 0, gap.Z).Magnitude <= Config.LiveRaid.tagRange then
					clearDecoy(player, state, true)
					return
				end
			end
		end
	end
end

local function stepSmoke(player: Player, state: State, t: number)
	local fx = state.smoke
	if fx == nil then
		return
	end
	local ctx = api.asyncOf(player)
	local pocketGone = fx.raidId ~= nil and (ctx == nil or ctx.raidId ~= fx.raidId)
	if t >= fx.cloud.endsAt or pocketGone then
		clearSmoke(state)
	end
end

-- A coil for someone neither carrying live nor in a pocket: this file sets their WalkSpeed.
local function stepCoil(player: Player, state: State, t: number)
	local coil = state.coil
	if coil == nil then
		return
	end
	local done = GearRules.coilAllowedFactor(coil, t) == 1
	if not api.isCarryingLive(player) and api.asyncOf(player) == nil then
		local humanoid = humanoidOf(player)
		local speed = StarterPlayer.CharacterWalkSpeed * GearRules.coilFactor(coil, t)
		if humanoid and humanoid.WalkSpeed ~= speed then
			humanoid.WalkSpeed = speed
		end
	end
	if done then
		state.coil = nil
	end
end

local function stepPick(player: Player, state: State, t: number)
	local pick = state.pick
	if pick == nil then
		return
	end
	local root = api.rootOf(player)
	if root == nil or api.asyncOf(player) ~= nil then
		endPick(player, state, "Interrupted", GearRules.Reason.Moved)
		return
	end
	local ownerUserId, lockdown = Lockdown.current(pick.plot)
	local ownerRoot = api.ownerRootOf(pick.plot)
	local gap = if ownerRoot then ownerRoot.Position - root.Position else nil
	local outcome, reason = GearRules.pickStep(pick, {
		now = t,
		x = root.Position.X,
		z = root.Position.Z,
		ownerUserId = ownerUserId,
		lockdown = lockdown,
		ownerDistance = if gap then Vector3.new(gap.X, 0, gap.Z).Magnitude else nil,
		carrying = api.isCarryingLive(player),
	})
	if outcome == "Done" and ownerUserId and lockdown then
		Lockdown.grantPass(player, ownerUserId, lockdown.startedAt)
		endPick(player, state, "Done", nil)
	elseif outcome == "Interrupted" then
		endPick(player, state, "Interrupted", reason)
	end
end

local STEPS = { stepPick, stepCoil, stepSmoke, stepDecoy }

local function step()
	local t = now()
	for player, state in states do
		for _, part in STEPS do
			local ok, err = pcall(part, player, state, t)
			if not ok then
				warn(`[Gear] step failed for {player.Name}: {err}`)
			end
		end
	end
end

local function onPlayerRemoving(player: Player)
	local state = states[player]
	states[player] = nil
	windows[player] = nil
	if state then
		pcall(clearSmoke, state)
		if state.decoy then
			state.decoy.part:Destroy()
		end
	end
end

-- Studio test hook ------------------------------------------------------------------------------

local function statusOf(player: Player): string
	local state = states[player]
	if not state then
		return "no gear used yet"
	end
	local t = now()
	local parts = {}
	for _, id in Profile.GEAR_IDS do
		local wait = math.max(0, math.ceil((state.readyAt[id] or 0) - t))
		local charges = if state.chargesRaidId then ` {state.charges[id]} charge(s)` else ""
		table.insert(parts, `{id} ready in {wait} s{charges}`)
	end
	if state.coil then
		table.insert(parts, `coil x{state.coil.factor}`)
	end
	if state.pick then
		table.insert(parts, `picking den {state.pick.plot} ({math.ceil(state.pick.doneAt - t)} s left)`)
	end
	if state.smoke then
		table.insert(parts, "smoke up")
	end
	if state.decoy then
		table.insert(parts, "decoy running")
	end
	local pass = Lockdown.passOf(player)
	if pass then
		table.insert(parts, `lockpick pass for {pass.ownerUserId}'s Lockdown at {pass.lockdownStartedAt}`)
	end
	return table.concat(parts, "; ")
end

local function testHook(command: string, a: any, b: any, c: any, d: any): string
	if command == "level" then
		local level = tonumber(a)
		if a == "off" then
			studioLevel = nil
			return "gear levels: from each profile"
		elseif level and level % 1 == 0 and level >= 0 and level <= Config.Gear.maxLevel then
			studioLevel = level
			return `every player's gear reads as level {level} (server memory only)`
		end
		return `level must be 0-{Config.Gear.maxLevel} or "off"`
	elseif command == "reset" then
		for _, state in states do
			table.clear(state.readyAt)
			state.chargesRaidId = nil
		end
		return "cooldowns and charges cleared"
	end
	local player = Players:GetPlayers()[1]
	if not player then
		return "no player"
	elseif command == "status" then
		return statusOf(player)
	elseif command == "use" then
		local x, y, z = tonumber(b), tonumber(c), tonumber(d)
		local target: Vector3? = nil
		if x and y and z then
			target = Vector3.new(x, y, z)
		else
			local root = api.rootOf(player)
			if root then
				target = root.Position + root.CFrame.LookVector * 16 - Vector3.new(0, LANDING_HEIGHT - 0.1, 0)
			end
		end
		local result = useGear(player, a, target)
		local tail = if result.charges then `, {result.charges} charge(s) left` else ""
		return `{a}: {if result.ok then "used" else `refused ({result.reason})`}{tail}`
	end
	return `unknown command {command}`
end

function Gear.start(injected: Api)
	api = injected
	local folder = Instance.new("Folder")
	folder.Name = "GearEffects"
	folder.Parent = workspace
	effects = folder
	local remotes = injected.remotes
	gearUsed = Instance.new("RemoteEvent")
	gearUsed.Name = Net.Pushes.GearUsed
	gearUsed.Parent = remotes
	local useRemote = Instance.new("RemoteFunction")
	useRemote.Name = Net.Requests.UseGear
	useRemote.OnServerInvoke = function(player: Player, gearId: any, target: any): Net.GearUseResult
		if not allow(player, "UseGear") then
			return refuse(GearRules.Reason.RateLimited, nil, nil, nil)
		end
		local ok, result = pcall(useGear, player, gearId, target)
		if not ok then
			warn(`[Gear] UseGear failed for {player.UserId}: {result}`)
			return refuse(GearRules.Reason.NotReady, nil, nil, nil)
		end
		return result
	end
	useRemote.Parent = remotes
	local getRemote = Instance.new("RemoteFunction")
	getRemote.Name = Net.Requests.GetGear
	getRemote.OnServerInvoke = function(player: Player): { Net.GearSlot }
		if not allow(player, "GetGear") then
			return {}
		end
		local ok, result = pcall(getGear, player)
		return if ok then result else {}
	end
	getRemote.Parent = remotes
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	if RunService:IsStudio() then
		local bindable = Instance.new("BindableFunction")
		bindable.Name = "GearTestHook"
		bindable.OnInvoke = function(command: string, a: any, b: any, c: any, d: any): string
			local ok, result = pcall(testHook, command, a, b, c, d)
			return if ok then result else `error: {result}`
		end
		bindable.Parent = ServerStorage
	end
	local clock = 0
	RunService.Heartbeat:Connect(function(dt: number)
		clock += dt
		if clock >= TICK then
			clock = 0
			step()
		end
	end)
end

return Gear

--!strict
--[[
	RaidService (owner: raid agent)

	Runs raids: live steals between players in this server (P0.5), and later async raids into
	pocket dens rebuilt from snapshots (Phase 1).

	Live stealing (decisions D-002, D-003, D-014, D-015). The server decides everything; the rules
	are pure functions in Shared/RaidRules.luau and this file only feeds them server state.
	  Grab    Every pad has a "StealPrompt" ProximityPrompt. Holding it asks for a grab; the
	          server times the hold itself (Config.LiveRaid.grabHoldSeconds) and re-checks
	          RaidRules.canGrabLive on every frame: kill switch (Escrow.canStartTransfer, the
	          only Config.Flags read), not your den, owner online and loaded, one carry at a time,
	          range to the server pad part. The critter is the one the owner's PROFILE has on
	          that pad; models and attributes never decide it. The owner gets BeingRaidedLive.
	  Carry   Walk speed = base * RaidRules.carrySpeedMultiplier(weight), set by the server, with
	          a placeholder over the raider's head. The critter is locked in IncomeService
	          (setCritterLock) so it is not drawn on its pad and the owner cannot move it.
	          Display-only Player attributes CarryingUid / CarryingSpecies ("" when not carrying).
	  Tag     The owner within Config.LiveRaid.tagRange studs of the carrier (server positions,
	          checked 10 times a second) makes them drop it. No remote: proximity is the trigger.
	  Drop    Tagged, teleported (RaidRules.carryMoveOk), died, left, or the owner left: the lock
	          clears and the critter is drawn on its pad again. No profile is ever written.
	  Escape  The carrier is inside their OWN den -> EscrowService.transferLive on its own thread
	          with server-tracked arguments (glowRequested 0, D-015). "InFlight" is retried with
	          the identical arguments; then the lock clears and both dens are refreshed.

	Server API:
	  requestGrab(player, plot, padIndex) -> (ok, reason?)  start a server-timed grab hold
	  cancelGrab(player)                                     stop a hold (prompt released)
	  isCarrying(player) -> boolean

	TODO (Phase 1, async raids):
	  [ ] StartRaid: RaidRules.canRaid, acquire lock, load snapshot, build pocket den far off-map
	      from pooled models, start the Config.Raid.durationSeconds timer
	  [ ] Guards (simple patrol/chase/tag AI) and traps from the snapshot
	  [ ] End raid: RaidRules.recordOutgoing; on escape hand off to EscrowService
	  [ ] Record replay frames (positions at 5 Hz + events) for the defender
	  [ ] One pocket per player, destroyed on exit; streaming keeps others from loading it
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local CritterCatalog = require(Shared.CritterCatalog)
local Escrow = require(Shared.Escrow)
local Net = require(Shared.Net)
local Plots = require(Shared.Plots)
local RaidRules = require(Shared.RaidRules)
local Types = require(Shared.Types)
local DataService = require(script.Parent.DataService)
local EscrowService = require(script.Parent.EscrowService)
local DenWorldService = require(script.Parent.DenWorldService) :: any
local IncomeService = require(script.Parent.IncomeService) :: any

type PlayerProfile = Types.PlayerProfile
type Critter = Types.Critter

type Hold = { plot: number, padIndex: number, critterUid: string, startedAt: number }
type Carry = {
	defenderUserId: number,
	plot: number,
	padIndex: number,
	critterUid: string,
	speciesId: string,
	walkSpeed: number,
	lastPos: Vector3,
	lastAt: number,
	wasInsideDefenderDen: boolean,
	prop: BasePart,
}

local LIVE_GLOW = 0 -- Phase 0 live steals take the critter only (decision D-015)
local HOLD_GRACE = 0.25 -- the prompt asks for a little longer than the server needs
local PROMPT_DISTANCE = 8 -- client-side prompt range; the server checks RaidRules.Live.grabRange
local CARRY_TICK = 0.1
local PROMPT_TICK = 0.5
local ESCAPE_RETRY_DELAYS = { 5, 20 } -- seconds between transferLive attempts on "InFlight"
local LIMIT_WINDOW_SECONDS = 10

local RaidService = {}

local holds: { [Player]: Hold } = {}
local carries: { [Player]: Carry } = {}
local locked: { [string]: true } = {} -- "<ownerUserId>:<uid>" while carried or in escrow
local prompts: { [BasePart]: ProximityPrompt } = {}
local windows: { [Player]: { start: number, count: number } } = {}
local beingRaided: RemoteEvent
local started = false

local function debugLog(message: string)
	if RunService:IsStudio() then
		print(`[RaidService] {message}`)
	end
end

local function lockKey(userId: number, uid: string): string
	return `{userId}:{uid}`
end

local function isLocked(userId: number, uid: string): boolean
	return locked[lockKey(userId, uid)] == true
end

local function allowGrab(player: Player): boolean
	local now = os.clock()
	local window = windows[player]
	if not window or now - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = now, count = 0 }
		windows[player] = window
	end
	window.count += 1
	return window.count <= Net.Limits.GrabCritter
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

-- The live root part of a player's character, or nil when dead or not spawned.
local function rootOf(player: Player): BasePart?
	local humanoid = humanoidOf(player)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Who owns a den: userId, their loaded profile, and their root part.
local function ownerOf(plot: number): (number?, PlayerProfile?, BasePart?)
	local owner = DenWorldService.getOwner(plot)
	if not owner then
		return nil, nil, nil
	end
	return owner.UserId, DataService.getProfile(owner.UserId), rootOf(owner)
end

local function refreshUser(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		IncomeService.refresh(player)
	end
end

-- Part C replaces these with the den's Lockdown state.
local function lockdownActive(_plot: number): boolean
	return false
end

local function lockdownBlocks(_player: Player, _plot: number): boolean
	return false
end

-- Grab --------------------------------------------------------------------------------------------

-- The kill switch (decision D-002). The only place this service reads Config.Flags.
local function liveAllowed(): boolean
	return (Escrow.canStartTransfer(Config.Flags, "Live", false)) -- no live revenge in Phase 0
end

local function checkGrab(player: Player, plot: number, padIndex: number): (boolean, string?, Critter?)
	local ownerUserId, ownerProfile = ownerOf(plot)
	local pad = DenWorldService.getPads(plot)[padIndex]
	local root = rootOf(player)
	return RaidRules.canGrabLive({
		flagsAllow = liveAllowed(),
		raiderUserId = player.UserId,
		raiderReady = DenWorldService.getPlot(player) ~= nil and DataService.getProfile(player.UserId) ~= nil,
		ownerUserId = ownerUserId,
		ownerProfile = ownerProfile,
		lockdownBlocked = lockdownBlocks(player, plot),
		padIndex = padIndex,
		carrying = carries[player] ~= nil,
		isLocked = function(uid: string): boolean
			return ownerUserId ~= nil and isLocked(ownerUserId, uid)
		end,
		distance = if pad and root then (root.Position - pad.Position).Magnitude else math.huge,
		now = os.time(),
	})
end

-- Removes the pad's critter model (drawn by IncomeService) while it is carried. Found by where it
-- sits over the server pad part, never by its attributes. IncomeService redraws it on refresh
-- once the lock clears.
local function hidePadModel(plot: number, padIndex: number)
	local pad = DenWorldService.getPads(plot)[padIndex]
	local folder = DenWorldService.getContents(plot):FindFirstChild("Critters")
	if not (pad and folder) then
		return
	end
	local half = pad.Size.X / 2
	for _, model in folder:GetChildren() do
		local primary = if model:IsA("Model") then model.PrimaryPart else nil
		if primary then
			local offset = primary.Position - pad.Position
			if math.abs(offset.X) <= half and math.abs(offset.Z) <= half then
				model:Destroy()
			end
		end
	end
end

local function buildProp(root: BasePart, species: Types.CritterSpecies): BasePart
	local prop = Instance.new("Part")
	prop.Name = "CarriedCritter"
	prop.Shape = Enum.PartType.Ball
	prop.Size = Vector3.one * 2
	prop.Color = Color3.fromHex(species.palette[1])
	prop.Material = Enum.Material.Neon
	prop.CanCollide = false
	prop.CanTouch = false
	prop.CanQuery = false
	prop.CastShadow = false
	prop.Massless = true
	prop.CFrame = root.CFrame * CFrame.new(0, 4.5, 0)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = prop
	weld.Parent = prop
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(140, 28)
	tag.StudsOffset = Vector3.new(0, 1.8, 0)
	tag.MaxDistance = 60
	tag.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = prop.Color
	label.TextStrokeTransparency = 0.4
	label.Text = species.name
	label.Parent = tag
	tag.Parent = prop
	prop.Parent = root.Parent
	return prop
end

local function startCarry(player: Player, plot: number, padIndex: number, critter: Critter)
	local ownerUserId = ownerOf(plot)
	local species = CritterCatalog.get(critter.speciesId)
	local root = rootOf(player)
	local humanoid = humanoidOf(player)
	if not (ownerUserId and species and root and humanoid) then
		return
	end
	local walkSpeed = RaidRules.carryWalkSpeed(StarterPlayer.CharacterWalkSpeed, species.weight)
	locked[lockKey(ownerUserId, critter.uid)] = true
	carries[player] = {
		defenderUserId = ownerUserId,
		plot = plot,
		padIndex = padIndex,
		critterUid = critter.uid,
		speciesId = species.id,
		walkSpeed = walkSpeed,
		lastPos = root.Position,
		lastAt = os.clock(),
		wasInsideDefenderDen = DenWorldService.isInsideDen(plot, root.Position),
		prop = buildProp(root, species),
	}
	humanoid.WalkSpeed = walkSpeed
	player:SetAttribute("CarryingUid", critter.uid)
	player:SetAttribute("CarryingSpecies", species.id)
	hidePadModel(plot, padIndex)
	refreshUser(ownerUserId)
	local owner = Players:GetPlayerByUserId(ownerUserId)
	if owner then
		beingRaided:FireClient(owner, player.UserId)
	end
	debugLog(`{player.Name} grabbed {species.id} from den {plot} pad {padIndex}`)
end

function RaidService.requestGrab(player: Player, plot: any, padIndex: any): (boolean, string?)
	if not allowGrab(player) then
		return false, "RateLimited"
	end
	if type(plot) ~= "number" or type(padIndex) ~= "number" or plot % 1 ~= 0 or padIndex % 1 ~= 0 then
		return false, "BadRequest"
	end
	if plot < 1 or plot > Plots.Layout.plotCount then
		return false, "BadRequest"
	end
	local ok, reason, critter = checkGrab(player, plot, padIndex)
	if not ok or not critter then
		debugLog(`grab refused for {player.Name} (den {plot} pad {padIndex}): {reason}`)
		return false, reason
	end
	holds[player] = { plot = plot, padIndex = padIndex, critterUid = critter.uid, startedAt = os.clock() }
	return true, nil
end

function RaidService.cancelGrab(player: Player)
	holds[player] = nil
end

function RaidService.isCarrying(player: Player): boolean
	return carries[player] ~= nil
end

-- Called every frame: a hold completes on the server's clock, with every check passing the
-- whole time (range included).
local function stepHolds()
	for player, hold in holds do
		local ok, reason, critter = checkGrab(player, hold.plot, hold.padIndex)
		if not ok or not critter or critter.uid ~= hold.critterUid then
			holds[player] = nil
			debugLog(`grab hold cancelled for {player.Name}: {reason or "critter changed"}`)
		elseif RaidRules.grabHoldDone(hold.startedAt, os.clock()) then
			holds[player] = nil
			startCarry(player, hold.plot, hold.padIndex, critter)
		end
	end
end

-- Carry, drop, escape -----------------------------------------------------------------------------

-- Ends the carry on the raider's side: placeholder, speed and display attributes.
local function clearCarrier(player: Player, carry: Carry)
	carries[player] = nil
	carry.prop:Destroy()
	player:SetAttribute("CarryingUid", "")
	player:SetAttribute("CarryingSpecies", "")
	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid.WalkSpeed = StarterPlayer.CharacterWalkSpeed
	end
end

-- The critter goes back to its pad. Nothing was ever written to a profile, so this only clears
-- the lock and redraws the owner's den.
local function drop(player: Player, carry: Carry, why: string)
	clearCarrier(player, carry)
	locked[lockKey(carry.defenderUserId, carry.critterUid)] = nil
	refreshUser(carry.defenderUserId)
	debugLog(`{player.Name} dropped {carry.speciesId} ({why}); back on den {carry.plot} pad {carry.padIndex}`)
end

local function escape(player: Player, carry: Carry)
	clearCarrier(player, carry)
	-- Fixed for every attempt: transferLive may only be retried with identical arguments.
	local raidId = HttpService:GenerateGUID(false)
	local raiderUserId = player.UserId
	local defenderUserId = carry.defenderUserId
	local critterUid = carry.critterUid
	debugLog(`{player.Name} escaped with {carry.speciesId}; raid {raidId} handed to EscrowService`)
	task.spawn(function()
		local status, reason = "InFlight", nil
		for attempt = 1, #ESCAPE_RETRY_DELAYS + 1 do
			local ok, s, r =
				pcall(EscrowService.transferLive, raidId, raiderUserId, defenderUserId, critterUid, LIVE_GLOW, false)
			status, reason = if ok then s else "InFlight", if ok then r else tostring(s)
			if status ~= "InFlight" or attempt > #ESCAPE_RETRY_DELAYS then
				break
			end
			task.wait(ESCAPE_RETRY_DELAYS[attempt])
		end
		-- Committed: the critter is the raider's. Refused: nothing moved, it is back on its pad.
		-- Still InFlight: EscrowService recovery finishes it; the profiles show the truth.
		locked[lockKey(defenderUserId, critterUid)] = nil
		refreshUser(raiderUserId)
		refreshUser(defenderUserId)
		local line = `raid {raidId}: transferLive {status}{if reason then ` ({reason})` else ""}`
		if status == "Committed" then
			debugLog(line)
		else
			warn(`[RaidService] {line}`)
		end
	end)
end

local function stepCarries()
	for player, carry in carries do
		local root = rootOf(player)
		if player.Parent == nil or not root then
			drop(player, carry, "raider gone")
			continue
		end
		local ownerUserId, ownerProfile, ownerRoot = ownerOf(carry.plot)
		local critter = if ownerProfile then ownerProfile.critters[carry.critterUid] else nil
		if ownerUserId ~= carry.defenderUserId or not critter or critter.placement ~= "Pad" then
			drop(player, carry, "owner gone")
			continue
		end
		local now = os.clock()
		local pos = root.Position
		local delta = pos - carry.lastPos
		local myPlot = DenWorldService.getPlot(player)
		local insideDefenderDen = DenWorldService.isInsideDen(carry.plot, pos)
		local outcome = RaidRules.carryStep({
			moved = Vector3.new(delta.X, 0, delta.Z).Magnitude,
			dt = now - carry.lastAt,
			walkSpeed = carry.walkSpeed,
			insideOwnDen = myPlot ~= nil and DenWorldService.isInsideDen(myPlot, pos),
			wasInsideDefenderDen = carry.wasInsideDefenderDen,
			insideDefenderDen = insideDefenderDen,
			lockdownActive = lockdownActive(carry.plot),
			ownerDistance = if ownerRoot then (ownerRoot.Position - pos).Magnitude else nil,
		})
		carry.lastPos, carry.lastAt, carry.wasInsideDefenderDen = pos, now, insideDefenderDen
		if outcome == "Escape" then
			escape(player, carry)
		elseif outcome ~= "Continue" then
			drop(player, carry, outcome)
		end
	end
end

-- Prompts -----------------------------------------------------------------------------------------

local function ensurePrompt(plot: number, padIndex: number, pad: BasePart): ProximityPrompt
	local prompt = prompts[pad]
	if prompt and prompt.Parent == pad then
		return prompt
	end
	-- DenWorldService destroys pad children when a den is released, so prompts are rebuilt here.
	local created = Instance.new("ProximityPrompt")
	created.Name = "StealPrompt"
	created.ActionText = "Steal"
	created.KeyboardKeyCode = Enum.KeyCode.F -- E is the den station's key
	created.HoldDuration = Config.LiveRaid.grabHoldSeconds + HOLD_GRACE
	created.MaxActivationDistance = PROMPT_DISTANCE
	created.RequiresLineOfSight = false
	created.Enabled = false
	created.PromptButtonHoldBegan:Connect(function(player: Player)
		RaidService.requestGrab(player, plot, padIndex)
	end)
	created.PromptButtonHoldEnded:Connect(function(player: Player)
		local hold = holds[player]
		if hold and hold.plot == plot and hold.padIndex == padIndex then
			holds[player] = nil
		end
	end)
	created.Parent = pad
	prompts[pad] = created
	return created
end

-- Shows a pad's prompt only while raids are on and it holds a critter that can be taken. Display
-- only: every
-- grab is checked again on the server.
local function syncPrompts()
	local on = liveAllowed()
	for plot = 1, Plots.Layout.plotCount do
		local ownerUserId, ownerProfile = ownerOf(plot)
		for padIndex, pad in DenWorldService.getPads(plot) do
			local prompt = ensurePrompt(plot, padIndex, pad)
			local critter = if ownerProfile then RaidRules.padCritter(ownerProfile, padIndex) else nil
			local species = if critter then CritterCatalog.get(critter.speciesId) else nil
			prompt.Enabled = on and species ~= nil and not isLocked(ownerUserId :: number, (critter :: Critter).uid)
			prompt.ObjectText = if species then species.name else ""
		end
	end
end

-- Lifecycle ---------------------------------------------------------------------------------------

-- One failing step must not stop the others or the next frame.
local function guard(name: string, step: () -> ())
	local ok, err = pcall(step)
	if not ok then
		warn(`[RaidService] {name} step failed: {err}`)
	end
end

local function onPlayerRemoving(player: Player)
	holds[player] = nil
	windows[player] = nil
	local carry = carries[player]
	if carry then
		drop(player, carry, "raider left")
	end
	for raider, other in carries do
		if other.defenderUserId == player.UserId then
			drop(raider, other, "owner left")
		end
	end
end

function RaidService.start()
	if started then
		return
	end
	started = true
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not (remotes and remotes:IsA("Folder")) then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end
	local existing = (remotes :: Folder):FindFirstChild(Net.Pushes.BeingRaidedLive)
	if existing and existing:IsA("RemoteEvent") then
		beingRaided = existing
	else
		beingRaided = Instance.new("RemoteEvent")
		beingRaided.Name = Net.Pushes.BeingRaidedLive
		beingRaided.Parent = remotes
	end

	IncomeService.setCritterLock(isLocked)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	local carryClock, promptClock = 0, PROMPT_TICK
	RunService.Heartbeat:Connect(function(dt: number)
		guard("holds", stepHolds)
		carryClock += dt
		promptClock += dt
		if carryClock >= CARRY_TICK then
			carryClock = 0
			guard("carries", stepCarries)
		end
		if promptClock >= PROMPT_TICK then
			promptClock = 0
			guard("prompts", syncPrompts)
		end
	end)
end

return RaidService

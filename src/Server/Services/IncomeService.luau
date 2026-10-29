--!strict
--[[
	IncomeService (owner: economy agent)

	Collecting, placing critters, buying eggs and upgrading the den. All math lives in
	Shared/Economy.luau; this service validates requests, calls it, pushes DenChanged and keeps
	the placeholder critter visuals on the pads in sync.

	Invariant: the den accrues BEFORE any change to placements or den level. Every request and
	push accrues through the Glow-factor helper first (below), with the same `now` the Economy
	call then gets, so the factor-1 accrue inside Economy.place, upgradeDen, buyEgg and autoPlace
	is a no-op.

	Glow-factor helper (P2.8; D-030, D-032, D-061): the one place a player's Glow factor changes
	and the only server code that accrues or collects. Every server accrue of an online player
	goes through IncomeService.accrue / collect, and the factor's inputs change only through
	setGlowInputs, which accrues at the old inputs first. A source guard
	(tests/specs/PurchaseSource.spec.luau) pins that Economy's accrue and collect functions appear
	in src/Server only between the helper's BEGIN and END markers.

	Phase 0 rule (decision D-027, issue #43): every push first runs Economy.autoPlace, so Inventory
	critters (a stolen critter, an egg hatched with full pads) fill free usable pads, oldest first,
	and show in the den. It never displaces a critter, never touches the Vault and skips locked
	(carried) critters. Side effect: a critter moved to Inventory comes straight back to a free pad.
	Revisit when P2.5 adds an inventory UI (placing from Inventory becomes the player's choice).

	Remotes live in ReplicatedStorage.Remotes, named exactly as in Shared/Net.luau:
	  RemoteFunctions GetDenState, Collect, PlaceCritter, BuyEgg, UpgradeDen, UpgradeGear
	  RemoteEvent     DenChanged (DenState), fired to the owner after every change
	Every request is rate-limited per player (Net.Limits, per 10 s) and every payload is checked.

	Each den also gets a greybox station (Contents/EconomyStation) with ProximityPrompts for
	Buy Egg, Collect and Upgrade. They run the same code as the remotes, for the owner only.

	Pad critters: Contents/Critters/Critter models, one per pad critter, with attributes
	CritterUid, SpeciesId, Tier, PadIndex, OwnerUserId, built by Server/Economy/CritterView (P2.4):
	the species' real model once loaded, else the placeholder (PrimaryPart "Body" sized by tier,
	child "Glow" in the species' first palette color), plus tier glow, particles and the critter's
	mutation effect. The attributes are display-only: which model draws which critter is kept in a
	server table (`drawn`), never read back from them. A model is rebuilt when its pad, species,
	mutation or body source (a real model finishing its load) changes.

	Server API:
	  refresh(player)               auto-place Inventory critters (D-027), re-push DenState and
	                                rebuild visuals after another service changed the profile
	                                (e.g. RaidService after a steal)
	  setCritterLock(fn?)           fn(userId, uid) -> true while a critter must not move (being
	                                carried). Locked critters cannot be placed, are never swapped
	                                off their pad by another placement, and are not drawn.
	  setPerks(hooks)               PurchaseService's pass perks: extraVaultSlots(userId) -> number
	                                and autoCollect(userId) -> boolean (both fail closed)
	  accrue(profile, now)          the helper: accrues at the player's factor when `profile` is
	                                the one loaded here for them, else at factor 1 (offline)
	  collect(profile, now)         the helper's collect: accrue, then bank whole stored Glow
	  setGlowInputs(userId, change, now)
	                                the only way a factor changes: accrues the loaded profile at
	                                the old inputs, then applies { vip?, paidRandomRestricted?,
	                                lanternNightUntil? } (Economy.changeGlowInputs)
	  glowFactor(userId, now)       the online factor in effect now (1 = none), for display
	  tutorialCritterAvailable(player)  true while grantTutorialCritter could still grant (the
	                                player is in onboarding and short of its stealHome step)
	  grantTutorialCritter(player)  the tutorial den steal (P2.6, D-064): grants one fixed Common,
	                                untradeable, at most once per player ever, keyed on onboarding
	                                step Economy.TUTORIAL_CLAIM_STEP (Economy.grantTutorialCritter).
	                                It advances that step itself, so never call
	                                DataService.advanceOnboarding("stealHome") before it: that
	                                spends the claim and the grant then refuses. Returns a copy of
	                                the critter, or nil. Never yields; saves ride the next autosave.

	Onboarding (P2.6, C6b): after an economy call succeeds this service reports the step through
	DataService.advanceOnboarding (forward only, so a step already behind the player is a no-op):
	  hatch     the free (untradeable) egg hatched; also "place" if that critter is on a pad, since
	            buyEgg and auto-place put it there without a PlaceCritter call
	  buyEgg    a paid egg hatched
	  place     PlaceCritter onto a Pad
	  collect   a collect banked more than 0

	Gear purchase (P2.8c; P2.10 handoff, D-068): UpgradeGear buys (level 0 -> 1) or upgrades one
	gear item with banked Glow through Economy.buyGear, which checks the id, the gear kill switches
	(Config.Gear.enabled, the item's own), the max level and the price, then writes the level and
	spends in one non-yielding call. Never Robux. Rate limit Net.Limits.UpgradeGear.

	Analytics (P2.9 call points; schema Shared/Analytics.luau, sender AnalyticsService, which never
	yields or throws): egg_bought, critter_placed (PlaceCritter only, not auto-placement) and
	glow_collected (player collects; the auto-collect pass logs only its economy flows, to keep the
	per-player budget for player actions). Economy flows: Glow source Collect, sinks Egg,
	DenUpgrade, GearUpgrade; DenGlow source DenOfflineIncome (the offline gap, logged when the
	first accrue of a load pays it) and DenIncome (online income, summed in the helper and logged
	before each collect and at the leave), sink DenCollect. Rebirth is not served yet: its
	`rebirth` event and Rebirth sink belong to the handler that serves it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage.Shared
local Economy = require(Shared.Economy) :: any
local Config = require(Shared.Config) :: any
local Types = require(Shared.Types)
local CritterCatalog = require(Shared.CritterCatalog) :: any
local Net = require(Shared.Net) :: any
local Plots = require(Shared.Plots) :: any
local Profile = require(Shared.Profile) :: any
local GearRules = require(Shared.GearRules) :: any
local DataService = require(script.Parent.DataService) :: any
local AnalyticsService = require(script.Parent.AnalyticsService) :: any
local DenWorldService = require(script.Parent.DenWorldService) :: any
local CritterView = require(script.Parent.Parent.Economy.CritterView) :: any

local LIMIT_WINDOW_SECONDS = 10
local MAX_UID_LENGTH = 64

local random = Random.new()
local remotes: Folder
local denChanged: RemoteEvent
local critterLock: ((number, string) -> boolean)? = nil
type Perks = { extraVaultSlots: (number) -> number, autoCollect: (number) -> boolean }
local perks: Perks = {
	extraVaultSlots = function(_userId: number): number
		return 0
	end,
	autoCollect = function(_userId: number): boolean
		return false
	end,
}
local stations: { [number]: { buy: ProximityPrompt, upgrade: ProximityPrompt } } = {}
-- The critter models this service built for each player's den: uid -> model and the pad it was
-- drawn on and its CritterView.lookKey. Cleared on plot release and player leave.
type Drawn = { model: Model, padIndex: number, look: string }
local drawn: { [Player]: { plot: number, models: { [string]: Drawn } } } = {}
local windows: { [Player]: { [string]: { start: number, count: number } } } = {}

local IncomeService = {}

local function allow(player: Player, name: string): boolean
	local limit = Net.Limits[name] or Net.Limits.default
	local now = os.clock()
	local perPlayer = windows[player]
	if not perPlayer then
		perPlayer = {}
		windows[player] = perPlayer
	end
	local window = perPlayer[name]
	if not window or now - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = now, count = 0 }
		perPlayer[name] = window
	end
	window.count += 1
	return window.count <= limit
end

local function isLocked(userId: number, uid: string): boolean
	return critterLock ~= nil and critterLock(userId, uid) == true
end

local function physicalPads(player: Player): number
	local plot = DenWorldService.getPlot(player)
	return if plot then #DenWorldService.getPads(plot) else 0
end

-- Placeholder visuals ---------------------------------------------------------------------------

local function ghostPart(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function buildCritter(critter: any, pad: BasePart, ownerUserId: number): Model?
	local species = CritterCatalog.get(critter.speciesId)
	if not species then
		return nil
	end
	local model = CritterView.build(species.id, critter.mutation or "None")
	if not model then
		return nil
	end
	model:SetAttribute("CritterUid", critter.uid)
	model:SetAttribute("SpeciesId", species.id)
	model:SetAttribute("Tier", species.tier)
	model:SetAttribute("PadIndex", critter.padIndex)
	model:SetAttribute("OwnerUserId", ownerUserId)
	model:PivotTo(pad.CFrame * CFrame.new(0, pad.Size.Y / 2, 0))
	return model
end

local function crittersFolder(plot: number): Folder
	local contents = DenWorldService.getContents(plot)
	local folder = contents:FindFirstChild("Critters")
	if folder and folder:IsA("Folder") then
		return folder
	end
	local created = Instance.new("Folder")
	created.Name = "Critters"
	created.Parent = contents
	return created
end

-- Brings the pad models in line with the profile. Unchanged models are kept so other services
-- can hold references to them; locked (carried) critters are left to their carrier. Decisions
-- come from the `drawn` table, never from the models' attributes.
local function renderDen(player: Player, profile: any)
	local plot = DenWorldService.getPlot(player)
	if not plot then
		drawn[player] = nil
		return
	end
	local pads = DenWorldService.getPads(plot)
	local folder = crittersFolder(plot)
	local state = drawn[player]
	if not state or state.plot ~= plot then
		state = { plot = plot, models = {} }
		drawn[player] = state
	end
	local wanted: { [string]: any } = {}
	for uid, critter in profile.critters do
		if critter.placement == "Pad" and pads[critter.padIndex] and not isLocked(player.UserId, uid) then
			wanted[uid] = critter
		end
	end
	local tracked: { [Instance]: boolean } = {}
	for uid, entry in state.models do
		local critter = wanted[uid]
		if isLocked(player.UserId, uid) then
			tracked[entry.model] = true -- its carrier owns the model for now
		elseif
			critter
			and entry.model.Parent == folder
			and entry.padIndex == critter.padIndex
			and entry.look == CritterView.lookKey(critter.speciesId, critter.mutation or "None")
		then
			tracked[entry.model] = true
			wanted[uid] = nil -- already drawn in the right place
		else
			if entry.model.Parent == folder then
				entry.model:Destroy()
			end
			state.models[uid] = nil
		end
	end
	for _, child in folder:GetChildren() do
		if not tracked[child] then
			child:Destroy() -- not one of ours
		end
	end
	for uid, critter in wanted do
		local model = buildCritter(critter, pads[critter.padIndex], player.UserId)
		if model then
			model.Parent = folder
			state.models[uid] = {
				model = model,
				padIndex = critter.padIndex,
				look = CritterView.lookKey(critter.speciesId, critter.mutation or "None"),
			}
		end
	end
end

local function updateStation(plot: number, profile: any)
	local station = stations[plot]
	if not station then
		return
	end
	local eggCost = Economy.eggCost(profile)
	station.buy.ObjectText = if eggCost == 0 then "Free starter egg" else `{eggCost} Glow`
	local upgradeCost = Economy.upgradeCost(profile.denLevel)
	station.upgrade.ObjectText = if upgradeCost
		then `Level {profile.denLevel} -> {profile.denLevel + 1}: {upgradeCost} Glow`
		else "Max level"
end

-- BEGIN GLOW FACTOR HELPER ------------------------------------------------------------------------
--[[
	The only server code that may call Economy's accrue and collect functions (source guard:
	tests/specs/PurchaseSource.spec.luau). One entry per player holds their GlowFactorState and the
	profile it belongs to. A profile that is not the one loaded in this server for its player
	(an offline copy, an absent defender) accrues at factor 1: offline income is unboosted.
]]
type GlowEntry = { state: any, profile: any, income: number }
local glowEntries: { [number]: GlowEntry } = {}

local function glowSettings(): any
	return {
		purchasesEnabled = Config.Flags.purchases == true,
		vipBoostsOffline = Config.Purchases.vipBoostsOffline == true,
	}
end

local function glowEntry(userId: number): GlowEntry
	local entry = glowEntries[userId]
	if not entry then
		entry = { state = Economy.newGlowFactorState(), profile = nil, income = 0 }
		glowEntries[userId] = entry
	end
	return entry :: GlowEntry
end

-- The entry for `profile` when it is the profile loaded here for its player, else nil. A newly
-- loaded profile starts unjoined, so its first accrue pays the offline gap unboosted.
local function loadedEntry(profile: any): GlowEntry?
	if type(profile) ~= "table" or type(profile.userId) ~= "number" then
		return nil
	end
	if DataService.getProfile(profile.userId) ~= profile then
		return nil
	end
	local entry = glowEntry(profile.userId)
	if entry.profile ~= profile then
		entry.profile = profile
		entry.state.joined = false
		entry.income = 0
	end
	return entry
end

-- Analytics for Glow one helper accrue paid into `profile`'s storage: the offline gap (the first
-- accrue of a load) is logged at once, online income is summed until flushIncome.
local function noteIncome(entry: GlowEntry, profile: any, added: number, wasJoined: boolean)
	if not (added > 0) then
		return
	end
	if wasJoined then
		entry.income += added
	else
		AnalyticsService.economy(profile.userId, "DenOfflineIncome", added, math.max(0, math.floor(profile.stored)))
	end
end

local function flushIncome(entry: GlowEntry, profile: any)
	local income = entry.income
	entry.income = 0
	if income > 0 then
		AnalyticsService.economy(profile.userId, "DenIncome", income, math.max(0, math.floor(profile.stored)))
	end
end

function IncomeService.accrue(profile: any, now: number): number
	local entry = loadedEntry(profile)
	if not entry then
		return Economy.accrue(profile, now)
	end
	local wasJoined = entry.state.joined == true
	local added = Economy.accrueBoosted(entry.state, profile, now, glowSettings())
	noteIncome(entry, profile, added, wasJoined)
	return added
end

function IncomeService.collect(profile: any, now: number): number
	local entry = loadedEntry(profile)
	if not entry then
		return Economy.collect(profile, now)
	end
	IncomeService.accrue(profile, now)
	flushIncome(entry, profile) -- DenIncome before the DenCollect sink that empties it
	return Economy.collectBoosted(entry.state, profile, now, glowSettings()) -- its accrue: a no-op
end

function IncomeService.setGlowInputs(userId: number, change: any, now: number): number
	if type(userId) ~= "number" then
		return 0
	end
	local entry = glowEntry(userId)
	local profile = DataService.getProfile(userId)
	local loaded = if profile and loadedEntry(profile) then profile else nil
	local wasJoined = entry.state.joined == true
	local added = Economy.changeGlowInputs(entry.state, loaded, now, change, glowSettings())
	if loaded then
		noteIncome(entry, loaded, added, wasJoined)
	end
	return added
end

function IncomeService.glowFactor(userId: number, now: number): number
	local entry = glowEntries[userId]
	return if entry then Economy.glowFactorAt(entry.state, now, glowSettings()) else 1
end

-- The final accrue before the leave save (DataService.onProfileReleasing: getProfile is already
-- nil here, so the entry's own profile reference decides), then forgets the player.
local function releaseGlow(userId: number, profile: any)
	local entry = glowEntries[userId]
	glowEntries[userId] = nil
	if entry and entry.profile == profile then
		local wasJoined = entry.state.joined == true
		noteIncome(entry, profile, Economy.accrueBoosted(entry.state, profile, os.time(), glowSettings()), wasJoined)
		flushIncome(entry, profile) -- logged only while the Player is still in the server
	else
		Economy.accrue(profile, os.time())
	end
end
-- END GLOW FACTOR HELPER --------------------------------------------------------------------------

-- Pushes ----------------------------------------------------------------------------------------

local function push(player: Player)
	local profile = DataService.getProfile(player.UserId)
	if not profile then
		return
	end
	local now = os.time()
	IncomeService.accrue(profile, now)
	-- D-027 (Phase 0): Inventory critters fill free pads. Needs the den world (0 pads = no-op).
	local userId = player.UserId
	Economy.autoPlace(profile, physicalPads(player), now, function(uid: string): boolean
		return isLocked(userId, uid)
	end)
	denChanged:FireClient(player, Economy.denState(profile, perks.extraVaultSlots(userId)))
	local plot = DenWorldService.getPlot(player)
	-- P2.3: show a newly unlocked pad at once, before critters are drawn on it (RaidService also
	-- syncs it at 2 Hz). setShownPads exists only once P2.3's DenWorldService is in.
	local setShownPads = DenWorldService.setShownPads
	if plot and setShownPads then
		setShownPads(plot, Economy.usablePadCount(profile.denLevel, physicalPads(player)))
	end
	renderDen(player, profile)
	if plot then
		updateStation(plot, profile)
	end
end

function IncomeService.refresh(player: Player)
	push(player)
end

function IncomeService.setCritterLock(fn: ((number, string) -> boolean)?)
	critterLock = fn
end

function IncomeService.setPerks(hooks: Perks)
	perks = hooks
end

-- Onboarding (P2.6) ------------------------------------------------------------------------------

-- Reports a server onboarding step. Forward only and never yields; a no-op once the player is past
-- it, outside onboarding, or not loaded here.
local function onboard(player: Player, stepId: string)
	DataService.advanceOnboarding(player.UserId, stepId)
end

function IncomeService.tutorialCritterAvailable(player: Player): boolean
	local profile = DataService.getProfile(player.UserId)
	if not profile or Profile.isOnboardingComplete(profile) then
		return false
	end
	return Profile.onboardingStep(profile) < Profile.onboardingStepIndex(Economy.TUTORIAL_CLAIM_STEP)
end

function IncomeService.grantTutorialCritter(player: Player): any
	local userId = player.UserId
	local profile = DataService.getProfile(userId)
	if not profile then
		return nil
	end
	local critter = Economy.grantTutorialCritter(
		profile,
		os.time(),
		HttpService:GenerateGUID(false),
		function(): boolean
			return DataService.advanceOnboarding(userId, Economy.TUTORIAL_CLAIM_STEP) == true
		end
	)
	if not critter then
		return nil
	end
	-- Granted and recorded: a failed push must not hide that from the caller.
	local ok, err = pcall(push, player)
	if not ok then
		warn(`[IncomeService] push after the tutorial grant failed for {userId}: {err}`)
	end
	return table.clone(critter)
end

-- Requests --------------------------------------------------------------------------------------

-- The tier of a species id, for analytics ("Common" for an unknown one, so it is never refused).
local function tierOf(speciesId: string): string
	local species = CritterCatalog.get(speciesId)
	return if species then species.tier else "Common"
end

-- `auto`: the auto-collect pass, which logs only its economy flows (see the header).
local function collect(player: Player, profile: any, now: number, auto: boolean?): number
	IncomeService.accrue(profile, now) -- so the fill below is current (a no-op after guarded's)
	local fill = Economy.storageFillRaw(profile)
	local banked = IncomeService.collect(profile, now)
	if banked > 0 then
		AnalyticsService.economy(player, "DenCollect", banked, math.max(0, math.floor(profile.stored)))
		AnalyticsService.economy(player, "Collect", banked, profile.glow)
		if not auto then
			AnalyticsService.track(player, "glow_collected", { amount = banked, storageFill = fill })
		end
	end
	push(player)
	if banked > 0 then
		onboard(player, "collect")
	end
	return banked
end

local function buyEgg(player: Player, profile: any, now: number): any
	local price = Economy.eggCost(profile) -- what this egg costs (0 = rescue); guarded accrued
	local denLevel = profile.denLevel
	local critter = Economy.buyEgg(profile, now, {
		tierRoll = random:NextNumber(),
		speciesRoll = random:NextNumber(),
		uid = HttpService:GenerateGUID(false),
		maxTier = Config.Economy.eggMaxTier :: Types.Tier,
		physicalPads = physicalPads(player),
	})
	if critter then
		AnalyticsService.track(player, "egg_bought", {
			tier = tierOf(critter.speciesId),
			price = price,
			denLevel = denLevel,
		})
		AnalyticsService.economy(player, "Egg", price, profile.glow) -- 0 (a rescue egg) logs nothing
		push(player)
		if critter.untradeable then
			-- The free egg is the hatch. buyEgg (or push's auto-place) puts it straight on a pad,
			-- which is Appendix C's "place it", so that step is done too.
			onboard(player, "hatch")
			local hatched = profile.critters[critter.uid]
			if hatched and hatched.placement == "Pad" then
				onboard(player, "place")
			end
		else
			onboard(player, "buyEgg")
		end
		return table.clone(critter)
	end
	return nil
end

local function upgradeDen(player: Player, profile: any, now: number): boolean
	local cost = Economy.upgradeCost(profile.denLevel)
	local ok = Economy.upgradeDen(profile, now)
	if ok then
		AnalyticsService.economy(player, "DenUpgrade", cost, profile.glow)
		push(player)
	end
	return ok
end

-- Economy.buyGear's rules, from GearRules and Profile (Economy cannot require them: a cycle).
local GEAR_SHOP = {
	isGearId = Profile.isGearId,
	level = Profile.gearLevel,
	setLevel = Profile.setGearLevel,
	upgradeCost = GearRules.upgradeCost,
	switchedOn = function(gearId: any): boolean
		return GearRules.switchedOn(Config.Gear, gearId)
	end,
}

local function upgradeGear(player: Player, profile: any, now: number, gearId: any): boolean
	if type(gearId) ~= "string" or #gearId > MAX_UID_LENGTH then
		return false
	end
	local ok, _, spent = Economy.buyGear(profile, gearId, now, GEAR_SHOP)
	if not ok then
		return false
	end
	AnalyticsService.economy(player, "GearUpgrade", spent, profile.glow)
	push(player)
	return true
end

local function placeCritter(player: Player, profile: any, now: number, uid: any, placement: any, padIndex: any): boolean
	if type(uid) ~= "string" or #uid > MAX_UID_LENGTH or type(placement) ~= "string" then
		return false
	end
	if padIndex ~= nil and type(padIndex) ~= "number" then
		return false
	end
	-- Economy.place refuses to move a locked critter, as the mover or as a swapped-out occupant.
	local userId = player.UserId
	local function locked(critterUid: string): boolean
		return isLocked(userId, critterUid)
	end
	-- The vault slot pass adds a slot while its perk is active (PurchaseService; fails closed to 0).
	local extraSlots = perks.extraVaultSlots(userId)
	local ok = Economy.place(profile, uid, placement, padIndex, physicalPads(player), now, locked, extraSlots)
	if ok then
		local critter = profile.critters[uid]
		AnalyticsService.track(player, "critter_placed", {
			tier = tierOf(if critter then critter.speciesId else ""),
			placement = placement,
		})
		push(player)
		if placement == "Pad" then
			onboard(player, "place")
		end
	end
	return ok
end

-- Wraps a handler: rate limit, loaded profile, and no error ever reaches the client. The den
-- accrues through the helper first, and the handler gets that same `now`.
local function guarded(name: string, failValue: any, handler: (Player, any, number, ...any) -> any)
	return function(player: Player, ...: any): any
		if not allow(player, name) then
			return failValue
		end
		local profile = DataService.getProfile(player.UserId)
		if not profile then
			return failValue
		end
		local ok, result = pcall(function(...: any): any
			local now = os.time()
			IncomeService.accrue(profile, now)
			return handler(player, profile, now, ...)
		end, ...)
		if not ok then
			warn(`[IncomeService] {name} failed for {player.UserId}: {result}`)
			return failValue
		end
		return result
	end
end

local handlers = {
	GetDenState = guarded(Net.Requests.GetDenState, nil, function(player, profile, _now)
		return Economy.denState(profile, perks.extraVaultSlots(player.UserId))
	end),
	Collect = guarded(Net.Requests.Collect, 0, function(player, profile, now)
		return collect(player, profile, now, false) -- client arguments never reach `auto`
	end),
	PlaceCritter = guarded(Net.Requests.PlaceCritter, false, placeCritter),
	BuyEgg = guarded(Net.Requests.BuyEgg, nil, buyEgg),
	UpgradeDen = guarded(Net.Requests.UpgradeDen, false, upgradeDen),
	UpgradeGear = guarded(Net.Requests.UpgradeGear, false, upgradeGear),
}

-- Auto-collect pass: banks each online owner's stored Glow every Config.Purchases.autoCollectSeconds
-- while the perk is active for them (PurchaseService decides: owned, purchases on, policy known
-- unrestricted). Through the helper, like a Collect request.
local function autoCollectLoop()
	while true do
		task.wait(Config.Purchases.autoCollectSeconds)
		for _, player in Players:GetPlayers() do
			local profile = DataService.getProfile(player.UserId)
			local ok, active = pcall(perks.autoCollect, player.UserId)
			if profile and ok and active == true then
				local done, err = pcall(collect, player, profile, os.time(), true)
				if not done then
					warn(`[IncomeService] auto-collect failed for {player.UserId}: {err}`)
				end
			end
		end
	end
end

-- World station ----------------------------------------------------------------------------------

local function buildStation(player: Player, plot: number)
	local contents = DenWorldService.getContents(plot)
	local old = contents:FindFirstChild("EconomyStation")
	if old then
		old:Destroy()
	end
	local floor = DenWorldService.getModel(plot).PrimaryPart :: BasePart
	local floorTop = floor.Position.Y + floor.Size.Y / 2
	local station = Instance.new("Model")
	station.Name = "EconomyStation"

	local function stationPart(name: string, localX: number, localZ: number, size: Vector3, color: Color3): Part
		local x, z = Plots.toWorld(plot, localX, localZ)
		local p = ghostPart(station, {
			Name = name,
			Size = size,
			CFrame = CFrame.new(x, floorTop + size.Y / 2, z),
			Color = color,
			Material = Enum.Material.SmoothPlastic,
		})
		p.CanCollide = true
		return p
	end
	local function prompt(parent: BasePart, action: string, key: Enum.KeyCode, run: (Player) -> any): ProximityPrompt
		local pp = Instance.new("ProximityPrompt")
		pp.ActionText = action
		pp.KeyboardKeyCode = key
		pp.HoldDuration = 0
		pp.MaxActivationDistance = 10
		pp.RequiresLineOfSight = false
		pp.Triggered:Connect(function(who: Player)
			if who == player and DenWorldService.getOwner(plot) == player then
				run(who)
			end
		end)
		pp.Parent = parent
		return pp
	end

	local belt = stationPart("EggConveyor", 20, 2, Vector3.new(4, 1.2, 12), Color3.fromRGB(50, 56, 84))
	local egg = stationPart("Egg", 20, -2, Vector3.new(2.4, 3, 2.4), Color3.fromRGB(255, 244, 200))
	egg.Shape = Enum.PartType.Ball
	egg.Material = Enum.Material.Neon
	egg.CFrame = egg.CFrame + Vector3.new(0, belt.Size.Y, 0)
	local jar = stationPart("GlowJar", -20, 2, Vector3.new(3, 4, 3), Color3.fromRGB(120, 230, 255))
	jar.Material = Enum.Material.Neon
	jar.Transparency = 0.3
	local plinth = stationPart("UpgradePlinth", -20, -10, Vector3.new(4, 3, 4), Color3.fromRGB(90, 80, 140))

	local buy = prompt(belt, "Buy Egg", Enum.KeyCode.E, handlers.BuyEgg)
	prompt(jar, "Collect Glow", Enum.KeyCode.E, handlers.Collect)
	local upgrade = prompt(plinth, "Upgrade Den", Enum.KeyCode.E, handlers.UpgradeDen)
	station.Parent = contents
	stations[plot] = { buy = buy, upgrade = upgrade }
end

-- Lifecycle --------------------------------------------------------------------------------------

local function makeRemote(className: string, name: string): Instance
	local existing = remotes:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = remotes
	return remote
end

function IncomeService.start()
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	remotes = folder :: Folder
	denChanged = makeRemote("RemoteEvent", Net.Pushes.DenChanged) :: RemoteEvent
	for name, handler in handlers do
		local remote = makeRemote("RemoteFunction", Net.Requests[name]) :: RemoteFunction
		remote.OnServerInvoke = handler
	end

	DenWorldService.onPlotAssigned(function(player: Player, plot: number)
		buildStation(player, plot)
		push(player)
	end)
	DenWorldService.onPlotReleased(function(player: Player, plot: number)
		stations[plot] = nil -- DenWorldService empties Contents right after this
		local state = drawn[player]
		if state and state.plot == plot then
			drawn[player] = nil
		end
	end)
	DataService.onProfileLoaded(function(player: Player)
		push(player)
	end)
	-- Real critter models load in the background; each one that arrives redraws the dens (the
	-- placeholders of that species become the real model, via the lookKey check in renderDen).
	CritterView.prefetch(function()
		for player in drawn do
			local profile = DataService.getProfile(player.UserId)
			if profile then
				renderDen(player, profile)
			end
		end
	end)
	-- The final accrue before the leave save, at the player's factor (must not yield).
	DataService.onProfileReleasing(releaseGlow)
	Players.PlayerRemoving:Connect(function(player: Player)
		windows[player] = nil
		drawn[player] = nil
		-- A player whose profile never loaded here (or whose lock was taken) has no release: drop
		-- their entry once nothing here holds their profile.
		local userId = player.UserId
		task.delay(60, function()
			if DataService.getProfile(userId) == nil and Players:GetPlayerByUserId(userId) == nil then
				glowEntries[userId] = nil
			end
		end)
	end)
	task.spawn(autoCollectLoop)
end

return IncomeService

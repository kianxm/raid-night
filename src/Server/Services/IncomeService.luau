--!strict
--[[
	IncomeService (owner: economy agent)

	Collecting, placing critters, buying eggs and upgrading the den. All math lives in
	Shared/Economy.luau; this service validates requests, calls it, pushes DenChanged and keeps
	the placeholder critter visuals on the pads in sync.

	Invariant: Economy.accrue(profile, now) runs BEFORE any change to placements or den level
	(Economy.place, upgradeDen and buyEgg do it themselves).

	Remotes live in ReplicatedStorage.Remotes, named exactly as in Shared/Net.luau:
	  RemoteFunctions GetDenState, Collect, PlaceCritter, BuyEgg, UpgradeDen
	  RemoteEvent     DenChanged (DenState), fired to the owner after every change
	Every request is rate-limited per player (Net.Limits, per 10 s) and every payload is checked.

	Each den also gets a greybox station (Contents/EconomyStation) with ProximityPrompts for
	Buy Egg, Collect and Upgrade. They run the same code as the remotes, for the owner only.

	Placeholder critters: Contents/Critters/Critter models, one per pad critter, with attributes
	CritterUid, SpeciesId, Tier, PadIndex, OwnerUserId. PrimaryPart "Body" (colored by tier size),
	child "Glow" (Neon, the species' first palette color). The attributes are display-only: which
	model draws which critter is kept in a server table (`drawn`), never read back from them.

	Server API:
	  refresh(player)               re-push DenState and rebuild visuals after another service
	                                changed the profile (e.g. RaidService after a steal)
	  setCritterLock(fn?)           fn(userId, uid) -> true while a critter must not move (being
	                                carried). Locked critters cannot be placed, are never swapped
	                                off their pad by another placement, and are not drawn.
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
local DataService = require(script.Parent.DataService) :: any
local DenWorldService = require(script.Parent.DenWorldService) :: any

local LIMIT_WINDOW_SECONDS = 10
local MAX_UID_LENGTH = 64

local TIER_SIZE: { [string]: number } = {
	Common = 1.8,
	Uncommon = 2.4,
	Rare = 3,
	Epic = 3.6,
	Legendary = 4.4,
	Mythic = 5.2,
	Secret = 6,
}

local random = Random.new()
local remotes: Folder
local denChanged: RemoteEvent
local critterLock: ((number, string) -> boolean)? = nil
local stations: { [number]: { buy: ProximityPrompt, upgrade: ProximityPrompt } } = {}
-- The critter models this service built for each player's den: uid -> model and the pad it was
-- drawn on. Cleared on plot release and player leave.
type Drawn = { model: Model, padIndex: number }
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
	local size = TIER_SIZE[species.tier] or 2
	local model = Instance.new("Model")
	model.Name = "Critter"
	model:SetAttribute("CritterUid", critter.uid)
	model:SetAttribute("SpeciesId", species.id)
	model:SetAttribute("Tier", species.tier)
	model:SetAttribute("PadIndex", critter.padIndex)
	model:SetAttribute("OwnerUserId", ownerUserId)

	local body = ghostPart(model, {
		Name = "Body",
		Shape = if species.tier == "Uncommon" then Enum.PartType.Block else Enum.PartType.Ball,
		Size = Vector3.one * size,
		CFrame = pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + size / 2, 0),
		Color = Color3.fromHex(species.palette[2] or species.palette[1]),
		Material = Enum.Material.SmoothPlastic,
	})
	body.CanTouch = true
	body.CanQuery = true
	ghostPart(model, {
		Name = "Glow",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * size * 0.45,
		CFrame = body.CFrame * CFrame.new(0, size * 0.5, 0),
		Color = Color3.fromHex(species.palette[1]),
		Material = Enum.Material.Neon,
		CanTouch = false,
		CanQuery = false,
	})
	model.PrimaryPart = body

	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(160, 36)
	tag.StudsOffset = Vector3.new(0, size + 1, 0)
	tag.MaxDistance = 45
	tag.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromHex(species.palette[1])
	label.TextStrokeTransparency = 0.4
	label.Text = `{species.name}\n{species.tier}`
	label.Parent = tag
	tag.Parent = body
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
		elseif critter and entry.model.Parent == folder and entry.padIndex == critter.padIndex then
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
			state.models[uid] = { model = model, padIndex = critter.padIndex }
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

-- Pushes ----------------------------------------------------------------------------------------

local function push(player: Player)
	local profile = DataService.getProfile(player.UserId)
	if not profile then
		return
	end
	Economy.accrue(profile, os.time())
	denChanged:FireClient(player, Economy.denState(profile))
	renderDen(player, profile)
	local plot = DenWorldService.getPlot(player)
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

-- Requests --------------------------------------------------------------------------------------

local function collect(player: Player, profile: any): number
	local banked = Economy.collect(profile, os.time())
	push(player)
	return banked
end

local function buyEgg(player: Player, profile: any): any
	local critter = Economy.buyEgg(profile, os.time(), {
		tierRoll = random:NextNumber(),
		speciesRoll = random:NextNumber(),
		uid = HttpService:GenerateGUID(false),
		maxTier = Config.Economy.eggMaxTier :: Types.Tier,
		physicalPads = physicalPads(player),
	})
	if critter then
		push(player)
		return table.clone(critter)
	end
	return nil
end

local function upgradeDen(player: Player, profile: any): boolean
	local ok = Economy.upgradeDen(profile, os.time())
	if ok then
		push(player)
	end
	return ok
end

local function placeCritter(player: Player, profile: any, uid: any, placement: any, padIndex: any): boolean
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
	local ok = Economy.place(profile, uid, placement, padIndex, physicalPads(player), os.time(), locked)
	if ok then
		push(player)
	end
	return ok
end

-- Wraps a handler: rate limit, loaded profile, and no error ever reaches the client.
local function guarded(name: string, failValue: any, handler: (Player, any, ...any) -> any)
	return function(player: Player, ...: any): any
		if not allow(player, name) then
			return failValue
		end
		local profile = DataService.getProfile(player.UserId)
		if not profile then
			return failValue
		end
		local ok, result = pcall(handler, player, profile, ...)
		if not ok then
			warn(`[IncomeService] {name} failed for {player.UserId}: {result}`)
			return failValue
		end
		return result
	end
end

local handlers = {
	GetDenState = guarded(Net.Requests.GetDenState, nil, function(_player, profile)
		Economy.accrue(profile, os.time())
		return Economy.denState(profile)
	end),
	Collect = guarded(Net.Requests.Collect, 0, collect),
	PlaceCritter = guarded(Net.Requests.PlaceCritter, false, placeCritter),
	BuyEgg = guarded(Net.Requests.BuyEgg, nil, buyEgg),
	UpgradeDen = guarded(Net.Requests.UpgradeDen, false, upgradeDen),
}

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
	Players.PlayerRemoving:Connect(function(player: Player)
		windows[player] = nil
		drawn[player] = nil
	end)
end

return IncomeService

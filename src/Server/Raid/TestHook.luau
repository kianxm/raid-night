--!strict
--[[
	TestHook (owner: raid agent): a Studio-only single-client harness for live stealing
	(decision D-010). install() does nothing unless RunService:IsStudio(), so it is never active in
	a live server, and nothing a client sends can reach it.

	It seeds a stand-in defender den: a fake owner (reserved test userId -1_000_001, which no
	player and no Studio test client can have) with an in-memory profile, one pad
	critter per weight on pads 1-4 plus a Vault and an Inventory critter, and a red "StandInOwner"
	block that tags like a real owner. One client can then grab, carry, get tagged, escape, and
	watch a Lockdown block entry. The real rules run unchanged: the stand-in is only another
	answer to "who owns this den, with what profile, standing where".

	Drive it from the Studio command bar (server side) during Play:
	  local hook = game:GetService("ServerStorage"):WaitForChild("RaidTestHook")
	  hook:Invoke("seed")              --> plot number of the stand-in den
	  hook:Invoke("status")            --> one-line summary: carries, locks, Lockdown, stand-in pads
	  hook:Invoke("chase", true)       --> the stand-in owner walks at you; within tagRange it tags
	  hook:Invoke("home")              --> the stand-in owner returns to its den and stops
	  hook:Invoke("lockdown")          --> start a Lockdown on the stand-in den: ok, reason
	  hook:Invoke("grab", plot, pad)   --> ask for a grab as the client, like the prompt: ok, reason
	  hook:Invoke("teleportHome")      --> teleport the client into their own den (exploit check)
	  hook:Invoke("clear")             --> remove the stand-in and free its den

	Escrow (decision D-019): an escape against the stand-in can commit only when the whole server
	keeps profiles and escrow in memory. Set the ServerStorage attribute StudioMemoryProfiles = true
	BEFORE Play; then DataService.persistence() is "Memory" and seed hands the stand-in profile to
	DataService.loadTestProfile first (a refused load refuses the seed, so no den is taken).
	Without Memory mode seed still works for grab, carry, tag and Lockdown, and an escape reports
	"test escape needs Memory persistence" without calling transferLive (nothing moves).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage.Shared
local CritterCatalog = require(Shared.CritterCatalog)
local Profile = require(Shared.Profile)
local Types = require(Shared.Types)
local Services = script.Parent.Parent.Services
local DataService = require(Services.DataService) :: any
local DenWorldService = require(Services.DenWorldService) :: any
local Lockdown = require(script.Parent.Lockdown)

type PlayerProfile = Types.PlayerProfile

export type Api = {
	setStandIn: (plot: number, standIn: any) -> (),
	requestGrab: (player: Player, plot: any, padIndex: any) -> (boolean, string?),
	isLocked: (userId: number, uid: string) -> boolean,
	describe: () -> string,
}

local STAND_IN_USER_ID = -1_000_001 -- reserved test id (<= -1_000_000, Profile.isTestUserId)
local MEMORY_HINT = "set the ServerStorage attribute StudioMemoryProfiles = true before Play"
local CHASE_SPEED = 18 -- faster than any carrier (16 * 0.9), so a chase always ends in a tag
local WEIGHTS = { "Light", "Medium", "Heavy", "VeryHeavy" }

local TestHook = {}

type Seeded = {
	plot: number,
	profile: PlayerProfile,
	loaded: boolean, -- handed to DataService.loadTestProfile (Memory mode)
	owner: Part,
	chase: RBXScriptConnection?,
}
local seeded: Seeded? = nil
local api: Api

local function client(): Player?
	return Players:GetPlayers()[1]
end

local function critter(speciesId: string, placement: Types.Placement, padIndex: number?): Types.Critter
	return {
		uid = HttpService:GenerateGUID(false),
		speciesId = speciesId,
		mutation = "None",
		placement = placement,
		padIndex = padIndex,
		acquiredAt = os.time(),
	}
end

local function buildProfile(): PlayerProfile
	local profile = Profile.new(STAND_IN_USER_ID, os.time() - 3 * 86400)
	local pad = 0
	local first: string? = nil
	for _, weight in WEIGHTS do
		for _, species in CritterCatalog.all() do
			if species.weight == weight then
				pad += 1
				first = first or species.id
				local c = critter(species.id, "Pad", pad)
				profile.critters[c.uid] = c
				break
			end
		end
	end
	for _, placement in { "Vault", "Inventory" } :: { Types.Placement } do
		local c = critter(first :: string, placement, nil)
		profile.critters[c.uid] = c
	end
	return profile
end

-- Placeholder pad critters, drawn like IncomeService draws a real den (Contents/Critters, one
-- model per pad critter, PrimaryPart over the pad). Carried critters are skipped.
local function draw(plot: number, profile: PlayerProfile)
	local contents = DenWorldService.getContents(plot)
	local folder = contents:FindFirstChild("Critters")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Critters"
		folder.Parent = contents
	end
	(folder :: Instance):ClearAllChildren()
	local pads = DenWorldService.getPads(plot)
	for uid, c in profile.critters do
		local pad = if c.placement == "Pad" and c.padIndex then pads[c.padIndex] else nil
		local species = CritterCatalog.get(c.speciesId)
		if pad and species and not api.isLocked(STAND_IN_USER_ID, uid) then
			local model = Instance.new("Model")
			model.Name = "Critter"
			local body = Instance.new("Part")
			body.Name = "Body"
			body.Shape = Enum.PartType.Ball
			body.Size = Vector3.one * 2.4
			body.Anchored = true
			body.CanCollide = false
			body.Material = Enum.Material.Neon
			body.Color = Color3.fromHex(species.palette[1])
			body.CFrame = pad.CFrame * CFrame.new(0, pad.Size.Y / 2 + 1.2, 0)
			body.Parent = model
			model.PrimaryPart = body
			model.Parent = folder
		end
	end
end

local function ownerHome(plot: number): CFrame
	return DenWorldService.getSpawnCFrame(plot) * CFrame.new(0, 0, -4)
end

local function stopChase()
	if seeded and seeded.chase then
		seeded.chase:Disconnect()
		seeded.chase = nil
	end
end

local function releaseProfile(): (boolean, string?)
	if type(DataService.releaseTestProfile) ~= "function" then
		return false, "DataService has no releaseTestProfile"
	end
	local ok, released, why = pcall(DataService.releaseTestProfile, STAND_IN_USER_ID)
	if not ok then
		return false, tostring(released)
	end
	return released == true, why
end

local function seed(): (number?, string?)
	if seeded then
		return seeded.plot, nil
	end
	local profile = buildProfile()
	-- The profile goes to DataService before any den is taken, so a refused load leaves nothing.
	local loaded = false
	if DataService.persistence() == "Memory" then
		if type(DataService.loadTestProfile) ~= "function" then
			return nil, "DataService has no loadTestProfile (data P0.5e)"
		end
		local ok, result, why = pcall(DataService.loadTestProfile, STAND_IN_USER_ID, profile)
		if not ok or result ~= true then
			return nil, `stand-in profile refused by DataService: {if ok then why or "refused" else result}`
		end
		loaded = true
	end
	local assignedOk, plot = pcall(DenWorldService.assignStandIn, STAND_IN_USER_ID, "Stand-in")
	if not assignedOk or not plot then
		if loaded then
			releaseProfile()
		end
		return nil, if assignedOk then "no free den" else `no den for the stand-in: {plot}`
	end
	local owner = Instance.new("Part")
	owner.Name = "StandInOwner"
	owner.Size = Vector3.new(2, 5, 1)
	owner.Anchored = true
	owner.CanCollide = false
	owner.Material = Enum.Material.Neon
	owner.Color = Color3.fromRGB(255, 80, 80)
	owner.CFrame = ownerHome(plot)
	owner.Parent = DenWorldService.getContents(plot)
	seeded = { plot = plot, profile = profile, loaded = loaded, owner = owner }
	api.setStandIn(plot, {
		userId = STAND_IN_USER_ID,
		profile = profile,
		root = owner,
		redraw = function()
			draw(plot, profile)
		end,
	})
	draw(plot, profile)
	if not loaded then
		return plot, `escapes against the stand-in will report "test escape needs Memory persistence"; {MEMORY_HINT}`
	end
	return plot, nil
end

local function chase(on: boolean): (boolean, string?)
	local s = seeded
	if not s then
		return false, "seed first"
	end
	stopChase()
	if on then
		s.chase = RunService.Heartbeat:Connect(function(dt: number)
			local player = client()
			local target = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if target and target:IsA("BasePart") then
				local from = s.owner.Position
				local to = Vector3.new(target.Position.X, from.Y, target.Position.Z)
				local gap = to - from
				if gap.Magnitude > 1.5 then
					local stepTo = from + gap.Unit * math.min(gap.Magnitude, CHASE_SPEED * dt)
					s.owner.CFrame = CFrame.lookAt(stepTo, to)
				end
			end
		end)
	end
	return true, nil
end

local function clear(): (boolean, string?)
	local s = seeded
	if not s then
		return true, nil
	end
	for uid in s.profile.critters do
		if api.isLocked(STAND_IN_USER_ID, uid) then
			return false, "a stand-in critter is being carried or is in escrow; try again when it lands"
		end
	end
	if s.loaded then
		local released, why = releaseProfile()
		if not released then
			return false, `DataService kept the stand-in profile: {why or "refused"}`
		end
	end
	stopChase()
	api.setStandIn(s.plot, nil)
	DenWorldService.releaseStandIn(STAND_IN_USER_ID)
	s.owner:Destroy()
	seeded = nil
	return true, nil
end

local function status(): string
	local s = seeded
	local lines = { api.describe() }
	if s then
		local pads = {}
		for _, c in s.profile.critters do
			table.insert(pads, `{c.speciesId}:{c.placement}{if c.padIndex then c.padIndex else ""}`)
		end
		table.sort(pads)
		local loaded = DataService.getProfile(STAND_IN_USER_ID) ~= nil
		local persistence = DataService.persistence()
		table.insert(
			lines,
			`stand-in den {s.plot} (persistence {persistence}, DataService loaded: {loaded}): {table.concat(pads, ", ")}`
		)
		table.insert(lines, `stand-in Lockdown active: {Lockdown.isActive(s.plot)}`)
	else
		table.insert(lines, "no stand-in (run seed)")
	end
	return table.concat(lines, " | ")
end

local commands: { [string]: (...any) -> ...any } = {
	seed = seed,
	status = status,
	chase = function(on: any)
		return chase(on == true)
	end,
	home = function()
		local s = seeded
		if not s then
			return false, "seed first"
		end
		stopChase()
		s.owner.CFrame = ownerHome(s.plot)
		return true, nil
	end,
	lockdown = function()
		local s = seeded
		if not s then
			return false, "seed first"
		end
		return Lockdown.request(STAND_IN_USER_ID, s.plot)
	end,
	grab = function(plot: any, pad: any)
		local player = client()
		if not player then
			return false, "no client"
		end
		return api.requestGrab(player, plot or (seeded and seeded.plot), pad or 1)
	end,
	teleportHome = function()
		local player = client()
		local plot = player and DenWorldService.getPlot(player)
		if not (player and plot and player.Character) then
			return false, "no client den"
		end
		player.Character:PivotTo(DenWorldService.getSpawnCFrame(plot))
		return true, nil
	end,
	clear = clear,
}

function TestHook.install(raidApi: Api)
	if not RunService:IsStudio() then
		return
	end
	api = raidApi
	local hook = Instance.new("BindableFunction")
	hook.Name = "RaidTestHook"
	hook.OnInvoke = function(command: any, ...: any): ...any
		local run = if type(command) == "string" then commands[command] else nil
		if not run then
			return false, `unknown command {command}`
		end
		return run(...)
	end
	hook.Parent = ServerStorage
	print('[RaidTestHook] Studio test hook ready: ServerStorage.RaidTestHook:Invoke("seed")')
end

return TestHook

--!strict
--[[
	Lockdown (owner: raid agent): the den owner's entry block for live raids (decisions D-003,
	D-011, D-013). Started and ticked by RaidService. The rules are pure, in Shared/RaidRules.luau
	(startLockdown, canStartLockdown, lockdownActive, entryBlocked); this file applies them.

	  - Net.Requests.Lockdown (RemoteFunction in ReplicatedStorage.Remotes): () -> boolean. Den
	    owner only, rate-limited by Net.Limits.Lockdown, refused while active or before ReadyAt.
	  - It blocks ENTRY only, every live raider alike (revenge too). 10 times a second the server
	    looks at where each character is; anyone in a locked den who was not in it at the last
	    look is moved out through the nearest edge. Raiders already inside may stay or leave.
	    RaidService drops a carried critter when its carrier crosses out during a Lockdown.
	  - State lives here, keyed by the owner's userId, so leaving and rejoining this server does
	    not reset the cooldown. Den attributes LockdownUntil / LockdownReadyAt
	    (workspace:GetServerTimeNow()) and the red border are display only, never read back.

	API (RaidService only):
	  start(remotes, ownerUserIdOf, rootOf, onPushed)   onPushed(player, delta): delta is how far
	                                                    the SERVER moved them (X/Z), nothing else
	  request(userId, plot) -> (boolean, reason?)   start one if userId owns plot and the rules allow
	  isActive(plot) -> boolean
	  blocks(player, plot) -> boolean               would this player be pushed out if in it now?
	  step()                                        push-backs, border colour, display attributes
	  current(plot) -> (ownerUserId?, Lockdown?)    the den's owner and Lockdown state (Gear)
	  grantPass(player, ownerUserId, startedAt)     a finished lockpick (P2.10): this player may
	                                                enter that owner's den during THAT Lockdown
	  passOf(player) -> Pass?

	Lockpick passes (P2.10, GearRules.passValid): a passholder is let in like the owner, but only
	for the Lockdown it was picked in. The way out is unchanged: RaidService still drops a critter
	carried across the border while the Lockdown lasts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Plots = require(Shared.Plots)
local RaidRules = require(Shared.RaidRules)
local GearRules = require(Shared.GearRules)
local DenWorldService = require(script.Parent.Parent.Services.DenWorldService) :: any

type Lockdown = RaidRules.Lockdown

local PUSH_MARGIN = 4 -- studs outside the border a pushed-out raider lands
local LOCKED_COLOR = Color3.fromRGB(255, 60, 70)
local LIMIT_WINDOW_SECONDS = 10

local Lockdown = {}

local byUser: { [number]: Lockdown } = {}
local lastPlot: { [Player]: number } = {} -- the den each character was in at the last step
local savedColors: { [number]: { [BasePart]: Color3 } } = {} -- border colours while shown red
local written: { [number]: Lockdown | false } = {} -- what the den attributes show
local windows: { [Player]: { start: number, count: number } } = {}
local passes: { [Player]: GearRules.Pass } = {} -- lockpick passes (P2.10)
-- Set by start(); these placeholders only answer before it runs.
local ownerUserIdOf: (number) -> number? = function(_plot: number): number?
	return nil
end
local rootOf: (Player) -> BasePart? = function(_player: Player): BasePart?
	return nil
end
local onPushed: (Player, Vector3) -> () = function(_player: Player, _delta: Vector3) end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stateOf(plot: number): (number?, Lockdown?)
	local ownerUserId = ownerUserIdOf(plot)
	return ownerUserId, if ownerUserId then byUser[ownerUserId] else nil
end

local function allow(player: Player): boolean
	local clock = os.clock()
	local window = windows[player]
	if not window or clock - window.start >= LIMIT_WINDOW_SECONDS then
		window = { start = clock, count = 0 }
		windows[player] = window
	end
	window.count += 1
	return window.count <= Net.Limits.Lockdown
end

-- Display only: attributes and border colour follow the den's current owner.
local function show(plot: number, lockdown: Lockdown?, active: boolean)
	local current = lockdown or false
	if written[plot] ~= current then
		written[plot] = current
		local model = DenWorldService.getModel(plot)
		model:SetAttribute("LockdownUntil", if lockdown then lockdown.untilAt else nil)
		model:SetAttribute("LockdownReadyAt", if lockdown then lockdown.readyAt else nil)
	end
	local saved = savedColors[plot]
	if active and not saved then
		local colors: { [BasePart]: Color3 } = {}
		for _, strip in DenWorldService.getBorder(plot):GetChildren() do
			if strip:IsA("BasePart") then
				colors[strip] = strip.Color
				strip.Color = LOCKED_COLOR
			end
		end
		savedColors[plot] = colors
	elseif not active and saved then
		for strip, color in saved do
			strip.Color = color
		end
		savedColors[plot] = nil
	end
end

function Lockdown.isActive(plot: number): boolean
	local _, lockdown = stateOf(plot)
	return RaidRules.lockdownActive(lockdown, now())
end

-- The owner, or a lockpick passholder for this den's current Lockdown: never pushed out.
local function letIn(player: Player, ownerUserId: number?, lockdown: Lockdown?): boolean
	return ownerUserId == player.UserId or GearRules.passValid(passes[player], ownerUserId, lockdown)
end

function Lockdown.blocks(player: Player, plot: number): boolean
	local ownerUserId, lockdown = stateOf(plot)
	-- isRevenge is false: a live revenge (P1.9b) never bypasses a Lockdown (D-013).
	return RaidRules.entryBlocked(
		lockdown,
		now(),
		letIn(player, ownerUserId, lockdown),
		false,
		lastPlot[player] == plot,
		true
	)
end

function Lockdown.current(plot: number): (number?, Lockdown?)
	return stateOf(plot)
end

function Lockdown.grantPass(player: Player, ownerUserId: number, startedAt: number)
	passes[player] = { ownerUserId = ownerUserId, lockdownStartedAt = startedAt }
end

function Lockdown.passOf(player: Player): GearRules.Pass?
	return passes[player]
end

function Lockdown.request(userId: number, plot: number): (boolean, string?)
	if ownerUserIdOf(plot) ~= userId then
		return false, "NotOwner"
	end
	local t = now()
	local ok, reason = RaidRules.canStartLockdown(byUser[userId], t)
	if not ok then
		return false, reason
	end
	local lockdown = RaidRules.startLockdown(t)
	byUser[userId] = lockdown
	show(plot, lockdown, true)
	if RunService:IsStudio() then
		print(`[Lockdown] den {plot} locked until {lockdown.untilAt}, ready again at {lockdown.readyAt}`)
	end
	return true, nil
end

local function pushOut(player: Player, root: BasePart, plot: number)
	local pos = root.Position
	local x, z = Plots.pushOutside(plot, pos.X, pos.Z, PUSH_MARGIN)
	local character = player.Character
	if character then
		character:PivotTo(CFrame.new(x, pos.Y, z) * root.CFrame.Rotation)
		-- Only the server's own move is reported, so a carrier's movement budget is still charged
		-- for everything the client moved before the push (e.g. a teleport into this den).
		onPushed(player, Vector3.new(x - pos.X, 0, z - pos.Z))
	end
end

function Lockdown.step()
	local t = now()
	for plot = 1, Plots.Layout.plotCount do
		local _, lockdown = stateOf(plot)
		show(plot, lockdown, RaidRules.lockdownActive(lockdown, t))
	end
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		local plot: number? = if root then DenWorldService.plotAt(root.Position) else nil
		if root and plot then
			local ownerUserId, lockdown = stateOf(plot)
			if
				RaidRules.entryBlocked(
					lockdown,
					t,
					letIn(player, ownerUserId, lockdown),
					false,
					lastPlot[player] == plot,
					true
				)
			then
				pushOut(player, root, plot)
				plot = nil
			end
		end
		lastPlot[player] = plot
	end
end

function Lockdown.start(
	remotes: Folder,
	getOwnerUserId: (number) -> number?,
	getRoot: (Player) -> BasePart?,
	pushed: (Player, Vector3) -> ()
)
	ownerUserIdOf, rootOf, onPushed = getOwnerUserId, getRoot, pushed
	local existing = remotes:FindFirstChild(Net.Requests.Lockdown)
	local remote: RemoteFunction
	if existing and existing:IsA("RemoteFunction") then
		remote = existing
	else
		remote = Instance.new("RemoteFunction")
		remote.Name = Net.Requests.Lockdown
		remote.Parent = remotes
	end
	remote.OnServerInvoke = function(player: Player): boolean
		if not allow(player) then
			return false
		end
		local ok, started = pcall(function(): boolean
			local plot = DenWorldService.getPlot(player)
			return plot ~= nil and (Lockdown.request(player.UserId, plot))
		end)
		if not ok then
			warn(`[Lockdown] request failed for {player.UserId}: {started}`)
			return false
		end
		return started == true
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		lastPlot[player] = nil
		windows[player] = nil
		passes[player] = nil
	end)
end

return Lockdown

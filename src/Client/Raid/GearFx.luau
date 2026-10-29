--!strict
--[[
	GearFx (owner: ui agent): placeholder world visuals for GearUsed pushes (P2.10). The server
	already applied every effect; these only draw it, so a missed push costs nothing but a
	missing puff. Plain parts, no assets: a grapple line, a smoke cloud, a running decoy.
	Anything with a lifetime ends at its `endsAt` (server time) or when the server says Ended.
	Under Reduced motion the decoy stands still and the line is shorter lived.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config")) :: any
local SettingsState = require(script.Parent.Parent:WaitForChild("Hud"):WaitForChild("SettingsState"))

local GearFx = {}

type Entry = { part: BasePart, endsAt: number, decoy: { from: Vector3, dir: Vector3, t0: number }? }
local active: { [string]: Entry } = {}
local conn: RBXScriptConnection? = nil

local function newPart(name: string, shape: Enum.PartType, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Transparency = transparency
	p.Parent = workspace
	return p
end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stop(key: string)
	local entry = active[key]
	if entry then
		entry.part:Destroy()
		active[key] = nil
	end
end

local function step()
	local t = now()
	for key, entry in active do
		if t >= entry.endsAt then
			stop(key)
		elseif entry.decoy and not SettingsState.get().reducedMotion then
			local d = entry.decoy
			entry.part.Position = d.from + d.dir * (Config.Gear.items.decoy.speed * (t - d.t0))
		end
	end
	if next(active) == nil and conn then
		conn:Disconnect()
		conn = nil
	end
end

local function track(key: string, part: BasePart, endsAt: number, decoy: any?)
	stop(key)
	active[key] = { part = part, endsAt = endsAt, decoy = decoy }
	if not conn then
		conn = RunService.Heartbeat:Connect(step)
	end
end

-- Draws one GearUsed event. Unknown shapes are ignored.
function GearFx.handle(event: any)
	if type(event) ~= "table" or type(event.gearId) ~= "string" then
		return
	end
	local key = `{event.userId}:{event.gearId}`
	if event.state == "Ended" then
		stop(key)
		return
	end
	if event.state ~= "Used" then
		return
	end
	local endsAt = if type(event.endsAt) == "number" then event.endsAt else now() + 3
	if event.gearId == "grapple" then
		if typeof(event.from) == "Vector3" and typeof(event.position) == "Vector3" then
			local a, b = event.from :: Vector3, event.position :: Vector3
			local length = (b - a).Magnitude
			if length > 0.1 then
				local line = newPart("GrappleLine", Enum.PartType.Block, Color3.fromHex("78E6FF"), 0.2)
				line.Material = Enum.Material.Neon
				line.Size = Vector3.new(0.25, 0.25, length)
				line.CFrame = CFrame.lookAt((a + b) / 2, b)
				Debris:AddItem(line, if SettingsState.get().reducedMotion then 0.2 else 0.4)
			end
		end
	elseif event.gearId == "smoke" then
		if typeof(event.position) == "Vector3" then
			local radius = if type(event.radius) == "number" then event.radius else 8
			local cloud = newPart("SmokeCloud", Enum.PartType.Ball, Color3.fromHex("B8BEDD"), 0.55)
			cloud.Size = Vector3.one * radius * 2
			cloud.Position = event.position
			track(key, cloud, endsAt)
		end
	elseif event.gearId == "decoy" then
		if typeof(event.position) == "Vector3" then
			local dummy = newPart("Decoy", Enum.PartType.Ball, Color3.fromHex("FFC857"), 0.35)
			dummy.Size = Vector3.one * 2.4
			dummy.Position = event.position
			local dir = if typeof(event.direction) == "Vector3" then event.direction else Vector3.zero
			track(key, dummy, endsAt, { from = event.position, dir = dir, t0 = now() })
		end
	end
end

function GearFx.clear()
	for key in active do
		stop(key)
	end
end

return GearFx

--!strict
--[[
	CarryProp (owner: raid agent): the critter drawn over a carrier's head (P2.6r, from P2.4).

	Built by economy's CritterView, so the carried critter looks like it did on its pad: the real
	model once loaded, else the placeholder, with its tier glow and mutation effect and name tag.
	Every part is unanchored, massless, non-colliding and welded to the carrier's root part. If
	CritterView fails, a neon ball in the species' first palette colour stands in.

	Display only: nothing reads it back, and the raid code never decides anything from it. The
	caller destroys it when the carry ends (a character reset destroys it with the character).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local CritterView = require(script.Parent.Parent.Economy.CritterView) :: any

local LIFT = 3 -- studs from the root part's centre to the carried critter's feet

local CarryProp = {}

local function weld(root: BasePart, part: BasePart)
	part.Anchored = false
	part.Massless = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	local constraint = Instance.new("WeldConstraint")
	constraint.Part0 = root
	constraint.Part1 = part
	constraint.Parent = part
end

local function ball(root: BasePart, species: Types.CritterSpecies): BasePart
	local prop = Instance.new("Part")
	prop.Name = "CarriedCritter"
	prop.Shape = Enum.PartType.Ball
	prop.Size = Vector3.one * 2
	prop.Color = Color3.fromHex(species.palette[1])
	prop.Material = Enum.Material.Neon
	prop.CFrame = root.CFrame * CFrame.new(0, LIFT + 1, 0)
	weld(root, prop)
	prop.Parent = root.Parent
	return prop
end

-- Draws `species` with `mutation` over the carrier's head and returns it, parented to the character.
function CarryProp.attach(root: BasePart, species: Types.CritterSpecies, mutation: Types.Mutation?): Instance
	local ok, built = pcall(CritterView.build, species.id, mutation or "None")
	local model: Model? = if ok and typeof(built) == "Instance" and built:IsA("Model") then built else nil
	if not model then
		if not ok then
			warn(`[CarryProp] CritterView could not draw {species.id}, using a ball: {built}`)
		end
		return ball(root, species)
	end
	local placed = pcall(function()
		model:PivotTo(root.CFrame * CFrame.new(0, LIFT, 0))
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				weld(root, descendant)
			end
		end
		model.Name = "CarriedCritter"
		model.Parent = root.Parent
	end)
	if not placed then
		model:Destroy()
		return ball(root, species)
	end
	return model
end

return CarryProp

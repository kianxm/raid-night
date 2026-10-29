--!strict
--[[
	CritterView (owner: economy agent): builds the world model for one critter.

	The real-critter seam (P2.4). A species with imported ids in Shared/Data/CritterModels (mirrored
	from assets/clean/<id>/ids.json) is drawn from its real model once `prefetch` has loaded it;
	every other species, and any species whose load failed or is still running, is drawn as the
	procedural placeholder (a palette-colored shape sized by tier with a neon glow part on top).
	Tier glow and particles, the four mutation effects and the name tag are then added the same
	way to either body, so real models drop in with no code change. All look choices come from
	Shared/CritterVisuals (pure, tested under Lune); this module only turns them into instances.

	A built model:
	  - is named "Critter", has a PrimaryPart (the placeholder's "Body", or the real model's
	    largest part) that is the only CanTouch/CanQuery part, every part anchored, no collisions
	  - pivots at its feet (Model:PivotTo(padTop) stands it on a pad)
	  - holds effect parts (Moonlit's rim shell) in a child Folder "Effects"; lights and particle
	    emitters sit in the PrimaryPart, each named after its CritterVisuals effect
	  - plays its real idle animation (ids.animation) once parented under Workspace

	The bob/sway idle (CritterVisuals.idleOffset) is client-side work and needs the reduced-motion
	setting from P2.5, so nothing here moves the model.

	Server API:
	  build(speciesId, mutation) -> Model?   unparented; nil for an unknown species
	  lookKey(speciesId, mutation) -> string changes when a rebuild would draw something different
	                                         (e.g. a real model finished loading)
	  sourceFor(speciesId) -> Source         what build() draws right now
	  prefetch(onReady)                      loads every real model in CritterModels in the
	                                         background; onReady(speciesId) after each success
	  showcase(origin?, parent?) -> Model    Studio only: one critter of every tier in all five
	                                         mutation states, for playtests
]]

local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Types = require(Shared.Types)
local CritterCatalog = require(Shared.CritterCatalog) :: any
local CritterModels = require(Shared.Data.CritterModels) :: any
local CritterVisuals = require(Shared.CritterVisuals) :: any

type Mutation = Types.Mutation
type CritterSpecies = Types.CritterSpecies

local MUTATIONS: { Mutation } = { "None", "Shiny", "Moonlit", "Haunted", "Golden" }
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SOFT_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local RIM_SCALE = 1.12 -- Moonlit shell size relative to the part it wraps

-- Real model templates by species id: loaded once, cloned per critter.
local templates: { [string]: Model } = {}
local loading: { [string]: boolean } = {}

local CritterView = {}

-- Helpers -----------------------------------------------------------------------------------------

local function ghostPart(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function numbers(from: number, to: number): NumberSequence
	return NumberSequence.new(from, to)
end

-- The model's body parts: every BasePart outside the Effects folder.
local function bodyParts(model: Model): { BasePart }
	local effects = model:FindFirstChild("Effects")
	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not (effects and d:IsDescendantOf(effects)) then
			table.insert(parts, d)
		end
	end
	return parts
end

local function isGlow(part: BasePart): boolean
	return CritterVisuals.isGlowPartName(part.Name) or part.Material == Enum.Material.Neon
end

-- A model with a PrimaryPart takes its pivot from that part (WorldPivot is then ignored), so set
-- both: the part's PivotOffset and WorldPivot.
local function setPivot(model: Model, pivot: CFrame)
	local primary = model.PrimaryPart
	if primary then
		primary.PivotOffset = primary.CFrame:ToObjectSpace(pivot)
	end
	model.WorldPivot = pivot
end

local function effectsFolder(model: Model): Folder
	local existing = model:FindFirstChild("Effects")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "Effects"
	folder.Parent = model
	return folder
end

-- Bodies ------------------------------------------------------------------------------------------

local function buildPlaceholder(species: CritterSpecies): Model
	local look = CritterVisuals.tierLook(species.tier)
	local size = look.placeholderSize
	local model = Instance.new("Model")
	local body = ghostPart(model, {
		Name = "Body",
		Shape = if look.placeholderShape == "Block" then Enum.PartType.Block else Enum.PartType.Ball,
		Size = Vector3.one * size,
		CFrame = CFrame.new(0, size / 2, 0),
		Color = Color3.fromHex(species.palette[2] or species.palette[1]),
		Material = Enum.Material.SmoothPlastic,
	})
	body.CanTouch = true
	body.CanQuery = true
	ghostPart(model, {
		Name = "Glow",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * size * 0.45,
		CFrame = CFrame.new(0, size, 0),
		Color = Color3.fromHex(species.palette[1]),
		Material = Enum.Material.Neon,
	})
	model.PrimaryPart = body
	setPivot(model, CFrame.identity) -- feet at the origin
	return model
end

-- Makes a loaded asset safe and uniform: no scripts, anchored, no collisions, a PrimaryPart,
-- scaled to the tier's height, pivot at the bottom center of its bounds. False if it has no parts.
local function prepareTemplate(model: Model, species: CritterSpecies): boolean
	local largest: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy() -- a loaded asset never brings code into the game
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			if largest == nil or d.Size.Magnitude > largest.Size.Magnitude then
				largest = d
			end
		end
	end
	local primary = model.PrimaryPart or largest
	if not primary then
		return false
	end
	model.PrimaryPart = primary
	primary.CanTouch = true
	primary.CanQuery = true

	local _, extents = model:GetBoundingBox()
	local scale = CritterVisuals.fitScale(extents.Y, species.tier)
	if scale ~= 1 then
		model:ScaleTo(model:GetScale() * scale)
	end
	local center, size = model:GetBoundingBox()
	setPivot(model, CFrame.new(center.Position - Vector3.new(0, size.Y / 2, 0)) * model:GetPivot().Rotation)

	local ids = CritterModels[species.id]
	if ids and ids.animation and not model:FindFirstChildWhichIsA("Animator", true) then
		local holder: Instance? = model:FindFirstChildWhichIsA("Humanoid", true)
			or model:FindFirstChildWhichIsA("AnimationController", true)
		if not holder then
			local controller = Instance.new("AnimationController")
			controller.Parent = model
			holder = controller
		end
		Instance.new("Animator").Parent = holder
	end
	return true
end

local function loadTemplate(species: CritterSpecies, ids: any, source: string): Model?
	local model: Model
	if source == "model" then
		local container = InsertService:LoadAsset(ids.model)
		local inner = container:FindFirstChildWhichIsA("Model")
		if inner then
			inner.Parent = nil
			container:Destroy()
			model = inner
		else
			model = container
		end
	else
		local part = AssetService:CreateMeshPartAsync(`rbxassetid://{ids.mesh}`)
		part.Name = `{species.id}_mesh`
		if ids.texture then
			part.TextureID = `rbxassetid://{ids.texture}`
		end
		model = Instance.new("Model")
		part.Parent = model
		model.PrimaryPart = part
	end
	model.Name = "Critter"
	if not prepareTemplate(model, species) then
		model:Destroy()
		return nil
	end
	return model
end

-- Effects -----------------------------------------------------------------------------------------

type Context = {
	model: Model,
	root: BasePart,
	species: CritterSpecies,
	mutation: Mutation,
	tier: any, -- CritterVisuals.TierLook
	look: any, -- CritterVisuals.MutationLook
	glow: Color3,
	span: number, -- the model's largest extent, for particle sizes
	body: { BasePart },
}

local function emitter(ctx: Context, name: string, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Shape = Enum.ParticleEmitterShape.Sphere
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.LightInfluence = 0
	e.SpreadAngle = Vector2.new(180, 180)
	for key, value in props do
		(e :: any)[key] = value
	end
	e.Parent = ctx.root
	return e
end

local function light(ctx: Context, name: string, color: Color3, brightness: number, range: number)
	local l = Instance.new("PointLight")
	l.Name = name
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Shadows = false
	l.Parent = ctx.root
end

local BUILDERS: { [string]: (Context) -> () } = {
	TierLight = function(ctx)
		light(ctx, "TierLight", ctx.glow, ctx.tier.lightBrightness, ctx.tier.lightRange)
	end,
	TierMotes = function(ctx)
		emitter(ctx, "TierMotes", {
			Texture = SPARKLE_TEXTURE,
			Color = ColorSequence.new(ctx.glow),
			LightEmission = 1,
			Rate = ctx.tier.moteRate,
			Lifetime = NumberRange.new(1.2, 2),
			Speed = NumberRange.new(0.3, 0.8),
			Acceleration = Vector3.new(0, 0.8, 0),
			Size = numbers(0.08 * ctx.span, 0),
			Transparency = numbers(0.1, 1),
		})
	end,
	TierAura = function(ctx)
		emitter(ctx, "TierAura", {
			Texture = SOFT_TEXTURE,
			Color = ColorSequence.new(ctx.glow),
			LightEmission = 1,
			Rate = 4,
			Lifetime = NumberRange.new(1.5, 2),
			Speed = NumberRange.new(0, 0),
			LockedToPart = true,
			Size = numbers(0.8 * ctx.span, 1.1 * ctx.span),
			Transparency = numbers(0.75, 1),
			RotSpeed = NumberRange.new(-20, 20),
		})
	end,
	SecretAura = function(ctx)
		-- Unique to Secret: an aura cycling through the whole palette, with rising sparks.
		local palette = ctx.species.palette
		local keys = {}
		for i, color in palette do
			table.insert(keys, ColorSequenceKeypoint.new((i - 1) / math.max(1, #palette - 1), Color3.fromHex(color)))
		end
		if #keys == 1 then
			table.insert(keys, ColorSequenceKeypoint.new(1, keys[1].Value))
		end
		emitter(ctx, "SecretAura", {
			Texture = SOFT_TEXTURE,
			Color = ColorSequence.new(keys),
			LightEmission = 1,
			Rate = 6,
			Lifetime = NumberRange.new(2, 2.5),
			Speed = NumberRange.new(0, 0),
			LockedToPart = true,
			Size = numbers(0.9 * ctx.span, 1.4 * ctx.span),
			Transparency = numbers(0.6, 1),
			RotSpeed = NumberRange.new(-60, 60),
		})
		emitter(ctx, "SecretSparks", {
			Texture = SPARKLE_TEXTURE,
			Color = ColorSequence.new(keys),
			LightEmission = 1,
			Rate = 10,
			Lifetime = NumberRange.new(1, 1.6),
			Speed = NumberRange.new(1, 2),
			Acceleration = Vector3.new(0, 2, 0),
			Size = numbers(0.1 * ctx.span, 0),
			Transparency = numbers(0, 1),
		})
	end,
	ShinySparkles = function(ctx)
		emitter(ctx, "ShinySparkles", {
			Texture = SPARKLE_TEXTURE,
			Color = ColorSequence.new(Color3.fromHex(ctx.look.sparkleColor)),
			LightEmission = 1,
			ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface,
			Rate = 12,
			Lifetime = NumberRange.new(0.5, 0.9),
			Speed = NumberRange.new(0, 0),
			LockedToPart = true,
			Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.3, 0.14 * ctx.span),
				NumberSequenceKeypoint.new(1, 0),
			}),
			RotSpeed = NumberRange.new(90, 180),
		})
	end,
	MoonlitRim = function(ctx)
		-- A slightly larger ForceField shell around each body part reads as a pale rim light.
		local rim = Color3.fromHex(ctx.look.rimColor)
		local folder = effectsFolder(ctx.model)
		for _, part in ctx.body do
			if not isGlow(part) then
				local shell = part:Clone()
				for _, child in shell:GetChildren() do
					child:Destroy()
				end
				shell.Name = "MoonlitRim"
				shell.Size = part.Size * RIM_SCALE
				shell.CFrame = part.CFrame
				shell.Material = Enum.Material.ForceField
				shell.Color = rim
				shell.Transparency = 0
				shell.Reflectance = 0
				shell.CastShadow = false
				shell.CanCollide = false
				shell.CanTouch = false
				shell.CanQuery = false
				if shell:IsA("MeshPart") then
					shell.TextureID = ""
				end
				shell.Parent = folder
			end
		end
	end,
	MoonlitLight = function(ctx)
		light(ctx, "MoonlitLight", Color3.fromHex(ctx.look.rimColor), 1.5, 8 + ctx.span)
	end,
	HauntedFade = function(ctx)
		for _, part in ctx.body do
			part.Transparency = CritterVisuals.partTransparency(ctx.mutation, isGlow(part))
		end
	end,
	HauntedWisps = function(ctx)
		emitter(ctx, "HauntedWisps", {
			Texture = SOFT_TEXTURE,
			Color = ColorSequence.new(Color3.fromHex(ctx.look.wispColor)),
			LightEmission = 0.7,
			Rate = 5,
			Lifetime = NumberRange.new(2, 3),
			Speed = NumberRange.new(0.2, 0.6),
			Acceleration = Vector3.new(0, 1.2, 0),
			Size = numbers(0.25 * ctx.span, 0.6 * ctx.span),
			Transparency = numbers(0.5, 1),
			RotSpeed = NumberRange.new(-30, 30),
		})
	end,
	GoldenSwap = function(ctx)
		local found, material = pcall(function(): any
			return (Enum.Material :: any)[ctx.look.goldMaterial]
		end)
		if not found or typeof(material) ~= "EnumItem" then
			material = Enum.Material.Foil
		end
		local gold = Color3.fromHex(ctx.look.goldColor)
		for _, part in ctx.body do
			if not isGlow(part) then
				part.Material = material
				part.Color = gold
				part.Reflectance = 0.25
				if part:IsA("MeshPart") then
					part.TextureID = ""
				end
				for _, child in part:GetChildren() do
					if child:IsA("SurfaceAppearance") then
						child:Destroy()
					end
				end
			end
		end
	end,
}

local function applyEffects(model: Model, species: CritterSpecies, mutation: Mutation)
	local root = model.PrimaryPart :: BasePart
	local _, extents = model:GetBoundingBox()
	local ctx: Context = {
		model = model,
		root = root,
		species = species,
		mutation = mutation,
		tier = CritterVisuals.tierLook(species.tier),
		look = CritterVisuals.mutationLook(mutation),
		glow = Color3.fromHex(species.palette[1]),
		span = math.max(extents.X, extents.Y, extents.Z),
		body = bodyParts(model),
	}
	for _, name in CritterVisuals.effects(species.tier, mutation) do
		local build = BUILDERS[name]
		if build then
			build(ctx)
		else
			warn(`[CritterView] no builder for effect {name}`)
		end
	end
end

local function addLabel(model: Model, species: CritterSpecies, mutation: Mutation)
	local root = model.PrimaryPart :: BasePart
	local _, extents = model:GetBoundingBox()
	local rootHeight = model:GetPivot():PointToObjectSpace(root.Position).Y
	local tag = Instance.new("BillboardGui")
	tag.Name = "NameTag"
	tag.Size = UDim2.fromOffset(170, 40)
	tag.StudsOffset = Vector3.new(0, extents.Y - rootHeight + 1, 0)
	tag.MaxDistance = 45
	tag.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromHex(species.palette[1])
	label.TextStrokeTransparency = 0.4
	label.Text = CritterVisuals.labelText(species, mutation)
	label.Parent = tag
	tag.Parent = root
end

-- Plays the real model's idle once the model is in the world (an Animator only loads there).
local function playIdleWhenPlaced(model: Model, animationId: number)
	task.defer(function()
		if not model:IsDescendantOf(workspace) then
			return
		end
		local animator = model:FindFirstChildWhichIsA("Animator", true)
		if not animator then
			return
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = `rbxassetid://{animationId}`
		local ok, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if ok and track then
			track.Looped = true
			track:Play()
		else
			warn(`[CritterView] idle animation {animationId} failed: {track}`)
		end
	end)
end

-- API ---------------------------------------------------------------------------------------------

function CritterView.sourceFor(speciesId: string): string
	if templates[speciesId] then
		return CritterVisuals.source(CritterModels[speciesId])
	end
	return "placeholder"
end

function CritterView.lookKey(speciesId: string, mutation: Mutation): string
	return `{speciesId}|{mutation}|{CritterView.sourceFor(speciesId)}`
end

function CritterView.build(speciesId: string, mutation: Mutation): Model?
	local species = CritterCatalog.get(speciesId) :: CritterSpecies?
	if not species then
		return nil
	end
	local template = templates[speciesId]
	local model = if template then template:Clone() else buildPlaceholder(species)
	model.Name = "Critter"
	applyEffects(model, species, mutation)
	addLabel(model, species, mutation)
	local ids = CritterModels[speciesId]
	if template and ids and ids.animation then
		playIdleWhenPlaced(model, ids.animation)
	end
	return model
end

function CritterView.prefetch(onReady: (speciesId: string) -> ())
	for speciesId, ids in CritterModels do
		local source = CritterVisuals.source(ids)
		local species = CritterCatalog.get(speciesId) :: CritterSpecies?
		if species and source ~= "placeholder" and not templates[speciesId] and not loading[speciesId] then
			loading[speciesId] = true
			task.spawn(function()
				local ok, result = pcall(loadTemplate, species, ids, source)
				loading[speciesId] = nil
				if ok and result then
					templates[speciesId] = result
					onReady(speciesId)
				else
					warn(`[CritterView] {speciesId} {source} failed to load, keeping the placeholder: {result}`)
				end
			end)
		end
	end
end

function CritterView.showcase(origin: CFrame?, parent: Instance?): Model
	assert(RunService:IsStudio(), "CritterView.showcase is a Studio playtest tool")
	local base = origin or CFrame.new(0, 40, 0)
	local spacing = 12
	local tiers = CritterCatalog.TIER_ORDER
	local gallery = Instance.new("Model")
	gallery.Name = "CritterShowcase"
	ghostPart(gallery, {
		Name = "Floor",
		Size = Vector3.new(spacing * #MUTATIONS, 1, spacing * #tiers),
		CFrame = base * CFrame.new(0, -0.5, spacing * (#tiers - 1) / 2),
		Color = Color3.fromHex("#1B1F3B"),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = true,
	})
	for row, tier in tiers do
		local species = CritterCatalog.byTier(tier)[1]
		if species then
			for col, mutation in MUTATIONS do
				local model = CritterView.build(species.id, mutation)
				if model then
					model.Name = `{tier}_{mutation}`
					model:PivotTo(base * CFrame.new((col - (#MUTATIONS + 1) / 2) * spacing, 0, (row - 1) * spacing))
					model.Parent = gallery
				end
			end
		end
	end
	gallery.Parent = parent or workspace
	return gallery
end

return CritterView

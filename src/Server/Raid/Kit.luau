--!strict
--[[
	Kit (owner: raid agent): builds world pieces through one lookup (P2.3, the world swap seam).
	The piece list, roles and authoring convention are in Shared/WorldKit.luau.

	Piece names are the asset manifest's ids (assets/kit/manifest.json): den_base, pad,
	vault_door, plaza, lamp_post, trap_<kind>, the street props, plus seam-only pieces.
	For a piece name, the art template is:
	  1. ServerStorage.WorldKit.<name> (a Model or a BasePart), else
	  2. WorldKit.Pieces[name].assetId, loaded by preload() with InsertService:LoadAsset, else
	  3. none: the caller's greybox placeholder is all there is.
	Templates are cached; a failed load warns once and falls back to the greybox.

	  preload()                          loads every assetId once. Yields only when an id is set.
	  has(name) -> boolean               is there art for this piece?
	  artCount() -> number               pieces with art loaded so far
	  dress(anchor, name, base?, footprint?) -> Model?
	                                     lays art over an Anchor piece's placeholder part
	  pivot(anchor, cframe)              moves an anchor and its art together
	  decor(name, parent, cframe, build) a Decor piece: art if there is some, else build(model)

	Art is display only: every part in it is anchored, with collision, touch, query and shadows
	off, and any script in an asset is removed before use.
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local WorldKit = require(ReplicatedStorage.Shared.WorldKit)

local ART = "Art"

type Template = { model: Model, extents: Vector3 }

local loaded: { [string]: Template } = {}
local missing: { [string]: boolean } = {}
local preloaded = false

local Kit = {}

-- Anchors the art and strips anything that is not display: scripts, collision, touch, query.
local function prepare(model: Model, ghost: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = false
			d.CastShadow = false
			if ghost then
				d.CanCollide = false
				d.CanQuery = false
			end
		end
	end
end

local function asModel(instance: Instance): Model?
	if instance:IsA("Model") then
		return instance
	elseif instance:IsA("BasePart") then
		local model = Instance.new("Model")
		instance.Parent = model
		model.PrimaryPart = instance
		return model
	end
	return nil
end

local function remember(name: string, instance: Instance?): Template?
	local model = if instance then asModel(instance) else nil
	if not model then
		return nil
	end
	local template = { model = model, extents = model:GetExtentsSize() }
	loaded[name] = template
	return template
end

local function template(name: string): Template?
	local cached = loaded[name]
	if cached then
		return cached
	end
	if missing[name] then
		return nil
	end
	local folder = ServerStorage:FindFirstChild("WorldKit")
	local source = if folder then folder:FindFirstChild(name) else nil
	if source then
		return remember(name, source:Clone())
	end
	missing[name] = true -- asset ids are only read by preload()
	return nil
end

function Kit.preload()
	if preloaded then
		return
	end
	preloaded = true
	for name, info in WorldKit.Pieces do
		if info.assetId ~= 0 and not loaded[name] then
			local ok, result = pcall(InsertService.LoadAsset, InsertService, info.assetId)
			local root = if ok then result:GetChildren()[1] else nil
			if root and remember(name, root) then
				missing[name] = nil
			else
				warn(`[Kit] {name}: asset {info.assetId} did not load ({if ok then "empty" else result}); greybox`)
			end
		end
	end
end

function Kit.has(name: string): boolean
	return template(name) ~= nil
end

-- How many pieces have art so far (0 tonight: everything is greybox).
function Kit.artCount(): number
	local n = 0
	for _ in loaded do
		n += 1
	end
	return n
end

local function clone(name: string, ghost: boolean): (Model?, Template?)
	local t = template(name)
	if not t then
		return nil, nil
	end
	local model = t.model:Clone()
	model.Name = ART
	prepare(model, ghost)
	return model, t
end

local function bottomOf(anchor: BasePart): CFrame
	return anchor.CFrame * CFrame.new(0, -anchor.Size.Y / 2, 0)
end

-- Lays the piece's art over `anchor`, fitted to its X/Z footprint, replacing any art already
-- there. Returns nil (and leaves the placeholder as it is) when the piece has no art. `base`
-- and `footprint` override the anchor's bottom centre and size, for a part whose axes are not
-- upright (the plaza cylinder); such an anchor must not be moved with pivot().
function Kit.dress(anchor: BasePart, name: string, base: CFrame?, footprint: Vector3?): Model?
	local old = anchor:FindFirstChild(ART)
	if old then
		old:Destroy()
	end
	local art, t = clone(name, true)
	if not (art and t) then
		return nil
	end
	local ext = t.extents
	local size = footprint or anchor.Size
	if ext.X > 0 and ext.Z > 0 then
		art:ScaleTo(art:GetScale() * math.min(size.X / ext.X, size.Z / ext.Z))
	end
	art:PivotTo(base or bottomOf(anchor))
	art.Parent = anchor
	local info = WorldKit.Pieces[name]
	if not (info and info.keepAnchor) then
		anchor.Transparency = 1
	end
	return art
end

function Kit.pivot(anchor: BasePart, cframe: CFrame)
	anchor.CFrame = cframe
	local art = anchor:FindFirstChild(ART)
	if art and art:IsA("Model") then
		art:PivotTo(bottomOf(anchor))
	end
end

-- A Decor piece at `cframe` (its bottom centre): the art if there is some, else a Model that
-- `build` fills with the greybox placeholder in world space.
function Kit.decor(name: string, parent: Instance, cframe: CFrame, build: (Model) -> ()): Model
	local art = clone(name, false)
	local model: Model
	if art then
		model = art
		model:PivotTo(cframe)
	else
		model = Instance.new("Model")
		build(model)
	end
	model.Name = name
	model.Parent = parent
	return model
end

return Kit

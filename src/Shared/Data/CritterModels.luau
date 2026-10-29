--!strict
--[[
	CritterModels (owner: economy agent): species id -> imported Roblox asset ids.

	Source of truth: `assets/clean/<id>/ids.json`, written by the assets agent at Stage 5 of
	docs/asset-pipeline.md. This table mirrors those files so the game can read them at runtime;
	`CritterModels.spec` fails if the two ever disagree. To add a real critter, add its ids.json
	AND the matching entry here (same numbers). No other code change: a species with an entry is
	drawn from its model, every other species keeps the procedural placeholder
	(Shared/CritterVisuals.source, Server/Economy/CritterView).

	Fields (all optional, Roblox asset ids):
	  model      a packaged Model asset (InsertService:LoadAsset). Wins over `mesh` when both exist.
	  mesh       a mesh asset; the server builds a MeshPart from it (AssetService:CreateMeshPartAsync)
	  texture    the mesh's texture (MeshPart.TextureID)
	  icon       2D icon for UI (shop, inventory, raid log)
	  animation  the happy den idle, played looped on the model's Animator

	Empty tonight (D-057: no art credits yet), so every critter draws as its placeholder.
	Keys are species ids from Data/Critters.luau and are permanent like them.
]]

export type ModelIds = {
	model: number?,
	mesh: number?,
	texture: number?,
	icon: number?,
	animation: number?,
}

local models: { [string]: ModelIds } = {
	-- dusk_mouse = { mesh = 0, texture = 0, icon = 0, animation = 0 },
}

for _, ids in models do
	table.freeze(ids)
end

return table.freeze(models)

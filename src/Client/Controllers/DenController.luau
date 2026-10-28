--!strict
--[[
	DenController (owner: ui agent)

	Shows the player's den: Glow wallet, storage bar, critter pads, collect button, shop.
	Renders from Net DenState pushes; predicts the storage bar locally between pushes using
	ratePerSecond, then snaps to the server value on each push.

	TODO (Phase 0): HUD with Glow + storage bar, collect button, egg shop conveyor
]]

local DenController = {}

function DenController.start()
	-- TODO
end

return DenController

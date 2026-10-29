--!strict
--[[
	Client entry point (owner: ui agent). Starts controllers. The client renders and requests;
	it never decides game outcomes. Remote names and payloads: Shared/Net.luau.
]]

local Controllers = script.Parent:WaitForChild("Controllers")

for _, name in
	{
		"RevengeController", -- first: it must hear RevengeJoinStatus the moment a teleport lands
		"DenController",
		"HudController",
		"MenuController", -- before the screens that register with it
		"ShopController",
		"InventoryController",
		"DenManageController",
		"SettingsController",
		"GearController",
		"CritterIdleController",
		"SoundController",
		"RaidLogController",
		"DenStatusController",
		"RaidPortalController",
		"RaidHudController",
	}
do
	local controller = require(Controllers:WaitForChild(name)) :: any
	controller.start()
end

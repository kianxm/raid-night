--!strict
--[[
	Client entry point (owner: ui agent). Starts controllers. The client renders and requests;
	it never decides game outcomes. Remote names and payloads: Shared/Net.luau.
]]

local Controllers = script.Parent:WaitForChild("Controllers")

for _, name in { "DenController", "HudController", "RaidLogController", "DenStatusController" } do
	local controller = require(Controllers:WaitForChild(name)) :: any
	controller.start()
end

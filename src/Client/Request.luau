--!strict
--[[
	Request (owner: ui agent): fire one RemoteFunction from a menu screen. The client only asks;
	the caller shows whatever the server answered. A second tap while one is in flight is
	ignored, so a double tap never double-buys.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Request = {}

local busy: { [string]: boolean } = {}

-- Calls `onResult(ok, result)` once the server answers. ok is false when the remote is missing,
-- busy, or errored.
function Request.invoke(name: string, onResult: (boolean, any) -> (), ...: any)
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = folder and folder:FindFirstChild(name)
	if not remote or not remote:IsA("RemoteFunction") or busy[name] then
		onResult(false, nil)
		return
	end
	busy[name] = true
	local args = table.pack(...)
	task.spawn(function()
		local ok, result = pcall(function()
			return (remote :: RemoteFunction):InvokeServer(table.unpack(args, 1, args.n))
		end)
		busy[name] = false
		onResult(ok, if ok then result else nil)
	end)
end

return Request

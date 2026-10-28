--!strict
--[[
	Server entry point. Starts services in dependency order. Each service is owned by one agent
	(see .claude/agents/). Services talk to each other only through their public functions.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CritterCatalog = require(Shared:WaitForChild("CritterCatalog")) :: any

-- Refuse to start with a broken catalog: a bad ship is worse than no ship.
local problems = CritterCatalog.validate()
if #problems > 0 then
	error("Critter catalog invalid:\n" .. table.concat(problems, "\n"))
end

local Services = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")

local order = {
	"DataService", -- profiles first; everything else reads them
	"DenWorldService", -- map, den plots and spawns; IncomeService and RaidService build on it
	"IncomeService",
	"SnapshotService",
	"EscrowService",
	"MatchmakingService",
	"RaidService",
	"NotificationService",
	"PurchaseService",
}

for _, name in order do
	local service = require(Services:WaitForChild(name)) :: any
	service.start()
end

print("[RaidNight] server started")

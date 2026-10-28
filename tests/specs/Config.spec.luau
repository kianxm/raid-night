--!strict
local expect = require("../lib/expect")
local Config = require("../../src/Shared/Config")

local tests = {}

-- The approved kill-switch contract (docs/contracts.md). Changing it is a contract change.
local EXPECTED_FLAGS = {
	raids = true,
	asyncRaids = false,
	purchases = false,
	trading = false,
	notifications = false,
}

tests["every kill switch exists with its launch default"] = function()
	for name, default in EXPECTED_FLAGS do
		expect.eq((Config.Flags :: any)[name], default, `Flags.{name}`)
	end
end

tests["no unlisted flags and every flag is a boolean"] = function()
	for name, value in Config.Flags :: any do
		expect.truthy(EXPECTED_FLAGS[name] ~= nil, `unexpected flag {name}`)
		expect.eq(type(value), "boolean", `Flags.{name}`)
	end
end

tests["flags are frozen so no service can flip one at runtime"] = function()
	expect.truthy(table.isfrozen(Config.Flags), "Config.Flags is frozen")
	expect.throws(function()
		(Config.Flags :: any).raids = false
	end)
end

return tests

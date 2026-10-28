--!strict
local expect = require("../lib/expect")
local fixtures = require("../lib/fixtures")
local Escrow = require("../../src/Shared/Escrow")
local Config = require("../../src/Shared/Config")

local NOW = 1_800_000_000

local function setup()
	local raider = fixtures.veteran(1, NOW)
	local defender = fixtures.veteran(2, NOW)
	fixtures.give(defender, fixtures.critter("fox", "crescent_fox", "Pad", 1))
	defender.stored = 1000
	local record = Escrow.create("raid-1", raider.userId, defender.userId, "fox", 250, false, NOW)
	return raider, defender, record
end

local function runAll(raider, defender, record)
	local debit = Escrow.debitDefender(defender, record, NOW)
	Escrow.markDebited(record, debit, NOW)
	Escrow.creditRaider(raider, record, NOW)
	Escrow.markCommitted(record, NOW)
end

local tests = {}

tests["happy path moves the critter and the Glow"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	expect.eq(defender.critters["fox"], nil, "defender lost the fox")
	expect.truthy(raider.critters["fox"], "raider has the fox")
	expect.eq(raider.critters["fox"].placement, "Inventory")
	expect.eq(raider.critters["fox"].stolenLockUntil, NOW + Config.Raid.stolenTradeLockSeconds)
	expect.eq(defender.stored, 750, "defender storage")
	expect.eq(raider.glow, 250, "raider wallet")
	expect.eq(record.state, "Committed")
end

tests["the defender gets a shield, a revenge token, a loss and a log entry"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	expect.eq(defender.shieldUntil, NOW + Config.Shield.afterSuccessfulRaidSeconds)
	expect.eq(defender.revengeTokens["raid-1"].targetUserId, raider.userId)
	expect.eq(defender.lossesToday, 1)
	expect.eq(defender.raidLog[1].direction, "Incoming")
	expect.eq(defender.raidLog[1].speciesId, "crescent_fox")
end

tests["repeating the debit changes nothing"] = function()
	local _, defender, record = setup()
	local first = Escrow.debitDefender(defender, record, NOW)
	local second = Escrow.debitDefender(defender, record, NOW + 5)
	expect.eq(first, second, "same applied transfer returned")
	expect.eq(defender.stored, 750, "Glow taken once")
	expect.eq(defender.lossesToday, 1, "loss counted once")
end

tests["repeating the credit changes nothing"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	Escrow.creditRaider(raider, record, NOW + 5)
	Escrow.creditRaider(raider, record, NOW + 6)
	expect.eq(raider.glow, 250, "Glow credited once")
end

tests["a critter moved to the vault before the debit is safe; Glow is still taken"] = function()
	local raider, defender, record = setup()
	defender.critters["fox"].placement = "Vault"
	runAll(raider, defender, record)
	expect.truthy(defender.critters["fox"], "fox stayed home")
	expect.eq(raider.critters["fox"], nil)
	expect.eq(raider.glow, 250)
	expect.eq(defender.lossesToday, 0, "no critter lost")
end

tests["the loss cap is enforced at debit time, even if a raid slipped through"] = function()
	local raider, defender, record = setup()
	defender.lossesToday = Config.Limits.maxLossesPerDay
	runAll(raider, defender, record)
	expect.truthy(defender.critters["fox"], "fox protected by the cap")
	expect.eq(raider.glow, 250, "Glow still taken")
end

tests["Glow taken never exceeds what is stored"] = function()
	local raider, defender, record = setup()
	defender.stored = 40.9
	runAll(raider, defender, record)
	expect.eq(raider.glow, 40)
	expect.near(defender.stored, 0.9, 1e-9)
end

tests["void only works before any debit"] = function()
	local _, defender, record = setup()
	expect.truthy(Escrow.void(table.clone(record), defender, NOW), "pending can be voided")
	local debit = Escrow.debitDefender(defender, record, NOW)
	Escrow.markDebited(record, debit, NOW)
	expect.falsy(Escrow.void(record, defender, NOW), "debited cannot be voided")
end

tests["void is refused if the debit landed but the record save crashed"] = function()
	local _, defender, record = setup()
	Escrow.debitDefender(defender, record, NOW) -- defender saved, record still Pending
	expect.eq(record.state, "Pending")
	expect.falsy(Escrow.void(record, defender, NOW), "would strand the fox")
	expect.eq(record.state, "Pending", "record untouched; recovery will finish it")
end

tests["out-of-order steps are refused"] = function()
	local raider, _, record = setup()
	expect.throws(function()
		Escrow.creditRaider(raider, record, NOW)
	end, "credit before debit must fail")
	expect.throws(function()
		Escrow.markCommitted(record, NOW)
	end, "commit before debit must fail")
end

tests["crediting a critter the raider already owns is refused as a duplicate"] = function()
	local raider, defender, record = setup()
	local debit = Escrow.debitDefender(defender, record, NOW)
	Escrow.markDebited(record, debit, NOW)
	fixtures.give(raider, fixtures.critter("fox", "crescent_fox", "Inventory"))
	expect.throws(function()
		Escrow.creditRaider(raider, record, NOW)
	end)
end

tests["old idempotency entries are pruned after the retention window"] = function()
	local raider, defender, record = setup()
	runAll(raider, defender, record)
	expect.eq(Escrow.pruneApplied(raider, NOW + 60), 0, "kept while fresh")
	expect.eq(Escrow.pruneApplied(raider, NOW + Config.Escrow.appliedTransferRetentionSeconds + 1), 1)
end

return tests

--!strict
--[[
	EscrowService (owner: data agent; every change reviewed by the reviewer agent)

	Turns a successful raid into a safe transfer using Shared/Escrow.luau.

	Flow when a raid ends in an escape:
	  1. Escrow.create -> save the record under its raidId key (write-once)
	  2. Debit the defender:
	       - defender online somewhere -> DataService.sendMessage(defender, { kind = "EscrowDebit", raidId })
	         and their session runs Escrow.debitDefender, then updates the record
	       - defender offline -> DataService.withOfflineProfile(defender, Escrow.debitDefender ...)
	  3. Credit the raider in this server (their profile is loaded here)
	  4. Escrow.markCommitted

	Recovery: on raider join, and every 60 seconds, advance any of this server's players'
	records still in Pending or Debited. Every step is idempotent, so retries are always safe.

	TODO (Phase 1):
	  [ ] Implement the Escrow.Store interface on top of DataService + an escrow DataStore
	  [ ] Index open records per raider (MemoryStore) so recovery does not scan
	  [ ] Duplication alarm: log loudly if creditRaider ever asserts on a duplicate uid

	Kill switches: a NEW transfer needs its raid kind's flag (Config.Flags.raids for live steals,
	Config.Flags.asyncRaids for offline raids). Recovery of records already in flight is never
	gated: switching a feature off must not strand loot that has already left a defender.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type TransferKind = "Live" | "Async"

local EscrowService = {}

-- Whether a new transfer of this kind may start. Every entry point that creates an escrow
-- record must call this first and refuse when it returns false.
function EscrowService.canStartTransfer(kind: TransferKind): (boolean, string?)
	local enabled = if kind == "Async" then Config.Flags.asyncRaids else Config.Flags.raids
	if not enabled then
		return false, `{kind} raids are switched off`
	end
	return true, nil
end

function EscrowService.start()
	-- TODO (Phase 1): start the recovery sweep here, unconditionally (never behind a flag).
end

return EscrowService

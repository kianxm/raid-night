--!strict
--[[
	SnapshotService (owner: matchmaking agent)

	Saves each den's raidable snapshot (Matchmaking.buildSnapshot) to its own DataStore key on
	leave and every Config.Snapshot.intervalSeconds while online, and keeps the player's
	MatchEntry fresh in the MemoryStore pool for their power band.

	TODO (Phase 1):
	  [ ] Save snapshot on PlayerRemoving and on the interval
	  [ ] Upsert MatchEntry into the band's MemoryStore sorted map; remove from the old band if
	      power moved bands
	  [ ] Batch MemoryStore writes to stay inside request budgets
]]

local SnapshotService = {}

function SnapshotService.start()
	-- TODO
end

return SnapshotService

--!strict
--[[
	RaidService (owner: raid agent)

	Runs raids: live steals between players in this server, and async raids into pocket dens
	rebuilt from snapshots.

	Server-authoritative rules:
	  - The client requests a grab; the server checks distance, lock state, RaidRules.validateGrab
	  - The server tracks who carries what and applies RaidRules.carrySpeedMultiplier
	  - Escape = the carried critter crosses the raider's border or the pocket's escape gate

	TODO (Phase 0, live stealing):
	  [ ] Den plots, pads, borders; grab, carry, tag-to-drop, lockdown button
	TODO (Phase 1, async raids):
	  [ ] StartRaid: RaidRules.canRaid, acquire lock, load snapshot, build pocket den far off-map
	      from pooled models, start the Config.Raid.durationSeconds timer
	  [ ] Guards (simple patrol/chase/tag AI) and traps from the snapshot
	  [ ] End raid: RaidRules.recordOutgoing; on escape hand off to EscrowService
	  [ ] Record replay frames (positions at 5 Hz + events) for the defender
	  [ ] One pocket per player, destroyed on exit; streaming keeps others from loading it
]]

local RaidService = {}

function RaidService.start()
	-- TODO
end

return RaidService

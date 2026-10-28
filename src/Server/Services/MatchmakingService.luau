--!strict
--[[
	MatchmakingService (owner: matchmaking agent)

	Answers GetRaidTargets: reads the raider's power band and both neighbors from MemoryStore,
	calls Matchmaking.pickCandidates, and adds any live revenge tokens on top.

	TODO (Phase 1):
	  [ ] Read pools for band - 1, band, band + 1
	  [ ] Exclude blocked users both ways
	  [ ] Revenge targets always shown first, regardless of power
	  [ ] Raid locks: MemoryStore key per defender, TTL Config.Raid.lockTtlSeconds;
	      acquire in RaidService.startRaid, release on raid end
	  [ ] Presence map userId -> JobId (refresh every 60 s) for live revenge
]]

local MatchmakingService = {}

function MatchmakingService.start()
	-- TODO
end

return MatchmakingService

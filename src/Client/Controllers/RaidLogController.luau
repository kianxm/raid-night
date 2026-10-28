--!strict
--[[
	RaidLogController (owner: ui agent)

	The raid log is the primary re-engagement surface (notifications only reach some players).
	On every login it opens first if anything happened while away: who raided you, what they
	took, a Watch Replay button, and a Revenge button while the token is live.

	TODO (Phase 1): raid log panel, revenge button -> StartRaid with revengeRaidId
	TODO (Phase 3): replay viewer, clip export
]]

local RaidLogController = {}

function RaidLogController.start()
	-- TODO
end

return RaidLogController

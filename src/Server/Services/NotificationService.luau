--!strict
--[[
	NotificationService (owner: notifications agent)

	Sends experience notifications. Platform limits (see docs/design-summary.md):
	  - opted-in users 13+ only; one notification per user per day per experience
	  - the opt-in prompt can show at most once per 30 days

	Send rules:
	  1. First critter lost today -> send immediately: "{raider} stole your {critter}. Get it back?"
	     with launch data carrying the raidId (Join lands on the revenge screen)
	  2. Glow-only losses -> wait until storage is ~90% full, then one combined send
	  3. Tag every send with an analytics category: revenge | storage | event

	TODO (Phase 2):
	  [ ] Notification strings created in the Creator Dashboard; ids in a config table
	  [ ] Open Cloud key stored in a Secret, never in code
	  [ ] Handle throttled responses quietly (no retry storms)
	  [ ] PromptOptIn right after a player's first successful raid, never on first join
	  [ ] Read launch data on join and route to the revenge screen
]]

local NotificationService = {}

function NotificationService.start()
	-- TODO
end

return NotificationService

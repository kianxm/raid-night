--!strict
--[[
	DataService (owner: data agent)

	Loads, migrates, holds and saves player profiles with ProfileStore (session locking).
	The ONLY module that touches the profiles DataStore.

	TODO (Phase 1, async core):
	  [ ] Vendor ProfileStore (see docs/setup.md) and create the store with Profile.new(0, 0) as template
	  [ ] On join: load with session lock, Profile.migrate, RaidRules.resetDailyIfNeeded,
	      RaidRules.pruneRevengeTokens, Escrow.pruneApplied, then fire profileLoaded
	  [ ] On leave: final accrue, save, release
	  [ ] Message handler: apply incoming escrow debits (Escrow.debitDefender) inside this session
	  [ ] withOfflineProfile(userId, fn): load an offline profile, run fn, save, release
	      (used by EscrowService when the defender is not online anywhere)
	  [ ] Kick the player if the profile cannot load. Never run the game on a default profile.
]]

local DataService = {}

function DataService.start()
	-- TODO: wire Players.PlayerAdded / PlayerRemoving
end

-- Returns the live profile for an online player in THIS server, or nil.
function DataService.getProfile(_userId: number): any
	return nil -- TODO
end

-- Sends a message to a player's profile wherever it is loaded (ProfileStore message queue).
-- If no server holds it, the message is applied the next time the profile loads.
function DataService.sendMessage(_userId: number, _message: { [string]: any })
	-- TODO
end

return DataService

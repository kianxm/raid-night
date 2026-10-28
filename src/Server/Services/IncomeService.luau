--!strict
--[[
	IncomeService (owner: economy agent)

	Collecting, placing critters, buying eggs, upgrading and rebirth. All math lives in
	Shared/Economy.luau; this service validates requests and calls it.

	Invariant: call Economy.accrue(profile, now) BEFORE any change to placements or den level.

	TODO (Phase 0, prototype):
	  [ ] Collect request -> Economy.collect
	  [ ] PlaceCritter request: validate ownership, pad index < Economy.padCount, vault slots
	  [ ] BuyEgg: price check, Economy.rollTier + Economy.rollSpecies with a server Random,
	      new uid via HttpService:GenerateGUID(false)
	  [ ] UpgradeDen, Rebirth
	  [ ] Push DenChanged after every change
]]

local IncomeService = {}

function IncomeService.start()
	-- TODO
end

return IncomeService

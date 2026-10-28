--!strict
--[[
	PurchaseService (owner: economy agent)

	ProcessReceipt for developer products and pass ownership checks. Launch catalog per the
	design doc: VIP, extra vault slot, auto-collect, raid scout, cosmetics; shields, Glow packs,
	timer skips, event pass.

	Hard rules:
	  - NO paid randomness at launch (eggs and luck boosts bought with Robux are paid random
	    items). Phase 2 adds them with an odds panel and PolicyService checks.
	  - Never sell the return of a stolen critter.
	  - ProcessReceipt is idempotent: store receipt ids on the profile; grant once; only return
	    PurchaseGranted after the profile change is saved.

	TODO (Phase 2):
	  [ ] Product id table in a config module
	  [ ] Receipt ledger on the profile (bounded, pruned)
	  [ ] PolicyService:GetPolicyInfoForPlayerAsync gate for trading and any future paid random items
]]

local PurchaseService = {}

function PurchaseService.start()
	-- TODO
end

return PurchaseService

--!strict
--[[
	PurchaseService (owner: economy agent)

	ProcessReceipt for developer products and pass ownership checks. Launch catalog per the
	design summary ("Monetization", D-029). Prices in Robux; ranges until the Phase 3 price tests.

	Passes:
	  - VIP 399
	  - Extra vault slot 199
	  - Auto-collect 149
	  - Raid scout 249
	  - Themes and gear skins
	  - Escape emotes (49-149 each)
	Products:
	  - Shield 49
	  - Timer skips
	  - Event pass 399
	  - Critter accessories (25-149, direct sale, cosmetic only: never change stats or income)
	  - "Lantern Night" server boost (99-199): +50% Glow EARNED by everyone in the server for
	    15 min, buyer announced via Net.Pushes.ServerAnnouncement. It multiplies earned Glow and
	    never grants Glow directly.

	Glow is earn-only at launch (D-028). Glow packs ship only in the Phase 2 paid-randomness
	mini-phase (Glow buys eggs, so Glow for Robux makes eggs paid random items): odds on screen,
	PolicyService region checks, reviewer audit.

	Hard rules:
	  - NO paid randomness at launch (eggs and luck boosts bought with Robux are paid random
	    items). Phase 2 adds them with an odds panel and PolicyService checks.
	  - No randomness in any launch product (D-029).
	  - Robux-linked Glow multipliers (D-030: VIP's +50% Glow and Lantern Night) never apply to a
	    player whose PolicyService info has ArePaidRandomItemsRestricted. Fail closed: until the
	    policy result arrives, or if it can't be read, the player counts as restricted. They are
	    also off while Config.Flags.purchases is false. Economy.glowBoostFactor encodes all three
	    (pure, tested); Economy.accrue applies it. VIP keeps its non-Glow perks for restricted
	    players. Both products ship only after the P2.8 reviewer policy audit and PolicyService
	    check.
	  - The restriction flag, VIP ownership and Lantern Night state come only from the server
	    (PolicyService, MarketplaceService, the server's Lantern Night timer), never from a client
	    request. Accrue at the OLD factor before any of them changes (Economy header).
	  - Never sell the return of a stolen critter.
	  - ProcessReceipt is idempotent: store receipt ids on the profile; grant once; only return
	    PurchaseGranted after the profile change is saved.

	TODO (Phase 2):
	  [ ] Product id table in a config module
	  [ ] Receipt ledger on the profile (bounded, pruned)
	  [ ] PolicyService:GetPolicyInfoForPlayerAsync gate for trading and any future paid random items

	TODO (P2.8, Lantern Night):
	  [ ] Stacking rule: a second purchase while a boost is active extends its end time; it never
	      multiplies (+50% stays +50%)
	  [x] Server-wide multiplier applied in Economy.accrue via a passed-in factor (P0.12:
	      Economy.glowBoostFactor + accrue's `factor`; no clock or server state inside Shared)
	  [ ] One server helper computes each player's factor; every accrue of an online player
	      (IncomeService, EscrowService, Matchmaking) passes it, or accrues with it first
	  [ ] Announcement text goes through the text filter if it includes player-provided text
	      (display names don't need filtering)
]]

local PurchaseService = {}

function PurchaseService.start()
	-- TODO
end

return PurchaseService

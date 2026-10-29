--!strict
--[[
	PurchaseService (owner: economy agent)

	Game passes, developer products and ProcessReceipt (P2.8). The catalog, prices and the
	per-item policy flags live in Config.Purchases (docs/contracts.md, "Purchases"); the pure rules
	(who is offered what, which perks apply, the receipt steps) live in Shared/Economy.luau.

	Hard rules:
	  - No paid randomness: no egg, luck or Glow pack is sold (D-028, D-029). No product grants
	    Glow. Nothing sells the return of a stolen critter.
	  - Robux-linked items (D-030, D-061): an item that raises or protects Glow
	    (Config.Purchases <item>.robuxLinked) never takes effect for a player whose PolicyService
	    info has ArePaidRandomItemsRestricted, and fails closed: until PolicyService answers, or
	    when it can't be read, the player counts as restricted. Such items are not offered to them
	    unless the item's offerRestricted says so (none does at launch; VIP is hidden too, D-065,
	    and its Glow bonus is Economy.glowBoostFactor's). A receipt for an item the player may not get answers
	    NotProcessedYet and grants nothing.
	  - Everything is off while Config.Flags.purchases is false, and an item whose id is still 0
	    (not created in the Creator Dashboard) is never offered, granted or checked.
	  - The restriction, pass ownership and Lantern Night come only from the server
	    (PolicyService, MarketplaceService, this service's timer), never from a client.
	  - A player's Glow factor changes only through IncomeService.setGlowInputs (the Glow-factor
	    helper), which accrues at the old factor first.

	ProcessReceipt (idempotent; Economy.processReceipt has the steps, C6's Profile receipts):
	  - receipt already on the profile (a redelivery): grant nothing; PurchaseGranted once a
	    confirmed save holds it, else NotProcessedYet;
	  - otherwise: may the product be granted now? record the receipt (Profile.recordReceipt;
	    false = bad input: NotProcessedYet) and grant in the same step with no yield between; then
	    DataService.saveNow confirming the saved data holds the receipt; only then PurchaseGranted;
	  - first it waits (up to RECEIPT_WAIT_SECONDS, while the player is here) for the profile to
	    load, and for a first grant of a Robux-linked product for loadPolicy to finish, since
	    Roblox may redeliver only at join; then it fetches player and profile again;
	  - player gone, profile still not loaded, unknown product, an error anywhere: NotProcessedYet.
	  Roblox redelivers a receipt until it is granted, so a forced shutdown mid-purchase either
	  lost the in-memory grant with the receipt (granted again on redelivery) or saved both
	  (acknowledged on redelivery, granted nothing).

	Lantern Night: one end time per server. A purchase starts one or extends a running one by
	Config.Boosts.lanternNightSeconds (the bonus never stacks), sets every player's
	lanternNightUntil through the helper and announces the buyer to each player:
	ServerAnnouncement("LanternNight", { buyerUserId, buyerName, endsAt, boosted }) (display name,
	no player text, so no filtering). `boosted` is whether the boost applies to that recipient
	(their policy known unrestricted and purchases on), so a restricted player's client never says
	they earn +50%. A player who joins while one runs gets its end time and the same announcement
	(for the latest buyer). The boost lives in this server's memory: a shutdown ends it early.

	Shop (P2.8c): GetShopOffers () -> Net.ShopOffers, Economy.shopOffers over Config.Purchases.
	Waits up to SHOP_POLICY_WAIT_SECONDS for loadPolicy, then answers; an unknown policy fails
	closed (no Robux-linked item unless offered to restricted players). Rate limit
	Net.Limits.GetShopOffers.

	Analytics (P2.9): `purchase` (product = the Config.Purchases key, price in Robux) once per
	first grant of a product receipt (never for a redelivery) and once per pass purchase
	MarketplaceService confirms.

	Server API:
	  policyOf(userId) -> Economy.PurchasePolicy
	  ownsPass(userId, passKey) -> boolean       MarketplaceService ownership, never saved
	  perkActive(userId, passKey) -> boolean     Economy.perkActive: owned, on, policy allows
	  offers(userId) -> { Net.ShopOffer }      what the shop may show this player (Economy.shopOffers)
	  lanternNightEndsAt() -> number             0 = none running
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config) :: any
local Economy = require(Shared.Economy) :: any
local Profile = require(Shared.Profile) :: any
local RaidRules = require(Shared.RaidRules) :: any
local Net = require(Shared.Net) :: any
local RateLimit = require(Shared.RateLimit) :: any
local DataService = require(script.Parent.DataService) :: any
local IncomeService = require(script.Parent.IncomeService) :: any
local AnalyticsService = require(script.Parent.AnalyticsService) :: any

local POLICY_ATTEMPTS = 3
local POLICY_BACKOFF_SECONDS = 2
-- How long ProcessReceipt waits for the profile to load (a rejoin after a forced shutdown waits
-- for the dead server's lock, about 45 s) and for loadPolicy to finish. Roblox may redeliver a
-- receipt only when the player joins, so answering before the load could leave it unprocessed
-- on every rejoin.
local RECEIPT_WAIT_SECONDS = 60
local PASS_CHECK_ATTEMPTS = 3
-- How long GetShopOffers waits for loadPolicy before answering with the policy still unknown.
local SHOP_POLICY_WAIT_SECONDS = 10

type PlayerState = {
	restricted: boolean?, -- PolicyService ArePaidRandomItemsRestricted; nil = unknown (restricted)
	policyDone: boolean, -- loadPolicy finished (answered, or gave up: restricted stays nil)
	owns: { [string]: boolean }, -- pass key -> owned
	limits: any, -- RateLimit.State for this service's requests
}

local states: { [number]: PlayerState } = {}
local lanternEndsAt = 0
local lanternBuyer: { userId: number, name: string }? = nil
local announce: RemoteEvent? = nil

local PurchaseService = {}

local function stateOf(userId: number): PlayerState
	local state = states[userId]
	if not state then
		state = { restricted = nil, policyDone = false, owns = {}, limits = {} }
		states[userId] = state
	end
	return state :: PlayerState
end

function PurchaseService.policyOf(userId: number): any
	local state = states[userId]
	return {
		paidRandomRestricted = if state then state.restricted else nil,
		purchasesEnabled = Config.Flags.purchases == true,
	}
end

function PurchaseService.ownsPass(userId: number, passKey: string): boolean
	local state = states[userId]
	return state ~= nil and state.owns[passKey] == true
end

function PurchaseService.perkActive(userId: number, passKey: string): boolean
	local item = Config.Purchases.passes[passKey]
	if not item then
		return false
	end
	return Economy.perkActive(item, PurchaseService.ownsPass(userId, passKey), PurchaseService.policyOf(userId))
end

function PurchaseService.offers(userId: number): { any }
	return Economy.shopOffers(Config.Purchases, PurchaseService.policyOf(userId), function(key: string): boolean
		return PurchaseService.ownsPass(userId, key)
	end)
end

function PurchaseService.lanternNightEndsAt(): number
	return if lanternEndsAt > os.time() then lanternEndsAt else 0
end

-- Policy and pass ownership ----------------------------------------------------------------------

-- Reads the player's paid-random-items restriction. Leaves it unknown (= restricted) when
-- PolicyService fails every attempt or answers without a boolean. Marks the state policyDone
-- either way, so ProcessReceipt stops waiting for it.
local function loadPolicy(player: Player)
	local userId = player.UserId
	for attempt = 1, POLICY_ATTEMPTS do
		local ok, info = pcall(function(): any
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		if ok and type(info) == "table" and type(info.ArePaidRandomItemsRestricted) == "boolean" then
			local state = states[userId]
			if state and player.Parent == Players then
				state.restricted = info.ArePaidRandomItemsRestricted
				state.policyDone = true
				IncomeService.setGlowInputs(
					userId,
					{ paidRandomRestricted = info.ArePaidRandomItemsRestricted },
					os.time()
				)
			end
			return
		end
		if attempt < POLICY_ATTEMPTS then
			task.wait(POLICY_BACKOFF_SECONDS * attempt)
		end
	end
	local state = states[userId]
	if state then
		state.policyDone = true
	end
	warn(`[PurchaseService] no PolicyService answer for {userId}; Robux-linked items stay off`)
end

-- Runs IncomeService.refresh on its own thread, so its errors never reach the caller (a saved
-- grant must never turn into NotProcessedYet because a DenState push failed).
local function refreshLater(player: Player)
	task.spawn(function()
		if player.Parent == Players then
			local ok, err = pcall(IncomeService.refresh, player)
			if not ok then
				warn(`[PurchaseService] refresh failed for {player.UserId}: {err}`)
			end
		end
	end)
end

local function setOwned(player: Player, passKey: string, owned: boolean)
	local state = states[player.UserId]
	if player.Parent ~= Players or not state then
		return
	end
	state.owns[passKey] = owned
	if passKey == "vip" then
		IncomeService.setGlowInputs(player.UserId, { vip = owned }, os.time())
	end
	if owned then
		refreshLater(player) -- e.g. a new vault slot or auto-collect shows at once
	end
end

-- MarketplaceService's own answer on whether `player` owns pass `passId`; false when it fails.
local function ownsPassAsync(player: Player, passId: number): boolean
	local ok, owned = pcall(function(): any
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	return ok and owned == true
end

-- Checks every created pass. A failed check counts as not owned (fail closed); a later purchase
-- in this session still turns it on (PromptGamePassPurchaseFinished).
local function loadPasses(player: Player)
	for key, item in Config.Purchases.passes do
		if item.id > 0 and ownsPassAsync(player, item.id) then
			setOwned(player, key, true)
		end
	end
end

local function passKeyById(passId: number): string?
	if type(passId) ~= "number" or passId <= 0 then
		return nil
	end
	for key, item in Config.Purchases.passes do
		if item.id == passId then
			return key
		end
	end
	return nil
end

-- Lantern Night ----------------------------------------------------------------------------------

-- The running Lantern Night's announcement to one player. `boosted`: the boost applies to them.
local function announceLanternNight(player: Player)
	local buyer = lanternBuyer
	if not (announce and buyer and lanternEndsAt > os.time()) then
		return
	end
	local policy = PurchaseService.policyOf(player.UserId)
	announce:FireClient(player, "LanternNight", {
		buyerUserId = buyer.userId,
		buyerName = buyer.name,
		endsAt = lanternEndsAt,
		boosted = policy.purchasesEnabled == true and policy.paidRandomRestricted == false,
	})
end

local function startLanternNight(buyer: Player, now: number)
	lanternEndsAt = Economy.extendLanternNight(lanternEndsAt, now)
	lanternBuyer = { userId = buyer.UserId, name = buyer.DisplayName }
	for _, player in Players:GetPlayers() do
		IncomeService.setGlowInputs(player.UserId, { lanternNightUntil = lanternEndsAt }, now)
	end
	for _, player in Players:GetPlayers() do
		announceLanternNight(player)
	end
end

-- Product grants ---------------------------------------------------------------------------------
-- canGrant and grant must agree: ProcessReceipt records the receipt between them with no yield.

local function canGrant(item: any, profile: any, now: number): boolean
	if item.kind == "shield" then
		local probe = { shieldUntil = profile.shieldUntil }
		RaidRules.applyPurchasedShield(probe, now)
		return probe.shieldUntil > profile.shieldUntil -- at the stack cap a shield adds nothing
	elseif item.kind == "lanternNight" then
		return true
	elseif item.kind == "eventPass" then
		local eventId = Config.Purchases.currentEventId
		return eventId ~= "" and not Profile.hasEventPass(profile, eventId)
	elseif item.kind == "accessory" then
		local id = item.accessoryId
		return type(id) == "string" and #id > 0 and #id <= 100
	end
	return false -- unknown kind: never granted
end

local function grant(item: any, player: Player, profile: any, now: number): boolean
	if item.kind == "shield" then
		RaidRules.applyPurchasedShield(profile, now)
		return true
	elseif item.kind == "lanternNight" then
		startLanternNight(player, now)
		return true
	elseif item.kind == "eventPass" then
		return Profile.grantEventPass(profile, Config.Purchases.currentEventId, now)
	elseif item.kind == "accessory" then
		return Profile.grantAccessory(profile, item.accessoryId)
	end
	return false
end

-- ProcessReceipt ---------------------------------------------------------------------------------

local function decide(info: any): string
	if type(info) ~= "table" or type(info.PlayerId) ~= "number" or type(info.ProductId) ~= "number" then
		return "NotProcessedYet"
	end
	local userId: number = info.PlayerId
	local purchaseId: any = info.PurchaseId
	local productId: number = info.ProductId
	local _, item = Economy.productById(productId)
	-- Roblox may redeliver only when the player joins, before their profile loads (after a forced
	-- shutdown the load waits ~45 s for the dead server's lock). So wait while they are here: for
	-- the profile, and for a first grant of a Robux-linked product, for loadPolicy to finish.
	local deadline = os.clock() + RECEIPT_WAIT_SECONDS
	local function waitFor(ready: () -> boolean): boolean
		while not ready() do
			local here = Players:GetPlayerByUserId(userId)
			if not here or here.Parent ~= Players or os.clock() >= deadline then
				return false
			end
			task.wait(1)
		end
		return true
	end
	if not waitFor(function(): boolean
		return DataService.getProfile(userId) ~= nil
	end) then
		return "NotProcessedYet" -- redelivered when they are back
	end
	local loaded = DataService.getProfile(userId)
	if item and item.robuxLinked and loaded and not Profile.hasReceipt(loaded, purchaseId) then
		waitFor(function(): boolean
			local state = states[userId]
			return state ~= nil and state.policyDone
		end) -- gave up: the policy stays unknown and canGrant refuses (fail closed)
	end
	-- Fetched again after the waits: the session may have changed while we yielded.
	local player = Players:GetPlayerByUserId(userId)
	local profile = DataService.getProfile(userId)
	if not player or not profile then
		return "NotProcessedYet"
	end
	local now = os.time()
	local granted = false -- this call granted (a redelivery grants nothing)
	local decision = Economy.processReceipt({
		hasReceipt = function(): boolean
			return Profile.hasReceipt(profile, purchaseId)
		end,
		canGrant = function(): boolean
			return item ~= nil
				and Economy.purchaseOffered(item, PurchaseService.policyOf(userId))
				and canGrant(item, profile, now)
		end,
		record = function(): boolean
			return Profile.recordReceipt(profile, purchaseId, productId, now)
		end,
		grant = function(): boolean
			local ok = grant(item, player, profile, now)
			if not ok then
				warn(`[PurchaseService] grant refused after canGrant for {userId} receipt {purchaseId}`)
			end
			granted = ok
			return ok
		end,
		save = function(): boolean
			local saved, why = DataService.saveNow(userId, function(data: any): boolean
				return type(data) == "table" and type(data.receipts) == "table" and data.receipts[purchaseId] ~= nil
			end)
			if not saved then
				warn(`[PurchaseService] receipt {purchaseId} for {userId} not confirmed saved: {why}`)
			end
			return saved == true
		end,
	})
	if decision == "PurchaseGranted" then
		refreshLater(player) -- a shield shows in DenState
		local key = Economy.productById(productId)
		if granted and key and item then
			AnalyticsService.track(player, "purchase", { product = key, price = item.price })
		end
	end
	return decision
end

local function processReceipt(info: any): Enum.ProductPurchaseDecision
	local ok, decision = pcall(decide, info)
	if not ok then
		warn(`[PurchaseService] ProcessReceipt failed: {decision}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if decision == "PurchaseGranted" then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- Lifecycle --------------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	stateOf(player.UserId)
	if lanternEndsAt > os.time() then
		IncomeService.setGlowInputs(player.UserId, { lanternNightUntil = lanternEndsAt }, os.time())
	end
	task.spawn(function()
		loadPolicy(player)
		-- After the policy answer, so `boosted` is right; nothing if it ended meanwhile. The
		-- refresh shows perks the answer turned on (DenState.vaultSlots).
		if player.Parent == Players then
			announceLanternNight(player)
			refreshLater(player)
		end
	end)
	task.spawn(loadPasses, player)
end

-- GetShopOffers: rate limit, then wait (while the player is here) for loadPolicy, then answer.
local function getShopOffers(player: Player): any
	local userId = player.UserId
	local state = states[userId]
	if
		not state or not RateLimit.take(state.limits, Net.Requests.GetShopOffers, Net.Limits.GetShopOffers, os.clock())
	then
		return { policyKnown = false, offers = {} }
	end
	local deadline = os.clock() + SHOP_POLICY_WAIT_SECONDS
	while not state.policyDone and player.Parent == Players and os.clock() < deadline do
		task.wait(0.5)
	end
	local current = states[userId]
	if current ~= state or player.Parent ~= Players then
		return { policyKnown = false, offers = {} }
	end
	return { policyKnown = state.restricted ~= nil, offers = PurchaseService.offers(userId) }
end

-- The remote named `name` of class `className` in ReplicatedStorage.Remotes, made if missing.
local function remoteOf(className: string, name: string): Instance
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	local existing = (folder :: Folder):FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = folder
	return remote
end

function PurchaseService.start()
	announce = remoteOf("RemoteEvent", Net.Pushes.ServerAnnouncement) :: RemoteEvent
	local shop = remoteOf("RemoteFunction", Net.Requests.GetShopOffers) :: RemoteFunction
	shop.OnServerInvoke = function(player: Player): any
		local ok, result = pcall(getShopOffers, player)
		if not ok then
			warn(`[PurchaseService] GetShopOffers failed for {player.UserId}: {result}`)
			return { policyKnown = false, offers = {} }
		end
		return result
	end
	IncomeService.setPerks({
		extraVaultSlots = function(userId: number): number
			return if PurchaseService.perkActive(userId, "vaultSlot") then 1 else 0
		end,
		autoCollect = function(userId: number): boolean
			return PurchaseService.perkActive(userId, "autoCollect")
		end,
	})
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local key = passKeyById(passId)
			if not (key and purchased) then
				return
			end
			-- Trust MarketplaceService, not the event alone. Its answer can lag a fresh purchase,
			-- so retry a little; still false means not owned (fail closed) until the next join.
			task.spawn(function()
				for attempt = 1, PASS_CHECK_ATTEMPTS do
					if player.Parent ~= Players then
						return
					end
					if ownsPassAsync(player, passId) then
						local already = PurchaseService.ownsPass(player.UserId, key)
						setOwned(player, key, true)
						if not already then
							local item = Config.Purchases.passes[key]
							AnalyticsService.track(player, "purchase", { product = key, price = item.price })
						end
						return
					end
					if attempt < PASS_CHECK_ATTEMPTS then
						task.wait(2 * attempt)
					end
				end
				warn(`[PurchaseService] pass {passId} purchase by {player.UserId} not confirmed by MarketplaceService`)
			end)
		end
	)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player.UserId] = nil
	end)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return PurchaseService

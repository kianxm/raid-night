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
	    unless the item's offerRestricted says so (VIP keeps its non-Glow perks; its Glow bonus is
	    Economy.glowBoostFactor's). A receipt for an item the player may not get answers
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
	  - player not here, profile not loaded, unknown product, an error anywhere: NotProcessedYet.
	  Roblox redelivers a receipt until it is granted, so a forced shutdown mid-purchase either
	  lost the in-memory grant with the receipt (granted again on redelivery) or saved both
	  (acknowledged on redelivery, granted nothing).

	Lantern Night: one end time per server. A purchase starts one or extends a running one by
	Config.Boosts.lanternNightSeconds (the bonus never stacks), sets every player's
	lanternNightUntil through the helper and announces the buyer:
	ServerAnnouncement("LanternNight", { buyerUserId, buyerName, endsAt }) (display name, no
	player text, so no filtering). Players who join later get the end time too. The boost lives
	in this server's memory: a shutdown ends it early.

	Server API:
	  policyOf(userId) -> Economy.PurchasePolicy
	  ownsPass(userId, passKey) -> boolean       MarketplaceService ownership, never saved
	  perkActive(userId, passKey) -> boolean     Economy.perkActive: owned, on, policy allows
	  offers(userId) -> { { key, kind, id, price } }  what the shop may show this player
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
local DataService = require(script.Parent.DataService) :: any
local IncomeService = require(script.Parent.IncomeService) :: any

local POLICY_ATTEMPTS = 3
local POLICY_BACKOFF_SECONDS = 2

type PlayerState = {
	restricted: boolean?, -- PolicyService ArePaidRandomItemsRestricted; nil = unknown (restricted)
	owns: { [string]: boolean }, -- pass key -> owned
}

local states: { [number]: PlayerState } = {}
local lanternEndsAt = 0
local announce: RemoteEvent? = nil

local PurchaseService = {}

local function stateOf(userId: number): PlayerState
	local state = states[userId]
	if not state then
		state = { restricted = nil, owns = {} }
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
	local policy = PurchaseService.policyOf(userId)
	local list = {}
	for key, item in Config.Purchases.passes do
		if Economy.purchaseOffered(item, policy) and not PurchaseService.ownsPass(userId, key) then
			table.insert(list, { key = key, kind = "pass", id = item.id, price = item.price })
		end
	end
	for key, item in Config.Purchases.products do
		local available = item.kind ~= "eventPass" or Config.Purchases.currentEventId ~= ""
		if available and Economy.purchaseOffered(item, policy) then
			table.insert(list, { key = key, kind = item.kind, id = item.id, price = item.price })
		end
	end
	return list
end

function PurchaseService.lanternNightEndsAt(): number
	return if lanternEndsAt > os.time() then lanternEndsAt else 0
end

-- Policy and pass ownership ----------------------------------------------------------------------

-- Reads the player's paid-random-items restriction. Leaves it unknown (= restricted) when
-- PolicyService fails every attempt or answers without a boolean.
local function loadPolicy(player: Player)
	for attempt = 1, POLICY_ATTEMPTS do
		local ok, info = pcall(function(): any
			return PolicyService:GetPolicyInfoForPlayerAsync(player)
		end)
		if ok and type(info) == "table" and type(info.ArePaidRandomItemsRestricted) == "boolean" then
			if player.Parent == Players then
				stateOf(player.UserId).restricted = info.ArePaidRandomItemsRestricted
				IncomeService.setGlowInputs(
					player.UserId,
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
	warn(`[PurchaseService] no PolicyService answer for {player.UserId}; Robux-linked items stay off`)
end

local function setOwned(player: Player, passKey: string, owned: boolean)
	if player.Parent ~= Players then
		return
	end
	stateOf(player.UserId).owns[passKey] = owned
	if passKey == "vip" then
		IncomeService.setGlowInputs(player.UserId, { vip = owned }, os.time())
	end
	if owned then
		IncomeService.refresh(player) -- e.g. a new vault slot or auto-collect shows at once
	end
end

-- Checks every created pass. A failed check counts as not owned (fail closed); a later purchase
-- in this session still turns it on (PromptGamePassPurchaseFinished).
local function loadPasses(player: Player)
	for key, item in Config.Purchases.passes do
		if item.id > 0 then
			local ok, owned = pcall(function(): any
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, item.id)
			end)
			if ok and owned == true then
				setOwned(player, key, true)
			end
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

local function startLanternNight(buyer: Player, now: number)
	lanternEndsAt = Economy.extendLanternNight(lanternEndsAt, now)
	for _, player in Players:GetPlayers() do
		IncomeService.setGlowInputs(player.UserId, { lanternNightUntil = lanternEndsAt }, now)
	end
	if announce then
		announce:FireAllClients("LanternNight", {
			buyerUserId = buyer.UserId,
			buyerName = buyer.DisplayName,
			endsAt = lanternEndsAt,
		})
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
	local player = Players:GetPlayerByUserId(userId)
	local profile = DataService.getProfile(userId)
	if not player or not profile then
		return "NotProcessedYet" -- redelivered when they are back
	end
	local _, item = Economy.productById(productId)
	local now = os.time()
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
	if decision == "PurchaseGranted" and player.Parent == Players then
		IncomeService.refresh(player) -- a shield shows in DenState
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
	task.spawn(loadPolicy, player)
	task.spawn(loadPasses, player)
end

local function announceRemote(): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not (folder and folder:IsA("Folder")) then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	local name = Net.Pushes.ServerAnnouncement
	local existing = (folder :: Folder):FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

function PurchaseService.start()
	announce = announceRemote()
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
			if key and purchased then
				setOwned(player, key, true)
			end
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

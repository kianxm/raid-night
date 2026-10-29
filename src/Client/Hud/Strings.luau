--!strict
--[[
	Strings (owner: ui agent): every player-facing HUD string in one table so it can be
	localized later. Keep them short. Use `Strings.format` for {placeholders}.
]]

local Strings = {
	glow = "Glow",
	storage = "Den storage",
	storageFull = "Full",
	collect = "Collect",
	buyEgg = "Buy Egg",
	free = "Free",
	freeEgg = "Free egg",
	carrying = "Carrying {name} ({tier})",
	odds = "Odds",
	oddsTitle = "Egg odds",
	oddsRescue = "Free egg: always Common",
	oddsEqual = "Same tier: every critter equally likely",
	oddsEach = "{pct} each",
	oddsClose = "Close",
	lockdown = "Lockdown",
	lockdownActive = "Locked {time}",
	lockdownCooldown = "Ready in {time}",
	lockdownStarted = "Lockdown on!",
	lockdownRefused = "Can't lock down now",
	beingRaided = "{name} is raiding your den!",
	beingRaidedUnknown = "You're being raided!",
	dropped = "Dropped {name}!",
	stolen = "You stole {name}! It's in your den.",
	stealUnconfirmed = "Steal not confirmed",
	stealUnconfirmedSub = "If it went through, it'll show up in your den.",
	protected = "Protected",
	protectedOwn = "Protected from steals",
	safeFor = "Safe for {time}",
	alreadyStealing = "Someone is already stealing here",

	-- Raid Portal
	raid = "Raid",
	portalTitle = "Pick a den",
	portalEmpty = "No dens to raid right now",
	portalRefused = "Can't raid that den now",
	power = "Power {n}",
	revengeTag = "Revenge",
	hintSmall = "Small stash",
	hintSolid = "Solid stash",
	hintRich = "Rich stash",
	hintUnknown = "Stash unknown",
	close = "Close",

	-- In-raid HUD
	raidFindCritter = "Grab a critter",
	raidCarryHint = "Get to the gate!",
	gate = "Gate {dist}m",
	raidEscaped = "Escaped with {name}!",
	raidEscapedNone = "Made it out!",
	raidGlowOnly = "Made it out with Glow!",
	raidPending = "On its way!",
	raidPendingNamed = "{name} is on its way!",
	raidCaught = "Caught!",
	raidGlow = "+{n} Glow",
	raidCritters = "{n} critters inside",
	raidRevengeGrab = "Revenge! Grab a critter",
	raidTimeout = "Time's up!",
	raidRetreat = "Left empty-handed",
	raidLeft = "You left the raid",
	raidError = "Raid ended early",

	-- Raid log
	logTitle = "While you were away",
	logTitleAll = "Raid log",
	logEmpty = "No raids yet",
	logTookFrom = "{name} took {critter}",
	logTookGlow = "{name} took {critter} and {n} Glow",
	logHeld = "You held off {name}",
	logYouTook = "You took {critter} from {name}",
	logYouFailed = "{name} stopped you",
	logAgo = "{time} ago",
	logRevengeRaid = "Revenge",
	replay = "Replay",
	replayNone = "Replay not ready",
	revenge = "Revenge",

	-- Revenge choice and live join
	revengeTitle = "Revenge on {name}",
	revengeJoin = "Join their server",
	revengeDen = "Raid their den",
	revengeDenInstead = "Raid their den instead",
	revengeJoining = "Joining {name}...",
	revengeSlow = "Taking a while",
	revengeArrived = "You're at {name}'s den",
	failSwitchedOff = "Live revenge is off right now",
	failInvalid = "That revenge isn't valid",
	failNoToken = "That revenge is used up",
	failExpired = "That revenge window closed",
	failUnavailable = "Can't revenge that player",
	failPairLimit = "You've raided them enough for now",
	failBusy = "They're busy right now",
	failRaiderOffline = "They just went offline",
	failServerFull = "Their server is full",
	failServerGone = "Their server closed",
	failTeleport = "Couldn't join. Try again",
	raiderFallback = "Raider",

	-- Menu strip and shared
	menuShop = "Shop",
	menuClose = "Close",

	-- Shop (Glow only: no Robux items at launch)
	shopTitle = "Shop",
	shopEggTitle = "Night egg",
	shopEggFree = "Free egg",
	shopBuyFor = "Buy  {price} Glow",
	shopBuyFree = "Get it free",
	shopNeedGlow = "Need {n} more Glow",
	shopHatched = "Hatched {name}!",
	shopBuyFailed = "Couldn't buy that now",
	shopUpgradeTitle = "Den level {n}",
	shopPads = "{n} pads",
	shopUpgradeFor = "Upgrade  {price} Glow",
	shopMaxLevel = "Max level",
	shopUpgraded = "Den upgraded!",
	shopUpgradeFailed = "Couldn't upgrade now",

	-- Bag (inventory) and Den management
	menuBag = "Bag",
	menuDen = "Den",
	bagTitle = "Bag",
	bagEmpty = "Nothing in your bag",
	bagToPad = "Pad",
	bagToVault = "Vault",
	critterLine = "{tier}",
	critterLineMutation = "{tier}, {mutation}",
	placeDone = "Moved!",
	placeFailed = "Can't move it now",
	denTitle = "Your den",
	denPads = "Pads {used}/{total}",
	denVault = "Vault {used}",
	denBag = "Bag {n}",
	denPickHint = "Tap a critter, then a pad",
	denPadEmpty = "Empty",
	denToVault = "To Vault",
	denToBag = "To Bag",
	denSelected = "{name} selected",

	-- Settings
	menuSettings = "Options",
	settingsTitle = "Settings",
	settingsMusic = "Music",
	settingsSfx = "Sound effects",
	settingsReducedMotion = "Reduced motion",
	settingsOn = "On",
	settingsOff = "Off",
	settingsPercent = "{pct}%",

	portalRefresh = "Refresh",
}

function Strings.format(template: string, values: { [string]: string }): string
	return (string.gsub(template, "{(%w+)}", function(key: string)
		return values[key]
	end))
end

return Strings

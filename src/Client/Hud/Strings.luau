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
}

function Strings.format(template: string, values: { [string]: string }): string
	return (string.gsub(template, "{(%w+)}", function(key: string)
		return values[key]
	end))
end

return Strings

--!strict
--[[
	NotificationRules (owner: notifications agent). Pure send rules, no Roblox services.

	Platform limits: one notification per user per day per experience; opt-in prompt at most once
	per 30 days; opted-in 13+ users only (the platform enforces age and opt-in, a send to anyone
	else simply fails, so the rules here only decide WHEN and WHAT).

	State (per defender, persisted by NotificationService's store):
	  lastSentDay        UTC day number of the last send (the daily slot)
	  glowLossPending    true after a Glow-only loss that has not been sent about yet
	  promptedAt         unix seconds of the last opt-in prompt

	  seenRaids        bounded list of raidIds onLoss already handled (two servers can both
	                   report the same loss; see Rules.noteRaid)

	Day boundary is UTC. A failed send never spends the slot (see Rules.afterSend).
]]

local Rules = {}

export type State = {
	lastSentDay: number?,
	glowLossPending: boolean?,
	promptedAt: number?,
	seenRaids: { string }?,
}

export type Category = "revenge" | "storage"

export type LossEvent = {
	kind: "Critter" | "Glow",
	raidId: string,
	raiderName: string?,
	critterName: string?,
}

export type Decision = {
	action: "Send" | "Hold" | "Skip",
	category: Category?,
	reason: string,
}

-- Which categories may send. The design sends only the first-critter-lost revenge notification;
-- storage stays off until Kian approves a storage-full category.
Rules.ENABLED_CATEGORIES = { revenge = true, storage = false } :: { [string]: boolean }

Rules.SECONDS_PER_DAY = 86400
Rules.PROMPT_COOLDOWN_SECONDS = 30 * 86400
Rules.MAX_LAUNCH_DATA = 200 -- platform limit on launch data length
Rules.MAX_PARAM_LENGTH = 40
Rules.LAUNCH_PREFIX = "revenge:"
Rules.MAX_SEEN_RAIDS = 20

function Rules.dayOf(now: number): number
	return math.floor(now / Rules.SECONDS_PER_DAY)
end

function Rules.dailySlotFree(state: State, now: number): boolean
	return state.lastSentDay ~= Rules.dayOf(now)
end

-- A critter loss spends the daily send if it is free. Glow-only losses are held for the storage
-- rule. A critter loss after a send already went out today is skipped (the raid log has it).
function Rules.decideLoss(state: State, event: LossEvent, now: number, enabled: boolean): Decision
	if not enabled then
		return { action = "Skip", reason = "Disabled" }
	end
	if Rules.ENABLED_CATEGORIES.revenge ~= true then
		return { action = "Skip", reason = "CategoryOff" }
	end
	if event.kind == "Glow" then
		return { action = "Hold", reason = "GlowOnly" }
	end
	if not Rules.dailySlotFree(state, now) then
		return { action = "Skip", reason = "DailyCapSpent" }
	end
	if Rules.cleanParam(event.raiderName) == nil or Rules.cleanParam(event.critterName) == nil then
		return { action = "Skip", reason = "MissingCopyParams" }
	end
	if not Rules.validRaidId(event.raidId) then
		return { action = "Skip", reason = "BadRaidId" }
	end
	return { action = "Send", category = "revenge", reason = "FirstCritterLost" }
end

-- One combined send once a pending Glow-only loss meets a nearly full storage.
function Rules.decideStorage(
	state: State,
	stored: number,
	capacity: number,
	share: number,
	now: number,
	enabled: boolean
): Decision
	if not enabled then
		return { action = "Skip", reason = "Disabled" }
	end
	if Rules.ENABLED_CATEGORIES.storage ~= true then
		return { action = "Skip", reason = "CategoryOff" }
	end
	if state.glowLossPending ~= true then
		return { action = "Skip", reason = "NothingPending" }
	end
	if capacity <= 0 or stored < capacity * share then
		return { action = "Hold", reason = "StorageNotFull" }
	end
	if not Rules.dailySlotFree(state, now) then
		return { action = "Hold", reason = "DailyCapSpent" }
	end
	return { action = "Send", category = "storage", reason = "StorageNearlyFull" }
end

-- Returns the new state. A sent notification spends the slot; a storage send also clears the
-- pending Glow loss. A failed or throttled send leaves state untouched (no retry storm: the
-- caller does not retry, the next qualifying event tries again).
function Rules.afterSend(state: State, category: Category, sent: boolean, now: number): State
	if not sent then
		return state
	end
	local nextState: State = {
		lastSentDay = Rules.dayOf(now),
		glowLossPending = state.glowLossPending,
		promptedAt = state.promptedAt,
		seenRaids = state.seenRaids,
	}
	if category == "storage" then
		nextState.glowLossPending = false
	end
	return nextState
end

function Rules.afterGlowLoss(state: State): State
	return {
		lastSentDay = state.lastSentDay,
		glowLossPending = true,
		promptedAt = state.promptedAt,
		seenRaids = state.seenRaids,
	}
end

-- Records a raidId in the bounded seen list. Returns (list, isNew); a raidId already in the list
-- returns isNew = false and the list unchanged. The oldest entries drop past MAX_SEEN_RAIDS.
function Rules.noteRaid(seen: { string }?, raidId: string): ({ string }, boolean)
	local list: { string } = {}
	if seen then
		for _, id in seen do
			if id == raidId then
				return seen, false
			end
			table.insert(list, id)
		end
	end
	table.insert(list, raidId)
	while #list > Rules.MAX_SEEN_RAIDS do
		table.remove(list, 1)
	end
	return list, true
end

-- Prompt only right after the player's first successful raid, at most once per 30 days.
function Rules.shouldPromptOptIn(state: State, successfulRaids: number, now: number, enabled: boolean): boolean
	if not enabled or successfulRaids ~= 1 then
		return false
	end
	local at = state.promptedAt
	return at == nil or now - at >= Rules.PROMPT_COOLDOWN_SECONDS
end

function Rules.afterPrompt(state: State, now: number): State
	return {
		lastSentDay = state.lastSentDay,
		glowLossPending = state.glowLossPending,
		promptedAt = now,
		seenRaids = state.seenRaids,
	}
end

-- Copy parameters: short, printable, no braces or angle brackets. Usernames and catalog names only.
function Rules.cleanParam(value: string?): string?
	if value == nil then
		return nil
	end
	local cleaned = string.gsub(value, "[%c{}<>]", "")
	cleaned = string.gsub(cleaned, "^%s+", "")
	cleaned = string.gsub(cleaned, "%s+$", "")
	if cleaned == "" then
		return nil
	end
	if #cleaned > Rules.MAX_PARAM_LENGTH then
		cleaned = string.sub(cleaned, 1, Rules.MAX_PARAM_LENGTH)
	end
	return cleaned
end

function Rules.validRaidId(raidId: string): boolean
	return #raidId > 0 and #raidId <= 43 and string.match(raidId, "^[%w%-_]+$") ~= nil
end

function Rules.launchData(raidId: string): string
	return Rules.LAUNCH_PREFIX .. raidId
end

-- The raidId carried by a join, or nil for any other launch data. Never trust it: the server
-- still checks the revenge token for that raid.
function Rules.parseLaunchData(data: any): string?
	if type(data) ~= "string" or #data > Rules.MAX_LAUNCH_DATA then
		return nil
	end
	if string.sub(data, 1, #Rules.LAUNCH_PREFIX) ~= Rules.LAUNCH_PREFIX then
		return nil
	end
	local raidId = string.sub(data, #Rules.LAUNCH_PREFIX + 1)
	if not Rules.validRaidId(raidId) then
		return nil
	end
	return raidId
end

return Rules

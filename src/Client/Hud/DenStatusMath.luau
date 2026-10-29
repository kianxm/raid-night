--!strict
--[[
	DenStatusMath (owner: ui agent): pure display logic for the live-protection marker and the
	post-loss countdown (D-031). Inputs are the den attributes `LiveProtected` and
	`LiveGrabReadyAt` plus `now` from workspace:GetServerTimeNow(). Display only: the server
	decides every grab. No Roblox services, so it is testable with Lune.
]]

local HudMath = require("./HudMath")
local Strings = require("./Strings")

local DenStatusMath = {}

-- Reason strings from RaidRules.Reason (stable names; kept literal so this stays pure).
DenStatusMath.REASON_LIVE_PROTECTED = "LiveProtected"
DenStatusMath.REASON_POST_LOSS_SAFETY = "PostLossSafety"

function DenStatusMath.isProtected(attr: any): boolean
	return attr == true
end

-- Seconds until grabs reopen, or nil when the attribute is absent, malformed or already past.
function DenStatusMath.secondsLeft(readyAt: any, now: number): number?
	if type(readyAt) ~= "number" or readyAt ~= readyAt then
		return nil
	end
	local left = readyAt - now
	if left > 0 then
		return left
	end
	return nil
end

-- Marker text for another player's den: "Protected", else "Safe for 0:42", else nil (hide).
function DenStatusMath.markerText(protected: any, readyAt: any, now: number): string?
	if DenStatusMath.isProtected(protected) then
		return Strings.protected
	end
	local left = DenStatusMath.secondsLeft(readyAt, now)
	if left then
		return Strings.format(Strings.safeFor, { time = HudMath.clock(left) })
	end
	return nil
end

-- Copy for the two new grab refusal reasons, or nil for any other reason (caller keeps its own).
function DenStatusMath.refusalText(reason: string, readyAt: any, now: number): string?
	if reason == DenStatusMath.REASON_LIVE_PROTECTED then
		return Strings.protected
	elseif reason == DenStatusMath.REASON_POST_LOSS_SAFETY then
		local left = DenStatusMath.secondsLeft(readyAt, now)
		if left then
			return Strings.format(Strings.safeFor, { time = HudMath.clock(left) })
		end
		return Strings.alreadyStealing
	end
	return nil
end

return DenStatusMath

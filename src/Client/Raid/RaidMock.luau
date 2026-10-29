--!strict
--[[
	RaidMock (owner: ui agent): fake server answers in the exact shapes from Net.luau / Types.luau,
	so the raid screens can be built and screenshotted with no server. RaidApi flips between this
	and the real remotes; the screens never know which.
]]

local RaidMock = {}

local HOUR = 3600
local DURATION = 180

local NAMES: { [number]: string } = {
	[101] = "NightOwl_Max",
	[102] = "SockThief99",
	[103] = "PixelPilfer",
	[104] = "MoonRaccoon",
	[105] = "Gloomgoblin",
}

function RaidMock.nameFor(userId: number): string
	return NAMES[userId] or "Raider"
end

-- Revenge target first, as the server will order them.
function RaidMock.getTargets(): { any }
	return {
		{ userId = 102, displayName = NAMES[102], power = 5400, isRevenge = true, revengeRaidId = "r3" },
		{ userId = 103, displayName = NAMES[103], power = 1800, isRevenge = false },
		{ userId = 104, displayName = NAMES[104], power = 420, isRevenge = false },
	}
end

-- Gate placement is not in RaidStart yet (handoff). The mock supplies one so the arrow works.
function RaidMock.startRaid(targetUserId: number, _revengeRaidId: string?): (any, Vector3)
	local now = workspace:GetServerTimeNow()
	return {
		raidId = "mock-raid-" .. tostring(targetUserId),
		targetUserId = targetUserId,
		endsAt = now + DURATION,
	},
		Vector3.new(0, 5, -80)
end

function RaidMock.getRaidLog(): { any }
	local now = workspace:GetServerTimeNow()
	return {
		{
			raidId = "r3",
			direction = "Incoming",
			otherUserId = 102,
			escaped = true,
			speciesId = "dusk_mouse",
			glow = 340,
			at = now - 2 * HOUR,
			isRevenge = false,
		},
		{
			raidId = "r2",
			direction = "Incoming",
			otherUserId = 105,
			escaped = false,
			speciesId = nil,
			glow = 0,
			at = now - 5 * HOUR,
			isRevenge = false,
		},
		{
			raidId = "r1",
			direction = "Outgoing",
			otherUserId = 103,
			escaped = true,
			speciesId = "blinkbug",
			glow = 120,
			at = now - 30 * HOUR,
			isRevenge = true,
		},
	}
end

function RaidMock.getReplay(_raidId: string): any?
	return nil -- the replay viewer is Phase 3
end

return RaidMock

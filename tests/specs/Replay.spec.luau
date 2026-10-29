--!strict
local expect = require("../lib/expect")
local rng = require("../lib/rng")
local source = require("../lib/source")
local Replay = require("../../src/Shared/Replay")

local ORIGIN = { x = 50000, y = 200, z = -50000 } -- a pocket den far off-map
local START = 1_800_000_000.25
local TOLERANCE = Replay.QUANTUM / 2 + 1e-9

-- A synthetic 3-minute raid: 900 raider positions at 5 Hz (walking at 16 studs/s with turns,
-- carrying slower, hiding still, jumping), plus grab, tag, trap and escape events.
local function syntheticRaid(seed: number): (Replay.Recorder, { { number } })
	local r = rng.new(seed)
	local rec = Replay.newRecorder(START, ORIGIN.x, ORIGIN.y, ORIGIN.z)
	local truth: { { number } } = {}
	local x, z, heading = 3.3, -60.7, 0
	local jumpLeft = 0
	for i = 0, 899 do
		local t = i / Replay.HZ
		local speed = if t < 40 then 16 elseif t < 60 then 0 else 16 * 0.6 -- walk, hide, carry
		if r.chance(0.1) then
			heading += (r.next() - 0.5) * 2
		end
		x += math.cos(heading) * speed / Replay.HZ
		z += math.sin(heading) * speed / Replay.HZ
		if jumpLeft == 0 and r.chance(0.03) then
			jumpLeft = 5
		end
		local y = 3 + (if jumpLeft > 0 then math.sin(jumpLeft / 5 * math.pi) * 7.2 else 0)
		jumpLeft = math.max(jumpLeft - 1, 0)
		local wx, wy, wz = ORIGIN.x + x, ORIGIN.y + y, ORIGIN.z + z
		-- server ticks jitter a little around each 0.2 s
		expect.truthy(Replay.recordFrame(rec, START + t + (r.next() - 0.5) * 0.08, wx, wy, wz), `frame {i}`)
		truth[i + 1] = { x, y, z }
	end
	expect.truthy(Replay.recordEvent(rec, START + 38.2, "Grab", "moon_moth"))
	expect.truthy(Replay.recordEvent(rec, START + 70, "Trap", "SlowPuddle"))
	expect.truthy(Replay.recordEvent(rec, START + 95.4, "Tag", "guard_2"))
	expect.truthy(Replay.recordEvent(rec, START + 96, "Drop"))
	expect.truthy(Replay.recordEvent(rec, START + 120, "Grab", "moon_moth"))
	expect.truthy(Replay.recordEvent(rec, START + 179.8, "Escape"))
	return rec, truth
end

local tests = {}

tests["a 3-minute raid (900 frames + events) encodes to under 3 KB and decodes within 0.25 studs"] = function()
	local rec, truth = syntheticRaid(7)
	local data = Replay.encode(rec)
	print(`        synthetic 3-minute raid: {rec.frames} frames, {#rec.events} events -> {#data} bytes`)
	expect.eq(rec.frames, 900)
	expect.truthy(#data < 3 * 1024, `encoded size {#data} bytes`)
	expect.truthy(string.find(data, "^[%w%-_~%.]+$") ~= nil, "printable, JSON-safe characters only")

	local decoded = assert(Replay.decode(data))
	expect.eq(decoded.version, 1)
	expect.eq(#decoded.frames, 900)
	for i, p in truth do
		local f = decoded.frames[i]
		expect.near(f.x, p[1], TOLERANCE, `frame {i} x`)
		expect.near(f.y, p[2], TOLERANCE, `frame {i} y`)
		expect.near(f.z, p[3], TOLERANCE, `frame {i} z`)
	end
	local expected = {
		{ 191, "Grab", "moon_moth" },
		{ 350, "Trap", "SlowPuddle" },
		{ 477, "Tag", "guard_2" },
		{ 480, "Drop", nil },
		{ 600, "Grab", "moon_moth" },
		{ 899, "Escape", nil },
	}
	expect.eq(#decoded.events, #expected)
	for i, e in expected do
		local got = decoded.events[i]
		expect.eq(got.frame, e[1], `event {i} frame`)
		expect.eq(got.kind, e[2], `event {i} kind`)
		expect.eq(got.arg, e[3], `event {i} arg`)
	end
end

tests["several seeds all stay under 3 KB"] = function()
	for seed = 1, 20 do
		local rec = syntheticRaid(seed)
		local size = #Replay.encode(rec)
		expect.truthy(size < 3 * 1024, `seed {seed}: {size} bytes`)
	end
end

tests["calls faster than 5 Hz keep one frame per tick; a missed tick is interpolated"] = function()
	local rec = Replay.newRecorder(100, 0, 0, 0)
	expect.truthy(Replay.recordFrame(rec, 100, 0, 0, 0))
	expect.falsy(Replay.recordFrame(rec, 100.05, 9, 9, 9), "same tick")
	expect.falsy(Replay.recordFrame(rec, 99, 9, 9, 9), "before the start")
	expect.truthy(Replay.recordFrame(rec, 100.6, 6, 0, 0)) -- ticks 1 and 2 were missed
	local decoded = assert(Replay.decode(Replay.encode(rec)))
	expect.eq(#decoded.frames, 4)
	expect.eq(decoded.frames[2].x, 2)
	expect.eq(decoded.frames[3].x, 4)
	expect.eq(decoded.frames[4].x, 6)
end

tests["frames and events are bounded, and bad input is refused"] = function()
	local rec = Replay.newRecorder(0, 0, 0, 0)
	expect.truthy(Replay.recordFrame(rec, (Replay.MAX_FRAMES - 1) / Replay.HZ, 1, 1, 1))
	expect.falsy(Replay.recordFrame(rec, Replay.MAX_FRAMES / Replay.HZ, 1, 1, 1), "past MAX_FRAMES")
	expect.eq(rec.frames, Replay.MAX_FRAMES)
	expect.falsy(Replay.recordFrame(rec, 1, 0 / 0, 0, 0), "NaN")
	expect.falsy(Replay.recordEvent(rec, 1, "Teleport" :: any), "unknown kind")
	expect.falsy(Replay.recordEvent(rec, 1, "Grab", "bad.arg"), "arg outside [%w_]")
	expect.falsy(Replay.recordEvent(rec, 1, "Grab", string.rep("a", Replay.MAX_ARG_LENGTH + 1)), "long arg")
	expect.truthy(Replay.recordEvent(rec, 1e6, "Escape"))
	expect.eq(rec.events[1].frame, Replay.MAX_FRAMES - 1, "events clamp into the recording")
	for i = 2, Replay.MAX_EVENTS do
		expect.truthy(Replay.recordEvent(rec, i, "Trap"), `event {i}`)
	end
	expect.eq(rec.events[2].frame, Replay.MAX_FRAMES - 1, "never before the previous event")
	expect.falsy(Replay.recordEvent(rec, 1, "Trap"), "event list full")
	expect.truthy(Replay.decode(Replay.encode(rec)), "a full recording still decodes")
end

tests["far positions clamp instead of growing without bound"] = function()
	local rec = Replay.newRecorder(0, 0, 0, 0)
	Replay.recordFrame(rec, 0, 1e12, -1e12, 0)
	local decoded = assert(Replay.decode(Replay.encode(rec)))
	expect.eq(decoded.frames[1].x, 8192)
	expect.eq(decoded.frames[1].y, -8192)
end

tests["decode refuses malformed data without erroring"] = function()
	local good = Replay.encode((syntheticRaid(3)))
	local cases: { any } = {
		42,
		"",
		"R2." .. string.sub(good, 4),
		"R1.",
		"R1.A", -- a frame missing its z
		"R1.~A.", -- a still run of 0
		"R1.AA.G", -- event with no varints
		"R1.AA.GAE", -- arg longer than the data
		"R1.AA.ZAA", -- unknown event kind
		"R1.AA.GAB.", -- '.' inside an arg
		"R1.zzzzzzzzAA.", -- varint too long
		string.rep("A", Replay.MAX_DATA_LENGTH + 1),
		string.sub(good, 1, #good - 3),
	}
	for i, case in cases do
		local ok, decoded = pcall(Replay.decode, case)
		expect.truthy(ok, `case {i} errored`)
		expect.falsy(decoded, `case {i} decoded`)
	end
	expect.truthy(Replay.decode("R1.."), "an empty replay is valid")
end

tests["raidIds: GUIDs pass, anything else is refused"] = function()
	expect.truthy(Replay.isRaidId("2F0C7C2E-8D3B-4E1A-9C2B-0D1E2F3A4B5C"))
	expect.falsy(Replay.isRaidId(""))
	expect.falsy(Replay.isRaidId(12))
	expect.falsy(Replay.isRaidId("a/b"))
	expect.falsy(Replay.isRaidId(string.rep("a", 44)))
end

tests["the raider index drops expired, malformed and overflow entries, never the new one"] = function()
	local now = 2_000_000
	local index: { [any]: any } = {
		old = now - Replay.LIFETIME_SECONDS,
		fresh = now - 10,
		bad = "x",
		["no/good"] = now,
	}
	local kept, dropped = Replay.indexAfterSave(index, "new", now)
	expect.eq(kept.new, now)
	expect.eq(kept.fresh, now - 10)
	expect.eq(kept.old, nil)
	expect.eq(table.concat(dropped, ","), "bad,old")

	local full: { [string]: number } = {}
	for i = 1, Replay.MAX_INDEX_ENTRIES do
		full[`r{i}`] = now - 1000 + i
	end
	local kept2, dropped2 = Replay.indexAfterSave(full, "latest", now)
	expect.eq(table.concat(dropped2, ","), "r1")
	local count = 0
	for _ in kept2 do
		count += 1
	end
	expect.eq(count, Replay.MAX_INDEX_ENTRIES)
	expect.eq(kept2.latest, now)
	local _, none = Replay.indexAfterSave(nil, "first", now)
	expect.eq(#none, 0)
end

tests["expiry is 7 days after saving"] = function()
	expect.falsy(Replay.isExpired(1000, 1000 + Replay.LIFETIME_SECONDS - 1))
	expect.truthy(Replay.isExpired(1000, 1000 + Replay.LIFETIME_SECONDS))
	expect.truthy(Replay.isExpired(nil, 0))
end

tests["ReplayStore: pcall around every store call, no profile access, both parties checked"] = function()
	local code = source.codeOnly(source.read("src/Server/Raid/ReplayStore.luau"))
	local calls = 0
	for call in string.gmatch(code, "store:(%a+Async)%(") do
		calls += 1
		expect.truthy(call ~= "IncrementAsync", "no increments")
	end
	expect.eq(calls, 4, "UpdateAsync, SetAsync, GetAsync, RemoveAsync")
	local wrapped = 0
	for _ in string.gmatch(code, "pcall%(function%(%)[^\n]*\n%s*[%w_ ,=]*%(?store:%a+Async%(") do
		wrapped += 1
	end
	expect.eq(wrapped, calls, "every store call is the first line of a pcall'd function")
	for use in string.gmatch(code, "DataService%.(%a+)") do
		expect.eq(use, "persistence", "DataService is only asked where data lives")
	end
	expect.falsy(string.find(code, "GetAttribute", 1, true), "no attribute reads")
	local fetch = assert(source.functionBody(code, "ReplayStore.fetch"))
	expect.truthy(
		string.find(fetch, "userId ~= record.raiderUserId and userId ~= record.defenderUserId", 1, true),
		"fetch refuses anyone but the raider and the defender"
	)
	local handler = assert(source.functionBody(code, "onGetReplay"))
	expect.truthy(string.find(handler, "ReplayStore.fetch, player.UserId, raidId", 1, true), "the caller is the player")
end

tests["AsyncRaid's 10 Hz tick with jitter and a lag spike records 5 Hz, under 3 KB for 3 minutes"] = function()
	local r = rng.new(7)
	local rec = Replay.newRecorder(START, ORIGIN.x, ORIGIN.y, ORIGIN.z)
	local t, x, z = START, 0, 20
	local written = 0
	while t < START + 180 do
		t += 0.1 + (r.next() - 0.5) * 0.04 -- Heartbeat-driven: about 10 Hz, never exact
		if math.abs(t - (START + 90)) < 0.05 then
			t += 1.3 -- one lag spike: the missed frames are interpolated
		end
		x = math.clamp(x + (r.next() - 0.5) * 3, -36, 36)
		z = math.clamp(z + (r.next() - 0.5) * 3, -36, 36)
		if Replay.recordFrame(rec, t, ORIGIN.x + x, ORIGIN.y + 3, ORIGIN.z + z) then
			written += 1
		end
	end
	for i, kind in { "Grab", "Trap", "Drop", "Grab", "Escape" } :: { Replay.EventKind } do
		expect.truthy(Replay.recordEvent(rec, START + i * 30, kind, if kind == "Grab" then "crescent_fox" else nil))
	end
	expect.truthy(written < 1000, "about half the ticks write a frame")
	expect.truthy(rec.frames >= 899 and rec.frames <= 901, `one frame per 0.2 s, got {rec.frames}`)
	local data = Replay.encode(rec)
	expect.truthy(#data < 3 * 1024, `{#data} bytes`)
	local decoded = assert(Replay.decode(data))
	expect.eq(#decoded.frames, rec.frames)
	expect.eq(#decoded.events, 5)
end

return tests

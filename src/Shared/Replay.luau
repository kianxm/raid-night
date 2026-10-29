--!strict
--[[
	Replay (owner: raid agent): the raid replay recorder and codec. Pure: no Roblox services, no
	clock. The caller passes `now` (unix seconds, fractions allowed) and world positions in.

	Recording (RaidService, P1.4b):
	  local rec = Replay.newRecorder(startedAt, origin.X, origin.Y, origin.Z) -- pocket den origin
	  Replay.recordFrame(rec, now, pos.X, pos.Y, pos.Z) -- call at 5 Hz or faster; extras are ignored
	  Replay.recordEvent(rec, now, "Grab", speciesId)
	  local data = Replay.encode(rec)                   -- a short printable string, a few KB at most

	Format version 1, "R1.<frames>.<events>" (full description: docs/contracts.md, Replays). One
	raider track at HZ frames a second, positions relative to the pocket den origin quantized to
	QUANTUM studs (decoded within QUANTUM / 2, no drift), as zigzag varints in URL-safe base64
	(5 data bits a character, bit 6 = more follows). A frame is varint(zigzag(dx) * 2 + yFlag),
	varint(zigzag(dz)), and varint(zigzag(dy)) only if yFlag; "~" + varint(n) is n still frames.
	An event is a kind character, varint(frames since the previous event), varint(#arg), arg.
	Missed ticks are interpolated, so frame i is always startedAt + i / HZ. Bounded by
	MAX_FRAMES and MAX_EVENTS.

	Lifetime (ReplayStore): a replay is served for LIFETIME_SECONDS after it is saved. Each
	raider's index (indexAfterSave) lists their saved replays; every new save drops expired and
	overflow entries, which ReplayStore then deletes.
]]

local Config = require("./Config")

export type EventKind = "Grab" | "Drop" | "Tag" | "Trap" | "Escape" | "Timeout"
export type Event = { frame: number, kind: EventKind, arg: string? }
export type Frame = { x: number, y: number, z: number } -- studs from the pocket den origin
export type Decoded = { version: number, hz: number, quantum: number, frames: { Frame }, events: { Event } }
export type Recorder = {
	startedAt: number,
	originX: number,
	originY: number,
	originZ: number,
	coords: { number }, -- quantized x, y, z of each frame, flat
	frames: number,
	events: { Event },
}
export type ReplayIndex = { [string]: number } -- raidId -> savedAt (unix seconds)

local Replay = {}

Replay.VERSION = 1
Replay.HZ = 5
Replay.QUANTUM = 0.5
Replay.MAX_FRAMES = (Config.Raid.durationSeconds + 20) * Replay.HZ
Replay.MAX_EVENTS = 64
Replay.MAX_ARG_LENGTH = 32
Replay.MAX_DATA_LENGTH = 32 * 1024 -- decode refuses anything longer
Replay.LIFETIME_SECONDS = 7 * 86400
Replay.MAX_INDEX_ENTRIES = 64 -- per raider; the oldest go first

local MAX_COORD = 8192 -- studs from the origin; anything further is clamped
local PREFIX = `R{Replay.VERSION}.`
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local STILL = "~"
local MAX_VARINT_CHARS = 6 -- 30 bits

local EVENT_CODES: { [EventKind]: string } = {
	Grab = "G",
	Drop = "D",
	Tag = "T",
	Trap = "P",
	Escape = "E",
	Timeout = "X",
}
local EVENT_KINDS: { [string]: EventKind } = {}
for kind, code in EVENT_CODES do
	EVENT_KINDS[code] = kind
end

local CHAR: { [number]: string } = {}
local VALUE: { [string]: number } = {}
for i = 1, #ALPHABET do
	local c = string.sub(ALPHABET, i, i)
	CHAR[i - 1] = c
	VALUE[c] = i - 1
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function quantize(v: number): number
	return math.floor(math.clamp(v, -MAX_COORD, MAX_COORD) / Replay.QUANTUM + 0.5)
end

local function frameAt(rec: Recorder, now: number): number
	return math.floor((now - rec.startedAt) * Replay.HZ + 0.5)
end

local function validArg(arg: any): boolean
	return arg == nil
		or (type(arg) == "string" and #arg <= Replay.MAX_ARG_LENGTH and string.find(arg, "^[%w_]*$") ~= nil)
end

-- A raidId as the server makes them (a GUID) and as DataStore keys allow: [%w_-], at most
-- Config.Escrow.maxRaidIdLength characters. Anything a client sends goes through this first.
function Replay.isRaidId(value: any): boolean
	return type(value) == "string"
		and #value > 0
		and #value <= Config.Escrow.maxRaidIdLength
		and string.find(value, "^[%w_%-]+$") ~= nil
end

function Replay.newRecorder(startedAt: number, originX: number, originY: number, originZ: number): Recorder
	assert(finite(startedAt) and finite(originX) and finite(originY) and finite(originZ), "bad recorder start")
	return {
		startedAt = startedAt,
		originX = originX,
		originY = originY,
		originZ = originZ,
		coords = {},
		frames = 0,
		events = {},
	}
end

-- Records the raider's world position at `now`. Returns true if a frame was written: false for a
-- frame already recorded (calls faster than HZ), before the start, past MAX_FRAMES, or a
-- non-finite input.
function Replay.recordFrame(rec: Recorder, now: number, x: number, y: number, z: number): boolean
	if not (finite(now) and finite(x) and finite(y) and finite(z)) then
		return false
	end
	local k = frameAt(rec, now)
	if k < rec.frames or k >= Replay.MAX_FRAMES then
		return false
	end
	local qx, qy, qz = quantize(x - rec.originX), quantize(y - rec.originY), quantize(z - rec.originZ)
	local coords = rec.coords
	local px, py, pz = qx, qy, qz
	if rec.frames > 0 then
		local base = (rec.frames - 1) * 3
		px, py, pz = coords[base + 1], coords[base + 2], coords[base + 3]
	end
	local steps = k - rec.frames + 1
	for i = 1, steps - 1 do -- missed ticks: interpolate from the last frame
		local t = i / steps
		table.insert(coords, math.floor(px + (qx - px) * t + 0.5))
		table.insert(coords, math.floor(py + (qy - py) * t + 0.5))
		table.insert(coords, math.floor(pz + (qz - pz) * t + 0.5))
	end
	table.insert(coords, qx)
	table.insert(coords, qy)
	table.insert(coords, qz)
	rec.frames = k + 1
	return true
end

-- Records an event at `now` (clamped into the recording, never before the previous event).
-- Returns false for an unknown kind, a bad arg, a full event list or a non-finite `now`.
function Replay.recordEvent(rec: Recorder, now: number, kind: EventKind, arg: string?): boolean
	if not finite(now) or EVENT_CODES[kind] == nil or not validArg(arg) or #rec.events >= Replay.MAX_EVENTS then
		return false
	end
	local frame = math.clamp(frameAt(rec, now), 0, Replay.MAX_FRAMES - 1)
	local last = rec.events[#rec.events]
	if last and frame < last.frame then
		frame = last.frame
	end
	table.insert(rec.events, { frame = frame, kind = kind, arg = arg })
	return true
end

local function writeVarint(out: { string }, n: number)
	repeat
		local group = n % 32
		n = (n - group) // 32
		table.insert(out, CHAR[if n > 0 then group + 32 else group])
	until n == 0
end

local function zigzag(v: number): number
	return if v >= 0 then v * 2 else -v * 2 - 1
end

local function unzigzag(u: number): number
	return if u % 2 == 0 then u // 2 else -(u + 1) // 2
end

function Replay.encode(rec: Recorder): string
	local out: { string } = { PREFIX }
	local coords = rec.coords
	local px, py, pz = 0, 0, 0
	local still = 0
	for i = 0, rec.frames - 1 do
		local x, y, z = coords[i * 3 + 1], coords[i * 3 + 2], coords[i * 3 + 3]
		local dx, dy, dz = x - px, y - py, z - pz
		px, py, pz = x, y, z
		if dx == 0 and dy == 0 and dz == 0 then
			still += 1
			continue
		end
		if still > 0 then
			table.insert(out, STILL)
			writeVarint(out, still)
			still = 0
		end
		writeVarint(out, zigzag(dx) * 2 + (if dy ~= 0 then 1 else 0))
		writeVarint(out, zigzag(dz))
		if dy ~= 0 then
			writeVarint(out, zigzag(dy))
		end
	end
	if still > 0 then
		table.insert(out, STILL)
		writeVarint(out, still)
	end
	table.insert(out, ".")
	local previous = 0
	for _, event in rec.events do
		local arg = event.arg or ""
		table.insert(out, EVENT_CODES[event.kind])
		writeVarint(out, event.frame - previous)
		writeVarint(out, #arg)
		table.insert(out, arg)
		previous = event.frame
	end
	return table.concat(out)
end

type Reader = { s: string, pos: number, stop: number }

local function readVarint(r: Reader): number?
	local n, scale = 0, 1
	for _ = 1, MAX_VARINT_CHARS do
		if r.pos > r.stop then
			return nil
		end
		local v = VALUE[string.sub(r.s, r.pos, r.pos)]
		if v == nil then
			return nil
		end
		r.pos += 1
		n += (v % 32) * scale
		if v < 32 then
			return n
		end
		scale *= 32
	end
	return nil
end

local function decodeFrames(r: Reader): { Frame }?
	local frames: { Frame } = {}
	local q = Replay.QUANTUM
	local x, y, z = 0, 0, 0
	while r.pos <= r.stop do
		if string.sub(r.s, r.pos, r.pos) == STILL then
			r.pos += 1
			local n = readVarint(r)
			if n == nil or n < 1 or #frames + n > Replay.MAX_FRAMES then
				return nil
			end
			for _ = 1, n do
				table.insert(frames, { x = x * q, y = y * q, z = z * q })
			end
		else
			local first = readVarint(r)
			local dz = readVarint(r)
			if first == nil or dz == nil then
				return nil
			end
			local dy = 0
			if first % 2 == 1 then
				local u = readVarint(r)
				if u == nil then
					return nil
				end
				dy = unzigzag(u)
			end
			x += unzigzag(first // 2)
			y += dy
			z += unzigzag(dz)
			if #frames >= Replay.MAX_FRAMES then
				return nil
			end
			table.insert(frames, { x = x * q, y = y * q, z = z * q })
		end
	end
	return frames
end

local function decodeEvents(r: Reader): { Event }?
	local events: { Event } = {}
	local frame = 0
	while r.pos <= r.stop do
		local kind = EVENT_KINDS[string.sub(r.s, r.pos, r.pos)]
		r.pos += 1
		local delta = readVarint(r)
		local length = readVarint(r)
		if kind == nil or delta == nil or length == nil or #events >= Replay.MAX_EVENTS then
			return nil
		end
		frame += delta
		local arg = string.sub(r.s, r.pos, r.pos + length - 1)
		r.pos += length
		if frame >= Replay.MAX_FRAMES or #arg ~= length or r.pos > r.stop + 1 or not validArg(arg) then
			return nil
		end
		table.insert(events, { frame = frame, kind = kind, arg = if length > 0 then arg else nil })
	end
	return events
end

-- Decodes Replay.encode output. Returns nil and a reason for anything malformed, too long, or of
-- an unknown version; never errors, so it is safe on data from a store or the network.
function Replay.decode(data: any): (Decoded?, string?)
	if type(data) ~= "string" or #data > Replay.MAX_DATA_LENGTH then
		return nil, "BadData"
	end
	if string.sub(data, 1, #PREFIX) ~= PREFIX then
		return nil, "UnknownVersion"
	end
	local split = string.find(data, ".", #PREFIX + 1, true)
	if split == nil then
		return nil, "BadData"
	end
	local frames = decodeFrames({ s = data, pos = #PREFIX + 1, stop = split - 1 })
	local events = decodeEvents({ s = data, pos = split + 1, stop = #data })
	if frames == nil or events == nil then
		return nil, "BadData"
	end
	return { version = Replay.VERSION, hz = Replay.HZ, quantum = Replay.QUANTUM, frames = frames, events = events }, nil
end

function Replay.isExpired(savedAt: any, now: number): boolean
	return not finite(savedAt) or now >= savedAt + Replay.LIFETIME_SECONDS
end

-- A raider's index after saving raidId at `now`: expired entries, malformed ones and the oldest
-- past MAX_INDEX_ENTRIES are dropped (the new raidId always stays). Returns the new index and the
-- dropped raidIds (sorted), whose replays the caller deletes.
function Replay.indexAfterSave(index: any, raidId: string, now: number): (ReplayIndex, { string })
	local kept: ReplayIndex = {}
	local dropped: { string } = {}
	local live: { string } = {}
	if type(index) == "table" then
		for id, savedAt in index do
			if id == raidId or not Replay.isRaidId(id) then
				continue
			elseif Replay.isExpired(savedAt, now) then
				table.insert(dropped, id)
			else
				kept[id] = savedAt
				table.insert(live, id)
			end
		end
	end
	table.sort(live, function(a: string, b: string): boolean
		if kept[a] ~= kept[b] then
			return kept[a] < kept[b]
		end
		return a < b
	end)
	for i = 1, #live - (Replay.MAX_INDEX_ENTRIES - 1) do
		kept[live[i]] = nil
		table.insert(dropped, live[i])
	end
	kept[raidId] = now
	table.sort(dropped)
	return kept, dropped
end

return Replay

--!strict
local expect = require("../lib/expect")
local Plots = require("../../src/Shared/Plots")

local L = Plots.Layout

local function fullServer()
	local state = Plots.new()
	for userId = 1, 8 do
		Plots.assign(state, userId)
	end
	return state
end

local tests = {}

tests["8 joins get 8 different plots"] = function()
	local state = Plots.new()
	local seen = {}
	for userId = 1, 8 do
		local plot = Plots.assign(state, userId)
		expect.truthy(plot, `user {userId} got no plot`)
		expect.falsy(seen[plot :: number], `plot {plot} given twice`)
		seen[plot :: number] = true
		expect.eq(Plots.plotOf(state, userId), plot)
		expect.eq(Plots.ownerOf(state, plot :: number), userId)
	end
	expect.eq(Plots.freeCount(state), 0)
end

tests["assign is idempotent"] = function()
	local state = Plots.new()
	expect.eq(Plots.assign(state, 7), 1)
	expect.eq(Plots.assign(state, 7), 1)
	expect.eq(Plots.freeCount(state), 7)
end

tests["the 9th join waits and gets no plot"] = function()
	local state = fullServer()
	expect.eq(Plots.assign(state, 9), nil)
	expect.eq(Plots.assign(state, 9), nil)
	expect.eq(#state.waiting, 1, "queued once")
	expect.eq(Plots.plotOf(state, 9), nil)
end

tests["leave frees the plot and a new join reuses it"] = function()
	local state = fullServer()
	local plot = Plots.plotOf(state, 3)
	local freed, promoted = Plots.release(state, 3)
	expect.eq(freed, plot)
	expect.eq(promoted, nil)
	expect.eq(Plots.ownerOf(state, plot :: number), nil)
	expect.eq(Plots.freeCount(state), 1)
	expect.eq(Plots.assign(state, 20), plot, "newcomer takes the freed plot")
end

tests["rejoin after leaving gets the lowest free plot"] = function()
	local state = fullServer()
	Plots.release(state, 6)
	Plots.release(state, 2)
	expect.eq(Plots.assign(state, 6), 2, "lowest free plot first")
	expect.eq(Plots.assign(state, 2), 6)
end

tests["a freed plot goes to the first waiting player"] = function()
	local state = fullServer()
	Plots.assign(state, 9)
	Plots.assign(state, 10)
	local freed, promoted = Plots.release(state, 5)
	expect.eq(freed, 5)
	expect.eq(promoted, 9)
	expect.eq(Plots.plotOf(state, 9), 5)
	expect.eq(Plots.isWaiting(state, 9), false)
	expect.eq(Plots.isWaiting(state, 10), true)
end

tests["a waiting player who leaves is dropped from the queue"] = function()
	local state = fullServer()
	Plots.assign(state, 9)
	Plots.assign(state, 10)
	expect.eq(Plots.release(state, 9), nil)
	local _, promoted = Plots.release(state, 1)
	expect.eq(promoted, 10)
end

tests["release is idempotent"] = function()
	local state = fullServer()
	expect.eq(Plots.release(state, 4), 4)
	expect.eq(Plots.release(state, 4), nil)
	expect.eq(Plots.release(state, 999), nil, "unknown user")
	expect.eq(Plots.freeCount(state), 1)
end

tests["plots do not overlap and the plaza is clear"] = function()
	for a = 1, L.plotCount do
		local ax, az = Plots.center(a)
		-- distance from the plaza centre to the nearest point of the plot
		local dx = math.max(math.abs(ax) - L.plotSize / 2, 0)
		local dz = math.max(math.abs(az) - L.plotSize / 2, 0)
		expect.truthy(math.sqrt(dx * dx + dz * dz) > L.plazaRadius, `plaza touches plot {a}`)
		for b = a + 1, L.plotCount do
			local bx, bz = Plots.center(b)
			local apart = math.abs(ax - bx) >= L.plotSize or math.abs(az - bz) >= L.plotSize
			expect.truthy(apart, `plots {a} and {b} overlap`)
		end
	end
	expect.eq(Plots.plotAt(0, 0), nil, "plaza belongs to no den")
end

tests["pads, spawn and sign sit inside their own den"] = function()
	local half = L.plotSize / 2
	for plot = 1, L.plotCount do
		for pad = 1, L.maxPads do
			local lx, lz = Plots.padLocal(pad)
			expect.truthy(math.abs(lx) + L.padSize / 2 <= half, `pad {pad} sticks out in x`)
			expect.truthy(math.abs(lz) + L.padSize / 2 <= half, `pad {pad} sticks out in z`)
			local x, z = Plots.padPosition(plot, pad)
			expect.eq(Plots.plotAt(x, z), plot, `pad {pad} of plot {plot}`)
			-- spawn must not be on a pad
			expect.truthy(math.abs(lz - L.spawnZ) > L.padSize / 2, `spawn overlaps pad {pad}`)
		end
		local sx, sz = Plots.spawnPosition(plot)
		expect.eq(Plots.plotAt(sx, sz), plot, `spawn of plot {plot}`)
		expect.truthy(math.abs(L.signZ) <= half, "sign inside den")
	end
end

tests["30 pads: front row first, no two overlap, all clear of the economy station"] = function()
	expect.eq(L.maxPads, 30)
	local _, frontZ = Plots.padLocal(1)
	for pad = 1, L.maxPads do
		local x, z = Plots.padLocal(pad)
		-- The station (IncomeService) stands at local x = +/-20, at least 2 studs wide each side.
		expect.truthy(math.abs(x) + L.padSize / 2 < L.padKeepOutX, `pad {pad} reaches the station`)
		expect.truthy(L.padKeepOutX <= 18, "keep-out covers the station's inner edge (x = 18)")
		if pad <= L.padColumns then
			expect.eq(z, frontZ, `pad {pad} is in the front row`)
		end
		for other = pad + 1, L.maxPads do
			local ox, oz = Plots.padLocal(other)
			local apart = math.abs(x - ox) >= L.padSize or math.abs(z - oz) >= L.padSize
			expect.truthy(apart, `pads {pad} and {other} overlap`)
		end
	end
end

tests["pads fill rows of padColumns from the street side back"] = function()
	local x1, z1 = Plots.padLocal(1)
	local x6, z6 = Plots.padLocal(6)
	local x7, z7 = Plots.padLocal(7)
	expect.eq(z1, z6)
	expect.truthy(x6 > x1, "left to right")
	expect.eq(x7, x1, "row 2 starts under pad 1")
	expect.eq(z7, z1 - L.padPitchZ, "row 2 is one pitch further back")
	local _, z30 = Plots.padLocal(30)
	expect.eq(z30, z1 - 4 * L.padPitchZ, "5 rows")
end

tests["den props stand off the pads and inside the den"] = function()
	local half = L.plotSize / 2
	local props = { { L.vaultX, L.vaultZ, 6.4 }, { L.lanternX, L.lanternZ, 1.6 }, { 0, L.signZ, 16 } }
	for i, prop in props do
		local px, pz, width = prop[1], prop[2], prop[3]
		expect.truthy(math.abs(px) + width / 2 <= half and math.abs(pz) + 1 <= half, `prop {i} inside`)
		for pad = 1, L.maxPads do
			local x, z = Plots.padLocal(pad)
			local apart = math.abs(x - px) >= (L.padSize + width) / 2 or math.abs(z - pz) >= L.padSize / 2 + 1
			expect.truthy(apart, `prop {i} sits on pad {pad}`)
		end
	end
end

tests["dens face the street on both rows"] = function()
	for plot = 1, L.plotCount do
		local _, cz = Plots.center(plot)
		local _, frontZ = Plots.toWorld(plot, 0, L.plotSize / 2)
		expect.truthy(math.abs(frontZ) < math.abs(cz), `plot {plot} faces away from the street`)
	end
end

tests["isInside counts the border line as inside"] = function()
	local cx, cz = Plots.center(1)
	local half = L.plotSize / 2
	expect.truthy(Plots.isInside(1, cx + half, cz - half), "corner")
	expect.falsy(Plots.isInside(1, cx + half + 0.01, cz), "just outside")
end

tests["invalid plot and pad numbers throw"] = function()
	expect.throws(function()
		Plots.center(0)
	end)
	expect.throws(function()
		Plots.center(9)
	end)
	expect.throws(function()
		Plots.padLocal(31)
	end)
end

tests["pushOutside moves a visitor out through the nearest edge, onto open ground"] = function()
	local half = L.plotSize / 2
	for plot = 1, L.plotCount do
		local cx, cz = Plots.center(plot)
		local cases = {
			{ cx + half - 1, cz, cx + half + 4, cz },
			{ cx - half + 1, cz + 3, cx - half - 4, cz + 3 },
			{ cx + 2, cz + half - 1, cx + 2, cz + half + 4 },
			{ cx - 5, cz - half + 2, cx - 5, cz - half - 4 },
		}
		for i, c in cases do
			local x, z = Plots.pushOutside(plot, c[1], c[2], 4)
			expect.eq(x, c[3], `plot {plot} case {i} x`)
			expect.eq(z, c[4], `plot {plot} case {i} z`)
			expect.eq(Plots.plotAt(x, z), nil, `plot {plot} case {i} lands in another den`)
		end
	end
end

tests["pushOutside leaves someone already outside where they are"] = function()
	local cx, cz = Plots.center(2)
	local x, z = Plots.pushOutside(2, cx, cz + L.plotSize, 4)
	expect.eq(x, cx)
	expect.eq(z, cz + L.plotSize)
end

return tests

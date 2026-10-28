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
		for pad = 1, L.padsPerPlot do
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
		Plots.padLocal(7)
	end)
end

return tests

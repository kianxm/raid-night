--!strict
--[[
	Plots (owner: raid agent): pure den-plot assignment and greybox layout math.

	Assignment: each player gets the lowest free plot. When the server is full, later joiners
	wait in join order and get the next plot that frees up. Everything is keyed by userId, so
	the server's DenWorldService just forwards PlayerAdded / PlayerRemoving here.

	Layout: two rows of dens on either side of a street, with a round plaza at the origin.
	Coordinates are studs on the ground plane (x, z). Each den has a local frame where local +z
	points at the street ("front"), so pads, spawn and sign mirror correctly on both rows.
	These numbers are world-building constants, not tuning values, so they live here rather
	than in Config.luau.
]]

local Plots = {}

Plots.Layout = table.freeze({
	plotCount = 8,
	padsPerPlot = 6,
	plotSize = 56, -- square den footprint
	plotSpacing = 68, -- centre to centre along a row (12 stud gap between dens)
	rowOffset = 64, -- each row's centre line sits this far from the plaza centre
	plazaRadius = 24,
	padSize = 8,
	padSpacing = 12,
	padFrontZ = 8, -- local z of the front pad row
	spawnZ = -18, -- local z of the spawn point, behind the pads
	signZ = -26, -- local z of the owner sign, at the back of the den
})

local L = Plots.Layout
local PER_ROW = L.plotCount // 2

export type State = {
	plotCount: number,
	ownerOf: { [number]: number }, -- plot -> userId
	plotOf: { [number]: number }, -- userId -> plot
	waiting: { number }, -- userIds without a plot, in join order
}

function Plots.new(plotCount: number?): State
	return {
		plotCount = plotCount or L.plotCount,
		ownerOf = {},
		plotOf = {},
		waiting = {},
	}
end

function Plots.plotOf(state: State, userId: number): number?
	return state.plotOf[userId]
end

function Plots.ownerOf(state: State, plot: number): number?
	return state.ownerOf[plot]
end

function Plots.freeCount(state: State): number
	local used = 0
	for _ in state.ownerOf do
		used += 1
	end
	return state.plotCount - used
end

function Plots.isWaiting(state: State, userId: number): boolean
	return table.find(state.waiting, userId) ~= nil
end

-- Gives `userId` a plot and returns it. Idempotent: a player who already has a plot keeps it.
-- Returns nil when the server is full; the player is queued for the next freed plot.
function Plots.assign(state: State, userId: number): number?
	local existing = state.plotOf[userId]
	if existing then
		return existing
	end
	for plot = 1, state.plotCount do
		if state.ownerOf[plot] == nil then
			state.ownerOf[plot] = userId
			state.plotOf[userId] = plot
			return plot
		end
	end
	if not Plots.isWaiting(state, userId) then
		table.insert(state.waiting, userId)
	end
	return nil
end

-- Frees `userId`'s plot (or drops them from the queue). Idempotent.
-- Returns the freed plot, and the waiting userId that was moved into it, if any.
function Plots.release(state: State, userId: number): (number?, number?)
	local queued = table.find(state.waiting, userId)
	if queued then
		table.remove(state.waiting, queued)
	end
	local plot = state.plotOf[userId]
	if plot == nil then
		return nil, nil
	end
	state.plotOf[userId] = nil
	state.ownerOf[plot] = nil
	local promoted = table.remove(state.waiting, 1)
	if promoted ~= nil then
		state.ownerOf[plot] = promoted
		state.plotOf[promoted] = plot
	end
	return plot, promoted
end

local function checkPlot(plot: number)
	assert(plot >= 1 and plot <= L.plotCount and plot % 1 == 0, `invalid plot {plot}`)
end

-- Centre of a plot, and which way its front faces along z (+1 or -1).
function Plots.center(plot: number): (number, number, number)
	checkPlot(plot)
	local col = (plot - 1) % PER_ROW
	local rowSign = if plot <= PER_ROW then -1 else 1
	local x = (col - (PER_ROW - 1) / 2) * L.plotSpacing
	return x, rowSign * L.rowOffset, -rowSign
end

-- Converts a den-local position to world x, z.
function Plots.toWorld(plot: number, localX: number, localZ: number): (number, number)
	local cx, cz, facing = Plots.center(plot)
	return cx + facing * localX, cz + facing * localZ
end

-- Den-local position of pad 1..6. Pads 1-3 are the front row, 4-6 the back row.
function Plots.padLocal(pad: number): (number, number)
	assert(pad >= 1 and pad <= L.padsPerPlot and pad % 1 == 0, `invalid pad {pad}`)
	local col = (pad - 1) % 3
	local row = (pad - 1) // 3
	return (col - 1) * L.padSpacing, L.padFrontZ - row * L.padSpacing
end

function Plots.padPosition(plot: number, pad: number): (number, number)
	local lx, lz = Plots.padLocal(pad)
	return Plots.toWorld(plot, lx, lz)
end

function Plots.spawnPosition(plot: number): (number, number)
	return Plots.toWorld(plot, 0, L.spawnZ)
end

-- Is (x, z) on the plot's footprint? The border line counts as inside.
function Plots.isInside(plot: number, x: number, z: number): boolean
	local cx, cz = Plots.center(plot)
	local half = L.plotSize / 2
	return math.abs(x - cx) <= half and math.abs(z - cz) <= half
end

-- Where to put someone at (x, z) so they stand `margin` studs outside the plot, moved straight
-- out through the nearest edge (Lockdown push-back). A point already outside is returned as is.
function Plots.pushOutside(plot: number, x: number, z: number, margin: number): (number, number)
	if not Plots.isInside(plot, x, z) then
		return x, z
	end
	local cx, cz = Plots.center(plot)
	local half = L.plotSize / 2
	local dx, dz = x - cx, z - cz
	local out = half + margin
	if half - math.abs(dx) <= half - math.abs(dz) then
		return cx + (if dx < 0 then -out else out), z
	end
	return x, cz + (if dz < 0 then -out else out)
end

-- Which plot (x, z) is in, or nil for the street, plaza and outside the map.
function Plots.plotAt(x: number, z: number): number?
	for plot = 1, L.plotCount do
		if Plots.isInside(plot, x, z) then
			return plot
		end
	end
	return nil
end

return Plots

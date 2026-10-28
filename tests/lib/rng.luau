--!strict
-- Deterministic random numbers for tests and simulations, so every failure is reproducible
-- from its seed. Park-Miller minimal standard generator.

export type Rng = {
	next: () -> number, -- uniform in [0, 1)
	int: (low: number, high: number) -> number, -- uniform integer in [low, high]
	chance: (p: number) -> boolean,
}

local MODULUS = 2147483647
local MULTIPLIER = 48271

local function new(seed: number): Rng
	local state = seed % MODULUS
	if state <= 0 then
		state += MODULUS - 1
	end

	local function nextValue(): number
		state = (state * MULTIPLIER) % MODULUS
		return (state - 1) / (MODULUS - 1)
	end

	return {
		next = nextValue,
		int = function(low: number, high: number): number
			return low + math.floor(nextValue() * (high - low + 1))
		end,
		chance = function(p: number): boolean
			return nextValue() < p
		end,
	}
end

return { new = new }

--!strict
local expect = require("../lib/expect")
local Kit = require("../../tools/assets/Kit")

local tests = {}

local TRAP_KINDS = { "SlowPuddle", "Net", "Sprinkler", "AlarmMoth", "Trapdoor" }

local function snake(kind: string): string
	return (string.lower((string.gsub(kind, "(%l)(%u)", "%1_%2"))))
end

local function byId()
	local map = {}
	for _, p in Kit.PIECES do
		expect.falsy(map[p.id], `duplicate piece id {p.id}`)
		map[p.id] = p
	end
	return map
end

tests["the kit covers den base, pad, vault door, plaza, every trap kind and 10 props"] = function()
	local map = byId()
	for _, id in { "den_base", "pad", "vault_door", "plaza" } do
		expect.truthy(map[id], `missing {id}`)
	end
	for _, kind in TRAP_KINDS do
		expect.truthy(map["trap_" .. snake(kind)], `missing trap for {kind}`)
	end
	local props = 0
	for _, p in Kit.PIECES do
		if p.group == "prop" then
			props += 1
		end
	end
	expect.eq(props, 10)
end

tests["every piece has a purpose, a positive size, a budget and notes"] = function()
	for _, p in Kit.PIECES do
		expect.truthy(p.purpose ~= "" and p.notes ~= "" and p.subject ~= "", `{p.id} has an empty field`)
		expect.truthy(p.size.x > 0 and p.size.y > 0 and p.size.z > 0, `{p.id} size`)
		expect.truthy(p.triangles > 0 and p.parts > 0, `{p.id} budget`)
		expect.truthy(string.match(p.id, "^[a-z0-9_]+$") ~= nil, `{p.id} is not snake_case`)
	end
end

tests["budgets stay mobile-sane: heavy only when few are on screen"] = function()
	for _, p in Kit.PIECES do
		expect.truthy(p.triangles <= 4000, `{p.id} over 4000 triangles`)
		expect.truthy(p.parts <= 12, `{p.id} over 12 parts`)
		-- Total triangles for the most of this piece that can be on screen stays under 25k.
		expect.truthy(p.triangles * p.repeats <= 25000, `{p.id} costs too much at its repeat count`)
	end
end

tests["sizes quoted from game code match it"] = function()
	local map = byId()
	expect.eq(map.pad.size.x, 8) -- Plots.Layout.padSize
	expect.eq(map.den_base.size.x, 56) -- Plots.Layout.plotSize
	expect.eq(map.plaza.size.x, 48) -- Plots.Layout.plazaRadius * 2
	expect.eq(map.trap_slow_puddle.size.x, 6) -- Pocket.trapRadius * 2
end

tests["prompts name one glow in words, never hex, text or a character"] = function()
	for _, p in Kit.PIECES do
		local prompt = Kit.prompt(p)
		expect.falsy(string.find(prompt, "#", 1, true), `{p.id} has a hex code`)
		expect.truthy(string.find(prompt, "Subject: ", 1, true), `{p.id} has no subject`)
		if p.glow then
			expect.truthy(Kit.GLOW_WORDS[p.glow], `{p.id} unknown glow {p.glow}`)
			expect.truthy(string.find(prompt, "No other glowing parts", 1, true), `{p.id} one-glow line`)
		else
			expect.truthy(string.find(prompt, "No glowing parts at all", 1, true), `{p.id} no-glow line`)
		end
		expect.truthy(string.find(prompt, "Avoid photorealism", 1, true), `{p.id} avoid block`)
	end
end

tests["credit estimate adds up"] = function()
	local est = Kit.estimate(Kit.PIECES)
	expect.eq(est.pieces, #Kit.PIECES)
	expect.eq(est.total, est.imageCredits + est.meshCredits)
	expect.eq(est.imageCredits, est.images * Kit.IMAGE_COST)
end

return tests

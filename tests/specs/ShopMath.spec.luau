--!strict
local expect = require("../lib/expect")
local ShopMath = require("../../src/Client/Hud/ShopMath")

local tests = {}

tests["free egg is enabled and costs nothing"] = function()
	local o = ShopMath.egg(0, 100, true)
	expect.eq(o.label, "free", "label")
	expect.eq(o.price, 0, "price")
	expect.truthy(o.enabled, "enabled")
end

tests["egg is disabled and reports the shortfall when poor"] = function()
	local o = ShopMath.egg(40.5, 100, false)
	expect.eq(o.label, "need", "label")
	expect.eq(o.missing, 60, "missing rounds up")
	expect.eq(o.enabled, false, "disabled")
end

tests["egg is buyable at exactly the price"] = function()
	local o = ShopMath.egg(100, 100, false)
	expect.eq(o.label, "buy", "label")
	expect.eq(o.price, 100, "price shown")
end

tests["upgrade handles max level, poor and rich"] = function()
	expect.eq(ShopMath.upgrade(1e9, nil).label, "max", "max")
	expect.eq(ShopMath.upgrade(5, 50).missing, 45, "missing")
	expect.truthy(ShopMath.upgrade(50, 50).enabled, "affordable")
end

tests["robux row with id 0 is not available"] = function()
	expect.eq(ShopMath.robux(0, 99).available, false, "zero")
	expect.eq(ShopMath.robux(-3, 99).available, false, "negative")
	expect.eq(ShopMath.robux(1.5, 99).available, false, "fraction")
	expect.eq(ShopMath.robux("7", 99).available, false, "string")
	expect.truthy(ShopMath.robux(123, 99).available, "real id")
	expect.eq(ShopMath.robux(123, 99).price, 99, "price")
end

tests["gear row: buy, upgrade, need, max"] = function()
	expect.eq(ShopMath.gear(0, 100, 50, false).label, "buy", "buy")
	expect.eq(ShopMath.gear(2, 100, 50, false).label, "upgrade", "upgrade")
	local need = ShopMath.gear(1, 10.2, 50, false)
	expect.eq(need.label, "need", "need")
	expect.eq(need.missing, 40, "missing")
	expect.eq(need.enabled, false, "disabled")
	expect.eq(ShopMath.gear(5, 1e9, nil, true).label, "max", "max")
	expect.eq(ShopMath.gear(0, 1e9, nil, false).label, "off", "off")
end

tests["lantern claims a boost only on literal true"] = function()
	expect.eq(ShopMath.lantern({ buyerName = "Ana", boosted = true }).boosted, true, "boosted")
	expect.eq(ShopMath.lantern({ buyerName = "Ana", boosted = false }).boosted, false, "not")
	expect.eq(ShopMath.lantern({ buyerName = "Ana", boosted = "yes" }).boosted, false, "truthy string")
	expect.eq(ShopMath.lantern({ buyerName = "Ana" }).boosted, false, "missing")
	expect.eq(ShopMath.lantern({ boosted = true }), nil, "no name")
	expect.eq(ShopMath.lantern(5), nil, "not a table")
end

return tests

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

return tests

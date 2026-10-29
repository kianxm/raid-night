--!strict
--[[
	ShopMath (owner: ui agent): pure shop display math. Display only; the server decides every
	purchase. No Roblox services, so Lune can test it.
]]

local ShopMath = {}

export type Offer = {
	label: "free" | "buy" | "need" | "max",
	price: number, -- Glow shown on the button (0 when free or maxed)
	missing: number, -- Glow still needed (0 when affordable)
	enabled: boolean,
}

-- The egg button: free when the rescue rule says so, else buy / need-more by banked Glow.
function ShopMath.egg(glow: number, price: number, free: boolean): Offer
	if free then
		return { label = "free", price = 0, missing = 0, enabled = true }
	end
	if glow >= price then
		return { label = "buy", price = price, missing = 0, enabled = true }
	end
	return { label = "need", price = price, missing = math.ceil(price - glow), enabled = false }
end

-- The upgrade button. `cost` is nil at max level.
function ShopMath.upgrade(glow: number, cost: number?): Offer
	if cost == nil then
		return { label = "max", price = 0, missing = 0, enabled = false }
	end
	if glow >= cost then
		return { label = "buy", price = cost, missing = 0, enabled = true }
	end
	return { label = "need", price = cost, missing = math.ceil(cost - glow), enabled = false }
end

return ShopMath

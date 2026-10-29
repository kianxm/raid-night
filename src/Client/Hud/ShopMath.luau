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

export type RobuxRow = {
	available: boolean, -- false: product id not set yet, show "Not available yet", never prompt
	price: number,
}

-- A Robux row. Product id 0 (or anything not a positive whole number) is never promptable.
function ShopMath.robux(id: any, price: any): RobuxRow
	local ok = type(id) == "number" and id > 0 and id == math.floor(id) and id < math.huge
	return { available = ok, price = if type(price) == "number" then price else 0 }
end

export type GearRow = {
	label: "buy" | "upgrade" | "need" | "max" | "off",
	cost: number,
	missing: number,
	enabled: boolean,
}

-- One gear row: level 0 buys level 1, else upgrades. `cost` nil = switched off (or unpriced).
function ShopMath.gear(level: number, glow: number, cost: number?, maxed: boolean): GearRow
	if maxed then
		return { label = "max", cost = 0, missing = 0, enabled = false }
	end
	if cost == nil then
		return { label = "off", cost = 0, missing = 0, enabled = false }
	end
	if glow < cost then
		return { label = "need", cost = cost, missing = math.ceil(cost - glow), enabled = false }
	end
	return { label = if level <= 0 then "buy" else "upgrade", cost = cost, missing = 0, enabled = true }
end

export type Lantern = { name: string, boosted: boolean }

-- Reads a Lantern Night announcement. Boost is claimed only on a literal `true`.
function ShopMath.lantern(payload: any): Lantern?
	if type(payload) ~= "table" or type(payload.buyerName) ~= "string" or payload.buyerName == "" then
		return nil
	end
	return { name = payload.buyerName, boosted = payload.boosted == true }
end

return ShopMath

--!strict
-- Minimal assertions for the Lune test runner. Each failure raises an error with context.

local expect = {}

local function show(value: any): string
	if type(value) == "string" then
		return `"{value}"`
	end
	return tostring(value)
end

function expect.eq(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`{message or "values differ"}: expected {show(expected)}, got {show(actual)}`, 2)
	end
end

function expect.near(actual: number, expected: number, tolerance: number, message: string?)
	if math.abs(actual - expected) > tolerance then
		error(`{message or "not near"}: expected {expected} +/- {tolerance}, got {actual}`, 2)
	end
end

function expect.truthy(value: any, message: string?)
	if not value then
		error(message or "expected a truthy value", 2)
	end
end

function expect.falsy(value: any, message: string?)
	if value then
		error(`{message or "expected a falsy value"}, got {show(value)}`, 2)
	end
end

function expect.throws(fn: () -> (), message: string?)
	local ok = pcall(fn)
	if ok then
		error(message or "expected an error, none was thrown", 2)
	end
end

return expect

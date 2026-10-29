--!strict
--[[
	Helpers for source guards: specs that read server code (which Lune cannot run) and check a
	rule holds in the text, e.g. "only one function reads a flag".
]]

local fs = require("@lune/fs")

local source = {}

-- Strips comments so a guard looks at code only.
function source.codeOnly(text: string): string
	text = string.gsub(text, "%-%-%[(=*)%[.-%]%1%]", "")
	text = string.gsub(text, "%-%-[^\n]*", "")
	return text
end

-- Reads a repo file by its path from the repo root, found from this module's own location (not
-- the working directory), so a guard checks the right file wherever `lune run` starts.
function source.read(relative: string): string
	local here = debug.info(1, "s")
	local root = string.match(here, "^(.*)[/\\]tests[/\\]lib[/\\][^/\\]+$")
	assert(root, `cannot find the repo root from "{here}"`)
	local path = `{root}/{relative}`
	assert(fs.isFile(path), `guarded source file missing: {path}`)
	return fs.readFile(path)
end

-- The text of `function <name>(...)` up to its closing `end` at column 0.
function source.functionBody(code: string, name: string): string?
	local pattern = "function " .. string.gsub(name, "%.", "%%.") .. "%(.-\nend\n"
	local first, last = string.find(code, pattern)
	return if first and last then string.sub(code, first, last) else nil
end

return source

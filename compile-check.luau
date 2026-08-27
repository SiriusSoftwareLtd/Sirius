--[[
	Compiles every shipped source with the real Luau compiler.

	This exists because format, lint and analyze all pass on a file that cannot be
	compiled. Luau allows 200 locals per function scope and the main chunk counts as
	one; source.lua reached 201 and `loadstring` returned nil, so every user of a
	stricter executor got "attempt to call a nil value" on line 1 and nothing else.
	luau-lsp did not catch it because that cap is a codegen limit, not a parse error.

	Note which half does the work. The compile is cheap insurance against outright
	broken syntax, but it does NOT reproduce the bug above: this Luau reuses registers
	from closed scopes and compiles 201 locals without complaint, which is precisely
	why Sirius worked for most people. The local count below is the real check.
]]

local luau = require("@lune/luau")
local fs = require("@lune/fs")
local process = require("@lune/process")

local FILES = { "source.lua", "boost.lua", "prompt.lua" }

-- Luau's limit. The main chunk is a function scope like any other.
local LOCAL_LIMIT = 200
-- Fail before the cliff rather than at it. The file sits at 191, so this leaves a few
-- for ordinary work and still stops anyone walking back up to 200 unnoticed -- where the
-- next local added, anywhere in the file, breaks every strict executor at once.
local WARN_AT = 195

--- Counts locals declared at the top level of the chunk, i.e. column 0.
---
--- This, not the compile above, is what actually guards the 200-local cap. Lune's Luau
--- is new enough to reuse registers from closed scopes, so it compiles 201 locals
--- happily -- exactly like the executors Sirius always worked on. The count is the only
--- thing here that sees what a stricter compiler would reject.
---
--- Approximate by design: it reads declarations at column 0 rather than parsing. It does
--- not need to be exact to stop the file drifting back to the limit.
local function countTopLevelLocals(source: string): number
	local count = 0
	local inLongComment = false

	for line in string.gmatch(source, "[^\n]*") do
		local text = line

		if inLongComment then
			local closeAt = string.find(text, "]]", 1, true)
			if closeAt then
				text = string.sub(text, closeAt + 2)
				inLongComment = false
			else
				text = ""
			end
		end

		local openAt = string.find(text, "--[[", 1, true)
		if openAt and not string.find(text, "]]", openAt, true) then
			text = string.sub(text, 1, openAt - 1)
			inLongComment = true
		end

		text = string.gsub(text, "%-%-.*$", "")

		if string.sub(text, 1, 6) == "local " then
			if string.match(text, "^local%s+function%s+[%a_][%w_]*") then
				count += 1
			else
				local names = string.match(text, "^local%s+([^=]+)")
				if names then
					for name in string.gmatch(names, "[^,]+") do
						local clean = string.match(name, "^%s*([%a_][%w_]*)")
						if clean then
							count += 1
						end
					end
				end
			end
		end
	end

	return count
end

local failed = false

for _, file in FILES do
	if not fs.isFile(file) then
		print(`SKIP    {file} (not present)`)
		continue
	end

	local source = fs.readFile(file)
	local ok, err = pcall(function()
		return luau.compile(source)
	end)

	if ok then
		print(`COMPILE {file} ok`)
	else
		failed = true
		print(`COMPILE {file} FAILED`)
		print(`        {err}`)
	end
end

-- Only source.lua is large enough for this to be a live concern.
if fs.isFile("source.lua") then
	local locals = countTopLevelLocals(fs.readFile("source.lua"))
	print(`LOCALS  source.lua top-level: {locals} / {LOCAL_LIMIT}`)

	if locals > WARN_AT then
		failed = true
		print(`        Too close to Luau's {LOCAL_LIMIT}-local limit. Wrap a trailing`)
		print(`        section in do ... end, as the end of source.lua already does.`)
	end
end

if failed then
	process.exit(1)
end

print("All sources compile.")

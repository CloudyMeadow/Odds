--!strict
-- Runs every *.spec.luau file in this folder: `lune run tests/run`
-- Pass a name to run matching spec files only: `lune run tests/run Pcg32`

local fs = require("@lune/fs")
local process = require("@lune/process")
local Test = require("./lib/Test")

local filter = process.args[1]
local files = fs.readDir("tests")
table.sort(files)

for _, file in files do
	local name = string.match(file, "^(.+)%.spec%.luau$")
	if name and (filter == nil or string.find(name, filter, 1, true)) then
		print(`{name}`);
		(require :: any)(`./{name}.spec`)
	end
end

local failed = Test.run()
process.exit(if failed > 0 then 1 else 0)

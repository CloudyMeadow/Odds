--!strict
-- A tiny test framework for Lune: describe/it blocks plus a few assertions.

local Test = {}

type Case = { name: string, fn: () -> () }
local cases: { Case } = {}
local prefix: { string } = {}

function Test.describe(name: string, fn: () -> ())
	table.insert(prefix, name)
	fn()
	table.remove(prefix)
end

function Test.it(name: string, fn: () -> ())
	local full = table.concat(prefix, " > ")
	table.insert(cases, { name = if full ~= "" then `{full} > {name}` else name, fn = fn })
end

local function fail(message: string, level: number?): never
	error(message, (level or 1) + 1)
end

function Test.equal(actual: any, expected: any, label: string?)
	if actual ~= expected then
		fail(`{label or "value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

function Test.near(actual: number, expected: number, tolerance: number, label: string?)
	if math.abs(actual - expected) > tolerance then
		fail(`{label or "value"}: expected {expected} ± {tolerance}, got {actual}`, 2)
	end
end

function Test.truthy(value: any, label: string?)
	if not value then
		fail(`{label or "value"}: expected a truthy value, got {tostring(value)}`, 2)
	end
end

function Test.throws(fn: () -> (), pattern: string?)
	local ok, err = pcall(fn :: any)
	if ok then
		fail("expected an error, but none was raised", 2)
	end
	if pattern and not string.find(tostring(err), pattern, 1, true) then
		fail(`expected an error containing "{pattern}", got: {tostring(err)}`, 2)
	end
end

-- Runs every registered case and returns the number of failures
function Test.run(): number
	local failed = 0
	for _, case in cases do
		local started = os.clock()
		local ok, err = pcall(case.fn :: any)
		local ms = (os.clock() - started) * 1000
		if ok then
			print(string.format("  PASS  %s (%.0f ms)", case.name, ms))
		else
			failed += 1
			print(`  FAIL  {case.name}\n        {tostring(err)}`)
		end
	end
	print(`\n{#cases - failed} passed, {failed} failed, {#cases} total`)
	table.clear(cases)
	return failed
end

return Test

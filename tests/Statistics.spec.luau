--!strict
-- Proves the roller matches the math: roll a million times with a fixed seed and
-- check the counts against table:odds() with a chi-square goodness-of-fit test.

local Odds = require("../src")
local Stats = require("./lib/Stats")
local Test = require("./lib/Test")

local describe, it, truthy = Test.describe, Test.it, Test.truthy

local ROLLS = 1_000_000

local function checkDistribution(tbl: Odds.Table, seed: number)
	local rows = tbl:odds()
	local indexByPath: { [{ string }]: number } = {}
	local probabilities: { number } = {}
	local observed: { number } = {}
	for i, row in rows do
		indexByPath[row.path] = i
		probabilities[i] = row.chance
		observed[i] = 0
	end

	local rng = Odds.Pcg32.new(seed)
	for _ = 1, ROLLS do
		local i = indexByPath[tbl:roll({ rng = rng }).path]
		observed[i] += 1
	end

	local chi = Stats.chiSquare(observed, probabilities, ROLLS)
	local critical = Stats.chiSquareCritical(#rows - 1)
	truthy(chi < critical, `chi-square {chi} should be below {critical} for {#rows - 1} degrees of freedom`)
end

describe("roll distribution", function()
	it("matches odds() for a flat table (1M rolls)", function()
		checkDistribution(
			Odds.table({
				name = "BasicEgg",
				entries = {
					{ id = "Chick", weight = 700 },
					{ id = "Rooster", weight = 250 },
					{ id = "GoldenChicken", weight = 49 },
					{ id = "CosmicHen", weight = 1 },
				},
			}),
			2026
		)
	end)

	it("matches odds() for nested tables with uneven weights (1M rolls)", function()
		local inner = Odds.table({
			name = "Inner",
			entries = {
				{ id = "I1", weight = 1 },
				{ id = "I2", weight = 2 },
				{ id = "I3", weight = 3.5 },
				{ id = "I4", weight = 0.5 },
			},
		})
		local entries: { Odds.Entry } = {}
		for i = 1, 40 do
			table.insert(entries, { id = `E{i}`, weight = i * i } :: Odds.Entry)
		end
		table.insert(entries, { id = "Nested", weight = 300, table = inner } :: Odds.Entry)
		checkDistribution(Odds.table({ name = "Big", entries = entries }), 7)
	end)

	it("catches a biased roller (sanity check of the test itself)", function()
		local probabilities = { 0.5, 0.5 }
		local chi = Stats.chiSquare({ 505_000, 495_000 }, probabilities, ROLLS)
		truthy(chi > Stats.chiSquareCritical(1), "a 1% bias over 1M rolls must fail")
	end)
end)

return nil

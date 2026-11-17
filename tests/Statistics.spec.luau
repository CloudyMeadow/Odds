--!strict
-- Proves the roller matches the math: roll a million times with a fixed seed and
-- check the counts against table:odds() with a chi-square goodness-of-fit test.

local Odds = require("../src")
local Stats = require("./lib/Stats")
local Test = require("./lib/Test")

local describe, it, truthy = Test.describe, Test.it, Test.truthy

local ROLLS = 1_000_000

local function checkDistribution(tbl: Odds.Table, seed: number, options: Odds.RollOptions?)
	local rows = tbl:odds(options :: any)
	local indexByPath: { [{ string }]: number } = {}
	local probabilities: { number } = {}
	local observed: { number } = {}
	for i, row in rows do
		indexByPath[row.path] = i
		probabilities[i] = row.chance
		observed[i] = 0
	end

	local rng = Odds.Pcg32.new(seed)
	local rollOptions: Odds.RollOptions = {
		rng = rng,
		modifiers = options and options.modifiers,
		state = options and options.state,
	}
	local skipped = 0
	for _ = 1, ROLLS do
		local i = indexByPath[tbl:roll(rollOptions).path]
		observed[i] += 1
	end

	-- Rows the modifiers removed must never appear, and are left out of the test
	local keptProbabilities: { number } = {}
	local keptObserved: { number } = {}
	for i, p in probabilities do
		if p > 0 then
			table.insert(keptProbabilities, p)
			table.insert(keptObserved, observed[i])
		else
			skipped += observed[i]
		end
	end
	truthy(skipped == 0, "removed results were rolled")
	local df = #keptProbabilities - 1
	local chi = Stats.chiSquare(keptObserved, keptProbabilities, ROLLS)
	local critical = Stats.chiSquareCritical(df)
	truthy(chi < critical, `chi-square {chi} should be below {critical} for {df} degrees of freedom`)
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

	local function premium()
		local legendaries = Odds.table({
			name = "Legendaries",
			entries = { { id = "Phoenix", weight = 3 }, { id = "Dragon", weight = 1 } },
		})
		return Odds.table({
			name = "Premium",
			tiers = { Common = { order = 1 }, Rare = { order = 2 }, Legendary = { order = 4 } },
			entries = {
				{ id = "Chick", weight = 800, tier = "Common" },
				{ id = "Duck", weight = 150, tier = "Common" },
				{ id = "Owl", weight = 45, tier = "Rare" },
				{ id = "Legendaries", weight = 5, tier = "Legendary", table = legendaries },
			},
			pity = { { tier = "Legendary", hard = 200, soft = { start = 150, perRoll = 0.01 } } },
		})
	end

	it("matches odds() with luck in every mode (1M rolls each)", function()
		local t = premium()
		checkDistribution(t, 11, { modifiers = { Odds.modifiers.luck(2) } })
		checkDistribution(t, 12, { modifiers = { Odds.modifiers.luck(3, { mode = "weight" }) } })
		checkDistribution(t, 13, { modifiers = { Odds.modifiers.luck(4, { mode = "rolls" }) } })
	end)

	it("matches odds() during soft pity, with modifiers (1M rolls)", function()
		local state: Odds.State = { version = 1, rolls = 0, pity = { ["Premium:Legendary"] = 170 } }
		checkDistribution(premium(), 14, {
			state = state,
			modifiers = { Odds.modifiers.exclude({ "Duck" }), Odds.modifiers.luck(2) },
		})
	end)

	it("matches odds() under hard pity with two rules at once (1M rolls)", function()
		local t = Odds.table({
			name = "TwoRules",
			tiers = { Common = { order = 1 }, Legendary = { order = 4 }, Mythic = { order = 5 } },
			entries = {
				{ id = "Chick", weight = 980, tier = "Common" },
				{ id = "Phoenix", weight = 12, tier = "Legendary" },
				{ id = "Dragon", weight = 6, tier = "Legendary" },
				{ id = "CosmicHen", weight = 2, tier = "Mythic" },
			},
			-- The annotation helps the current Luau solver with mixed rule shapes
			pity = {
				{ tier = "Legendary", hard = 50 },
				{ tier = "Mythic", soft = { start = 10, perRoll = 0.03 } },
			} :: { Odds.PityDefinition },
		})
		local state: Odds.State =
			{ version = 1, rolls = 0, pity = { ["TwoRules:Legendary"] = 49, ["TwoRules:Mythic"] = 15 } }
		checkDistribution(t, 15, { state = state })
	end)

	it("catches a biased roller (sanity check of the test itself)", function()
		local probabilities = { 0.5, 0.5 }
		local chi = Stats.chiSquare({ 505_000, 495_000 }, probabilities, ROLLS)
		truthy(chi > Stats.chiSquareCritical(1), "a 1% bias over 1M rolls must fail")
	end)
end)

return nil

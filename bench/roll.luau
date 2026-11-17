--!strict
-- Rough performance check: `lune run bench/roll`

local Odds = require("../src")

local function time(label: string, count: number, fn: () -> ())
	local started = os.clock()
	fn()
	local seconds = os.clock() - started
	print(string.format("%-44s %8.0f ms  (%.0f ns per roll)", label, seconds * 1000, seconds / count * 1e9))
end

local small = Odds.table({
	name = "BasicEgg",
	entries = {
		{ id = "Chick", weight = 700 },
		{ id = "Rooster", weight = 250 },
		{ id = "GoldenChicken", weight = 49 },
		{ id = "CosmicHen", weight = 1 },
	},
})

local bigEntries: { Odds.Entry } = {}
for i = 1, 10_000 do
	bigEntries[i] = { id = `Item{i}`, weight = i }
end
local big = Odds.table({ name = "Big", entries = bigEntries })

local nested = Odds.table({
	name = "Premium",
	entries = {
		{ id = "Commons", weight = 900, table = small },
		{ id = "Big", weight = 100, table = big },
	},
})

local N = 1_000_000
local rng = Odds.Pcg32.new(1)

time("1M rolls, 4 entries", N, function()
	for _ = 1, N do
		small:roll({ rng = rng })
	end
end)

time("1M rolls, 10,000 entries", N, function()
	for _ = 1, N do
		big:roll({ rng = rng })
	end
end)

time("1M rolls, nested two levels", N, function()
	for _ = 1, N do
		nested:roll({ rng = rng })
	end
end)

time("1M rolls via rollMany, 4 entries", N, function()
	small:rollMany(N, { rng = rng })
end)

local tiered = Odds.table({
	name = "Tiered",
	tiers = { Common = { order = 1 }, Rare = { order = 2 }, Legendary = { order = 4 } },
	entries = {
		{ id = "Chick", weight = 900, tier = "Common" },
		{ id = "Owl", weight = 95, tier = "Rare" },
		{ id = "Big", weight = 5, tier = "Legendary", table = big },
	},
	pity = { { tier = "Legendary", hard = 200, soft = { start = 150, perRoll = 0.01 } } },
})
local luck = { Odds.modifiers.luck(2) }

time("1M rolls with 2x luck (cached), 10,003 results", N, function()
	tiered:rollMany(N, { rng = rng, modifiers = luck })
end)

time("1M rolls with pity state, 10,003 results", N, function()
	tiered:rollMany(N, { rng = rng, state = Odds.state() })
end)

time("1M raw Pcg32:NextNumber calls", N, function()
	for _ = 1, N do
		rng:NextNumber()
	end
end)

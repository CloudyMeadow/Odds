--!strict
local Odds = require("../src")
local Test = require("./lib/Test")

local describe, it, equal, near, truthy, throws =
	Test.describe, Test.it, Test.equal, Test.near, Test.truthy, Test.throws

local TIERS: { [string]: Odds.TierInfo } = {
	Common = { order = 1 },
	Rare = { order = 2 },
	Legendary = { order = 4 },
	Mythic = { order = 5 },
}

local function egg(pity: { Odds.PityDefinition }, pityGroup: string?)
	return Odds.table({
		name = "Egg",
		pityGroup = pityGroup,
		tiers = TIERS,
		entries = {
			{ id = "Chick", weight = 890, tier = "Common" },
			{ id = "Owl", weight = 100, tier = "Rare" },
			{ id = "Phoenix", weight = 9, tier = "Legendary" },
			{ id = "CosmicHen", weight = 1, tier = "Mythic" },
		},
		pity = pity,
	})
end

local function stateWith(counters: { [string]: number }): Odds.State
	return { version = 1, rolls = 0, pity = counters }
end

describe("hard pity", function()
	it("guarantees the tier or better by roll N", function()
		local t = egg({ { tier = "Legendary", hard = 40 } })
		local state: Odds.State? = Odds.state()
		local rng = Odds.Pcg32.new(99)
		local sinceHit = 0
		local longest = 0
		for _ = 1, 20000 do
			local result
			result, state = t:roll({ state = state, rng = rng })
			sinceHit += 1
			if result.tier == "Legendary" or result.tier == "Mythic" then
				longest = math.max(longest, sinceHit)
				sinceHit = 0
			end
		end
		equal(longest, 40, "longest wait")
	end)

	it("marks only guaranteed rolls as pityTriggered", function()
		local t = egg({ { tier = "Legendary", hard = 10 } })
		local result = t:roll({ state = stateWith({ ["Egg:Legendary"] = 9 }) })
		truthy(result.tier == "Legendary" or result.tier == "Mythic")
		equal(result.pityTriggered, true)
		local normal = t:roll({ state = stateWith({ ["Egg:Legendary"] = 0 }), rng = Odds.Pcg32.new(1) })
		equal(normal.pityTriggered, false)
	end)

	it("keeps the guaranteed roll's odds proportional inside the tier", function()
		local t = egg({ { tier = "Legendary", hard = 10 } })
		local rows = t:odds({ state = stateWith({ ["Egg:Legendary"] = 9 }) })
		local byId: { [string]: number } = {}
		for _, row in rows do
			byId[row.id] = row.chance
		end
		near(byId.Phoenix, 0.9, 1e-12)
		near(byId.CosmicHen, 0.1, 1e-12)
		equal(byId.Chick, 0)
	end)

	it("works with a hard pity of 1", function()
		local t = egg({ { tier = "Mythic", hard = 1 } })
		local state: Odds.State? = Odds.state()
		local rng = Odds.Pcg32.new(3)
		for _ = 1, 100 do
			local result
			result, state = t:roll({ state = state, rng = rng })
			equal(result.id, "CosmicHen")
		end
	end)

	it("ignores pity when no state is passed", function()
		local t = egg({ { tier = "Mythic", hard = 1 } })
		local rng = Odds.Pcg32.new(4)
		local sawOther = false
		for _ = 1, 50 do
			if t:roll({ rng = rng }).id ~= "CosmicHen" then
				sawOther = true
			end
		end
		truthy(sawOther)
	end)
end)

describe("soft pity", function()
	it("adds perRoll to the tier's chance from the start roll", function()
		local t = egg({ { tier = "Legendary", hard = 100, soft = { start = 80, perRoll = 0.05 } } })
		near(t:chanceOf("Phoenix", { state = stateWith({ ["Egg:Legendary"] = 0 }) }), 0.009, 1e-12)
		-- Counter 78 means the next roll is roll 79: not ramping yet
		near(t:chanceOf("Phoenix", { state = stateWith({ ["Egg:Legendary"] = 78 }) }), 0.009, 1e-12)
		-- Roll 80: base 1% for Legendary or better, plus 0.05
		local share = 0.01 + 0.05
		near(t:chanceOf("Phoenix", { state = stateWith({ ["Egg:Legendary"] = 79 }) }), share * 0.9, 1e-12)
		near(t:chanceOf("CosmicHen", { state = stateWith({ ["Egg:Legendary"] = 84 }) }), (0.01 + 0.3) * 0.1, 1e-12)
	end)

	it("caps at 100%", function()
		local t = egg({ { tier = "Legendary", soft = { start = 1, perRoll = 0.5 } } })
		near(t:chanceOf("Chick", { state = stateWith({ ["Egg:Legendary"] = 10 }) }), 0, 1e-12)
	end)

	it("shows the ramp in the pity stage of odds()", function()
		local t = egg({ { tier = "Legendary", soft = { start = 1, perRoll = 0.1 } } })
		for _, row in t:odds({ state = stateWith({ ["Egg:Legendary"] = 0 }) }) do
			if row.id == "Phoenix" then
				near(row.stages.luck, 0.009, 1e-12)
				near(row.stages.pity, 0.11 * 0.9, 1e-12)
			end
		end
	end)
end)

describe("reset policies and groups", function()
	local mythicOnly = Odds.modifiers.exclude({ "Chick", "Owl", "Phoenix" })

	it("resets on a better tier by default", function()
		local t = egg({ { tier = "Legendary", hard = 100 } })
		local _, state = t:roll({ state = stateWith({ ["Egg:Legendary"] = 20 }), modifiers = { mythicOnly } })
		equal((state :: Odds.State).pity["Egg:Legendary"], 0)
	end)

	it('only resets on an exact match with reset = "exact"', function()
		local t = egg({ { tier = "Legendary", hard = 100, reset = "exact" } })
		local _, state = t:roll({ state = stateWith({ ["Egg:Legendary"] = 20 }), modifiers = { mythicOnly } })
		equal((state :: Odds.State).pity["Egg:Legendary"], 21)
		-- And an exact rule only guarantees that tier
		local rows = t:odds({ state = stateWith({ ["Egg:Legendary"] = 99 }) })
		for _, row in rows do
			equal(row.chance, if row.id == "Phoenix" then 1 else 0)
		end
	end)

	it("counts up on a miss", function()
		local t = egg({ { tier = "Legendary", hard = 100 } })
		local _, state = t:roll({
			state = stateWith({ ["Egg:Legendary"] = 5 }),
			modifiers = { Odds.modifiers.exclude({ "Owl", "Phoenix", "CosmicHen" }) },
		})
		equal((state :: Odds.State).pity["Egg:Legendary"], 6)
	end)

	it("shares counters between tables in the same pity group", function()
		local a = egg({ { tier = "Legendary", hard = 100 } }, "Premium")
		local b = Odds.table({
			name = "OtherEgg",
			pityGroup = "Premium",
			tiers = TIERS,
			entries = { { id = "Duck", weight = 1, tier = "Common" }, { id = "Gold", weight = 1, tier = "Legendary" } },
			pity = { { tier = "Legendary", hard = 100 } },
		})
		local _, state =
			a:roll({ state = Odds.state(), modifiers = { Odds.modifiers.exclude({ "Owl", "Phoenix", "CosmicHen" }) } })
		local _, state2 = b:roll({ state = state, modifiers = { Odds.modifiers.exclude({ "Gold" }) } })
		equal((state2 :: Odds.State).pity["Premium:Legendary"], 2)
	end)

	it("applies several rules together, rarest last", function()
		local t = egg({
			{ tier = "Mythic", soft = { start = 1, perRoll = 0.5 } },
			{ tier = "Legendary", hard = 10 },
		})
		local rows = t:odds({ state = stateWith({ ["Egg:Legendary"] = 9, ["Egg:Mythic"] = 0 }) })
		local byId: { [string]: number } = {}
		for _, row in rows do
			byId[row.id] = row.chance
		end
		-- Legendary or better is guaranteed first. Inside that, Mythic already has a
		-- 0.1 share (1 of 10 weight), and its soft pity adds 0.5 on top.
		near(byId.CosmicHen, 0.6, 1e-12)
		near(byId.Phoenix, 0.4, 1e-12)
		equal(byId.Chick, 0)
	end)

	it("does nothing when modifiers removed the guaranteed tier", function()
		local t = egg({ { tier = "Legendary", hard = 10 } })
		local result = t:roll({
			state = stateWith({ ["Egg:Legendary"] = 9 }),
			modifiers = { Odds.modifiers.exclude({ "Phoenix", "CosmicHen" }) },
		})
		truthy(result.id == "Chick" or result.id == "Owl")
	end)
end)

describe("pity definitions", function()
	it("rejects broken rules with a clear error", function()
		throws(function()
			egg({ { tier = "Secret", hard = 10 } })
		end, `no entry in this table has tier "Secret"`)
		throws(function()
			egg({ { tier = "Legendary" } })
		end, "hard, soft or both")
		throws(function()
			egg({ { tier = "Legendary", hard = 0 } })
		end, "hard must be")
		throws(function()
			egg({ { tier = "Legendary", hard = 10, soft = { start = 10, perRoll = 0.1 } } })
		end, "lower than hard")
		throws(function()
			egg({ { tier = "Legendary", soft = { start = 5, perRoll = 0 } } })
		end, "perRoll")
		throws(function()
			egg({ { tier = "Legendary", hard = 5, reset = "sometimes" :: any } })
		end, "reset")
		throws(function()
			egg({ { tier = "Legendary", hard = 5 }, { tier = "Legendary", hard = 6 } })
		end, "defined twice")
	end)

	it("warns in validate() when 'or better' can't work", function()
		local t = Odds.table({
			name = "Loose",
			tiers = { Common = { order = 1 }, Special = {} },
			entries = { { id = "A", weight = 1, tier = "Common" }, { id = "B", weight = 1, tier = "Special" } },
			pity = { { tier = "Special", hard = 5 } },
		})
		local ok, issues = t:validate()
		equal(ok, false)
		truthy((string.find(issues[1], "exact match", 1, true)))
	end)

	it("finds tiers declared in nested tables", function()
		local inner = Odds.table({
			name = "Inner",
			tiers = { Legendary = { order = 4 } },
			entries = { { id = "Gold", weight = 1, tier = "Legendary" } },
		})
		local t = Odds.table({
			name = "Outer",
			tiers = { Common = { order = 1 } },
			entries = { { id = "Duck", weight = 99, tier = "Common" }, { id = "Inner", weight = 1, table = inner } },
			pity = { { tier = "Legendary", hard = 3 } },
		})
		local result = t:roll({ state = stateWith({ ["Outer:Legendary"] = 2 }) })
		equal(result.id, "Gold")
		equal(result.pityTriggered, true)
	end)
end)

return nil

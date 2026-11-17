--!strict
local Odds = require("../src")
local Test = require("./lib/Test")

local describe, it, equal, near, truthy, throws =
	Test.describe, Test.it, Test.equal, Test.near, Test.truthy, Test.throws
local luck, boostEntry, exclude, onlyTags, custom =
	Odds.modifiers.luck,
	Odds.modifiers.boostEntry,
	Odds.modifiers.exclude,
	Odds.modifiers.onlyTags,
	Odds.modifiers.custom

local function egg()
	local Legendaries = Odds.table({
		name = "Legendaries",
		entries = {
			{ id = "Phoenix", weight = 1, tags = { "Fire" } },
			{ id = "Dragon", weight = 1, tags = { "Fire", "Flying" } },
		},
	})
	return Odds.table({
		name = "Egg",
		tiers = { Common = { order = 1 }, Rare = { order = 2 }, Legendary = { order = 4 } },
		entries = {
			{ id = "Chick", weight = 89, tier = "Common", tags = { "Flying" } },
			{ id = "Owl", weight = 10, tier = "Rare", tags = { "Flying" } },
			{ id = "Legendaries", weight = 1, tier = "Legendary", table = Legendaries },
		},
	})
end

local function sum(rows: { Odds.OddsRow }): number
	local total = 0
	for _, row in rows do
		total += row.chance
	end
	return total
end

describe("luck", function()
	it('doubles the chance exactly in the default "chance" mode', function()
		local t = egg()
		local m: Odds.OddsOptions = { modifiers = { luck(2, { tiers = { "Legendary" } }) } }
		near(t:chanceOf("Legendaries", m), 0.02, 1e-12)
		near(t:chanceOf("Phoenix", m), 0.01, 1e-12)
		-- The extra comes from the other tiers, proportionally
		near(t:chanceOf("Chick", m), 0.89 * 0.98 / 0.99, 1e-12)
		near(sum(t:odds(m)), 1, 1e-12)
	end)

	it("boosts every tier above the lowest order by default", function()
		local t = egg()
		local m: Odds.OddsOptions = { modifiers = { luck(2) } }
		near(t:chanceOf("Owl", m), 0.2, 1e-12)
		near(t:chanceOf("Legendaries", m), 0.02, 1e-12)
		near(t:chanceOf("Chick", m), 0.78, 1e-12)
	end)

	it("boosts everything but the most common result in an untiered table", function()
		local t = Odds.table({
			name = "Plain",
			entries = { { id = "A", weight = 90 }, { id = "B", weight = 9 }, { id = "C", weight = 1 } },
		})
		local m: Odds.OddsOptions = { modifiers = { luck(2) } }
		near(t:chanceOf("A", m), 0.8, 1e-12)
		near(t:chanceOf("C", m), 0.02, 1e-12)
	end)

	it("caps at 100% and leaves the other tiers at 0", function()
		local t = egg()
		local m: Odds.OddsOptions = { modifiers = { luck(1000, { tiers = { "Legendary" } }) } }
		near(t:chanceOf("Legendaries", m), 1, 1e-12)
		equal(t:chanceOf("Chick", m), 0)
	end)

	it('under-delivers in "weight" mode, as documented', function()
		local t = egg()
		local m: Odds.OddsOptions = { modifiers = { luck(2, { tiers = { "Legendary" }, mode = "weight" }) } }
		near(t:chanceOf("Legendaries", m), 2 / 101, 1e-12)
	end)

	it('matches 1 - (1 - p)^k for the rarest result in "rolls" mode', function()
		local t = Odds.table({
			name = "Plain",
			entries = { { id = "A", weight = 90 }, { id = "B", weight = 9 }, { id = "C", weight = 1 } },
		})
		local m: Odds.OddsOptions = { modifiers = { luck(3, { mode = "rolls" }) } }
		near(t:chanceOf("C", m), 1 - 0.99 ^ 3, 1e-12)
		near(t:chanceOf("A", m), 0.9 ^ 3, 1e-12)
		near(sum(t:odds(m)), 1, 1e-12)
		near(t:chanceOf("C", { modifiers = { luck(1, { mode = "rolls" }) } }), 0.01, 1e-12)
		throws(function()
			luck(1.5, { mode = "rolls" })
		end, "whole number")
	end)

	it("makes lucky tiers rarer with a multiplier below 1", function()
		near(egg():chanceOf("Legendaries", { modifiers = { luck(0.5, { tiers = { "Legendary" } }) } }), 0.005, 1e-12)
	end)

	it("never makes a boosted tier rarer (property test)", function()
		local rng = Odds.Pcg32.new(2024)
		for _ = 1, 200 do
			local entries: { Odds.Entry } = {}
			for i = 1, rng:NextInteger(2, 8) do
				entries[i] = {
					id = `E{i}`,
					weight = rng:NextNumber(0.01, 100),
					tier = if rng:NextNumber() < 0.5 then "Rare" else "Common",
				}
			end
			local t = Odds.table({
				name = "Random",
				tiers = { Common = { order = 1 }, Rare = { order = 2 } },
				entries = entries,
			})
			local mult = rng:NextNumber(1, 10)
			for _, mode in { "chance", "weight", "rolls" } :: { any } do
				local m = luck(if mode == "rolls" then math.floor(mult) else mult, { tiers = { "Rare" }, mode = mode })
				local boosted = t:odds({ modifiers = { m } })
				local before, after = 0, 0
				for _, row in t:odds() do
					if row.tier == "Rare" then
						before += row.chance
					end
				end
				for _, row in boosted do
					if row.tier == "Rare" then
						after += row.chance
					end
				end
				if mode ~= "rolls" then
					truthy(after >= before - 1e-12, `{mode}: {after} >= {before}`)
				end
				near(sum(boosted), 1, 1e-9)
			end
		end
	end)

	it("rejects bad arguments", function()
		throws(function()
			luck(0)
		end, "multiplier")
		throws(function()
			luck(2, { mode = "double" :: any })
		end, "mode")
	end)
end)

describe("entry modifiers", function()
	it("boostEntry multiplies a weight, including nested entries", function()
		local t = egg()
		near(t:chanceOf("Owl", { modifiers = { boostEntry("Owl", 2) } }), 20 / 110, 1e-12)
		near(t:chanceOf("Phoenix", { modifiers = { boostEntry("Legendaries", 11) } }), 5.5 / 110, 1e-12)
	end)

	it("exclude removes results, and nested ids remove everything inside", function()
		local t = egg()
		local m: Odds.OddsOptions = { modifiers = { exclude({ "Chick", "Legendaries" }) } }
		equal(t:chanceOf("Owl", m), 1)
		local rng = Odds.Pcg32.new(6)
		for _ = 1, 200 do
			equal(t:roll({ modifiers = m.modifiers, rng = rng }).id, "Owl")
		end
	end)

	it("onlyTags keeps results with any of the tags", function()
		local t = egg()
		local m: Odds.OddsOptions = { modifiers = { onlyTags({ "Fire" }) } }
		near(t:chanceOf("Phoenix", m), 0.5, 1e-12)
		equal(t:chanceOf("Chick", m), 0)
	end)

	it("raises an error when nothing is left to roll", function()
		throws(function()
			egg():roll({ modifiers = { exclude({ "Chick", "Owl", "Legendaries" }) } })
		end, "nothing that can be rolled")
	end)
end)

describe("custom modifiers and stacking", function()
	it("passes frozen weights and the rows", function()
		local sawFrozen, sawRows = false, false
		local m = custom(function(weights, context)
			sawFrozen = table.isfrozen(weights)
			sawRows = #context.rows == #weights and context.tableName == "Egg"
			local new = table.clone(weights)
			for i, row in context.rows do
				if row.id == "Owl" then
					new[i] = 0
				end
			end
			return new
		end)
		equal(egg():chanceOf("Owl", { modifiers = { m } }), 0)
		truthy(sawFrozen and sawRows)
	end)

	it("validates what the function returns", function()
		local bad = custom(function(_weights, _context)
			return { -1 }
		end)
		throws(function()
			egg():odds({ modifiers = { bad } })
		end, "one weight per row")
	end)

	it("runs entry modifiers before luck, whatever the list order", function()
		local t = egg()
		local a =
			t:chanceOf("Legendaries", { modifiers = { luck(2, { tiers = { "Legendary" } }), exclude({ "Owl" }) } })
		local b =
			t:chanceOf("Legendaries", { modifiers = { exclude({ "Owl" }), luck(2, { tiers = { "Legendary" } }) } })
		near(a, b, 1e-15)
		-- Exclude first: Legendaries is 1/90, then luck doubles it
		near(a, 2 / 90, 1e-12)
	end)

	it("shows each stage in odds()", function()
		local rows = egg():odds({ modifiers = { exclude({ "Owl" }), luck(2, { tiers = { "Legendary" } }) } })
		for _, row in rows do
			if row.id == "Phoenix" then
				near(row.stages.base, 0.005, 1e-12)
				near(row.stages.entry, 0.5 / 90, 1e-12)
				near(row.stages.luck, 1 / 90, 1e-12)
				near(row.stages.pity, row.chance, 0)
			end
		end
	end)

	it("caches keyed modifier sets but still rolls the same distribution", function()
		local t = egg()
		local m = { luck(2) }
		local a = t:rollMany(100, { modifiers = m, rng = Odds.Pcg32.new(8) })
		local b = t:rollMany(100, { modifiers = { luck(2) }, rng = Odds.Pcg32.new(8) })
		for i = 1, 100 do
			equal(a[i].id, b[i].id)
		end
	end)

	it("rejects things that aren't modifiers", function()
		throws(function()
			egg():roll({ modifiers = { 2 :: any } })
		end, "Odds.modifiers")
	end)
end)

return nil

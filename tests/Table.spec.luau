--!strict
local Odds = require("../src")
local Test = require("./lib/Test")

local describe, it, equal, near, truthy, throws =
	Test.describe, Test.it, Test.equal, Test.near, Test.truthy, Test.throws

local function basicEgg()
	return Odds.table({
		name = "BasicEgg",
		entries = {
			{ id = "Chick", weight = 700 },
			{ id = "Rooster", weight = 250 },
			{ id = "GoldenChicken", weight = 49, rarity = "Legendary" },
			{ id = "CosmicHen", weight = 1, tags = { "Mythic" } },
		},
	})
end

describe("Odds.table", function()
	it("reports chanceOf and oneIn from the weights", function()
		local egg = basicEgg()
		near(egg:chanceOf("Chick"), 0.7, 1e-12)
		near(egg:chanceOf("CosmicHen"), 0.001, 1e-12)
		near(egg:oneIn("CosmicHen"), 1000, 1e-9)
		equal(egg:chanceOf("Nope"), 0)
		equal(egg:oneIn("Nope"), math.huge)
	end)

	it("keeps entry metadata and tags, frozen", function()
		local egg = basicEgg()
		equal(egg.entries[3].rarity, "Legendary")
		equal((egg.entries[4].tags :: { string })[1], "Mythic")
		truthy(table.isfrozen(egg.entries[1]))
		truthy(table.isfrozen(egg))
	end)

	it("is not affected by changes to the definition after creation", function()
		local entries: { Odds.Entry } = { { id = "A", weight = 1 }, { id = "B", weight = 1 } }
		local t = Odds.table({ name = "T", entries = entries })
		entries[1].weight = 1000
		table.insert(entries, { id = "C", weight = 5 } :: Odds.Entry)
		near(t:chanceOf("A"), 0.5, 1e-12)
		equal(#t.entries, 2)
	end)

	it("returns frozen, reused results so rolling does not allocate", function()
		local egg = basicEgg()
		local first: { [string]: Odds.RollResult } = {}
		for _, result in egg:rollMany(5000, { rng = Odds.Pcg32.new(3) }) do
			truthy(table.isfrozen(result))
			local seen = first[result.id]
			if seen then
				truthy(rawequal(seen, result), "same object for the same outcome")
			else
				first[result.id] = result
			end
		end
	end)

	it("gives the same rolls for the same seed", function()
		local egg = basicEgg()
		local a = egg:rollMany(200, { rng = Odds.Pcg32.new(42) })
		local b = egg:rollMany(200, { rng = Odds.Pcg32.new(42) })
		for i = 1, 200 do
			equal(a[i].id, b[i].id)
		end
	end)

	it("uses the table's rng option by default", function()
		local a = Odds.table({ name = "A", entries = basicEgg().entries }, { rng = Odds.Pcg32.new(5) })
		local b = Odds.table({ name = "B", entries = basicEgg().entries }, { rng = Odds.Pcg32.new(5) })
		for _ = 1, 100 do
			equal(a:roll().id, b:roll().id)
		end
	end)

	it("accepts any object with NextNumber as rng", function()
		local fixed = {
			value = 0,
			NextNumber = function(self: any): number
				return self.value
			end,
		}
		local t = Odds.table({ name = "T", entries = { { id = "A", weight = 1 }, { id = "B", weight = 1 } } })
		fixed.value = 0.1
		equal(t:roll({ rng = fixed }).id, "A")
		fixed.value = 0.9
		equal(t:roll({ rng = fixed }).id, "B")
	end)

	it("rejects an rng without NextNumber", function()
		throws(function()
			basicEgg():roll({ rng = {} })
		end, "NextNumber")
	end)

	it("works with a single entry", function()
		local t = Odds.table({ name = "One", entries = { { id = "Only", weight = 3 } } })
		equal(t:roll().id, "Only")
		equal(t:chanceOf("Only"), 1)
	end)

	it("never rolls an entry with a weight of 0", function()
		local t = Odds.table({
			name = "Z",
			entries = { { id = "Off", weight = 0 }, { id = "On", weight = 1 }, { id = "Off2", weight = 0 } },
		})
		local rng = Odds.Pcg32.new(8)
		for _ = 1, 20000 do
			equal(t:roll({ rng = rng }).id, "On")
		end
		equal(t:oneIn("Off"), math.huge)
	end)

	it("rolls the requested number with rollMany", function()
		equal(#basicEgg():rollMany(10), 10)
		equal(#basicEgg():rollMany(0), 0)
		throws(function()
			basicEgg():rollMany(-1)
		end)
	end)
end)

describe("nested tables and tiers", function()
	local function premiumEgg()
		local Commons = Odds.table({
			name = "Commons",
			entries = { { id = "Chick", weight = 3 }, { id = "Duckling", weight = 1 } },
		})
		local Legendaries = Odds.table({
			name = "Legendaries",
			entries = {
				{ id = "Phoenix", weight = 1 },
				{ id = "GoldenGoose", weight = 1, tier = "Golden" },
			},
		})
		return Odds.table({
			name = "PremiumEgg",
			tiers = {
				Common = { order = 1 },
				Legendary = { order = 4, displayName = "LEGENDARY" },
			},
			entries = {
				{ id = "Commons", weight = 90, tier = "Common", table = Commons },
				{ id = "Legendaries", weight = 10, tier = "Legendary", table = Legendaries },
			},
		})
	end

	it("multiplies chances through nested tables", function()
		local egg = premiumEgg()
		near(egg:chanceOf("Chick"), 0.9 * 0.75, 1e-12)
		near(egg:chanceOf("Phoenix"), 0.05, 1e-12)
		near(egg:chanceOf("Legendaries"), 0.1, 1e-12)
		near(egg:oneIn("Phoenix"), 20, 1e-9)
	end)

	it("reports the path and inherits the tier from the parent entry", function()
		local egg = premiumEgg()
		local rng = Odds.Pcg32.new(11)
		local sawPhoenix, sawGoose = false, false
		for _ = 1, 2000 do
			local r = egg:roll({ rng = rng })
			equal(#r.path, 2)
			equal(r.path[2], r.id)
			if r.id == "Phoenix" then
				sawPhoenix = true
				equal(r.tier, "Legendary")
				equal(r.path[1], "Legendaries")
			elseif r.id == "GoldenGoose" then
				sawGoose = true
				equal(r.tier, "Golden", "innermost tier wins")
			elseif r.id == "Chick" then
				equal(r.tier, "Common")
			end
		end
		truthy(sawPhoenix and sawGoose)
	end)

	it("returns the same result objects from odds() and roll()", function()
		local egg = premiumEgg()
		local rows = egg:odds()
		local r = egg:roll({ rng = Odds.Pcg32.new(1) })
		local found = false
		for _, row in rows do
			if rawequal(row.path, r.path) then
				found = true
			end
		end
		truthy(found)
	end)

	it("lists odds rarest last, summing to 1", function()
		local rows = premiumEgg():odds()
		equal(#rows, 4)
		local sum = 0
		for i, row in rows do
			sum += row.chance
			near(row.oneIn, 1 / row.chance, 1e-9)
			if i > 1 then
				truthy(rows[i - 1].chance >= row.chance)
			end
		end
		near(sum, 1, 1e-12)
		equal(rows[1].id, "Chick")
		truthy(table.isfrozen(rows) and table.isfrozen(rows[1]))
	end)

	it("handles tables nested 10 levels deep", function()
		local t = Odds.table({ name = "L0", entries = { { id = "Leaf", weight = 1 }, { id = "Other", weight = 1 } } })
		for level = 1, 10 do
			t = Odds.table({
				name = `L{level}`,
				entries = { { id = `N{level}`, weight = 1, table = t }, { id = `Skip{level}`, weight = 1 } },
			})
		end
		near(t:chanceOf("Leaf"), 0.5 ^ 11, 1e-15)
		local r = nil
		local rng = Odds.Pcg32.new(4)
		repeat
			r = t:roll({ rng = rng })
		until r.id == "Leaf"
		equal(#r.path, 11)
	end)

	it("exposes tier display data", function()
		equal(premiumEgg().tiers.Legendary.displayName, "LEGENDARY")
	end)
end)

describe("errors and validate()", function()
	it("rejects broken definitions with a clear error", function()
		throws(function()
			Odds.table({ name = "Empty", entries = {} })
		end, "at least one entry")
		throws(function()
			Odds.table({ name = "", entries = { { id = "A", weight = 1 } } })
		end, "name")
		throws(function()
			Odds.table({ name = "Neg", entries = { { id = "A", weight = -1 } } })
		end, "finite number")
		throws(function()
			Odds.table({ name = "NaN", entries = { { id = "A", weight = 0 / 0 } } })
		end, "finite number")
		throws(function()
			Odds.table({ name = "Inf", entries = { { id = "A", weight = math.huge } } })
		end, "finite number")
		throws(function()
			Odds.table({ name = "NoId", entries = { { weight = 1 } :: any } })
		end, "id")
		throws(function()
			Odds.table({ name = "Zero", entries = { { id = "A", weight = 0 } } })
		end, "total weight")
		throws(function()
			Odds.table({ name = "Fake", entries = { { id = "A", weight = 1, table = {} :: any } } })
		end, "Odds.table")
	end)

	it("says to use ':' when a method is called with '.'", function()
		throws(function()
			(basicEgg().roll :: any)()
		end, "':'")
	end)

	it("passes a clean table", function()
		local ok, issues = basicEgg():validate()
		truthy(ok)
		equal(#issues, 0)
	end)

	it("reports duplicates, zero weights and tier typos, including in nested tables", function()
		local inner = Odds.table({
			name = "Inner",
			entries = { { id = "X", weight = 1 }, { id = "X", weight = 1 } },
		})
		local t = Odds.table({
			name = "Outer",
			tiers = { Common = {}, Legendary = {} },
			entries = {
				{ id = "A", weight = 1, tier = "Comon" },
				{ id = "B", weight = 0 },
				{ id = "Nested", weight = 1, table = inner },
			},
		})
		local ok, issues = t:validate()
		equal(ok, false)
		equal(#issues, 3)
		local text = table.concat(issues, "\n")
		truthy(string.find(text, `tier "Comon"`, 1, true), "tier typo")
		truthy(string.find(text, `"B" has a weight of 0`, 1, true), "zero weight")
		truthy(string.find(text, `"Outer" > Nested: duplicate id "X"`, 1, true), "nested duplicate")
	end)

	it("recognizes Odds tables with isTable", function()
		truthy(Odds.isTable(basicEgg()))
		equal(Odds.isTable({}), false)
		equal(Odds.isTable(nil), false)
	end)
end)

return nil

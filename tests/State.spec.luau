--!strict
local Odds = require("../src")
local Test = require("./lib/Test")

local describe, it, equal, truthy, throws = Test.describe, Test.it, Test.equal, Test.truthy, Test.throws

local function egg()
	return Odds.table({
		name = "Egg",
		tiers = { Common = { order = 1 }, Legendary = { order = 4 } },
		entries = {
			{ id = "Chick", weight = 99, tier = "Common" },
			{ id = "Phoenix", weight = 1, tier = "Legendary" },
		},
		pity = { { tier = "Legendary", hard = 50 } },
	})
end

describe("roller state", function()
	it("starts empty", function()
		local state = Odds.state()
		equal(state.version, 1)
		equal(state.rolls, 0)
		equal(next(state.pity), nil)
	end)

	it("never changes the state passed in, and returns a new one", function()
		local state = Odds.state()
		local _, newState = egg():roll({ state = state })
		equal(state.rolls, 0)
		equal(next(state.pity), nil)
		truthy(newState ~= nil and newState ~= state)
		equal((newState :: Odds.State).rolls, 1)
	end)

	it("returns no state when none was passed", function()
		local _, newState = egg():roll()
		equal(newState, nil)
		local _, manyState = egg():rollMany(3)
		equal(manyState, nil)
	end)

	it("counts every roll in rollMany", function()
		local results, state = egg():rollMany(10, { state = Odds.state(), rng = Odds.Pcg32.new(1) })
		equal(#results, 10)
		equal((state :: Odds.State).rolls, 10)
	end)

	it("round-trips through serialize and deserialize", function()
		local _, state = egg():rollMany(30, { state = Odds.state(), rng = Odds.Pcg32.new(2) })
		local data = Odds.serialize(state :: Odds.State)
		equal(data.v, 1)
		local restored = Odds.deserialize(data)
		equal(restored.rolls, 30)
		equal(restored.pity["Egg:Legendary"], (state :: Odds.State).pity["Egg:Legendary"])
	end)

	it("drops zero counters when serializing", function()
		local data = Odds.serialize({ version = 1, rolls = 5, pity = { A = 0, B = 3 } })
		equal(data.p.A, nil)
		equal(data.p.B, 3)
	end)

	it("treats nil as a new player", function()
		local state = Odds.deserialize(nil)
		equal(state.rolls, 0)
	end)

	it("rejects corrupt or newer data instead of resetting pity", function()
		throws(function()
			Odds.deserialize({ r = 1, p = {} })
		end, "version")
		throws(function()
			Odds.deserialize({ v = 99, r = 1, p = {} })
		end, "newer")
		throws(function()
			Odds.deserialize({ v = 1, r = -1, p = {} })
		end, "roll count")
		throws(function()
			Odds.deserialize({ v = 1, r = 1, p = { A = 1.5 } })
		end, "whole numbers")
		throws(function()
			Odds.deserialize("nope")
		end)
	end)

	it("rejects a state that isn't one", function()
		throws(function()
			egg():roll({ state = {} :: any })
		end, "state must come from")
	end)
end)

return nil

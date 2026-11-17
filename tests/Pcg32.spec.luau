--!strict
local Odds = require("../src")
local Test = require("./lib/Test")

local Pcg32 = Odds.Pcg32
local describe, it, equal, truthy, throws = Test.describe, Test.it, Test.equal, Test.truthy, Test.throws

describe("Pcg32", function()
	it("matches the reference pcg32 output for seed 42, stream 54", function()
		-- From the reference C implementation's pcg32-demo
		local expected = { 0xa15c02b7, 0x7b47f409, 0xba1d3330, 0x83d2f293, 0xbfa4784b, 0xcbed606e }
		local rng = Pcg32.new(42, 54)
		for i, value in expected do
			equal(rng:NextU32(), value, `output {i}`)
		end
	end)

	it("handles seeds near 2^53 exactly", function()
		-- Checked against a Python implementation using arbitrary-precision integers
		local rng = Pcg32.new(2 ^ 53 - 1, 7)
		equal(rng:NextU32(), 0xdd3f3886)
		equal(rng:NextU32(), 0x0129fc9e)
		equal(rng:NextU32(), 0x68a08ef2)
	end)

	it("gives the same sequence for the same seed and different ones otherwise", function()
		local a, b, c = Pcg32.new(123), Pcg32.new(123), Pcg32.new(124)
		local differs = false
		for _ = 1, 100 do
			local x = a:NextNumber()
			equal(x, b:NextNumber())
			if x ~= c:NextNumber() then
				differs = true
			end
		end
		truthy(differs, "different seeds differ")
	end)

	it("keeps NextNumber in [0, 1) and scales to a range", function()
		local rng = Pcg32.new(1)
		for _ = 1, 10000 do
			local x = rng:NextNumber()
			truthy(x >= 0 and x < 1, `{x} in range`)
			local y = rng:NextNumber(5, 10)
			truthy(y >= 5 and y < 10, `{y} in range`)
		end
	end)

	it("keeps NextInteger within bounds and hits every value", function()
		local rng = Pcg32.new(9)
		local seen = {}
		for _ = 1, 5000 do
			local x = rng:NextInteger(-3, 3)
			truthy(x >= -3 and x <= 3 and x % 1 == 0, `{x} in range`)
			seen[x] = true
		end
		for v = -3, 3 do
			truthy(seen[v], `saw {v}`)
		end
		equal(rng:NextInteger(7, 7), 7)
	end)

	it("continues the same sequence from Clone and from saved state", function()
		local rng = Pcg32.new(77)
		rng:NextU32()
		local clone = rng:Clone()
		local restored = Pcg32.fromState(rng:GetState())
		for _ = 1, 20 do
			local x = rng:NextU32()
			equal(clone:NextU32(), x)
			equal(restored:NextU32(), x)
		end
	end)

	it("rejects invalid seeds and state", function()
		throws(function()
			Pcg32.new(-1)
		end, "seed")
		throws(function()
			Pcg32.new(1.5)
		end, "seed")
		throws(function()
			Pcg32.new(0 / 0)
		end, "seed")
		throws(function()
			Pcg32.fromState({ 1, 2, 3 })
		end)
		throws(function()
			Pcg32.fromState({ 1, 2, 3, 4 })
		end, "odd")
	end)
end)

return nil

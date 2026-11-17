--!strict
--!native
--[=[
	@class Alias
	@private

	Vose's alias method. Building takes O(n) once; every sample afterwards is
	O(1) and uses a single random number, no matter how many entries there are.
]=]

export type Rng = { NextNumber: (self: any) -> number }

export type Alias = {
	n: number,
	prob: { number },
	alias: { number },
}

local Alias = {}

--[=[
	Builds an alias table from non-negative weights. At least one weight must be positive.
]=]
function Alias.build(weights: { number }): Alias
	local n = #weights
	local total = 0
	for i = 1, n do
		total += weights[i]
	end
	assert(n > 0 and total > 0, "Alias.build needs at least one positive weight")

	local prob = table.create(n, 0) :: { number }
	local alias = table.create(n, 0) :: { number }
	local scaled = table.create(n, 0) :: { number }
	local small: { number } = {}
	local large: { number } = {}

	for i = 1, n do
		local s = weights[i] * n / total
		scaled[i] = s
		if s < 1 then
			table.insert(small, i)
		else
			table.insert(large, i)
		end
	end

	while #small > 0 and #large > 0 do
		local l = table.remove(small) :: number
		local g = table.remove(large) :: number
		prob[l] = scaled[l]
		alias[l] = g
		scaled[g] = (scaled[g] + scaled[l]) - 1
		if scaled[g] < 1 then
			table.insert(small, g)
		else
			table.insert(large, g)
		end
	end

	-- Whatever is left is 1 up to floating point error
	for _, g in large do
		prob[g] = 1
		alias[g] = g
	end
	for _, l in small do
		prob[l] = 1
		alias[l] = l
	end

	-- A zero weight must never be picked, even through rounding
	local fallback = 1
	while weights[fallback] <= 0 do
		fallback += 1
	end
	for i = 1, n do
		if weights[i] == 0 then
			prob[i] = 0
			if alias[i] == i then
				alias[i] = fallback
			end
		end
	end

	return { n = n, prob = prob, alias = alias }
end

--[=[
	Returns a 1-based index, chosen with probability proportional to its weight.
]=]
function Alias.sample(self: Alias, rng: Rng): number
	local u = rng:NextNumber() * self.n
	local column = u // 1
	local i = column + 1
	if i > self.n then
		-- Only reachable if a custom rng returns 1, which it should never do
		i = self.n
	end
	if u - column < self.prob[i] then
		return i
	end
	return self.alias[i]
end

return Alias

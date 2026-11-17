--!strict
-- Statistics helpers for the roll-distribution tests.

local Stats = {}

-- Pearson's chi-square statistic for observed counts against expected probabilities
function Stats.chiSquare(observed: { number }, probabilities: { number }, total: number): number
	local sum = 0
	for i, p in probabilities do
		local expected = p * total
		local diff = observed[i] - expected
		sum += diff * diff / expected
	end
	return sum
end

-- Upper critical value of the chi-square distribution, using the Wilson–Hilferty
-- approximation. z = 3.719 is the one-sided normal quantile for p = 0.0001.
function Stats.chiSquareCritical(degreesOfFreedom: number, z: number?): number
	local k = degreesOfFreedom
	local q = z or 3.719
	local t = 1 - 2 / (9 * k) + q * math.sqrt(2 / (9 * k))
	return k * t * t * t
end

return Stats

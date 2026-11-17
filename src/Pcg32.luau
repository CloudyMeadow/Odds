--!strict
--!native
--[=[
	@class Pcg32

	A deterministic PCG32 (XSH RR) random number generator written in pure Luau.

	The same seed always produces the same sequence in Studio, in live servers
	and in Lune, independent of the engine's own `Random` implementation.
	It is fast and well distributed, but it is not cryptographically secure:
	never let a client see or choose a seed.

	Luau numbers are doubles, so the 64-bit state is kept as two 32-bit halves
	and multiplied with 16-bit limbs to stay exact.
]=]

local Pcg32 = {}
Pcg32.__index = Pcg32

export type Pcg32 = {
	NextU32: (self: Pcg32) -> number,
	NextNumber: (self: Pcg32, min: number?, max: number?) -> number,
	NextInteger: (self: Pcg32, min: number, max: number) -> number,
	Clone: (self: Pcg32) -> Pcg32,
	GetState: (self: Pcg32) -> { number },
}

type State = {
	_hi: number,
	_lo: number,
	_incHi: number,
	_incLo: number,
}

local TWO_16 = 0x10000
local TWO_32 = 0x100000000
local TWO_53 = 2 ^ 53

-- 6364136223846793005, the standard PCG 64-bit multiplier
local MUL_HI = 0x5851F42D
local MUL_LO = 0x4C957F2D

local DEFAULT_STREAM = 54

local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local rrotate = bit32.rrotate

-- (x * y) mod 2^32 for 32-bit unsigned x and y, exact in doubles
local function mulLow32(x: number, y: number): number
	local x0, x1 = x % TWO_16, x // TWO_16
	local y0, y1 = y % TWO_16, y // TWO_16
	local cross = (x1 * y0 + x0 * y1) % TWO_16
	return (x0 * y0 + cross * TWO_16) % TWO_32
end

-- Full 64-bit product of two 32-bit unsigned numbers, as (hi, lo)
local function mulFull32(x: number, y: number): (number, number)
	local x0, x1 = x % TWO_16, x // TWO_16
	local y0, y1 = y % TWO_16, y // TWO_16
	local mid = x0 * y1 + x1 * y0
	local lo = x0 * y0 + (mid % TWO_16) * TWO_16
	local hi = x1 * y1 + mid // TWO_16 + lo // TWO_32
	return hi % TWO_32, lo % TWO_32
end

-- state = state * MUL + inc (mod 2^64)
local function step(self: State)
	local hi, lo = self._hi, self._lo
	local pHi, pLo = mulFull32(lo, MUL_LO)
	pHi = (pHi + mulLow32(hi, MUL_LO) + mulLow32(lo, MUL_HI)) % TWO_32
	local newLo = pLo + self._incLo
	self._lo = newLo % TWO_32
	self._hi = (pHi + self._incHi + newLo // TWO_32) % TWO_32
end

local function split53(n: number, name: string): (number, number)
	assert(
		type(n) == "number" and n == n and n >= 0 and n < TWO_53 and n % 1 == 0,
		`{name} must be an integer from 0 to 2^53 - 1`
	)
	return (n // TWO_32) % TWO_32, n % TWO_32
end

--[=[
	Creates a generator. `seed` and `stream` are integers from 0 to 2^53 - 1.
	Different streams with the same seed give independent sequences.
]=]
function Pcg32.new(seed: number, stream: number?): Pcg32
	local seedHi, seedLo = split53(seed, "seed")
	local streamHi, streamLo = split53(stream or DEFAULT_STREAM, "stream")

	-- inc = (stream << 1) | 1, truncated to 64 bits
	local incHi = (lshift(streamHi, 1) + rshift(streamLo, 31)) % TWO_32
	local incLo = bor(lshift(streamLo, 1), 1)

	local self: State = { _hi = 0, _lo = 0, _incHi = incHi, _incLo = incLo }
	step(self)
	local lo = self._lo + seedLo
	self._lo = lo % TWO_32
	self._hi = (self._hi + seedHi + lo // TWO_32) % TWO_32
	step(self)
	return setmetatable(self, Pcg32) :: any
end

--[=[
	Returns the next raw 32-bit unsigned integer.
]=]
function Pcg32.NextU32(self: State): number
	local hi, lo = self._hi, self._lo
	step(self)
	-- xorshifted = uint32(((old >> 18) ^ old) >> 27)
	local xHi = bxor(hi, rshift(hi, 18))
	local xLo = bxor(lo, bor(rshift(lo, 18), lshift(hi, 14)))
	local xorshifted = bor(rshift(xLo, 27), lshift(xHi, 5))
	-- rot = old >> 59
	return rrotate(xorshifted, rshift(hi, 27))
end

--[=[
	Matches `Random:NextNumber`. With no arguments it returns a number in
	[0, 1) with 53 bits of precision, enough for odds far rarer than 1 in a billion.
]=]
function Pcg32.NextNumber(self: Pcg32, min: number?, max: number?): number
	local a = rshift(self:NextU32(), 5) -- 27 bits
	local b = rshift(self:NextU32(), 6) -- 26 bits
	local u = (a * 67108864 + b) / TWO_53
	if min == nil and max == nil then
		return u
	end
	local lo = min or 0
	local hi = max or 1
	return lo + u * (hi - lo)
end

--[=[
	Matches `Random:NextInteger`. Returns a uniformly distributed integer in
	[min, max], without modulo bias. The range may hold at most 2^32 values.
]=]
function Pcg32.NextInteger(self: Pcg32, min: number, max: number): number
	assert(min % 1 == 0 and max % 1 == 0 and max >= min, "NextInteger expects integers with min <= max")
	local range = max - min + 1
	assert(range <= TWO_32, "NextInteger range must hold at most 2^32 values")
	-- Rejection sampling: discard the low values that would bias the result
	local threshold = (TWO_32 - range) % range
	while true do
		local r = self:NextU32()
		if r >= threshold then
			return min + r % range
		end
	end
end

--[=[
	Returns an independent copy that continues the same sequence.
]=]
function Pcg32.Clone(self: State): Pcg32
	return setmetatable({ _hi = self._hi, _lo = self._lo, _incHi = self._incHi, _incLo = self._incLo }, Pcg32) :: any
end

--[=[
	Returns the generator's position as plain data, safe to save and to pass to `fromState`.
]=]
function Pcg32.GetState(self: State): { number }
	return { self._hi, self._lo, self._incHi, self._incLo }
end

--[=[
	Recreates a generator from `GetState` data.
]=]
function Pcg32.fromState(data: { number }): Pcg32
	assert(type(data) == "table" and #data == 4, "fromState expects the array returned by GetState")
	for i = 1, 4 do
		local v = data[i]
		assert(
			type(v) == "number" and v >= 0 and v < TWO_32 and v % 1 == 0,
			"fromState expects 32-bit unsigned integers"
		)
	end
	assert(band(data[4], 1) == 1, "fromState: the stream increment must be odd")
	return setmetatable({ _hi = data[1], _lo = data[2], _incHi = data[3], _incLo = data[4] }, Pcg32) :: any
end

return Pcg32

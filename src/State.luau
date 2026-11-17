--!strict
--[=[
	@class State

	Per-player roller data: pity counters and a roll count. Tables are shared by
	every player; state is not. Keep one state per player (or per player and pity
	group) in your player data.

	Odds never changes a state you pass in. `roll` and `rollMany` return a new state
	instead, so a failed save can't leave counters half-updated. Treat states as
	read-only and replace the whole value when you get a new one.
]=]

--[=[
	@interface State
	@within State
	.version number -- format version, for safe upgrades
	.rolls number -- total rolls made with this state
	.pity { [string]: number } -- rolls since the last hit, per pity counter
]=]
export type State = {
	version: number,
	rolls: number,
	pity: { [string]: number },
}

local VERSION = 1

local State = {}

local function isCount(value: any): boolean
	return type(value) == "number" and value >= 0 and value % 1 == 0 and value < math.huge
end

--[=[
	@within Odds
	@function state
	@return State

	Creates an empty roller state.
]=]
function State.new(): State
	return { version = VERSION, rolls = 0, pity = {} }
end

function State.check(state: any, where: string): State
	assert(
		type(state) == "table" and type(state.pity) == "table" and isCount(state.rolls),
		`{where}: state must come from Odds.state() or Odds.deserialize()`
	)
	return state
end

--[=[
	@within Odds
	@function serialize
	@param state State
	@return { v: number, r: number, p: { [string]: number } }

	Turns a state into compact, versioned plain data that is safe to store in a DataStore.
]=]
function State.serialize(state: State): { v: number, r: number, p: { [string]: number } }
	State.check(state, "Odds.serialize")
	local pity: { [string]: number } = {}
	for key, count in state.pity do
		if count > 0 then
			pity[key :: string] = count :: number
		end
	end
	return { v = VERSION, r = state.rolls, p = pity }
end

--[=[
	@within Odds
	@function deserialize
	@param data any
	@return State

	Reads data from `serialize`. Passing nil (a new player) returns an empty state.
	Corrupt values raise an error instead of silently resetting someone's pity.
]=]
function State.deserialize(input: any): State
	local data: any = input
	if data == nil then
		return State.new()
	end
	assert(type(data) == "table", "Odds.deserialize expects the table returned by Odds.serialize")
	local version = data.v
	assert(type(version) == "number", "Odds.deserialize: missing format version")
	assert(version <= VERSION, `Odds.deserialize: data is format {version}, newer than this version of Odds supports`)
	-- Future format changes migrate older versions here.
	assert(isCount(data.r), "Odds.deserialize: roll count must be a whole number of 0 or more")
	assert(type(data.p) == "table", "Odds.deserialize: pity counters are missing")
	local pity: { [string]: number } = {}
	for key, count in data.p do
		assert(type(key) == "string" and isCount(count), "Odds.deserialize: pity counters must be whole numbers")
		pity[key :: string] = count :: number
	end
	return { version = VERSION, rolls = data.r :: number, pity = pity }
end

return State

--!strict
--!native
--[=[
	@class Modifiers

	Modifiers reshape a table's odds for one roll without changing the table.
	Pass them in `roll`, `rollMany`, `odds`, `chanceOf` and `oneIn` options:

	```lua
	local luck = Odds.modifiers.luck(2)
	local result, newState = PremiumEgg:roll({ state = state, modifiers = { luck } })
	```

	They run in a fixed order, whatever order you list them in:

	1. the table's own weights
	2. entry modifiers: `boostEntry`, `exclude`, `onlyTags` and `custom` (by default)
	3. tier and luck modifiers: `luck`, and `custom` with `stage = "tier"`
	4. pity, from the roller state
	5. the final pick

	Within a stage, modifiers apply in the order listed.
]=]

--[=[
	@interface ModifierRow
	@within Modifiers
	.id string -- the final entry's id
	.path { string } -- ids from the outermost entry to the final one
	.tier string? -- the result's tier
	.tierOrder number? -- that tier's `order`, if the table declares one
	.tags { string } -- the final entry's tags
	.entry Entry -- the final entry

	One possible result, as modifiers see it. Row `i` matches weight `i`.
]=]
export type ModifierRow = {
	id: string,
	path: { string },
	tier: string?,
	tierOrder: number?,
	tags: { string },
	entry: any,
}

--[=[
	@interface ModifierContext
	@within Modifiers
	.rows { ModifierRow }
	.tableName string
]=]
export type ModifierContext = {
	rows: { ModifierRow },
	tableName: string,
}

export type Stage = "entry" | "tier"

--[=[
	@interface Modifier
	@within Modifiers
	.kind string -- "luck", "boostEntry", "exclude", "onlyTags" or "custom"
	.stage "entry" | "tier"
	.key string? -- identifies the modifier for caching; nil means "never cache"
	.apply (weights: { number }, context: ModifierContext) -> { number }
]=]
export type Modifier = {
	kind: string,
	stage: Stage,
	key: string?,
	apply: (weights: { number }, context: ModifierContext) -> { number },
}

export type LuckMode = "weight" | "chance" | "rolls"

--[=[
	@interface LuckOptions
	@within Modifiers
	.tiers { string }? -- which tiers count as lucky; see `luck`
	.mode ("weight" | "chance" | "rolls")? -- defaults to "chance"
]=]
export type LuckOptions = {
	tiers: { string }?,
	mode: LuckMode?,
}

--[=[
	@interface CustomOptions
	@within Modifiers
	.stage ("entry" | "tier")? -- defaults to "entry"
	.key string? -- give one to let Odds cache the result; it must change whenever fn's behaviour does
]=]
export type CustomOptions = {
	stage: Stage?,
	key: string?,
}

local Modifiers = {}

local function freezeModifier(modifier: Modifier): Modifier
	return table.freeze(modifier :: any) :: any
end

local function checkMultiplier(mult: any, name: string)
	assert(
		type(mult) == "number" and mult == mult and mult > 0 and mult < math.huge,
		`{name} expects a finite multiplier above 0 (got {tostring(mult)})`
	)
end

local function stringList(list: any, name: string): { string }
	assert(type(list) == "table", `{name} expects an array of strings`)
	local copy: { string } = {}
	for _, value in list do
		assert(type(value) == "string", `{name} expects an array of strings`)
		table.insert(copy, value)
	end
	table.sort(copy)
	return copy
end

local function pathContainsAny(path: { string }, set: { [string]: boolean }): boolean
	for _, id in path do
		if set[id] then
			return true
		end
	end
	return false
end

local function toSet(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, value in list do
		set[value] = true
	end
	return set
end

-- The rows that luck boosts when no tiers are named: every tier above the
-- table's lowest `order`, or, without ordered tiers, everything but the most common result.
local function defaultLuckTargets(weights: { number }, rows: { ModifierRow }): { boolean }
	local lowest = math.huge
	for _, row in rows do
		if row.tierOrder ~= nil and row.tierOrder < lowest then
			lowest = row.tierOrder
		end
	end
	local targets = table.create(#rows, false) :: { boolean }
	if lowest < math.huge then
		for i, row in rows do
			targets[i] = row.tierOrder ~= nil and row.tierOrder > lowest
		end
	else
		local most = 0
		for _, w in weights do
			most = math.max(most, w)
		end
		for i, w in weights do
			targets[i] = w < most
		end
	end
	return targets
end

--[=[
	Rescales `weights` so the rows in `targets` hold `share` of the total (0 to 1) and the
	others hold the rest, keeping proportions inside each group. Returns a new array.
	Used by luck's "chance" mode and by pity.
]=]
function Modifiers.setShare(weights: { number }, targets: { boolean }, share: number): { number }
	local total, inside = 0, 0
	for i, w in weights do
		total += w
		if targets[i] then
			inside += w
		end
	end
	local result = table.clone(weights)
	if total <= 0 or inside <= 0 then
		return result
	end
	local outside = total - inside
	share = math.clamp(share, 0, 1)
	if outside <= 0 then
		return result
	end
	local inScale = share * total / inside
	local outScale = (1 - share) * total / outside
	for i, w in weights do
		result[i] = w * (if targets[i] then inScale else outScale)
	end
	return result
end

--[=[
	Makes the lucky tiers more likely.

	`tiers` names the tiers that count as lucky. Without it, luck applies to every tier
	above the table's lowest `order` (everything but Common, say), or, in a table without
	ordered tiers, to everything but the most common result.

	The `mode` decides what "2x" means:

	| Mode | How it works | Effect of `luck(2)` on a 1% tier |
	| --- | --- | --- |
	| `"chance"` (default) | Multiplies the lucky tiers' combined chance by `mult`, taking the extra from the others. Capped at 100%. | exactly 2% |
	| `"weight"` | Multiplies the lucky tiers' weights, then renormalizes. | about 1.98% |
	| `"rolls"` | Rolls `mult` times and keeps the rarest result. `mult` must be a whole number and `tiers` is ignored. | about 1.99%, and much stronger for the rarest items |

	`mult` below 1 makes the lucky tiers rarer ("bad luck").
]=]
function Modifiers.luck(mult: number, options: LuckOptions?): Modifier
	checkMultiplier(mult, "Odds.modifiers.luck")
	local mode: LuckMode = (options and options.mode) or "chance"
	assert(
		mode == "chance" or mode == "weight" or mode == "rolls",
		`Odds.modifiers.luck mode must be "chance", "weight" or "rolls" (got {tostring(mode)})`
	)
	local tierList = if options and options.tiers then stringList(options.tiers, "Odds.modifiers.luck tiers") else nil
	local tierSet = if tierList then toSet(tierList) else nil

	if mode == "rolls" then
		assert(mult % 1 == 0, `Odds.modifiers.luck mode "rolls" needs a whole number of rolls (got {mult})`)
		local k = mult
		return freezeModifier({
			kind = "luck",
			stage = "tier",
			key = `luck|rolls|{k}`,
			apply = function(weights: { number }, _context: ModifierContext): { number }
				-- Exact distribution of "the rarest of k rolls": sort from most to least
				-- likely, then P(best = i) = C_i^k - C_(i-1)^k with C the cumulative chance.
				local n = #weights
				local total = 0
				for _, w in weights do
					total += w
				end
				local order = table.create(n, 0) :: { number }
				for i = 1, n do
					order[i] = i
				end
				table.sort(order, function(a: number, b: number): boolean
					if weights[a] ~= weights[b] then
						return weights[a] > weights[b]
					end
					return a < b
				end)
				local result = table.create(n, 0) :: { number }
				local cumulative, previous = 0, 0
				for _, i in order do
					cumulative += weights[i] / total
					local power = math.min(cumulative, 1) ^ k
					result[i] = math.max(power - previous, 0)
					previous = power
				end
				return result
			end,
		})
	end

	local tierKey = if tierList then table.concat(tierList, ",") else "*"
	return freezeModifier({
		kind = "luck",
		stage = "tier",
		key = `luck|{mode}|{mult}|{tierKey}`,
		apply = function(weights: { number }, context: ModifierContext): { number }
			local targets: { boolean }
			if tierSet then
				targets = table.create(#weights, false) :: { boolean }
				for i, row in context.rows do
					targets[i] = row.tier ~= nil and tierSet[row.tier] == true
				end
			else
				targets = defaultLuckTargets(weights, context.rows)
			end

			if mode == "weight" then
				local result = table.clone(weights)
				for i, isTarget in targets do
					if isTarget then
						result[i] *= mult
					end
				end
				return result
			end

			local total, inside = 0, 0
			for i, w in weights do
				total += w
				if targets[i] then
					inside += w
				end
			end
			if total <= 0 or inside <= 0 then
				return table.clone(weights)
			end
			return Modifiers.setShare(weights, targets, math.min(1, inside / total * mult))
		end,
	})
end

--[=[
	Multiplies the weight of `id` by `mult`. `id` can be a final entry or a nested
	entry such as "Legendaries", which boosts everything inside it.
]=]
function Modifiers.boostEntry(id: string, mult: number): Modifier
	assert(type(id) == "string", "Odds.modifiers.boostEntry expects an id string")
	checkMultiplier(mult, "Odds.modifiers.boostEntry")
	return freezeModifier({
		kind = "boostEntry",
		stage = "entry",
		key = `boostEntry|{id}|{mult}`,
		apply = function(weights: { number }, context: ModifierContext): { number }
			local result = table.clone(weights)
			local set = { [id] = true }
			for i, row in context.rows do
				if pathContainsAny(row.path, set) then
					result[i] *= mult
				end
			end
			return result
		end,
	})
end

--[=[
	Removes the given ids from this roll, for example to prevent duplicates.
	Nested entry ids remove everything inside them.
]=]
function Modifiers.exclude(ids: { string }): Modifier
	local list = stringList(ids, "Odds.modifiers.exclude")
	local set = toSet(list)
	return freezeModifier({
		kind = "exclude",
		stage = "entry",
		key = `exclude|{table.concat(list, ",")}`,
		apply = function(weights: { number }, context: ModifierContext): { number }
			local result = table.clone(weights)
			for i, row in context.rows do
				if pathContainsAny(row.path, set) then
					result[i] = 0
				end
			end
			return result
		end,
	})
end

--[=[
	Keeps only results whose final entry has at least one of `tags`.
]=]
function Modifiers.onlyTags(tags: { string }): Modifier
	local list = stringList(tags, "Odds.modifiers.onlyTags")
	local set = toSet(list)
	return freezeModifier({
		kind = "onlyTags",
		stage = "entry",
		key = `onlyTags|{table.concat(list, ",")}`,
		apply = function(weights: { number }, context: ModifierContext): { number }
			local result = table.clone(weights)
			for i, row in context.rows do
				local keep = false
				for _, tag in row.tags do
					if set[tag] then
						keep = true
						break
					end
				end
				if not keep then
					result[i] = 0
				end
			end
			return result
		end,
	})
end

--[=[
	Wraps your own function as a modifier. `fn` receives a frozen copy of the current
	weights (one per possible result, matching `context.rows`) and returns new ones.

	```lua
	local nightBoost = Odds.modifiers.custom(function(weights, context)
		local new = table.clone(weights)
		for i, row in context.rows do
			if row.entry.night then
				new[i] *= 3
			end
		end
		return new
	end, { key = "nightBoost" })
	```
]=]
function Modifiers.custom(
	fn: (weights: { number }, context: ModifierContext) -> { number },
	options: CustomOptions?
): Modifier
	assert(type(fn) == "function", "Odds.modifiers.custom expects a function")
	local stage: Stage = (options and options.stage) or "entry"
	assert(stage == "entry" or stage == "tier", `Odds.modifiers.custom stage must be "entry" or "tier"`)
	local key = options and options.key
	assert(key == nil or type(key) == "string", "Odds.modifiers.custom key must be a string")
	return freezeModifier({
		kind = "custom",
		stage = stage,
		key = if key then `custom|{key}` else nil,
		apply = function(weights: { number }, context: ModifierContext): { number }
			local result = fn(table.freeze(table.clone(weights)), context)
			assert(type(result) == "table" and #result == #weights, "custom modifier must return one weight per row")
			for _, w in result do
				assert(
					type(w) == "number" and w == w and w >= 0 and w < math.huge,
					"custom modifier weights must be finite numbers of 0 or more"
				)
			end
			return result
		end,
	})
end

return Modifiers

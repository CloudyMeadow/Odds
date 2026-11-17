--!strict
--!native
--[=[
	@class Table

	An immutable loot table: a list of weighted entries, optionally with rarity
	tiers, nested tables and pity rules. Create one with `Odds.table`.
]=]

local Alias = require("./Alias")
local Environment = require("./Environment")
local Modifiers = require("./Modifiers")
local Pcg32 = require("./Pcg32")
local Pity = require("./Pity")
local StateModule = require("./State")

type Modifier = Modifiers.Modifier
type ModifierRow = Modifiers.ModifierRow
type ModifierContext = Modifiers.ModifierContext
type State = StateModule.State
export type PityDefinition = Pity.PityDefinition

--[=[
	@interface Rng
	@within Table
	.NextNumber (self) -> number -- returns a number in [0, 1)

	Any random source. `Random.new()` and `Odds.Pcg32.new(seed)` both fit.
]=]
export type Rng = Alias.Rng

-- Options accept `any` for rng on purpose. Both Luau type solvers reject some valid
-- sources (Pcg32, custom objects with extra fields) against a stricter type, and a
-- false type error is worse than none. The value is checked at runtime instead.
type RngSource = any

--[=[
	@interface TierInfo
	@within Table
	.order number? -- rarity rank: higher is rarer (Common = 1, Legendary = 4)
	.color Color3? -- display color for your UI
	.displayName string? -- shown instead of the tier's key

	Display data for a rarity tier. Extra fields are kept, so you can store anything your UI needs.
	`order` also decides which tiers count as "better" for pity and which are lucky by default.
]=]
export type TierInfo = {
	order: number?,
	color: any,
	displayName: string?,
	[string]: any,
}

--[=[
	@interface Entry
	@within Table
	.id string -- unique within its table
	.weight number -- relative chance, 0 or more
	.tier string? -- rarity tier name
	.tags { string }? -- free-form labels
	.table Table? -- roll this table when the entry is picked

	One possible result. Any other fields (such as `rarity` or `image`) are kept as metadata.
]=]
export type Entry = {
	id: string,
	weight: number,
	tier: string?,
	tags: { string }?,
	table: Table?,
	[string]: any,
}

--[=[
	@interface TableDefinition
	@within Table
	.name string
	.entries { Entry }
	.tiers { [string]: TierInfo }?
	.pity { PityDefinition }? -- see the Pity section of the README
	.pityGroup string? -- tables with the same group share pity counters; defaults to the table's name
]=]
export type TableDefinition = {
	name: string,
	entries: { Entry },
	tiers: { [string]: TierInfo }?,
	pity: { PityDefinition }?,
	pityGroup: string?,
}

--[=[
	@interface TableOptions
	@within Table
	.rng Rng? -- the default random source for this table's rolls
]=]
export type TableOptions = {
	rng: RngSource?,
}

--[=[
	@interface RollOptions
	@within Table
	.rng Rng? -- overrides the table's random source for this roll
	.state State? -- the player's roller state; needed for pity
	.modifiers { Modifier }? -- luck, boosts and filters for this roll
]=]
export type RollOptions = {
	rng: RngSource?,
	state: State?,
	modifiers: { Modifier }?,
}

--[=[
	@interface OddsOptions
	@within Table
	.state State? -- include pity for the player's next roll
	.modifiers { Modifier }?
]=]
export type OddsOptions = {
	state: State?,
	modifiers: { Modifier }?,
}

--[=[
	@interface RollResult
	@within Table
	.id string -- the id of the final (innermost) entry
	.entry Entry -- the final entry itself, frozen
	.tier string? -- the innermost tier declared along the path
	.path { string } -- ids from the outermost entry to the final one
	.pityTriggered boolean -- true when a hard pity guarantee decided this roll

	Results are frozen and reused, so rolling does not allocate. Compare results by `id`.
]=]
export type RollResult = {
	id: string,
	entry: Entry,
	tier: string?,
	path: { string },
	pityTriggered: boolean,
}

--[=[
	@interface OddsStages
	@within Table
	.base number -- from the table's weights alone
	.entry number -- after entry modifiers (boostEntry, exclude, onlyTags, custom)
	.luck number -- after tier and luck modifiers
	.pity number -- after pity; this is the final chance

	Each stage's chance from 0 to 1. Use it to debug "why is this item so rare?"
]=]
export type OddsStages = {
	base: number,
	entry: number,
	luck: number,
	pity: number,
}

--[=[
	@interface OddsRow
	@within Table
	.id string
	.entry Entry
	.tier string?
	.path { string }
	.chance number -- final probability from 0 to 1
	.oneIn number -- 1 / chance, or math.huge when the chance is 0
	.stages OddsStages -- the chance after each step of the stacking order
]=]
export type OddsRow = {
	id: string,
	entry: Entry,
	tier: string?,
	path: { string },
	chance: number,
	oneIn: number,
	stages: OddsStages,
}

export type Table = {
	name: string,
	entries: { Entry },
	tiers: { [string]: TierInfo },

	roll: (self: Table, options: RollOptions?) -> (RollResult, State?),
	rollMany: (self: Table, count: number, options: RollOptions?) -> ({ RollResult }, State?),
	chanceOf: (self: Table, id: string, options: OddsOptions?) -> number,
	oneIn: (self: Table, id: string, options: OddsOptions?) -> number,
	odds: (self: Table, options: OddsOptions?) -> { OddsRow },
	validate: (self: Table) -> (boolean, { string }),
}

type FlatItem = {
	result: RollResult,
	chance: number,
}

-- Weights ready for O(log n) picking with a binary search
type Prepared = {
	weights: { number },
	cumulative: { number },
	total: number,
	lastPositive: number,
}

type Internal = {
	name: string,
	rng: Rng,
	alias: Alias.Alias,
	-- Per entry index: the frozen result for a leaf entry, nil for a nested one
	leafResults: { [number]: RollResult },
	-- Per entry index: the nested table for a nested entry
	children: { [number]: Table },
	-- Per nested entry index: child result -> this table's frozen result for it
	wrapCache: { [number]: { [RollResult]: RollResult } },
	-- Every distinct result this table can produce, with its chance
	flat: { FlatItem },
	-- The same results as modifiers see them, and each result's position in flat
	context: ModifierContext,
	indexOf: { [RollResult]: number },
	-- Lazily built copies of results with pityTriggered = true
	pityResults: { [number]: RollResult },
	base: Prepared,
	-- Pity cells for each set of pre-pity weights
	partitions: { [Prepared]: Pity.Partition },
	modifierCache: { [string]: Prepared },
	modifierCacheSize: number,
	pityRules: { Pity.Rule },
	-- Tier orders from this table and every nested table (this table wins on conflict)
	tierOrders: { [string]: number },
	chanceById: { [string]: number },
	odds: { OddsRow }?,
	depth: number,
}

local MAX_DEPTH = 32
local MAX_CACHED_MODIFIER_SETS = 64
local EMPTY_TAGS: { string } = table.freeze({}) :: any
local NO_MODIFIERS: { Modifier } = table.freeze({}) :: any

local TableMethods = {}
local TableMetatable = { __index = TableMethods }

-- Private state lives outside the public object so the object can be frozen
local internals: { [Table]: Internal } = setmetatable({}, { __mode = "k" }) :: any

-- table.freeze, typed to keep the original (writable) type so results match the public types
local function freeze<T>(value: T): T
	return table.freeze(value :: any) :: any
end

local function getInternal(self: Table): Internal
	local internal = internals[self]
	assert(internal, "Expected an Odds table. Call methods with ':' (for example BasicEgg:roll())")
	return internal
end

local function isTable(value: any): boolean
	return type(value) == "table" and internals[value] ~= nil
end

local defaultRng: Rng = Pcg32.new((os.time() * 1048576 + math.random(0, 1048575)) % 2 ^ 53, math.random(0, 2147483647))

local function checkRng(rng: any, where: string): Rng
	assert(
		(type(rng) == "table" or type(rng) == "userdata") and rng.NextNumber ~= nil,
		`{where}: rng must have a NextNumber method, such as Random.new() or Odds.Pcg32.new(seed)`
	)
	return rng
end

local function checkModifiers(modifiers: any, where: string): { Modifier }
	if modifiers == nil then
		return NO_MODIFIERS
	end
	assert(type(modifiers) == "table", `{where}: modifiers must be an array of Odds.modifiers`)
	for _, modifier in modifiers do
		assert(
			type(modifier) == "table" and type(modifier.apply) == "function",
			`{where}: modifiers must be created with Odds.modifiers (luck, boostEntry, exclude, onlyTags or custom)`
		)
	end
	return modifiers
end

local function makeLeafResult(entry: Entry): RollResult
	return freeze({
		id = entry.id,
		entry = entry,
		tier = entry.tier,
		path = freeze({ entry.id }),
		pityTriggered = false,
	})
end

local function wrapResult(internal: Internal, index: number, parent: Entry, child: RollResult): RollResult
	local cache = internal.wrapCache[index]
	local existing: RollResult? = cache[child]
	if existing then
		return existing
	end
	local path = table.create(#child.path + 1) :: { string }
	path[1] = parent.id
	for i, id in child.path do
		path[i + 1] = id
	end
	local wrapped: RollResult = freeze({
		id = child.id,
		entry = child.entry,
		tier = if child.tier ~= nil then child.tier else parent.tier,
		path = freeze(path),
		pityTriggered = false,
	})
	cache[child] = wrapped
	return wrapped
end

local function checkEntry(raw: any, index: number, tableName: string): Entry
	local where = `Odds.table "{tableName}" entry #{index}`
	assert(type(raw) == "table", `{where} must be a table`)
	assert(type(raw.id) == "string" and raw.id ~= "", `{where} needs a non-empty string id`)
	where = `Odds.table "{tableName}" entry "{raw.id}"`
	local weight = raw.weight
	assert(type(weight) == "number", `{where} needs a number weight`)
	assert(
		weight == weight and weight >= 0 and weight < math.huge,
		`{where} weight must be a finite number of 0 or more (got {weight})`
	)
	assert(raw.tier == nil or type(raw.tier) == "string", `{where} tier must be a string`)
	assert(raw.table == nil or isTable(raw.table), `{where} table must be a table created with Odds.table`)

	local entry: Entry = table.clone(raw)
	if raw.tags ~= nil then
		assert(type(raw.tags) == "table", `{where} tags must be an array of strings`)
		for _, tag in raw.tags do
			assert(type(tag) == "string", `{where} tags must be an array of strings`)
		end
		entry.tags = freeze(table.clone(raw.tags :: { string }))
	end
	return freeze(entry)
end

local function prepare(weights: { number }, where: string): Prepared
	local n = #weights
	local cumulative = table.create(n, 0) :: { number }
	local total = 0
	local lastPositive = 0
	for i = 1, n do
		local w = weights[i]
		if w > 0 then
			total += w
			lastPositive = i
		end
		cumulative[i] = total
	end
	assert(total > 0 and total < math.huge, `{where}: the modifiers left nothing that can be rolled`)
	return { weights = weights, cumulative = cumulative, total = total, lastPositive = lastPositive }
end

local function pick(prepared: Prepared, rng: Rng): number
	local u = rng:NextNumber() * prepared.total
	local cumulative = prepared.cumulative
	local lo, hi = 1, prepared.lastPositive
	while lo < hi do
		local mid = (lo + hi) // 2
		if cumulative[mid] > u then
			hi = mid
		else
			lo = mid + 1
		end
	end
	return lo
end

-- Runs the entry stage, then the tier stage. Returns the weights after each.
local function applyModifiers(internal: Internal, modifiers: { Modifier }): ({ number }, { number })
	local weights = internal.base.weights
	for _, modifier in modifiers do
		if modifier.stage ~= "tier" then
			weights = modifier.apply(weights, internal.context)
		end
	end
	local afterEntry = weights
	for _, modifier in modifiers do
		if modifier.stage == "tier" then
			weights = modifier.apply(weights, internal.context)
		end
	end
	return afterEntry, weights
end

-- The weights after all modifiers (before pity), cached when every modifier has a key
local function prepared(internal: Internal, modifiers: { Modifier }): Prepared
	if #modifiers == 0 then
		return internal.base
	end
	local keys = table.create(#modifiers) :: { string }
	local cacheable = true
	for i, modifier in modifiers do
		local key = modifier.key
		if key == nil then
			cacheable = false
			break
		end
		keys[i] = key
	end
	local cacheKey = if cacheable then table.concat(keys, "\0") else nil
	if cacheKey then
		local hit = internal.modifierCache[cacheKey]
		if hit then
			return hit
		end
	end
	local _, weights = applyModifiers(internal, modifiers)
	local result = prepare(weights, `Odds table "{internal.name}"`)
	if cacheKey then
		if internal.modifierCacheSize >= MAX_CACHED_MODIFIER_SETS then
			table.clear(internal.modifierCache)
			internal.modifierCacheSize = 0
		end
		internal.modifierCache[cacheKey] = result
		internal.modifierCacheSize += 1
	end
	return result
end

local function pityResult(internal: Internal, index: number): RollResult
	local existing = internal.pityResults[index]
	if existing then
		return existing
	end
	local base = internal.flat[index].result
	local result: RollResult = freeze({
		id = base.id,
		entry = base.entry,
		tier = base.tier,
		path = base.path,
		pityTriggered = true,
	})
	internal.pityResults[index] = result
	internal.indexOf[result] = index
	return result
end

local function rollWith(self: Table, rng: Rng): RollResult
	local internal = internals[self]
	local index = Alias.sample(internal.alias, rng)
	local leaf = internal.leafResults[index]
	if leaf then
		return leaf
	end
	local child = rollWith(internal.children[index], rng)
	return wrapResult(internal, index, self.entries[index], child)
end

-- Picks a row under active pity: choose a cell by its adjusted mass, then a row inside it
local function pickWithPity(
	partition: Pity.Partition,
	cellWeights: { number },
	cellForced: { boolean }?,
	rng: Rng
): (number, boolean)
	local total = 0
	for _, w in cellWeights do
		total += w
	end
	assert(total > 0, "Odds: nothing can be rolled")
	local u = rng:NextNumber() * total
	local cell = 0
	for c, w in cellWeights do
		if w > 0 then
			cell = c
			if u < w then
				break
			end
			u -= w
		end
	end
	-- Map the leftover onto the cell's original weights
	local cumulative = partition.cumulative[cell]
	local target = math.min(u / cellWeights[cell], 1) * partition.totals[cell]
	local lo, hi = 1, #cumulative
	while lo < hi do
		local mid = (lo + hi) // 2
		if cumulative[mid] > target then
			hi = mid
		else
			lo = mid + 1
		end
	end
	return partition.rows[cell][lo], cellForced ~= nil and cellForced[cell] == true
end

local function rollOnce(self: Table, internal: Internal, rng: Rng, modifiers: { Modifier }, state: State?): RollResult
	if state ~= nil and #internal.pityRules > 0 then
		local pre = prepared(internal, modifiers)
		local partition = internal.partitions[pre]
		if partition == nil then
			partition = Pity.partition(pre.weights, internal.pityRules)
			internal.partitions[pre] = partition
		end
		local cellWeights, cellForced = Pity.apply(partition.totals, internal.pityRules, state, partition.ruleTargets)
		if cellWeights ~= nil then
			local index, forced = pickWithPity(partition, cellWeights, cellForced, rng)
			return if forced then pityResult(internal, index) else internal.flat[index].result
		end
		if #modifiers > 0 then
			return internal.flat[pick(pre, rng)].result
		end
	end

	if #modifiers == 0 then
		-- The fast path: O(1) alias sampling
		return rollWith(self, rng)
	end
	return internal.flat[pick(prepared(internal, modifiers), rng)].result
end

local function nextState(internal: Internal, state: State, result: RollResult): State
	return Pity.update(state, internal.pityRules, internal.indexOf[result])
end

--[=[
	@within Odds
	@function table
	@param definition TableDefinition
	@param options TableOptions?
	@return Table

	Creates an immutable loot table. Invalid weights, ids or pity rules raise an error right away.
	Softer problems (see `validate`) are printed as warnings in Studio and skipped in live servers.
]=]
local function newTable(definition: TableDefinition, options: TableOptions?): Table
	assert(type(definition) == "table", "Odds.table expects a definition table")
	local name = definition.name
	assert(type(name) == "string" and name ~= "", "Odds.table needs a non-empty string name")
	local rawEntries = definition.entries
	assert(type(rawEntries) == "table" and #rawEntries > 0, `Odds.table "{name}" needs at least one entry`)
	local pityGroup = definition.pityGroup or name
	assert(type(pityGroup) == "string" and pityGroup ~= "", `Odds.table "{name}" pityGroup must be a non-empty string`)

	local tiers: { [string]: TierInfo } = {}
	if definition.tiers ~= nil then
		assert(type(definition.tiers) == "table", `Odds.table "{name}" tiers must be a table`)
		for tierName, info in definition.tiers do
			assert(type(tierName) == "string", `Odds.table "{name}" tier names must be strings`)
			assert(type(info) == "table", `Odds.table "{name}" tier "{tierName}" must be a table`)
			assert(
				info.order == nil or (type(info.order) == "number" and info.order == info.order),
				`Odds.table "{name}" tier "{tierName}" order must be a number`
			)
			tiers[tierName] = freeze(table.clone(info :: TierInfo))
		end
	end

	local entries = table.create(#rawEntries) :: { Entry }
	local weights = table.create(#rawEntries) :: { number }
	local total = 0
	for i, raw in rawEntries do
		local entry = checkEntry(raw, i, name)
		entries[i] = entry
		weights[i] = entry.weight
		total += entry.weight
	end
	assert(total > 0 and total < math.huge, `Odds.table "{name}" needs a total weight above 0`)

	local depth = 1
	local tierOrders: { [string]: number } = {}
	for _, entry in entries do
		if entry.table then
			local childInternal = getInternal(entry.table)
			depth = math.max(depth, childInternal.depth + 1)
			for tierName, order in childInternal.tierOrders do
				tierOrders[tierName] = order
			end
		end
	end
	assert(depth <= MAX_DEPTH, `Odds.table "{name}" nests more than {MAX_DEPTH} tables deep`)
	for tierName, info in tiers do
		if info.order ~= nil then
			tierOrders[tierName] = info.order
		end
	end

	local internal: Internal = {
		name = name,
		rng = if options and options.rng then checkRng(options.rng, `Odds.table "{name}"`) else defaultRng,
		alias = Alias.build(weights),
		leafResults = {},
		children = {},
		wrapCache = {},
		flat = {},
		context = nil :: any,
		indexOf = {},
		pityResults = {},
		base = nil :: any,
		partitions = setmetatable({}, { __mode = "k" }) :: any,
		modifierCache = {},
		modifierCacheSize = 0,
		pityRules = {},
		tierOrders = tierOrders,
		chanceById = {},
		odds = nil,
		depth = depth,
	}

	for i, entry in entries do
		local p = entry.weight / total
		local child = entry.table
		if child == nil then
			local result = makeLeafResult(entry)
			internal.leafResults[i] = result
			table.insert(internal.flat, { result = result, chance = p })
		else
			internal.children[i] = child
			internal.wrapCache[i] = {}
			for _, item in getInternal(child).flat do
				local wrapped = wrapResult(internal, i, entry, item.result)
				table.insert(internal.flat, { result = wrapped, chance = p * item.chance })
			end
		end
	end

	local rows = table.create(#internal.flat) :: { ModifierRow }
	local baseWeights = table.create(#internal.flat) :: { number }
	for i, item in internal.flat do
		local r = item.result
		internal.indexOf[r] = i
		baseWeights[i] = item.chance
		local row: ModifierRow = {
			id = r.id,
			path = r.path,
			tier = r.tier,
			tierOrder = if r.tier ~= nil then tierOrders[r.tier] else nil,
			tags = r.entry.tags or EMPTY_TAGS,
			entry = r.entry,
		}
		rows[i] = freeze(row)
	end
	local context: ModifierContext = { rows = freeze(rows), tableName = name :: string }
	internal.context = freeze(context)
	internal.base = prepare(freeze(baseWeights), `Odds.table "{name}"`)
	internal.pityRules = Pity.parse(definition.pity, rows, tierOrders, pityGroup, name)

	-- chanceOf counts every result whose path passes through the id
	for _, item in internal.flat do
		local seen: { [string]: boolean } = {}
		for _, id in item.result.path do
			if not seen[id] then
				seen[id] = true
				internal.chanceById[id] = (internal.chanceById[id] or 0) + item.chance
			end
		end
	end

	local self: any = freeze(setmetatable({
		name = name,
		entries = freeze(entries),
		tiers = freeze(tiers),
	}, TableMetatable) :: any)
	internals[self] = internal

	if Environment.isStudio then
		local ok, issues = (self :: Table):validate()
		if not ok then
			for _, issue in issues do
				Environment.warn(`[Odds] {issue}`)
			end
		end
	end

	return self :: Table
end

--[=[
	Rolls the table once. Returns the result and, when you pass `options.state`, the
	player's new state. The state you passed in is never changed, so save the new one.

	```lua
	local result = BasicEgg:roll()
	print(result.id) -- "Rooster"

	local result, newState = PremiumEgg:roll({ state = state, modifiers = { Odds.modifiers.luck(2) } })
	Data.set(player, "eggState", newState)
	```

	Pity only applies when you pass a state. Without one, every roll is a fresh roll.
]=]
function TableMethods.roll(self: Table, options: RollOptions?): (RollResult, State?)
	local internal = getInternal(self)
	local rng: Rng = if options and options.rng then checkRng(options.rng, self.name) else internal.rng
	local modifiers = checkModifiers(options and options.modifiers, self.name)
	local state = if options and options.state then StateModule.check(options.state, self.name) else nil
	local result = rollOnce(self, internal, rng, modifiers, state)
	if state == nil then
		return result, nil
	end
	return result, nextState(internal, state, result)
end

--[=[
	Rolls the table `count` times, for example to open 10 eggs at once. Pity counts every
	roll in the batch. Returns the results and, when you pass a state, the final state.
]=]
function TableMethods.rollMany(self: Table, count: number, options: RollOptions?): ({ RollResult }, State?)
	local internal = getInternal(self)
	assert(type(count) == "number" and count >= 0 and count % 1 == 0, "rollMany expects a whole number count")
	local rng: Rng = if options and options.rng then checkRng(options.rng, self.name) else internal.rng
	local modifiers = checkModifiers(options and options.modifiers, self.name)
	local state = if options and options.state then StateModule.check(options.state, self.name) else nil
	local results = table.create(count) :: { RollResult }
	if state == nil and #modifiers == 0 then
		for i = 1, count do
			results[i] = rollWith(self, rng)
		end
		return results, nil
	end
	for i = 1, count do
		local result = rollOnce(self, internal, rng, modifiers, state)
		results[i] = result
		if state then
			state = nextState(internal, state, result)
		end
	end
	return results, state
end

local function sortRows(rows: { OddsRow })
	table.sort(rows, function(a: OddsRow, b: OddsRow): boolean
		if a.chance ~= b.chance then
			return a.chance > b.chance
		end
		return a.id < b.id
	end)
end

local function normalized(weights: { number }): { number }
	local total = 0
	for _, w in weights do
		total += w
	end
	local result = table.create(#weights, 0) :: { number }
	if total > 0 then
		for i, w in weights do
			result[i] = w / total
		end
	end
	return result
end

--[=[
	Returns every possible result with its chance and "1 in X" figure, most common first.
	The rows are frozen plain data, safe to send to clients for an egg-preview UI.

	Pass `modifiers` (and a player's `state`, for pity) to get the odds the player
	really has on their next roll. Each row's `stages` shows the chance after each
	step of the stacking order, so you can see exactly what every modifier did.
]=]
function TableMethods.odds(self: Table, options: OddsOptions?): { OddsRow }
	local internal = getInternal(self)
	local modifiers = checkModifiers(options and options.modifiers, self.name)
	local state = if options and options.state then StateModule.check(options.state, self.name) else nil
	local cacheable = #modifiers == 0 and (state == nil or #internal.pityRules == 0)
	if cacheable and internal.odds then
		return internal.odds
	end

	local base = internal.base.weights
	local afterEntry, afterLuck = base, base
	if #modifiers > 0 then
		afterEntry, afterLuck = applyModifiers(internal, modifiers)
	end
	local afterPity = afterLuck
	if state ~= nil and #internal.pityRules > 0 then
		afterPity = Pity.apply(afterLuck, internal.pityRules, state) or afterLuck
	end
	local stageBase, stageEntry, stageLuck, stagePity =
		normalized(base), normalized(afterEntry), normalized(afterLuck), normalized(afterPity)

	local rows = table.create(#internal.flat) :: { OddsRow }
	for i, item in internal.flat do
		local r = item.result
		local chance = stagePity[i]
		local row: OddsRow = {
			id = r.id,
			entry = r.entry,
			tier = r.tier,
			path = r.path,
			chance = chance,
			oneIn = if chance > 0 then 1 / chance else math.huge,
			stages = freeze({
				base = stageBase[i],
				entry = stageEntry[i],
				luck = stageLuck[i],
				pity = chance,
			}),
		}
		table.insert(rows, freeze(row))
	end
	sortRows(rows)
	freeze(rows)
	if cacheable then
		internal.odds = rows
	end
	return rows
end

--[=[
	Returns the probability (0 to 1) that a roll's path includes `id`.
	For a nested entry such as "Legendaries" this is the chance of landing anywhere inside it.
	Unknown ids return 0. Pass `modifiers` and `state` to include luck and pity.
]=]
function TableMethods.chanceOf(self: Table, id: string, options: OddsOptions?): number
	local internal = getInternal(self)
	if options == nil or (options.modifiers == nil and options.state == nil) then
		return internal.chanceById[id] or 0
	end
	local chance = 0
	for _, row in self:odds(options) do
		if table.find(row.path, id) then
			chance += row.chance
		end
	end
	return chance
end

--[=[
	Returns the "1 in X" figure for `id`, or `math.huge` when it can never be rolled.
	Takes the same options as `chanceOf`.
]=]
function TableMethods.oneIn(self: Table, id: string, options: OddsOptions?): number
	local chance = self:chanceOf(id, options)
	return if chance > 0 then 1 / chance else math.huge
end

--[=[
	Checks the table for likely mistakes and returns `(ok, issues)`.
	Runs automatically in Studio when a table is created.

	It reports duplicate ids, entries with a weight of 0, tier names that the
	table's `tiers` does not declare, pity rules whose "or better" can't work
	because the tier has no `order`, and the same problems in nested tables.
]=]
function TableMethods.validate(self: Table): (boolean, { string })
	local internal = getInternal(self)
	local issues: { string } = {}

	local function visit(tbl: Table, prefix: string, depth: number)
		if depth > MAX_DEPTH then
			table.insert(issues, `{prefix}: nested more than {MAX_DEPTH} levels deep`)
			return
		end
		local seenIds: { [string]: boolean } = {}
		local hasTiers = next(tbl.tiers) ~= nil
		for _, entry in tbl.entries do
			if seenIds[entry.id] then
				table.insert(issues, `{prefix}: duplicate id "{entry.id}"`)
			end
			seenIds[entry.id] = true
			if entry.weight == 0 then
				table.insert(issues, `{prefix}: entry "{entry.id}" has a weight of 0 and can never be rolled`)
			end
			if entry.tier ~= nil and hasTiers and tbl.tiers[entry.tier] == nil then
				table.insert(issues, `{prefix}: entry "{entry.id}" uses tier "{entry.tier}", which is not in tiers`)
			end
			if entry.table then
				visit(entry.table, `{prefix} > {entry.id}`, depth + 1)
			end
		end
	end

	visit(self, `"{self.name}"`, 1)
	for _, rule in internal.pityRules do
		if rule.order == nil and next(internal.tierOrders) ~= nil then
			table.insert(
				issues,
				`"{self.name}": pity for "{rule.tier}" only resets on an exact match, because that tier has no order`
			)
		end
	end
	return #issues == 0, issues
end

return {
	new = newTable,
	isTable = isTable,
}

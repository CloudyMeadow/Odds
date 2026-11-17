--!strict
--!native
--[=[
	@class Table

	An immutable loot table: a list of weighted entries, optionally with rarity
	tiers and nested tables. Create one with `Odds.table`.
]=]

local Alias = require("./Alias")
local Environment = require("./Environment")
local Pcg32 = require("./Pcg32")

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
	.order number? -- sort order, lower is more common
	.color Color3? -- display color for your UI
	.displayName string? -- shown instead of the tier's key

	Display data for a rarity tier. Extra fields are kept, so you can store anything your UI needs.
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
]=]
export type TableDefinition = {
	name: string,
	entries: { Entry },
	tiers: { [string]: TierInfo }?,
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
]=]
export type RollOptions = {
	rng: RngSource?,
}

--[=[
	@interface RollResult
	@within Table
	.id string -- the id of the final (innermost) entry
	.entry Entry -- the final entry itself, frozen
	.tier string? -- the innermost tier declared along the path
	.path { string } -- ids from the outermost entry to the final one

	Results are frozen and reused, so rolling does not allocate. Compare results by `id`.
]=]
export type RollResult = {
	id: string,
	entry: Entry,
	tier: string?,
	path: { string },
}

--[=[
	@interface OddsRow
	@within Table
	.id string
	.entry Entry
	.tier string?
	.path { string }
	.chance number -- probability from 0 to 1
	.oneIn number -- 1 / chance, or math.huge when the chance is 0
]=]
export type OddsRow = {
	id: string,
	entry: Entry,
	tier: string?,
	path: { string },
	chance: number,
	oneIn: number,
}

export type Table = {
	name: string,
	entries: { Entry },
	tiers: { [string]: TierInfo },

	roll: (self: Table, options: RollOptions?) -> RollResult,
	rollMany: (self: Table, count: number, options: RollOptions?) -> { RollResult },
	chanceOf: (self: Table, id: string) -> number,
	oneIn: (self: Table, id: string) -> number,
	odds: (self: Table) -> { OddsRow },
	validate: (self: Table) -> (boolean, { string }),
}

type FlatItem = {
	result: RollResult,
	chance: number,
}

type Internal = {
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
	chanceById: { [string]: number },
	odds: { OddsRow }?,
	depth: number,
}

local MAX_DEPTH = 32

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

local function makeLeafResult(entry: Entry): RollResult
	return freeze({
		id = entry.id,
		entry = entry,
		tier = entry.tier,
		path = freeze({ entry.id }),
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

--[=[
	@within Odds
	@function table
	@param definition TableDefinition
	@param options TableOptions?
	@return Table

	Creates an immutable loot table. Invalid weights or ids raise an error right away.
	Softer problems (see `validate`) are printed as warnings in Studio and skipped in live servers.
]=]
local function newTable(definition: TableDefinition, options: TableOptions?): Table
	assert(type(definition) == "table", "Odds.table expects a definition table")
	local name = definition.name
	assert(type(name) == "string" and name ~= "", "Odds.table needs a non-empty string name")
	local rawEntries = definition.entries
	assert(type(rawEntries) == "table" and #rawEntries > 0, `Odds.table "{name}" needs at least one entry`)

	local tiers: { [string]: TierInfo } = {}
	if definition.tiers ~= nil then
		assert(type(definition.tiers) == "table", `Odds.table "{name}" tiers must be a table`)
		for tierName, info in definition.tiers do
			assert(type(tierName) == "string", `Odds.table "{name}" tier names must be strings`)
			assert(type(info) == "table", `Odds.table "{name}" tier "{tierName}" must be a table`)
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
	for _, entry in entries do
		if entry.table then
			depth = math.max(depth, getInternal(entry.table).depth + 1)
		end
	end
	assert(depth <= MAX_DEPTH, `Odds.table "{name}" nests more than {MAX_DEPTH} tables deep`)

	local internal: Internal = {
		rng = if options and options.rng then checkRng(options.rng, `Odds.table "{name}"`) else defaultRng,
		alias = Alias.build(weights),
		leafResults = {},
		children = {},
		wrapCache = {},
		flat = {},
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

--[=[
	Rolls the table once and returns a frozen result.

	```lua
	local result = BasicEgg:roll()
	print(result.id) -- "Rooster"
	```
]=]
function TableMethods.roll(self: Table, options: RollOptions?): RollResult
	local internal = getInternal(self)
	local rng: Rng = if options and options.rng then checkRng(options.rng, self.name) else internal.rng
	return rollWith(self, rng)
end

--[=[
	Rolls the table `count` times, for example to open 10 eggs at once.
]=]
function TableMethods.rollMany(self: Table, count: number, options: RollOptions?): { RollResult }
	local internal = getInternal(self)
	assert(type(count) == "number" and count >= 0 and count % 1 == 0, "rollMany expects a whole number count")
	local rng: Rng = if options and options.rng then checkRng(options.rng, self.name) else internal.rng
	local results = table.create(count) :: { RollResult }
	for i = 1, count do
		results[i] = rollWith(self, rng)
	end
	return results
end

--[=[
	Returns the probability (0 to 1) that a roll's path includes `id`.
	For a nested entry such as "Legendaries" this is the chance of landing anywhere inside it.
	Unknown ids return 0.
]=]
function TableMethods.chanceOf(self: Table, id: string): number
	return getInternal(self).chanceById[id] or 0
end

--[=[
	Returns the "1 in X" figure for `id`, or `math.huge` when it can never be rolled.
]=]
function TableMethods.oneIn(self: Table, id: string): number
	local chance = getInternal(self).chanceById[id] or 0
	return if chance > 0 then 1 / chance else math.huge
end

--[=[
	Returns every possible result with its chance and "1 in X" figure, rarest last.
	The rows are frozen plain data, safe to send to clients for an egg-preview UI.
]=]
function TableMethods.odds(self: Table): { OddsRow }
	local internal = getInternal(self)
	local cached = internal.odds
	if cached then
		return cached
	end
	local rows = table.create(#internal.flat) :: { OddsRow }
	for _, item in internal.flat do
		local r = item.result
		local row: OddsRow = {
			id = r.id,
			entry = r.entry,
			tier = r.tier,
			path = r.path,
			chance = item.chance,
			oneIn = if item.chance > 0 then 1 / item.chance else math.huge,
		}
		table.insert(rows, freeze(row))
	end
	table.sort(rows, function(a: OddsRow, b: OddsRow): boolean
		if a.chance ~= b.chance then
			return a.chance > b.chance
		end
		return a.id < b.id
	end)
	freeze(rows)
	internal.odds = rows
	return rows
end

--[=[
	Checks the table for likely mistakes and returns `(ok, issues)`.
	Runs automatically in Studio when a table is created.

	It reports duplicate ids, entries with a weight of 0, tier names that the
	table's `tiers` does not declare, and the same problems in nested tables.
]=]
function TableMethods.validate(self: Table): (boolean, { string })
	getInternal(self)
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
	return #issues == 0, issues
end

return {
	new = newTable,
	isTable = isTable,
}

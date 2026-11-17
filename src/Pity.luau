--!strict
--!native
--[=[
	@class Pity
	@private

	Pity rules: hard pity guarantees a tier by roll N, soft pity ramps its chance up
	before that. Counters live in the roller state, keyed by pity group and tier.
]=]

local Modifiers = require("./Modifiers")
local StateModule = require("./State")

type State = StateModule.State
type ModifierRow = Modifiers.ModifierRow

--[=[
	@interface PityDefinition
	@within Table
	.tier string -- the tier to guarantee
	.hard number? -- guarantee a hit on this roll at the latest
	.soft { start: number, perRoll: number }? -- from roll `start`, add `perRoll` to the tier's chance each roll
	.reset ("tierOrBetter" | "exact")? -- which hits reset the counter; defaults to "tierOrBetter"

	Rolls are counted from 1 after each hit, so `hard = 150` means the 150th roll without
	a hit is guaranteed. "Better" means a tier with a higher `order`.
]=]
export type PityDefinition = {
	tier: string,
	hard: number?,
	soft: { start: number, perRoll: number }?,
	reset: ("tierOrBetter" | "exact")?,
}

export type Rule = {
	tier: string,
	key: string,
	hard: number?,
	softStart: number?,
	softPerRoll: number,
	order: number?,
	-- Per flat row: does this result count as a hit for the rule?
	targets: { boolean },
}

local Pity = {}

local function isWhole(value: any): boolean
	return type(value) == "number" and value >= 1 and value % 1 == 0 and value < math.huge
end

function Pity.parse(
	definitions: any,
	rows: { ModifierRow },
	tierOrders: { [string]: number },
	group: string,
	tableName: string
): { Rule }
	if definitions == nil then
		return {}
	end
	assert(type(definitions) == "table", `Odds.table "{tableName}" pity must be an array of rules`)
	local rules: { Rule } = {}
	local seen: { [string]: boolean } = {}
	for i, rawDef in definitions do
		local def: any = rawDef
		local where = `Odds.table "{tableName}" pity rule #{i}`
		assert(type(def) == "table", `{where} must be a table`)
		local tier = def.tier
		assert(type(tier) == "string", `{where} needs a tier name`)
		where = `Odds.table "{tableName}" pity rule for "{tier}"`
		assert(not seen[tier], `{where} is defined twice`)
		seen[tier] = true
		assert(def.hard ~= nil or def.soft ~= nil, `{where} needs hard, soft or both`)
		assert(def.hard == nil or isWhole(def.hard), `{where} hard must be a whole number of 1 or more`)

		local softStart: number? = nil
		local softPerRoll = 0
		local soft: any = def.soft
		if soft ~= nil then
			assert(type(soft) == "table", `{where} soft must be a table like \{ start = 100, perRoll = 0.02 }`)
			assert(isWhole(soft.start), `{where} soft.start must be a whole number of 1 or more`)
			local per = soft.perRoll
			assert(
				type(per) == "number" and per > 0 and per <= 1,
				`{where} soft.perRoll must be a number above 0 and at most 1`
			)
			if def.hard ~= nil then
				assert(soft.start < def.hard, `{where} soft.start must be lower than hard`)
			end
			softStart = soft.start :: number
			softPerRoll = per :: number
		end

		local reset = def.reset or "tierOrBetter"
		assert(
			reset == "tierOrBetter" or reset == "exact",
			`{where} reset must be "tierOrBetter" or "exact" (got {tostring(reset)})`
		)
		local order = tierOrders[tier]
		local targets = table.create(#rows, false) :: { boolean }
		local any = false
		for r, row in rows do
			local hit = row.tier == tier
			if not hit and reset == "tierOrBetter" and order ~= nil and row.tierOrder ~= nil then
				hit = row.tierOrder >= order
			end
			targets[r] = hit
			any = any or hit
		end
		assert(any, `{where}: no entry in this table has tier "{tier}"`)

		local rule: Rule = {
			tier = tier :: string,
			key = `{group}:{tier}`,
			hard = def.hard :: number?,
			softStart = softStart,
			softPerRoll = softPerRoll,
			order = order,
			targets = targets,
		}
		table.insert(rules, rule)
	end

	-- Apply the most common tiers first so the rarest tier's rule has the final say
	local index: { [Rule]: number } = {}
	for i, rule in rules do
		index[rule] = i
	end
	table.sort(rules, function(a: Rule, b: Rule): boolean
		local ao, bo = a.order or -math.huge, b.order or -math.huge
		if ao ~= bo then
			return ao < bo
		end
		return index[a] < index[b]
	end)
	return rules
end

--[=[
	Splits rows into cells that every rule treats the same way (in practice one cell
	per tier band). Pity only ever rescales whole cells, so a roll under pity can pick
	a cell first and then a row inside it, in O(cells + log n) instead of O(n).
]=]
export type Partition = {
	-- Per cell: its row indices, their cumulative weights, and the cell's total
	rows: { { number } },
	cumulative: { { number } },
	totals: { number },
	-- Per rule: which cells it targets
	ruleTargets: { { boolean } },
}

function Pity.partition(weights: { number }, rules: { Rule }): Partition
	local cellBySignature: { [string]: number } = {}
	local partition: Partition = { rows = {}, cumulative = {}, totals = {}, ruleTargets = {} }
	for r = 1, #rules do
		partition.ruleTargets[r] = {}
	end
	local bits = table.create(#rules, "") :: { string }
	for i, w in weights do
		for r, rule in rules do
			bits[r] = if rule.targets[i] then "1" else "0"
		end
		local signature = table.concat(bits)
		local cell = cellBySignature[signature]
		if cell == nil then
			cell = #partition.rows + 1
			cellBySignature[signature] = cell
			partition.rows[cell] = {}
			partition.cumulative[cell] = {}
			partition.totals[cell] = 0
			for r, rule in rules do
				partition.ruleTargets[r][cell] = rule.targets[i]
			end
		end
		if w > 0 then
			local total = partition.totals[cell] + w
			partition.totals[cell] = total
			table.insert(partition.rows[cell], i)
			table.insert(partition.cumulative[cell], total)
		end
	end
	return partition
end

--[=[
	Adjusts weights for the next roll. Returns nil when no rule is active, which lets the
	caller keep using cached weights. Otherwise returns the new weights and, per row,
	whether a hard guarantee made that row a forced hit.
]=]
function Pity.apply(
	weights: { number },
	rules: { Rule },
	state: State,
	ruleTargets: { { boolean } }?
): ({ number }?, { boolean }?)
	local adjusted: { number }? = nil
	local forced: { boolean }? = nil
	for r, rule in rules do
		-- Callers can pass grouped weights (one per cell) with matching target masks
		local targets: { boolean } = if ruleTargets then ruleTargets[r] else rule.targets
		local rollNumber = (state.pity[rule.key] or 0) + 1
		local share: number? = nil
		local isHard = rule.hard ~= nil and rollNumber >= rule.hard
		if isHard then
			share = 1
		elseif rule.softStart ~= nil and rollNumber >= rule.softStart then
			local current = adjusted or weights
			local total, inside = 0, 0
			for i, w in current do
				total += w
				if targets[i] then
					inside += w
				end
			end
			if total > 0 then
				share = math.min(1, inside / total + rule.softPerRoll * (rollNumber - rule.softStart + 1))
			end
		end
		if share ~= nil then
			adjusted = Modifiers.setShare(adjusted or weights, targets, share)
			if isHard then
				local mask: { boolean } = forced or (table.create(#weights, false) :: { boolean })
				for i, hit in targets do
					if hit then
						mask[i] = true
					end
				end
				forced = mask
			end
		end
	end
	return adjusted, forced
end

--[=[
	Returns the state after rolling flat row `index`. Never changes `state`.
]=]
function Pity.update(state: State, rules: { Rule }, index: number): State
	local pity = table.clone(state.pity)
	for _, rule in rules do
		if rule.targets[index] then
			pity[rule.key] = 0
		else
			pity[rule.key] = (pity[rule.key] or 0) + 1
		end
	end
	return { version = state.version, rolls = state.rolls + 1, pity = pity }
end

return Pity

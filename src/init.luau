--!strict
--[=[
	@class Odds

	Loot tables, rarity rolls, luck and pity systems for Roblox, with odds you can trust.

	```lua
	local Odds = require(ReplicatedStorage.Packages.Odds)

	local BasicEgg = Odds.table({
		name = "BasicEgg",
		entries = {
			{ id = "Chick", weight = 700 },
			{ id = "Rooster", weight = 250 },
			{ id = "GoldenChicken", weight = 49 },
			{ id = "CosmicHen", weight = 1, tags = { "Mythic" } },
		},
	})

	print(BasicEgg:roll().id)
	print(BasicEgg:oneIn("CosmicHen")) -- 1000
	```
]=]

local Modifiers = require("@self/Modifiers")
local Pcg32 = require("@self/Pcg32")
local State = require("@self/State")
local TableModule = require("@self/Table")

export type Table = TableModule.Table
export type TableDefinition = TableModule.TableDefinition
export type TableOptions = TableModule.TableOptions
export type Entry = TableModule.Entry
export type TierInfo = TableModule.TierInfo
export type RollOptions = TableModule.RollOptions
export type RollResult = TableModule.RollResult
export type OddsRow = TableModule.OddsRow
export type OddsOptions = TableModule.OddsOptions
export type OddsStages = TableModule.OddsStages
export type PityDefinition = TableModule.PityDefinition
export type State = State.State
export type Modifier = Modifiers.Modifier
export type ModifierContext = Modifiers.ModifierContext
export type ModifierRow = Modifiers.ModifierRow
export type LuckOptions = Modifiers.LuckOptions
export type Rng = TableModule.Rng
export type Pcg32 = Pcg32.Pcg32

local Odds = {
	--[=[
		@within Odds
		@prop version string
	]=]
	version = "0.2.0",

	table = TableModule.new,

	--[=[
		@within Odds
		@function isTable
		@param value any
		@return boolean

		Returns true if `value` was created by `Odds.table`.
	]=]
	isTable = TableModule.isTable,

	--[=[
		@within Odds
		@prop Pcg32 Pcg32

		The built-in deterministic generator. Pass `Odds.Pcg32.new(seed)` as `rng`
		to get the same rolls every time, for tests and bug reports.
	]=]
	Pcg32 = Pcg32,

	state = State.new,
	serialize = State.serialize,
	deserialize = State.deserialize,

	--[=[
		@within Odds
		@prop modifiers Modifiers

		`luck`, `boostEntry`, `exclude`, `onlyTags` and `custom`.
	]=]
	modifiers = table.freeze({
		luck = Modifiers.luck,
		boostEntry = Modifiers.boostEntry,
		exclude = Modifiers.exclude,
		onlyTags = Modifiers.onlyTags,
		custom = Modifiers.custom,
	}),
}

return table.freeze(Odds)

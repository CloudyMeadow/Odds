# Odds

Strictly typed loot tables, rarity rolls and pity systems for Roblox, with odds you can trust.

Most RNG code on Roblox is a hand-rolled weighted pick. Odds does that well (O(1) rolls, deterministic seeds, no allocations per roll) and is growing into a toolkit that answers the questions developers actually have, such as "How many rolls until the average player gets a Mythic?" and "What does my 2x luck potion really do to the odds?"

> **Status: v0.1 (in development).** Core rolls are done. Pity, luck modifiers, the simulator and roll costs are next. See the [roadmap](#roadmap).

## Quick start

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

local result = BasicEgg:roll() -- { id = "Rooster", entry = {...}, path = { "Rooster" } }
print(BasicEgg:chanceOf("CosmicHen")) -- 0.001
print(BasicEgg:oneIn("CosmicHen")) -- 1000
```

## Installation

**Wally**

```toml
[dependencies]
Odds = "cloudymeadow/odds@0.1.0"
```

**Manually:** copy the `src` folder into your game as a ModuleScript named `Odds` (with [Rojo](https://rojo.space), `default.project.json` does this for you). A ready-made `.rbxm` will be attached to each GitHub release.

Odds has no dependencies and uses Luau's string `require`, so it works the same in Roblox and in [Lune](https://lune-org.github.io/docs).

## Features in v0.1

### Rarity tiers and nested tables

Roll a rarity tier first, then an item within it. Chances multiply through the nesting, and results carry the tier and the full path.

```lua
local Legendaries = Odds.table({
	name = "Legendaries",
	entries = {
		{ id = "Phoenix", weight = 1 },
		{ id = "Dragon", weight = 1 },
	},
})

local PremiumEgg = Odds.table({
	name = "PremiumEgg",
	tiers = {
		Common = { color = Color3.fromRGB(200, 200, 200), order = 1 },
		Legendary = { color = Color3.fromRGB(255, 170, 0), order = 4 },
	},
	entries = {
		{ id = "Commons", weight = 900, tier = "Common", table = BasicEgg },
		{ id = "Legendaries", weight = 10, tier = "Legendary", table = Legendaries },
	},
})

local result = PremiumEgg:roll()
print(result.id, result.tier, table.concat(result.path, " > ")) -- Phoenix  Legendary  Legendaries > Phoenix
print(PremiumEgg:oneIn("Legendaries")) -- 91
```

A result's `tier` is the innermost tier declared along its path, so an item can override its group's tier.

### Odds for your UI

`table:odds()` lists every possible result with its `chance` and `oneIn` figure, most common first. The rows are frozen plain data, so they are safe to send to clients for an egg-preview screen.

```lua
for _, row in PremiumEgg:odds() do
	print(row.id, row.tier, string.format("%.2f%% (1 in %.1f)", row.chance * 100, row.oneIn))
end
```

### Batch rolls

```lua
local results = PremiumEgg:rollMany(10) -- "Open 10 eggs"
```

### Deterministic seeds

Every roll goes through a random source with a `NextNumber` method. Odds ships with `Odds.Pcg32`, a pure-Luau PCG32 generator that matches the reference implementation bit for bit, so the same seed gives the same rolls in Studio, live servers and Lune. That makes bugs reproducible and tests reliable.

```lua
local rng = Odds.Pcg32.new(42)
local a = BasicEgg:rollMany(100, { rng = rng })

-- Or set a default source for a table
local SeededEgg = Odds.table(definition, { rng = Random.new(1234) })
```

`Pcg32` is not cryptographically secure. Roll on the server and never accept a seed from a client.

### Validation

Broken definitions (negative or `NaN` weights, missing ids, empty tables) raise a clear error as soon as the table is created. Softer mistakes are reported by `table:validate()`, which runs automatically in Studio and is skipped in live servers:

- duplicate ids
- entries with a weight of 0, which can never be rolled
- tier names that are not declared in `tiers` (typos such as `"Comon"`)
- the same problems inside nested tables

## API

| Function | Returns | Description |
| --- | --- | --- |
| `Odds.table(definition, options?)` | `Table` | Creates an immutable loot table. `options.rng` sets its default random source. |
| `table:roll(options?)` | `RollResult` | Rolls once. `options.rng` overrides the random source. |
| `table:rollMany(count, options?)` | `{ RollResult }` | Rolls `count` times. |
| `table:chanceOf(id)` | `number` | Probability (0 to 1) that a roll's path includes `id`. |
| `table:oneIn(id)` | `number` | `1 / chanceOf(id)`, or `math.huge` if it can never be rolled. |
| `table:odds()` | `{ OddsRow }` | Every possible result with `chance` and `oneIn`, most common first. |
| `table:validate()` | `(boolean, { string })` | Checks for likely mistakes. |
| `Odds.isTable(value)` | `boolean` | Whether `value` was created by `Odds.table`. |
| `Odds.Pcg32.new(seed, stream?)` | `Pcg32` | Deterministic generator with `NextNumber`, `NextInteger`, `Clone`, `GetState` and `Pcg32.fromState`. |

All public types are exported (`Odds.Table`, `Odds.Entry`, `Odds.RollResult`, `Odds.OddsRow` and more) and the library type checks cleanly under `--!strict` with both the current and the new Luau type solver.

Results are frozen and reused: rolling the same outcome twice returns the same object, so rolls do not allocate. Compare results by `id`, and do not try to modify them.

## How it works

- **Vose's alias method** builds each table in O(n) once. Every roll after that is O(1), whether the table has 4 entries or 10,000.
- **PCG32 in pure Luau** keeps its 64-bit state in two 32-bit halves and produces 53-bit floats, so odds rarer than 1 in a billion are still represented accurately.
- **Statistical tests in CI** roll one million times with a fixed seed and run a chi-square goodness-of-fit test against `table:odds()`. This proves that what the library rolls matches what it reports.

Early numbers from `lune run bench/roll` (Lune 0.10 with native code generation, on a cloud dev machine). CI prints fresh numbers on every run.

| Benchmark | Time |
| --- | --- |
| 1M rolls, 4 entries, `rollMany` | ~0.3 s |
| 1M rolls, 10,000 entries | ~0.7 s |
| 1M rolls, two nested levels | ~1.1 s |

## Development

The repository uses [Rojo](https://rojo.space), [Wally](https://wally.run), [StyLua](https://github.com/JohnnyMorganz/StyLua), [selene](https://github.com/Kampfkarren/selene) and [Lune](https://lune-org.github.io/docs).

```sh
lune run tests/run          # all tests
lune run tests/run Pcg32    # only spec files whose name contains "Pcg32"
lune run bench/roll         # benchmarks
stylua src tests bench      # format
selene src tests bench      # lint
luau-analyze src/*.luau     # type check
```

CI runs all of these on every pull request.

## Roadmap

- **v0.1, core rolls:** tables, tiers, nesting, `roll`, `rollMany`, `chanceOf`, `oneIn`, `odds`, `validate`, PCG32, alias sampling, statistical tests.
- **v0.2, pity and modifiers:** per-player roller state, hard and soft pity, pity groups, luck modes (`weight`, `chance`, `rolls`), `boostEntry`, `exclude`, custom modifiers, a stage-by-stage `odds()` breakdown.
- **v0.3, the simulator:** exact (Markov chain) and Monte Carlo modes, wait-time percentiles, worst-case streaks, collection completion, `Odds.compare`.
- **v0.4, roll costs:** currencies, bulk discounts, an atomic `purchaseRoll` and a `ProcessReceipt` helper.
- **v1.0:** documentation site, example place and a Studio plugin.

## Similar projects

RollEngine (on the DevForum) covers weighted rarity rolls, pity and modifiers and is worth a look. Odds focuses on the balancing toolkit on top: exact wait-time math, comparing table versions, roll costs and a Studio plugin.

## License

[MIT](LICENSE)

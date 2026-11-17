# Changelog

All notable changes to Odds are listed here. The project follows [semantic versioning](https://semver.org).

## [0.2.0] - Unreleased

### Added

- Per-player roller state: `Odds.state`, `Odds.serialize` and `Odds.deserialize`, with format versioning.
- Pity rules on tables: hard pity, soft pity, `reset = "tierOrBetter" | "exact"` and shared `pityGroup` counters.
- `result.pityTriggered`, true when a hard guarantee decided the roll.
- `Odds.modifiers`: `luck` with `"chance"`, `"weight"` and `"rolls"` modes, `boostEntry`, `exclude`, `onlyTags` and `custom`, applied in a documented stacking order.
- `odds`, `chanceOf` and `oneIn` take `modifiers` and `state`, and odds rows include a stage-by-stage `stages` breakdown.

### Changed

- `roll` and `rollMany` now also return the new state when one is passed (the first return value is unchanged).

## [0.1.0] - 2026-11-17

### Added

- `Odds.table` for immutable weighted loot tables, with rarity tiers, metadata and nested tables.
- `roll`, `rollMany`, `chanceOf`, `oneIn`, `odds` and `validate` on tables.
- `Odds.Pcg32`, a deterministic PCG32 generator in pure Luau that matches the reference implementation.
- O(1) rolls through Vose's alias method, with frozen, reused results so rolling does not allocate.
- Lune test suite, including a one-million-roll chi-square test, and CI for StyLua, selene and both Luau type solvers.

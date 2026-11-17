# Changelog

All notable changes to Odds are listed here. The project follows [semantic versioning](https://semver.org).

## [0.1.0] - Unreleased

### Added

- `Odds.table` for immutable weighted loot tables, with rarity tiers, metadata and nested tables.
- `roll`, `rollMany`, `chanceOf`, `oneIn`, `odds` and `validate` on tables.
- `Odds.Pcg32`, a deterministic PCG32 generator in pure Luau that matches the reference implementation.
- O(1) rolls through Vose's alias method, with frozen, reused results so rolling does not allocate.
- Lune test suite, including a one-million-roll chi-square test, and CI for StyLua, selene and both Luau type solvers.

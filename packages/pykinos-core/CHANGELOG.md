# Changelog for `pykinos-core`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the [Haskell Package Versioning Policy (PVP)](https://pvp.haskell.org/).

## [0.1.0.0] - 2026-11-18

### Added
- Unboxed SIMD two-tier Roaring Bitmaps (`Pykinos.Bitset.Roaring`).
- Cache-conscious 4-tier Adaptive Radix Tree (`Pykinos.IntMap.ART`).
- Multi-way balanced B+ search trees (`Pykinos.Tree.BPlus`).
- FAST architecture-sensitive sequential search accelerators (`Pykinos.Tree.FAST`).
- Swiss table open-addressing hash table (`Pykinos.Mutable.SwissTable`).
- Dynamic hidden class schema interning (`Pykinos.Schema.HiddenClass`).
- Comprehensive Hackage package manifest, documentation, and unit test suite.

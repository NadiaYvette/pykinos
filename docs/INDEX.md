# pykinos Documentation Index

Welcome to the `pykinos` technical documentation corpus.

`pykinos` (Epic Greek **πυκινός** *pykinos*, Attic **πυκνός** *pyknos*: *close, compact, dense, solid, shrewd, terse*, cf. Liddell & Scott, *A Greek-English Lexicon*, 1940) provides cache-conscious, unboxed, blocked data structures for high-performance algebraic evaluation, AST indexing, and transactional memory in the Haskell ecosystem.

---

## Core Orientation & Reading Paths

- [`README.md`](../README.md) — High-level workspace overview, architecture, etymology, and quick start.
- [`AGENTS.md`](../AGENTS.md) — AI coding assistant guidance, rules, and bounded context pointers.
- [`PLAN.md`](../PLAN.md) — Strategic roadmap and phase delivery schedule.
- [`STATE.md`](../STATE.md) — Active operational session frontier and verification ledger.
- [`TUTORIAL.md`](TUTORIAL.md) — Step-by-step practical tutorial track across Roaring Bitsets, ART, and MVCC.
- [`NEWBIE_GUIDE.md`](NEWBIE_GUIDE.md) — Token-conservation funnel, unboxed memory model, and navigation.
- [`MAINTAINER_GUIDE.md`](MAINTAINER_GUIDE.md) — Maintenance runbook, 5 physical verification gates, and cache profiling.

---

## Design Notes (`docs/notes/`)

- [`ETYMOLOGY.md`](notes/ETYMOLOGY.md) — Comprehensive philological and lexicographical record of **πυκνός** / **πυκινός** across physical density, military tactics, and intellectual shrewdness.
- [`PYKINOS_DESIGN.md`](notes/PYKINOS_DESIGN.md) — Canonical architectural design monograph: hardware cache topography, two-tier Roaring bitsets, 4-tier Adaptive Radix Trees, and pushout MVCC.
- [`DOC_STRATEGY.md`](notes/DOC_STRATEGY.md) — Canonical documentation policy and precedence rules.
- [`COMMIT_ATTRIBUTION.md`](notes/COMMIT_ATTRIBUTION.md) — Commit attribution standards and RFC 2822 trailer specification.

---

## Active Package Inventory

The `pykinos` workspace provides two modular Cabal packages:

### 1. Blocked Containers
- [`packages/pykinos-core/`](../packages/pykinos-core/) — Cache-conscious data structures: two-tier Roaring bitsets, 4-tier Adaptive Radix Trees (ART), B+ trees, FAST accelerators, and dynamic hidden classes.

### 2. Transactional & Effect Integration
- [`packages/pykinos-penelope/`](../packages/pykinos-penelope/) — Penelope algebraic effect integration: transient epoch isolation (`withTransientEpoch`) and lockless categorical MVCC pushout merges (`pushoutMergeMVCC`).

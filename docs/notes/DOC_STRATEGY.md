# Documentation Strategy & Policy

**Project:** pykinos  
**Index:** [`../INDEX.md`](../INDEX.md)

## 1. Precedence Rule (§4)

> **Code wins at runtime; notes corrected regardless.** When code and documentation disagree, the running code defines runtime reality. A stale design document or comment is a defect that must be corrected in the exact same change set. Silent drift is prohibited.

---

## 2. Audience & Genre Map

1. **Arrivals → Orientation:** [`README.md`](../../README.md) and [`docs/NEWBIE_GUIDE.md`](../NEWBIE_GUIDE.md). High-level overview, quickstart examples, and progressive disclosure navigation.
2. **API Consumers → Tutorial & Haddock:** [`docs/TUTORIAL.md`](../TUTORIAL.md) and inline Haddock documentation. Full parameter explanations, failure modes, complexity bounds, and working examples.
3. **Maintainers → Corpus & Design Notes:** [`docs/notes/COMMIT_ATTRIBUTION.md`](COMMIT_ATTRIBUTION.md) and [`docs/MAINTAINER_GUIDE.md`](../MAINTAINER_GUIDE.md). Architectural invariants and physical verification gates.
4. **AI Coding Assistants → Advisory Layer:** [`AGENTS.md`](../../AGENTS.md) and [`.agents/rules/`](../../.agents/rules/). Token-conservation funnels and operational rules.

---

## 3. Forge-Tiered CI Policy

{- Note [Forge-Tiered CI Resource Allocation and Static Gate Partitioning]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
[tag:note-forge-tiered-ci]
In multi-forge environments (GitHub Actions, GitLab CI / Framagit, Radicle),
continuous integration pipelines are strictly partitioned to conserve compute
and provide instantaneous diagnostic feedback:

1. **Tier 1 (Fast Static Gates):** Tagref cross-reference verification, markdown
   link integrity checking, HLint static analysis, and CLOC comment density checks
   execute within seconds on lightweight runners without compiler downloads.
2. **Tier 2 (Full Compilation & Test Suites):** Multi-package Cabal builds, Hspec
   unit test execution, and fuel-bounded execution validation execute across
   supported GHC releases.
-}

Every CI manifest (`.github/workflows/ci.yml`, `.gitlab-ci.yml`) must preserve
this tiered execution structure.

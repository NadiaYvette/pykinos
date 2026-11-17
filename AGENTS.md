# AGENTS.md — Advisory Context for AI Coding Assistants

Pointer file. Canonical sources win on any disagreement.

## What this repository is

`pykinos` (πυκινός — serried, dense, closely-woven) — high-performance in-memory indexing, cache-line blocked B+ and Intel FAST search trees, SIMD unboxed Roaring bitmaps, Adaptive Radix Trees (ART), and Penelope transient epoch mutation handles for lockless MVCC pushout trees.

## Read first, in this order

1. [`cabal.project`](cabal.project) — package workspace definition (`pykinos-core`, `pykinos-penelope`).
2. `pykinos-core/src/Pykinos/` — core data structures (Roaring, ART, B+, FAST).
3. `pykinos-penelope/src/Pykinos/Effect/Penelope.hs` — transient epoch & MVCC pushout effect handles.

## Subdivided operational rules (`.agents/rules/`)

- [`.agents/rules/commit-attribution.md`](.agents/rules/commit-attribution.md) — Linux kernel RFC 2822 trailer format (`Assisted-by:`), DCO boundaries.
- [`.agents/rules/code-navigation.md`](.agents/rules/code-navigation.md) — Token-saving funnel (`./tags` symbol jump, targeted slice viewing).
- [`.agents/rules/compiler-verification.md`](.agents/rules/compiler-verification.md) — Zero-log compiler verification (`tricorder status --json`) and test suites.
- [`.agents/rules/documentation-precedence.md`](.agents/rules/documentation-precedence.md) — Precedence rule ("code wins at runtime; notes corrected regardless").
- [`.agents/rules/kioku-context.md`](.agents/rules/kioku-context.md) — Durable memory, context offloading loop (`kioku-remember`), and compaction cadence.
- [`.agents/rules/task-execution.md`](.agents/rules/task-execution.md) — Yamaarashi runner invariants, `executor: auto` preference, and zero-polling discipline.

## Subdivided operational skills (`.agents/skills/`)

- [`.agents/skills/code-navigation/SKILL.md`](.agents/skills/code-navigation/SKILL.md) — Fast, token-efficient code navigation using tags, ripgrep, and ast-grep.
- [`.agents/skills/contextful/SKILL.md`](.agents/skills/contextful/SKILL.md) — Query project context packs, local FTS5 BM25 search.
- [`.agents/skills/kioku/SKILL.md`](.agents/skills/kioku/SKILL.md) — Durable agent memory and hybrid recall via shinzui kioku.
- [`.agents/skills/ponytail/SKILL.md`](.agents/skills/ponytail/SKILL.md) — Minimalist / YAGNI / lazy-mode coding.
- [`.agents/skills/shikumi/SKILL.md`](.agents/skills/shikumi/SKILL.md) — Typed language-model programs & hierarchical tracing.
- [`.agents/skills/tricorder/SKILL.md`](.agents/skills/tricorder/SKILL.md) — Check continuous GHCi build status and zero-log compiler diagnostics.
- [`.agents/skills/yamaarashi/SKILL.md`](.agents/skills/yamaarashi/SKILL.md) — Autonomous task packet runner and ASCII Kanban board projection.

## Operational advisories

1. **In-memory cache invariants:** Nodes are aligned to 64-byte cache lines; SIMD bitmap operations operate on unboxed `ByteArray#` primitives.
2. **Commits:** Descriptive-imperative subject under 72 chars, body explains why, HEREDOC style. AI attribution uses git trailers:
   `Assisted-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)` (or appropriate engine). Never `Co-authored-by:` or `Signed-off-by:` for AI tools.
3. **Toolchain:** GHC 9.14 / Cabal 3.18.

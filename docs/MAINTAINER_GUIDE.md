# pykinos Maintainer Guide

**Corpus Inventory:** [`INDEX.md`](INDEX.md)  
**Philological Exegesis:** [`notes/ETYMOLOGY.md`](notes/ETYMOLOGY.md)  
**Design Monograph:** [`notes/PYKINOS_DESIGN.md`](notes/PYKINOS_DESIGN.md)  
**Attribution Standards:** [`notes/COMMIT_ATTRIBUTION.md`](notes/COMMIT_ATTRIBUTION.md)  
**Documentation Policy:** [`notes/DOC_STRATEGY.md`](notes/DOC_STRATEGY.md)  
**Tutorial Track:** [`TUTORIAL.md`](TUTORIAL.md)  

---

## 1. Scope & Maintainer Responsibilities

As a maintainer of `pykinos`, you uphold the physical performance and cache-conscious integrity of the unboxed container suite:
1. **Cache Contiguity Invariant:** No boxed pointer chains may be introduced into the core container paths (`Roaring`, `ART`, `BPlus`, `FAST`). Data must remain contiguous and unboxed.
2. **Zero Memory Leaks in Transient Epochs:** Ephemeral buffers allocated during `withTransientEpoch` must reclaim cleanly without lingering references across epoch boundaries.
3. **Strict Hackage Distribution Readiness:** Both `pykinos-core` and `pykinos-penelope` must pass `cabal check` with zero errors and zero warnings.
4. **Physical Verification Gates:** Every commit must pass all five verification gates enforced by `./bin/pykinos-verify`.

---

## 2. The Five Physical Verification Gates

The automated verification harness [`./bin/pykinos-verify`](../bin/pykinos-verify) runs five non-negotiable checks:

```
[1/5] HLint Static Analysis Gate (0 hints)
  │
  ▼
[2/5] Full Cabal Test Suites (both packages: 100% PASS)
  │
  ▼
[3/5] Tagref Cross-Reference Integrity Gate (0 dead refs)
  │
  ▼
[4/5] Markdown Link & Anchor Integrity Gate (0 broken links)
  │
  ▼
[5/5] CLOC Comment Density Gate (>= 50.0% in production code)
```

### Running the Full Verification Gate

```bash
./bin/pykinos-verify
```

### Running Targeted Gates

- **HLint Analysis:**
  ```bash
  hlint packages/*/src
  ```
- **Cabal Test Suites:**
  ```bash
  cabal test pykinos-core pykinos-penelope
  ```
- **Tagref Cross-References:**
  ```bash
  ./bin/pykinos-tagref
  ```
- **Markdown Link Integrity:**
  ```bash
  ./bin/pykinos-linkcheck --quiet
  ```
- **Comment Density Audit:**
  ```bash
  ./bin/pykinos-cloc --quiet --check
  ```

---

## 3. Hackage Readiness & PVP Governance

Every package in `pykinos` must strictly adhere to the Haskell Package Versioning Policy (PVP):

1. **Dependency Upper & Lower Bounds:**
   - Every external dependency must declare both lower and upper bounds:
     `primitive >= 0.9 && < 0.10`, `containers >= 0.6 && < 0.9`, `text >= 2.0 && < 2.2`.
   - Internal dependencies between workspace packages must be pinned:
     `pykinos-core >= 0.1.0.0 && < 0.2`.
2. **Hackage Compliance Auditing:**
   ```bash
   for pkg in packages/*; do
     (cd "$pkg" && cabal check)
   done
   ```
   Output must show `No errors or warnings; this package complies with Hackage standards.`

---

## 4. Performance Benchmarking & Cache Profiling

Maintainers must verify that modifications do not introduce cache regressions:
1. **Hardware Performance Counters (`perf`):**
   ```bash
   perf stat -e L1-dcache-loads,L1-dcache-load-misses,LLC-load-misses cabal run pykinos-core:bench
   ```
   Verify that cache miss ratios remain below 2% during sequential and random lookup workloads.
2. **Memory Contiguity Verification:**
   - Confirm that chunks in `Pykinos.Bitset.Roaring` pack at least 4,096 items before converting to bitmaps, and that `Node4`/`Node16` remain within 64-byte alignment boundaries.

---

## 5. Commit Attribution & The Two-File Loop

- **RFC 2822 Attribution:** All AI-assisted commits must conclude with:
  ```
  Assisted-by: Antigravity (Google DeepMind / Gemini 3.8 Flash)
  ```
- **The Two-File Loop:** Always record updated milestone completions and active frontiers in [`PLAN.md`](../PLAN.md) and [`STATE.md`](../STATE.md) at the end of each session.

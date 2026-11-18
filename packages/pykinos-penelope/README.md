# pykinos-penelope — Transient Epoch Mutation & Lockless MVCC

> **πυκινός** (*pykinos*, Epic Greek; Attic **πυκνός** *pyknos*): *close, compact, dense, solid, shrewd, terse*.

`pykinos-penelope` integrates the unboxed memory substrates of `pykinos-core` with Penelope effect systems to provide zero-allocation transient mutation and lockless multi-version concurrency control (MVCC):

1. **Transient Epochs (`withTransientEpoch`):** Isolates in-place mutation within bounded execution epochs, materializing persistent snapshots only at epoch boundaries.
2. **Lockless MVCC Pushouts (`pushoutMergeMVCC`):** Categorical pushout merges over divergent transaction branches without global locks.

## License

EUPL-1.2.

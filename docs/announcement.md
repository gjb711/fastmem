# FASTMEM — Public announcement material

Ready-to-paste text for promoting FASTMEM on external channels
(MariaDB JIRA / community forums / Reddit / Stack Overflow / social).

Project: <https://github.com/gjb711/fastmem> (GPL-2.0, source distribution)

## Short version (social / Reddit r-MariaDB / Stack Overflow)

> FASTMEM is a row-lock in-memory storage engine for MariaDB 12.x:
> row-level write locks (per-slot spinlock, no table lock at all) and
> completely lock-free readers (seqlock). On MariaDB 12.1.1, 8 concurrent
> writers x 2000 hot-row UPDATEs finish in ~1.0 s while the built-in
> MEMORY engine takes 8.08 s because its table lock serializes every
> statement. Readers never block writers (0.80 -> 1.83 s as readers grow
> 0 -> 8). Source distribution: clone + ./install.sh --mariadb-version
> 12.1.1, no prebuilt binaries, validated end-to-end in Docker. GPL-2.0.
> <https://github.com/gjb711/fastmem>

## Long version (forum / blog)

FASTMEM is an open-source (GPL-2.0) in-memory storage engine for
MariaDB 12.x, designed around the MEMORY (heap) engine's known pain
points:

- **No table locks.** `store_lock()` returns empty. MEMORY serializes
  every statement on one whole-table lock; FASTMEM writers only spin on
  the slot lock of the row they touch.
- **Lock-free readers.** Row images are copied via a seqlock
  (odd/even sequence + retry). Readers never block writers and writers
  never block readers.
- **Row-level read-modify-write atomicity.** Concurrent UPDATE/DELETE
  cannot lose updates (verified on a real server: SUM delta exactly
  equals the statement count under 8-writer hot-row contention).
- **Concurrent-safe AUTO_INCREMENT** via CAS interval reservation.
- Fixed-size slots, zero allocation on hot paths; hash-only indexes.

Measured on MariaDB 12.1.1 (7000-row K-line table, 100 hot rows):

| Scenario | FASTMEM | MEMORY | InnoDB |
|---|---|---|---|
| 8 procs x 2000 concurrent UPDATE | 1.03 s | 8.08 s | 1.06 s |
| Hot-row 8 writers + 4 readers x 300 | 1.23 s | 1.90 s | 1.62 s |
| 8 writers x 500, 4 readers | 1.41 s | 2.86 s | 2.09 s |
| 8 writers x 500, 8 readers | 1.83 s | 3.16 s | 2.94 s |

Every run doubled as a correctness check: final SUM matches the expected
increment exactly, zero lost updates.

The full protocol was independently replicated on Linux with the official
`mariadb:12.1.2` Docker image (plugin compiled from the matching source
inside the image — one command: `./docker/run-benchmark.sh`): 8 x 2000
concurrent hot-row UPDATEs finish in **2 s on FASTMEM vs 7 s on MEMORY vs
30 s on InnoDB**, and all 18 per-phase zero-loss checks pass. Build
walkthrough and the pitfalls we hit (maturity gate, plugin ABI version
gate): `docs/DOCKER.md`.

Distribution is source-only plus `./install.sh`: it fetches the MariaDB
server source of the requested version (`--mariadb-version 12.1.1`,
falls back to the `12.1` branch), drops `storage/fastmem/` into it and
builds the plugin with the server's own cmake — no prebuilt binaries, no
GLIBC/ABI compatibility concerns. Validated end-to-end in a Docker
Ubuntu 24.04 container.

Docs: README (EN/zh-CN), DESIGN.md (concurrency model & proofs),
docs/BENCHMARK.md (+ zh-CN) with full methodology and reproduction
scripts in bench/.

We welcome feedback, review of the concurrency proofs (DESIGN.md), and
contributions.

## JIRA ticket template (jira.mariadb.org)

- **Summary**: New open-source memory storage engine plugin (FASTMEM) —
  no table locks, lock-free readers, row-level writers
- **Type**: Task (informational / discussion)
- **Description**:

```
Announcement / request for peer review.

We published FASTMEM, a GPL-2.0 MariaDB 12.x storage engine plugin that
addresses the MEMORY (heap) engine's whole-table lock: row-level writer
serialization (per-slot spinlocks), completely lock-free readers
(seqlock), no THR_LOCK entries, concurrent AUTO_INCREMENT via CAS.

Measured on 12.1.1 (7000-row table, 100 hot rows, 8 processes x 2000
UPDATEs): FASTMEM 1.03 s vs MEMORY 8.08 s vs InnoDB 1.06 s; readers
never block writers. Full benchmark & concurrency-design doc:
https://github.com/gjb711/fastmem  (README + DESIGN.md + docs/BENCHMARK.md)

Source distribution: git clone + ./install.sh --mariadb-version 12.1.1
(no prebuilt binaries; validated end-to-end in Docker Ubuntu 24.04).
Linux replication on mariadb 12.1.2 via ./docker/run-benchmark.sh:
8-way hot-row UPDATEs FASTMEM 2 s vs MEMORY 7 s vs InnoDB 30 s, 18/18
zero-loss checks pass (docs/DOCKER.md).
Licensed GPL-2.0. Contributions and technical review welcome.

Link to this JIRA ticket: please provide the ticket URL here.
```
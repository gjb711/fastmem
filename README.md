# FASTMEM

**Row-lock in-memory storage engine for MariaDB 12.x — no table locks, lock-free readers**

[![License: GPL-2.0](https://img.shields.io/badge/license-GPL--2.0-blue.svg)](LICENSE)
[![MariaDB](https://img.shields.io/badge/MariaDB-12.x-003545.svg)](https://mariadb.org)
[![Platform](https://img.shields.io/badge/platform-Windows%20x64%20%7C%20Linux-4A4A55.svg)]()

English | [简体中文](README.zh-CN.md)

FASTMEM is an in-memory storage engine for MariaDB (validated against **12.1.1**) designed to outperform the built-in **MEMORY (heap)** engine under high-concurrency read/write workloads:

- **No table-level locks at all** — `store_lock()` returns zero `THR_LOCK_DATA` entries.
- **Lock-free readers** — row images are copied through a seqlock (odd/even sequence + retry); readers never block writers and vice versa.
- **Row-granular writers** — per-slot spinlocks plus per-bucket hash-chain spinlocks.

## Why FASTMEM?

| Problem with MEMORY (heap) | FASTMEM |
|---|---|
| One whole-table lock serializes **every** statement | No table lock, no THR_LOCK entries |
| Readers block behind writers (and vice versa) | Readers are completely lock-free (seqlock) |
| Concurrent `UPDATE` is table-serialized | Row-level read-modify-write serialization, hot rows don't block cold rows |
| Trivial auto-increment relies on the table lock | CAS interval reservation — safe under concurrency |

Full design rationale, the concurrency model and correctness proofs are in **[DESIGN.md](DESIGN.md)**.

## Features

- No table locks (`store_lock()` returns empty; no waiter lists, no lock contention point)
- **Seqlock readers**: tear-free row copy, practically zero retries under real load
- **Per-slot writer spinlock** + per-bucket hash spinlock; correct concurrent chain insert/unlink
- **Statement-level read-modify-write serialization**: concurrent `UPDATE`/`DELETE` can never lose an update (verified on a real server: SUM delta exactly equals the statement count under 8-writer hot-row contention)
- **Concurrent-safe `AUTO_INCREMENT`**: CAS interval reservation → disjoint ranges per statement, no duplicate ids on parallel inserts
- Fixed-size slots: zero allocation on hot paths, rows replaced by a single `memcpy`
- 8-byte position refs = slot id + generation → stale references can never dangle
- **Hash-only indexes** (explicit `BTREE` is rejected at `CREATE`, no fake support)
- `TRUNCATE` / clear recycles memory; auto-increment counter reset supported
- Non-transactional (`HA_NO_TRANSACTIONS`), statement-level semantics, last-writer-wins

## Quick start

```sql
INSTALL SONAME 'ha_fastmem';           -- or start mariadbd with --plugin-load-add=ha_fastmem

CREATE TABLE t (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  v  BIGINT NOT NULL
) ENGINE=FASTMEM;

INSERT INTO t (v) VALUES (1),(2),(3);
SELECT * FROM t WHERE id = 2;          -- lock-free read
UPDATE t SET v = v + 1 WHERE id = 2;   -- row-level serialized read-modify-write
```

> **Note (MariaDB ≥ 12.1.2):** the server only accepts plugins whose
> maturity reaches `plugin_maturity` (default `beta`, distro images may set
> `gamma`). FASTMEM honestly declares itself `BETA`; if you see *"Loading of
> beta plugin FASTMEM is prohibited"*, run `SET GLOBAL plugin_maturity='beta';`
> before `INSTALL`, or put `plugin-maturity=beta` under `[mysqld]`.

Same public contract as the MEMORY engine:

- row limit governed by `max_heap_table_size` (estimated at `CREATE`)
- data is **not persisted**: server restart empties the table (definition survives)
- no transactions, no foreign keys

## Building

### 0) One-command install from source (recommended)

The repository is a source distribution: clone it, run one script, get a
built plugin. No prebuilt binaries, no GLIBC/ABI compatibility concerns —
the script fetches the MariaDB server source of your chosen version, drops
`storage/fastmem/` into it and builds with the server's own cmake.

```bash
git clone https://github.com/gjb711/fastmem.git
cd fastmem
./install.sh --mariadb-version 12.1.1     # any version/branch: 12.1.1, 11.4, 10.11...
```

| Flag | Meaning |
|---|---|
| `--mariadb-version <v>` | target version (default `12.1.1`); tries tag `maria-<v>` then branch `<v>` |
| `--branch <name>` | fetch a specific branch/tag instead |
| `--source-dir <dir>` | reuse an existing MariaDB source tree (no clone) |
| `--build-dir <dir>` | cmake build directory (default `<src>/build_fastmem`) |
| `--jobs <n>` | parallel build jobs |
| `--plugin-dir <dir>` | install plugin here (default: auto-detect) |
| `--dry-run` | print the plan, change nothing |

Validated end-to-end in a Docker Ubuntu 24.04 container (clone →
configure → build → `ha_fastmem.so`); macOS uses the same path, and
Windows works under Git-Bash with the MSVC generator. First run is slow
(server configure); afterwards the script can be repeated with the same
checkout.

### 1) Fastest check: standalone concurrency-core test

No server, no cmake. Needs MSVC `cl` or any C++17 compiler:

```bat
call "...\VC\Auxiliary\Build\vcvars64.bat"
cd standalone-test
cl /nologo /W3 /std:c++17 /O2 /EHsc /MT main.cpp /Fe:fmtest.exe
fmtest.exe          :: prints "ALL TESTS PASSED"
```

It runs 4 concurrency suites: tear detection, unique-key integrity under parallel writers, stale-reference safety, multi-key accounting.

### 2) As a MariaDB plugin

Place `storage/fastmem/` inside a MariaDB 12.x source tree, then configure:

```bat
cmake -S <src> -B <src>\build -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
      -DCMAKE_GENERATOR_PLATFORM=x64 -DWITH_SSL=bundled ^
      -DWITH_WSREP=OFF -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO ...
cmake --build <src>\build --config RelWithDebInfo --target fastmem -- -m
```

`CMakeLists.txt` uses `MYSQL_ADD_PLUGIN(fastmem ... STORAGE_ENGINE)` and is picked up automatically by the top-level `CONFIGURE_PLUGINS()`.

The exact, validated Windows/mariadb-12.1.1 recipe (wolfssl **v5.7.6-stable**, winflexbison, proxy for the pcre2 external download, MSVC porting notes) is in the [简体中文 README](README.zh-CN.md) §7.

## Benchmark — MariaDB 12.1.1, Windows x64, real machine

Three-engine comparison (FASTMEM vs MEMORY vs InnoDB). 7000-row K-line
dataset (`varchar(50)` PK + 2 indexes), 100 hot rows, local port 3309,
separate `mysql` client connections as workers, scripts in `bench/`.
Full report: [docs/BENCHMARK.md](docs/BENCHMARK.md).

| Scenario | FASTMEM | MEMORY | InnoDB |
|---|---|---|---|
| A. Single-connection 2000 UPDATE | **0.50 s** | 1.37 s | 0.55 s |
| A. Single-connection 500 SUM scans | 0.67 s | **0.58 s** | 1.13 s |
| B. 8 procs × 2000 concurrent UPDATE | **1.03 s** | 8.08 s | 1.06 s |
| C. Hot-row 8 writers + 4 readers × 300 | **1.23 s** | 1.90 s | 1.62 s |
| D. 8 writers × 500, no readers | **0.80 s** | 2.42 s | 0.79 s |
| D. 8 writers × 500, 4 readers | **1.41 s** | 2.86 s | 2.09 s |
| D. 8 writers × 500, 8 readers | **1.83 s** | 3.16 s | 2.94 s |

Every row above is also a correctness check: the final `SUM(close)` matches
the expected increment exactly — **zero lost updates** on every run.

Observations:

- **Concurrent writes are where the table lock hurts**: MEMORY serializes
  all 16 000 updates on its table lock (8.08 s vs ~1 s). FASTMEM writers
  only touch the slot spinlock of the row they update.
- **Readers never block writers**: as readers grow 0 → 4 → 8, FASTMEM writer
  time degrades the least (0.80 → 1.83 s); FASTMEM reads are pure seqlock
  copies that take no lock.
- Single-connection numbers are close across engines — end-to-end latency is
  dominated by the MySQL protocol/connection layer (~200 ms per local
  connection); the in-engine data path itself is sub-microsecond.

### Reproduce the whole comparison in one Docker command

Want the same numbers on Linux, without setting up anything? This builds a
`mariadb:<ver>` image with FASTMEM compiled from the matching official source
tarball (so no ABI guesswork), starts it, and runs the four scenarios A–D plus
the per-phase zero-loss checks:

```bash
git clone https://github.com/gjb711/fastmem.git
cd fastmem
./docker/run-benchmark.sh 12.1.2
```

First run downloads ~120 MB of server source and builds the plugin (a few
minutes); afterwards the image is cached. See `docker/Dockerfile` and
`docker/bench.sh` — you can also run them stage by stage.

## Tests

| Location | What it covers |
|---|---|
| `mysql-test/` | MTR functional tests (`fastmem.test`, `have_fastmem.inc`) |
| `standalone-test/main.cpp` | Concurrency core: tear detection, unique-key integrity, stale refs, multi-key accounting (no server needed) |
| `bench/` | Reproducible benchmarks: single connection, 8-way, hot-row contention, pure UPDATE streams, table reset |
| `docker/` | One-command Linux reproduction of the full A–D three-engine comparison inside a container (`run-benchmark.sh`) |

## Limitations (by design)

- No transactions, no foreign keys, no persistence (same as MEMORY)
- Hash-only indexes; `index_prev` / `index_first` / `index_last` return `HA_ERR_WRONG_COMMAND` (the optimizer avoids these access methods)
- Full scans are "loose" — the row set may change mid-scan (`can_continue_handler_scan() == 0`)
- On a concurrent key-change `UPDATE`, orphaned hash-chain nodes are consistently skipped by lookup/delete (functionally correct; see DESIGN.md §2.5)

## License

**GPL-2.0** — same as the MariaDB server. The hash helpers in `fm_hash.cc` are ported from the MEMORY engine and inherit the same license.

---

[简体中文](README.zh-CN.md)
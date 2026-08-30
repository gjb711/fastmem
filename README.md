# FASTMEM

**Lock-free in-memory storage engine for MariaDB 12.x**

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

Same public contract as the MEMORY engine:

- row limit governed by `max_heap_table_size` (estimated at `CREATE`)
- data is **not persisted**: server restart empties the table (definition survives)
- no transactions, no foreign keys

## Building

### 1) Fastest check: standalone concurrency-core test

No server, no cmake. Needs MSVC `cl` or any C++17 compiler:

```bat
call "...\VC\Auxiliary\Build\vcvars64.bat"
cd storage\fastmem\standalone-test
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

7000-row K-line dataset (`varchar(50)` PK + 2 hash indexes), local port 3309, scripts in `bench/`.

| Scenario | FASTMEM | Reference | Notes |
|---|---|---|---|
| Single-connection baseline | ~1.00x | MEMORY | UPDATE 0.92x / SELECT 1.06x / INSERT 1.00x — at parity |
| **Hot-row: 8 writers + 4 readers × 300 loops** | **1.24 s** | InnoDB **1.66 s** | 2400 contended UPDATEs on 100 hot rows + 1200 concurrent reads; **both sides delta = +2400 exact, zero lost updates** |
| Pure UPDATE stream, 8 procs × 2000 stmts | ~1.0 s | InnoDB ~1.1 s | identical random sequence, 16 000 updates total |
| Concurrent AUTO_INCREMENT, 4 procs × 250 rows | 1000 ids | — | ids 1..1000, **no duplicates, no gaps** |

Observations:

- Under heavy hot-row contention InnoDB pays row-lock queueing; FASTMEM's cost barely grows with contention because there is no table lock, readers are lock-free and writers only spin on the row they touch.
- End-to-end latency is still bounded by the MySQL protocol/connection layer (a local connection costs ~200 ms); the in-engine data path itself is sub-microsecond.

## Tests

| Location | What it covers |
|---|---|
| `mysql-test/` | MTR functional tests (`fastmem.test`, `have_fastmem.inc`) |
| `standalone-test/main.cpp` | Concurrency core: tear detection, unique-key integrity, stale refs, multi-key accounting (no server needed) |
| `bench/` | Reproducible benchmarks: single connection, 8-way, hot-row contention, pure UPDATE streams, table reset |

## Limitations (by design)

- No transactions, no foreign keys, no persistence (same as MEMORY)
- Hash-only indexes; `index_prev` / `index_first` / `index_last` return `HA_ERR_WRONG_COMMAND` (the optimizer avoids these access methods)
- Full scans are "loose" — the row set may change mid-scan (`can_continue_handler_scan() == 0`)
- On a concurrent key-change `UPDATE`, orphaned hash-chain nodes are consistently skipped by lookup/delete (functionally correct; see DESIGN.md §2.5)

## License

**GPL-2.0** — same as the MariaDB server. The hash helpers in `fm_hash.cc` are ported from the MEMORY engine and inherit the same license.

---

[简体中文](README.zh-CN.md)
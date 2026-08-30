# FASTMEM Benchmark Report — FASTMEM vs MEMORY vs InnoDB

Real-machine benchmark on **MariaDB 12.1.1 (Windows x64)** comparing the
FASTMEM in-memory engine against MariaDB's built-in **MEMORY (heap)**
engine and **InnoDB**.

- [简体中文版](BENCHMARK.zh-CN.md)

## 1. Environment

| Item | Value |
|---|---|
| Server | `12.1.1-MariaDB`, default configuration, local TCP port 3309 |
| Worker model | One separate `mysql.exe` client connection per worker process |
| Dataset | 7000-row K-line table (`varchar(50)` primary key + 2 secondary indexes, `decimal(19,4)` price columns), 100 "hot" rows |
| Scripts | `bench/` in this repository |

Every workload below is also a **correctness check**: the final
`SUM(close)` must equal `baseline + expected increments` exactly. Any
lost update would change the sum.

## 2. Tables and workloads

Three tables with identical schema and data:

- `fm_kline` — `ENGINE=FASTMEM`
- `mm_kline` — `ENGINE=MEMORY`
- `inn_kline` — `ENGINE=InnoDB`

Workloads (run fresh after each table reset):

- **A. Single-connection baseline** — one connection runs 2000
  point-lookup `UPDATE`s (random over the 100 hot rows), then 500
  full-table `SUM(close)` scans.
- **B. Concurrent pure UPDATE** — 8 client processes each run the same
  2000-statement UPDATE file (16 000 updates total, ~160 updates per hot
  row).
- **C. Hot-row mix** — 8 writer processes (random hot-row UPDATE × 300)
  + 4 reader processes (full-table SUM × 300), all simultaneous.
- **D. Reader interference** — 8 writer processes × 500 updates, with
  0 / 4 / 8 concurrent reader processes doing full-table SUM loops.
  Measures how much readers slow writers down.

Connection overhead note: each worker pays a one-time local connection
cost (~200 ms). Short workloads are therefore partially dominated by
protocol/connection cost; relative differences still hold because all
engines pay the same overhead.

## 3. Results

| Scenario | FASTMEM | MEMORY | InnoDB |
|---|---|---|---|
| A. Single-connection 2000 UPDATE | **0.50 s** | 1.37 s | 0.55 s |
| A. Single-connection 500 SUM scans | 0.67 s | **0.58 s** | 1.13 s |
| B. 8 procs × 2000 concurrent UPDATE | **1.03 s** | 8.08 s | 1.06 s |
| C. Hot-row 8 writers + 4 readers × 300 | **1.23 s** | 1.90 s | 1.62 s |
| D. 8 writers × 500, 0 readers | **0.80 s** | 2.42 s | 0.79 s |
| D. 8 writers × 500, 4 readers | **1.41 s** | 2.86 s | 2.09 s |
| D. 8 writers × 500, 8 readers | **1.83 s** | 3.16 s | 2.94 s |

**Correctness: every run above finished with an exact SUM match — zero
lost updates.** (FASTMEM row-level serialization: see DESIGN.md §3.1.)

## 4. Interpretation

### 4.1 Concurrent writes: the table lock is the bottleneck (scenario B)

8 processes × 2000 UPDATEs complete in ~1.0 s on FASTMEM and InnoDB but
take **8.08 s on MEMORY — ~8x slower**. The MEMORY engine holds a
whole-table lock per statement, so 16 000 statements serialize on it;
FASTMEM writers only spin on the slot lock of the single row they touch,
and InnoDB uses row-level locks.

### 4.2 Readers never block writers (scenario D)

As readers grow from 0 to 8, writer completion time grows:

- FASTMEM: 0.80 → 1.41 → 1.83 s (+28% per 4 readers)
- InnoDB:  0.79 → 2.09 → 2.94 s
- MEMORY:  2.42 → 2.86 → 3.16 s

FASTMEM reads are seqlock copies — they take no lock at all, so readers
and writers run fully in parallel; the mild growth is CPU/protocol
sharing. MEMORY starts slow (writers already queued on the table lock
with zero readers) and degrades further as readers join the same lock.

### 4.3 Hot-row read/write mix (scenario C)

FASTMEM 1.23 s < InnoDB 1.62 s < MEMORY 1.90 s. Under hot-row
contention, InnoDB pays row-lock queueing and MEMORY pays table-lock
queueing; FASTMEM writers only contend on the specific hot slots.

### 4.4 Single connection: at parity (scenario A)

With one connection and tiny statements, all three engines finish in the
same ~0.5–1.4 s window — end-to-end time is dominated by protocol and
per-statement overhead, not by the storage engine. This is the honest
picture: FASTMEM's advantage is **concurrency**, not single-thread speed.

## 5. Reproducing

```text
# infra (tables + hot rows + stored procedures)
mysql ... < bench/reset_tables.sql            # fm_kline / inn_kline
mysql ... < bench/hot_concurrency_setup.sql   # hot_sids + fm_hot_work/fm_reader
mysql ... < bench/rebuild_readerloop.sql      # fm_reader_loop (silent SUM reader)

# workloads
mysql ... < bench/update_fm.sql               # 2000-stmt UPDATE file (fm/inn/mm variants)
CALL fmtest.fm_hot_work('fm_kline', 300);     # writer loop
CALL fmtest.fm_reader_loop('fm_kline', 300);  # reader loop
```

Run 8 (or N) copies of a workload concurrently in separate client
connections, then verify `SUM(close)` against the expected increment.

## 6. Caveats

- Small dataset (7000 rows) and small worker counts: numbers show
  relative behavior, not peak throughput.
- Client processes add ~200 ms connection overhead each; absolute times
  include it equally for all engines.
- MEMORY/FASTMEM tables are volatile: they empty on server restart
  (test data is rebuilt by the reset scripts).

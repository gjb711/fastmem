# Docker Guide — Building and Three-Engine Benchmarking FASTMEM

Everything in this guide is **verified end-to-end** on Linux (Docker
Desktop / WSL2, x86_64, 12 vCPU) with `mariadbd 12.1.2-MariaDB-ubu2404`.
It covers how the server image is built with the plugin compiled from the
matching official source, and how the A–D FASTMEM vs MEMORY vs InnoDB
comparison runs inside the container.

- Windows baseline + full methodology: [`BENCHMARK.md`](BENCHMARK.md)
  ([中文](BENCHMARK.zh-CN.md))
- Scripts discussed here: [`docker/Dockerfile`](../docker/Dockerfile),
  [`docker/run-benchmark.sh`](../docker/run-benchmark.sh),
  [`docker/bench.sql`](../docker/bench.sql),
  [`docker/bench.sh`](../docker/bench.sh)

## 1. Prerequisites

| requirement | note |
|---|---|
| Docker Engine 24+ (or Docker Desktop) | Linux containers, not Hyper-V/WSL1 |
| ~2 GB free disk | MariaDB source tarball ≈ 120 MB + build tree |
| Network to `archive.mariadb.org` | source tarball; GitHub is **not** needed |

No MariaDB packages, no headers, no toolchain on the host: the build
happens entirely inside the container.

## 2. One-command flow

```bash
./docker/run-benchmark.sh            # defaults to MARIADB_VERSION=12.1.2
./docker/run-benchmark.sh 12.1.2     # explicit
```

What it does, in order:

1. `docker build -f docker/Dockerfile` — two-stage image (Section 3)
2. `docker run -d` with `MARIADB_ROOT_PASSWORD=bench` — official
   entrypoint initializes the datadir; our `conf.d` drop-in auto-loads
   the plugin (Section 3.2)
3. `docker exec bash /bench/bench.sh` — full A–D benchmark with
   per-phase zero-loss verification (Section 5)
4. Prints the report to stdout and removes the container.

Re-running is safe: the benchmark drops and recreates `fmtest.*` each
time. The image layers cache, so a second run only pays for the
benchmark itself (minutes). On Docker Desktop the *first* build can
take 10–30 minutes (apt + tarball extraction on slow block devices).

## 3. How the image is built (`docker/Dockerfile`)

### 3.1 Stage 1 — compile the plugin against the *exact* server version

`ubuntu:24.04` + build toolchain (`build-essential cmake bison
libssl-dev libncurses-dev libpcre2-dev libxml2-dev libcurl4-openssl-dev
libkrb5-dev ...`). Then:

```
download  https://archive.mariadb.org/mariadb-<ver>/source/mariadb-<ver>.tar.gz
extract → /work/src            (official tarball ships all submodules,
                                incl. libmariadb → no git needed)
/fastmem/install.sh --source-dir /work/src --jobs $(nproc)
```

`install.sh` drops `storage/fastmem/` into the server tree and runs
`cmake --build ... --target fastmem`, producing `ha_fastmem.so`.

**Why compile inside the image?** Storage-engine plugins are
version-gated: MariaDB refuses a plugin whose interface constants don't
match the server build (`ERROR 1126 ... API version ... not supported`).
Building against the same version the container runs is the only
reliable strategy — there are no portable prebuilt `.so` files.

### 3.2 Stage 2 — server image

```
FROM mariadb:<ver>
COPY --from=builder /work/ha_fastmem.so /usr/lib/mysql/plugin/
RUN printf '[mariadbd]\nplugin-load-add=ha_fastmem.so\n' \
    > /etc/mysql/mariadb.conf.d/99-fastmem.cnf
```

The drop-in loads the engine at server start with a single line:

- `plugin-load-add=ha_fastmem.so` — no `INSTALL PLUGIN` ever needed
  (and see the double-registration warning in Section 6).
- Since **v1.1** the plugin declares **GAMMA** maturity, so it passes the
  default maturity gate of MariaDB ≥ 12.x servers directly (verified:
  `INSTALL SONAME 'ha_fastmem'` succeeds on an unconfigured 12.1.2
  server). The old `1.0` (BETA) build additionally required
  `plugin-maturity=beta` in this file, because servers configured with
  `--plugin-maturity=gamma` refuse lower-maturity plugins.

## 4. Manual, stage-by-stage

```bash
# build
docker build -t fastmem-server:12.1.2 --build-arg MARIADB_VERSION=12.1.2 \
             -f docker/Dockerfile .

# start (official entrypoint initializes the datadir)
docker run -d --name fastmem -e MARIADB_ROOT_PASSWORD=bench fastmem-server:12.1.2

# verify the engine is live
docker exec fastmem mariadb -uroot -pbench -e "SHOW ENGINES; SHOW PLUGINS"
#   FASTMEM  YES  Lock-free in-memory tables (seqlock row images, per-slot writers)
#   FASTMEM  ACTIVE

# benchmark (prints the A–D report to stdout)
docker exec -e MARIADB_ROOT_PASSWORD=bench fastmem bash /bench/bench.sh

# keep it running as a normal server, or clean up
docker rm -f fastmem
```

`SHOW ENGINES` printing `FASTMEM YES` is the single success criterion
for a correct build + load.

## 5. What the benchmark measures (`docker/bench.sql` + `docker/bench.sh`)

### 5.1 Fixture (`bench.sql`)

- `fm_kline` (FASTMEM), `mm_kline` (MEMORY), `inn_kline` (InnoDB):
  identical schema, `sid VARCHAR(190) PRIMARY KEY, close DECIMAL(19,4)`
- 7000 rows loaded with MariaDB's `seq_1_to_7000` (a plain
  `WITH RECURSIVE` CTE insert trips `max_recursive_iterations=1000` on
  default server settings)
- `hot_sids`: 100 randomly chosen rows = the contention target
- worker procedures so the loops run **server-side** (client round-trips
  would dominate the engine delta):
  - `fm_writer(tbl, n)`: n × (pick one random hot `sid` in its own
    statement, then `UPDATE tbl SET close=close+1 WHERE sid=@sid`)
  - `fm_reader(tbl, n)`: n × full-table `SELECT SUM(close)` — a
    lock-free scan for FASTMEM, a table-lock reader for MEMORY

### 5.2 Phases and the zero-loss check

Each phase runs per engine, then verifies
`Δ SUM(close) == number of +1 statements` — an exact lost-update
detector: a single dropped RMW shows up immediately.

| phase | load | expected Δ |
|---|---|---|
| A | 1 conn × 2000 PK updates | 2000 |
| B | 8 conns concurrently × 2000 | 16000 |
| C | 8 writers + 4 readers × 300 | 2400 |
| D | 8 writers × 500 with r∈{0,4,8} readers × 500 | 4000 each |

### 5.3 Timing notes

- Times are whole seconds; fast phases collapse to `0–1 s` — treat A/C/D
  as ordering proofs, B as the throughput comparison.
- Absolute numbers depend on vCPUs/scheduler; compare engines within one
  run, not across machines.
- The hot-row `sid` is deliberately resolved *before* the `UPDATE`
  (`SET @sid=(…)`) instead of `UPDATE … WHERE sid=(SELECT … ORDER BY
  RAND() …)` — see Section 6.

## 6. Known pitfalls (all hit and fixed during real runs)

1. **`INSTALL` on a `plugin-load-add`-ed engine crashes the server.**
   If the engine is already loaded at startup, a later
   `INSTALL PLUGIN fastmem SONAME 'ha_fastmem.so'` double-registers it;
   the next `SHOW ENGINES` segfaults `mariadbd` (SIGSEGV, exit 139).
   Pick exactly one load path. The image uses `conf.d` only.
2. **Maturity gate (v1.1+: not needed; pre-1.1: config-time only).**
   Since **v1.1** the plugin is `GAMMA` and loads on a stock 12.1.2
   server — see the verified `INSTALL SONAME` result in Section 3.2. The
   old `1.0` (BETA) build required `plugin-maturity=beta` in a place the
   *startup* reads (config file or command line); a runtime
   `SET GLOBAL plugin_maturity='beta'` did **not** unblock `INSTALL` on
   12.1.2 in our tests.
3. **Maturity warning is just a warning.** A low-maturity plugin loaded
   via `plugin-load-add` logs
   `Plugin 'FASTMEM' is of maturity level X while the server is Y` but
   still loads; it is `INSTALL` that hard-fails with
   `errno: 1 ... prohibited` when the plugin maturity is below the
   server's gate. Match the plugin version to the server (Section 3.1)
   and this never bites.
4. **`UPDATE ... WHERE sid=(SELECT ... ORDER BY RAND() LIMIT 1)`** is
   re-evaluated *per candidate row* by the 12.1.2 optimizer: scenario A
   took 205 s on any engine. Resolve the id first (5.1) — otherwise you
   benchmark the query layer, not the engines.
5. **CTE insert limit.** `INSERT INTO ... WITH RECURSIVE seq(n)` beyond
   1000 rows fails with `max_recursive_iterations=1000` on defaults;
   `seq_1_to_7000` avoids both the limit and the recursion cost.
6. **Docker Hub tags.** `mariadb:12.1.1` was never published (the
   registry returns `denied`); patch tags like `12.1.2` and branch tags
   like `12.1` are available. The plugin must match the *exact* server
   build, so keep `MARIADB_VERSION` as one variable for both stages (as
   the Dockerfile does) and prefer a concrete patch tag.

## 7. Verified results on this platform

`./docker/run-benchmark.sh 12.1.2` (12 vCPU, x86_64):

| phase | FASTMEM | MEMORY | InnoDB | Δ check |
|---|---|---|---|---|
| A | 1 s | 1 s | 7 s | 3× PASS |
| B | **2 s** | 7 s | 30 s | 3× PASS |
| C | **0 s** | 2 s | 5 s | 3× PASS |
| D(r=0) | 1 s | 1 s | 8 s | 3× PASS |
| D(r=4) | 1 s | 2 s | 8 s | 3× PASS |
| D(r=8) | 1 s | 2 s | 9 s | 3× PASS |

18/18 zero-loss checks pass: FASTMEM's row-level write serialization is
correct under 8-way hot-row contention on Linux, and it is the fastest
engine in every mixed phase (MEMORY pays its whole-table lock, InnoDB
pays row-lock + MVCC + buffer-pool machinery).

## 8. Cleanup

```bash
docker rm -f fastmem fastmem-bench-* 2>/dev/null
docker rmi fastmem-server:12.1.2     # ~1 GB with build cache layers
docker builder prune -f              # build cache of stage 1
```

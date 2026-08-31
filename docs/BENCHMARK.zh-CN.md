# FASTMEM 基准测试报告 —— FASTMEM vs MEMORY vs InnoDB

在 **MariaDB 12.1.1（Windows x64）真机**上，将 FASTMEM 内存引擎与
MariaDB 自带的 **MEMORY（heap）** 引擎及 **InnoDB** 做完整对比。

- [English version](BENCHMARK.md)

## 1. 环境

| 项目 | 值 |
|---|---|
| 服务器 | `12.1.1-MariaDB`，默认配置，本地 TCP 3309 |
| 并发模型 | 每个工作进程一个独立的 `mysql.exe` 客户端连接 |
| 数据集 | 7000 行 K 线表（`varchar(50)` 主键 + 2 个二级索引，`decimal(19,4)` 价格列），100 个「热行」 |
| 脚本 | 本仓库 `bench/` 目录 |

下面每个负载同时都是**正确性校验**：结束时 `SUM(close)` 必须精确等于
「基线 + 期望增量」。任何一次丢失更新都会改变总和。

## 2. 表与负载

三张表结构与数据完全一致：

- `fm_kline` —— `ENGINE=FASTMEM`
- `mm_kline` —— `ENGINE=MEMORY`
- `inn_kline` —— `ENGINE=InnoDB`

负载（每轮前重置表）：

- **A. 单连接基线** —— 单连接执行 2000 条点查 `UPDATE`（随机命中 100
  热行），再做 500 次全表 `SUM(close)` 扫描。
- **B. 并发纯 UPDATE** —— 8 个客户端进程各执行同一份 2000 条 UPDATE
  文件（共 16000 次更新，每热行约 160 次碰撞）。
- **C. 热行读写混合** —— 8 个写者进程（随机热行 UPDATE × 300）+ 4 个
  读者进程（全表 SUM × 300），同时进行。
- **D. 读者干扰** —— 8 个写者进程 × 500 次更新，分别叠加 0 / 4 / 8 个
  并发读者（全表 SUM 循环）。衡量读者对写者的拖慢程度。

连接开销说明：每个工作进程承担一次性的本地连接开销（约 200ms）。短
负载因此部分被协议/连接成本主导；三引擎开销相同，相对差异依然成立。

## 3. 结果

| 场景 | FASTMEM | MEMORY | InnoDB |
|---|---|---|---|
| A. 单连接 2000 条 UPDATE | **0.50 s** | 1.37 s | 0.55 s |
| A. 单连接 500 次 SUM 扫描 | 0.67 s | **0.58 s** | 1.13 s |
| B. 8 进程 × 2000 条并发 UPDATE | **1.03 s** | 8.08 s | 1.06 s |
| C. 热行 8 写者 + 4 读者 × 300 | **1.23 s** | 1.90 s | 1.62 s |
| D. 8 写者 × 500，0 读者 | **0.80 s** | 2.42 s | 0.79 s |
| D. 8 写者 × 500，4 读者 | **1.41 s** | 2.86 s | 2.09 s |
| D. 8 写者 × 500，8 读者 | **1.83 s** | 3.16 s | 2.94 s |

**正确性：以上每一轮结束时 SUM 均与期望增量精确相等——零丢失
更新。**（FASTMEM 的行级串行化见 DESIGN.md §3.1。）

## 4. 解读

### 4.1 并发写：表锁是瓶颈（场景 B）

8 进程 × 2000 条 UPDATE，FASTMEM 与 InnoDB 约 1.0 秒完成，而 **MEMORY
要 8.08 秒——慢约 8 倍**。MEMORY 每条语句持整表锁，16000 条语句全被
串在这把锁上；FASTMEM 写者只在目标行的槽锁上自旋，InnoDB 用行锁。

### 4.2 读者永不阻塞写者（场景 D）

读者从 0 增到 8，写者完成时间的变化：

- FASTMEM：0.80 → 1.41 → 1.83 s（每加 4 读者约 +28%）
- InnoDB：0.79 → 2.09 → 2.94 s
- MEMORY：2.42 → 2.86 → 3.16 s

FASTMEM 的读是 seqlock 拷贝——完全不取任何锁，读者与写者全并行；轻微
的退化来自 CPU/协议共享。MEMORY 即使 0 读者也已很慢（写者排队表锁），
读者加入同一把锁后继续退化。

### 4.3 热行读写混合（场景 C）

FASTMEM 1.23 s < InnoDB 1.62 s < MEMORY 1.90 s。热行碰撞下，InnoDB
付出的是行锁排队成本，MEMORY 付出的是表锁排队成本；FASTMEM 写者只在
具体热槽上竞争。

### 4.4 单连接：基本持平（场景 A）

单连接、小语句时三引擎都在 0.5–1.4 s 区间——端到端时间被协议与每语句
开销主导，而非存储引擎。这是诚实的结论：FASTMEM 的优势在**并发**，
不在单线程速度。

## 5. 复现

```text
# 基础设施（表 + 热行 + 存储过程）
mysql ... < bench/reset_tables.sql            # fm_kline / inn_kline
mysql ... < bench/hot_concurrency_setup.sql   # hot_sids + fm_hot_work/fm_reader
mysql ... < bench/rebuild_readerloop.sql      # fm_reader_loop（静音 SUM 读者）

# 负载
mysql ... < bench/update_fm.sql               # 2000 条 UPDATE 文件（fm/inn/mm 变体）
CALL fmtest.fm_hot_work('fm_kline', 300);     # 写者循环
CALL fmtest.fm_reader_loop('fm_kline', 300);  # 读者循环
```

用独立客户端连接并行跑 8（或 N）份负载，再用 `SUM(close)` 对比期望增量。

## 6. 注意事项

- 数据集小（7000 行）、并发数小：数字反映相对行为，非峰值吞吐。
- 客户端进程各自有 ~200ms 连接开销；绝对耗时对三引擎同等包含该开销。
- MEMORY/FASTMEM 表是易失的：服务器重启后清空（测试数据由重置脚本重建）。

## 7. 一条命令在 Linux 复现（Docker）

完整讲解（镜像分阶段构建、手动分步、实测结果与踩坑）见
[`DOCKER.zh-CN.md`](DOCKER.zh-CN.md)。

想在 Linux 上一键复现完整的 A–D 对比，构建一个用对应版本官方源码现场编译
插件的 `mariadb:<ver>` 镜像，然后跑同一套负载：

```bash
./docker/run-benchmark.sh 12.1.2
```

`docker/bench.sql`（建表 + worker 存储过程）、`docker/bench.sh`（A–D 负载框架，
逐阶段 `SUM(close)` 零丢失校验）、`docker/Dockerfile` 都是自包含的，需要时
可分步手动执行。Docker 的结果是独立的 Linux 复现——绝对数字会不同于上面的
Windows 表（调度器/vCPU 差异），属正常，不构成矛盾。

## 8. Docker 实测结果（Linux 复现）

本项目在 `./docker/run-benchmark.sh 12.1` 下的真实输出
（server `mariadbd 12.1.2-MariaDB-ubu2404`，x86_64，12 vCPU，负载在存储
过程内循环执行，客户端往返不再是主要开销）：

| 场景 | FASTMEM | MEMORY | InnoDB |
|---|---|---|---|
| A — 1 连接 × 2000 主键更新 | **1 s** | 1 s | 7 s |
| B — 8 连接 × 2000 主键更新 | **2 s** | 7 s | 30 s |
| C — 8 写 + 4 读 × 300 | **0 s** | 2 s | 5 s |
| D(r=0) — 8 写 × 500 | **1 s** | 1 s | 8 s |
| D(r=4) — 再加 4 读 × 500 | **1 s** | 2 s | 8 s |
| D(r=8) — 再加 8 读 × 500 | **1 s** | 2 s | 9 s |

18 项零丢失校验全部 PASS：每个阶段、每个引擎的 `SUM(close)` 增量都精确
等于已执行的 `+1` 语句数（2000 / 16000 / 2400 / 4000）——语句串行化的
读改写路径在 Linux 上与 Windows 一样正确。

本次运行的补充说明：

- 计时粒度为整秒，亚秒阶段收敛为 `0–1 s`，A/C/D 主要说明先后次序，
  B 才拉开真实并发差距（8 写热行：FASTMEM 2 s，MEMORY 7 s，InnoDB 30 s）。
- 随机热行 id 在 `UPDATE` 之前单独解析（`SET @sid=(…)` 之后
  `UPDATE … WHERE sid=@sid`）。若写成
  `WHERE sid=(SELECT … ORDER BY RAND() …)`，12.1.2 优化器会对每个候选行
  重新执行子查询（任何引擎场景 A 都要 205 s）——引擎对比不应为这种
  查询层产物买单。
- 插件通过 `conf.d` 里的 `plugin-load-add=ha_fastmem.so` +
  `plugin-maturity=beta` 随服务器启动加载（BETA 插件会被 `gamma` 默认值
  拒绝 `INSTALL`；而对已按命令行加载的插件再 `INSTALL` 会重复注册并
  导致服务器崩溃——两坑都不要踩）。

# Docker 指南 —— 构建 FASTMEM 镜像并跑三引擎对比

本指南全部内容在 Linux（Docker Desktop / WSL2，x86_64，12 vCPU）、
`mariadbd 12.1.2-MariaDB-ubu2404` 上**端到端实测通过**。它说明：服务端
镜像如何用与运行版本完全一致的官方源码现场编译插件，以及容器内如何执行
A–D 三引擎（FASTMEM vs MEMORY vs InnoDB）对比。

- Windows 基线与完整方法论：[`BENCHMARK.zh-CN.md`](BENCHMARK.zh-CN.md)
- 涉及脚本：[`docker/Dockerfile`](../docker/Dockerfile)、
  [`docker/run-benchmark.sh`](../docker/run-benchmark.sh)、
  [`docker/bench.sql`](../docker/bench.sql)、
  [`docker/bench.sh`](../docker/bench.sh)

## 1. 前置条件

| 要求 | 说明 |
|---|---|
| Docker Engine 24+（或 Docker Desktop） | Linux 容器 |
| 约 2 GB 磁盘 | MariaDB 源码包 ≈ 120 MB + 构建树 |
| 能访问 `archive.mariadb.org` | 源码下载；**不需要** GitHub |

宿主机不需要任何 MariaDB 软件包、头文件或工具链：构建全程在容器内完成。

## 2. 一键流程

```bash
./docker/run-benchmark.sh            # 默认 MARIADB_VERSION=12.1.2
./docker/run-benchmark.sh 12.1.2     # 显式指定
```

按顺序做四件事：

1. `docker build -f docker/Dockerfile` —— 两阶段镜像（见第 3 节）；
2. `docker run -d` 带 `MARIADB_ROOT_PASSWORD=bench` —— 官方 entrypoint
   初始化数据目录，我们投放的 `conf.d` 配置自动加载插件（见 3.2）；
3. `docker exec bash /bench/bench.sh` —— 完整 A–D 对比 + 逐阶段零丢失
   校验（见第 5 节）；
4. 报告打印到 stdout，并删除容器。

可重复执行：基准测试每次都会删表重建。镜像层有缓存，第二次跑只需支付
测试本身的时间（分钟级）。Docker Desktop 上**首次**构建可能 10–30 分钟
（apt 与解包在慢速块设备上）。

## 3. 镜像构建（`docker/Dockerfile`）

### 3.1 阶段一：按“完全相同的服务器版本”编译插件

`ubuntu:24.04` + 构建依赖（`build-essential cmake bison libssl-dev
libncurses-dev libpcre2-dev libxml2-dev libcurl4-openssl-dev
libkrb5-dev …`），然后：

```
下载  https://archive.mariadb.org/mariadb-<ver>/source/mariadb-<ver>.tar.gz
解压 → /work/src          （官方源码包自带全部子模块，含 libmariadb，
                            因此不需要 git）
/fastmem/install.sh --source-dir /work/src --jobs $(nproc)
```

`install.sh` 把 `storage/fastmem/` 放进服务器源码树，用服务器自带的
cmake 构建出 `ha_fastmem.so`。

**为什么必须在镜像内编译？** 存储引擎插件有严格的版本闸门：接口常量与
服务器构建不匹配会被直接拒绝
（`ERROR 1126 ... API version ... not supported`）。12.1.1 编译的 `.so`
加载进 12.1.2 服务器即失败。用与运行版本一致的源码现场编译是唯一可靠
方案——不存在可移植的预编译 `.so`。

### 3.2 阶段二：带插件的服务端镜像

```
FROM mariadb:<ver>
COPY --from=builder /work/ha_fastmem.so /usr/lib/mysql/plugin/
RUN printf '[mariadbd]\nplugin-load-add=ha_fastmem.so\nplugin-maturity=beta\n' \
    > /etc/mysql/mariadb.conf.d/99-fastmem.cnf
```

这个配置片段同时做两件事，必须放在一起理解：

- `plugin-load-add=ha_fastmem.so`：服务器启动即加载引擎，全程不需要
  `INSTALL PLUGIN`（重复注册的后果见第 6 节）；
- `plugin-maturity=beta`：放宽成熟度闸门。FASTMEM 如实声明 `BETA`，
  而 MariaDB ≥ 12.x 会拒绝低于配置成熟度的插件（发行版镜像可能默认
  `gamma`），否则报
  `Loading of beta plugin FASTMEM is prohibited by --plugin-maturity=gamma`。

## 4. 手动分步执行

```bash
# 构建
docker build -t fastmem-server:12.1.2 --build-arg MARIADB_VERSION=12.1.2 \
             -f docker/Dockerfile .

# 启动（官方 entrypoint 负责初始化数据目录）
docker run -d --name fastmem -e MARIADB_ROOT_PASSWORD=bench fastmem-server:12.1.2

# 确认引擎已就绪
docker exec fastmem mariadb -uroot -pbench -e "SHOW ENGINES; SHOW PLUGINS"
#   FASTMEM  YES  Lock-free in-memory tables (seqlock row images, per-slot writers)
#   FASTMEM  ACTIVE

# 跑基准（A–D 报告打印到 stdout）
docker exec -e MARIADB_ROOT_PASSWORD=bench fastmem bash /bench/bench.sh

# 当普通服务器继续用，或清理
docker rm -f fastmem
```

`SHOW ENGINES` 出现 `FASTMEM YES` 即“构建 + 加载”成功的唯一判据。

## 5. 基准测试设计（`docker/bench.sql` + `docker/bench.sh`)

### 5.1 数据夹具（`bench.sql`）

- 三张结构完全相同的表：`fm_kline`（FASTMEM）、`mm_kline`（MEMORY）、
  `inn_kline`（InnoDB），
  `sid VARCHAR(190) PRIMARY KEY, close DECIMAL(19,4)`；
- 用 MariaDB 内建序列表 `seq_1_to_7000` 灌入 7000 行（默认配置下
  `WITH RECURSIVE` 插入超过 1000 行会被 `max_recursive_iterations=1000`
  拒绝）；
- `hot_sids`：随机挑选 100 行作为争抢目标；
- worker 存储过程让循环在**服务器内**执行（客户端往返会淹没引擎差异）：
  - `fm_writer(tbl, n)`：n 次「先单独解析一个随机热行 `@sid`，再
    `UPDATE tbl SET close=close+1 WHERE sid=@sid`」；
  - `fm_reader(tbl, n)`：n 次全表 `SELECT SUM(close)`——对 FASTMEM 是
    无锁扫描，对 MEMORY 是表锁读者。

### 5.2 阶段与零丢失校验

每个阶段每引擎跑完后校验
`Δ SUM(close) == +1 语句数`——这是精确的丢失更新探测器：丢一条 RMW
就会当场暴露。

| 阶段 | 负载 | 预期 Δ |
|---|---|---|
| A | 1 连接 × 2000 主键更新 | 2000 |
| B | 8 连接并发 × 2000 | 16000 |
| C | 8 写 + 4 读 × 300 | 2400 |
| D | 8 写 × 500，读者 r∈{0,4,8} × 500 | 各 4000 |

### 5.3 计时口径

- 计时为整秒，快的阶段收敛为 `0–1 s`：A/C/D 看次序，B 看真实吞吐差距；
- 绝对数字取决于 vCPU/调度器，只在同一次运行内做引擎间对比；
- 热行 `sid` 刻意在 `UPDATE` 之前单独解析（`SET @sid=(…)`），不要写成
  `UPDATE … WHERE sid=(SELECT … ORDER BY RAND() …)`——原因见第 6 节。

## 6. 已踩平的全部坑（均为实测复现后修复）

1. **对 `plugin-load-add` 已加载的引擎再 `INSTALL` 会打崩服务器。**
   启动时已加载的插件再执行 `INSTALL PLUGIN fastmem SONAME
   'ha_fastmem.so'` 会重复注册，下一次 `SHOW ENGINES` 直接让
   `mariadbd` SIGSEGV（退出码 139）。加载路径二选一，镜像只用
   `conf.d`。
2. **成熟度闸门要在启动时生效。** `plugin-maturity=beta` 必须写在
   配置文件或服务器启动参数里；实测 12.1.2 上运行时
   `SET GLOBAL plugin_maturity='beta'` 并不能放行 `INSTALL`。
3. **BETA 插件 vs gamma 默认值。** 新服务器/发行版镜像可能把
   `plugin-maturity` 默认提到 `beta` 之上，加载即报
   `errno: 1 ... prohibited`。这是 FASTMEM 诚实声明成熟度，不是构建错误。
4. **`UPDATE ... WHERE sid=(SELECT ... ORDER BY RAND() LIMIT 1)`** 会被
   12.1.2 优化器按候选行逐行重复求值：任何引擎跑场景 A 都要 205 秒。
   先把 id 解析出来（5.1），否则测的是查询层而不是引擎。
5. **CTE 插入上限。** 默认配置下超过 1000 行的 `WITH RECURSIVE` 插入报
   `max_recursive_iterations=1000`；`seq_1_to_7000` 既绕开上限也无递归开销。
6. **Docker Hub 标签。** `mariadb:12.1.1` 从未发布（registry 返回
   `denied`）；补丁号标签 `12.1.2` 与分支标签 `12.1` 可用。插件必须与
   服务器构建精确匹配，所以 Dockerfile 用同一个 `MARIADB_VERSION` 同时
   决定源码包与基础镜像，建议始终指定具体补丁号。

## 7. 本平台实测结果

`./docker/run-benchmark.sh 12.1.2`（12 vCPU，x86_64）：

| 阶段 | FASTMEM | MEMORY | InnoDB | Δ 校验 |
|---|---|---|---|---|
| A | 1 s | 1 s | 7 s | 3× PASS |
| B | **2 s** | 7 s | 30 s | 3× PASS |
| C | **0 s** | 2 s | 5 s | 3× PASS |
| D(r=0) | 1 s | 1 s | 8 s | 3× PASS |
| D(r=4) | 1 s | 2 s | 8 s | 3× PASS |
| D(r=8) | 1 s | 2 s | 9 s | 3× PASS |

18/18 零丢失校验全部通过：FASTMEM 的行级写串行化在 Linux 的 8 写热行
争抢下完全正确，且在所有混合阶段都是最快引擎（MEMORY 付出整表锁代价，
InnoDB 付出行锁 + MVCC + buffer pool 机器开销）。

## 8. 清理

```bash
docker rm -f fastmem fastmem-bench-* 2>/dev/null
docker rmi fastmem-server:12.1.2     # 含阶段一缓存约 1 GB
docker builder prune -f              # 清掉构建缓存
```

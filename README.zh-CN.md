# FASTMEM — 无表锁内存表存储引擎

[![License: GPL-2.0](https://img.shields.io/badge/license-GPL--2.0-blue.svg)](LICENSE)
[![MariaDB](https://img.shields.io/badge/MariaDB-12.x-003545.svg)](https://mariadb.org)

[English](README.md) | 简体中文

FASTMEM 是面向 **MariaDB 12.x（已按 12.1.1 编译验证）** 的内存存储引擎，
目标是替代/超越内置 MEMORY（heap）引擎在"高并发读写"场景下的性能：
**完全去掉表级锁**，读路径无锁（seqlock），写路径行级自旋（槽锁 +
哈希桶锁）。

- 无事务（`HA_NO_TRANSACTIONS`），语句级语义，最后写入者获胜；
- 索引：**仅 HASH**（BTREE 在 CREATE 时直接报错拒绝，避免伪支持）；
- 与 MEMORY 相同的 SQL 约束：数据不持久化，`max_heap_table_size` 限制表大小。

详细设计与正确性证明见 [DESIGN.md](DESIGN.md)。

## 1. 目录结构

```
storage/fastmem/
├── fm_core.h         并发核心（无服务器依赖，C++17 + std::atomic）
├── fm_def.h          服务器侧内部定义（FM_SHARE / FM_INFO / 原型）
├── fm_create.cc      share 注册表与生命周期（create/open/close/rename/...）
├── fm_data.cc        行级操作：write/update/delete/rrnd/scan/info/自增
├── fm_hash.cc        键哈希/比较/打包（移植自 storage/heap/hp_hash.c）
├── ha_fastmem.h/.cc  THD handler（store_lock 返回零锁）
├── CMakeLists.txt    MYSQL_ADD_PLUGIN 接入
├── DESIGN.md         设计文档（中文）
├── standalone-test/  并发核心独立压测（不依赖服务器，cl/g++ 可直接编译）
└── mysql-test/       MTR 功能测试
```

## 2. 并发模型（30 秒速览）

- 每条记录一个**固定大小槽**；槽内带序号锁（seqlock）。
- **读**：复制槽镜像，两次读 seq 校验，失败重试 → 无锁、无撕裂。
- **写**：槽级自旋锁 `wlock` 串行化同一行；更新镜像前 seq 置奇，
  复制完置偶 → 读者要么看到旧值要么看到新值。
- **哈希**：每键 2^n 个桶，桶自旋锁保护链表指针；等值查找只取桶锁，
  行内容无锁读取。
- **位置引用**：8 字节 = 槽号 + 代号（generation）；槽被复用前代号 +1，
  所有过期引用立即失效 → 无悬垂指针。
- 全局互斥 `struct_mutex` 只用于 INSERT 分配 / DELETE 还槽 / TRUNCATE，
  **UPDATE 与读热路径永不触碰**。

详见 DESIGN.md 第 2、3 节。

### 2.1 写语句的行级串行化（read-modify-write 原子性）

SQL 层的 `UPDATE/DELETE` 是「读旧图 → 计算 → 写回」三步（跨 handler
两次调用）。若不串行化，两个并发写者会读到同一旧图、后写覆盖前写 →
**丢失更新**。修复（三步缺一不可）：

- `external_lock()` 收到 `F_WRLCK`（fcntl 常量，MariaDB 实际传入的
  锁类型）时置 `write_stmt` 标志（仅句柄内标志，**无任何表级锁**）；
- 写语句期间，每次读行（`index_read*` / `rnd_next` / `rnd_pos`）先对
  命中的行槽取 `wlock`，**然后在锁内重读该行**（定位时的预读可能已
  过期）——保证后续计算基于锁内的最新值；
- `update_row()` / `delete_row()` 在同一把锁内执行后释放；
- 效果：写者之间的整个「锁 → 重读 → 算 → 写」原子化（等价行锁，
  逐行释放），**纯 SELECT 完全不进锁路径**，无锁读保持。

## 3. 构建

### 3.1 编译独立测试（验证并发核心，最快路径）

无需服务器、无需 cmake；需要 MSVC（cl）或任一 C++17 编译器：

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvars64.bat"
cd storage\fastmem\standalone-test
cl /nologo /W3 /std:c++17 /O2 /EHsc /MT main.cpp /Fe:fmtest.exe
fmtest.exe
```

程序跑 4 组并发测试（撕裂检测 / 唯一键并发完整性 / 失效引用 /
多键记账），全部通过输出 `ALL TESTS PASSED`。

### 3.2 作为 MariaDB 插件编译

把 `storage/fastmem/` 目录放进任意 **MariaDB 12.x 源码树**的
`storage/` 下（本引擎在 **mariadb-12.1.1 发布版源码树**上完成编译验证；
13.x 开发树用作持续同步），然后正常 configure：

```bat
cmake -S . -B build ^
  -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
  -DCMAKE_GENERATOR_PLATFORM=x64 ^
  -DWITH_SSL=bundled ^
  -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO ...
cmake --build build --config RelWithDebInfo
```

`CMakeLists.txt` 通过 `MYSQL_ADD_PLUGIN(fastmem ... STORAGE_ENGINE)`
自动被 `CONFIGURE_PLUGINS()`（顶层 CMakeLists 第 503 行）发现。

> 注意：12.1.1 构建需补齐子模块并对齐版本：
> - wolfssl **v5.7.6-stable** → `extra/wolfssl/wolfssl/`
>   （12.1.1 的 `user_settings.h.in` 按 5.7.6 编写，5.7.2 会缺
>   `wolfSSL_CTX_get_verify_mode` 符号）
> - libmariadb（mariadb-connector-c 3.4+）→ `libmariadb/`
> - bison（Windows 用 winflexbison）→ `-DBISON_EXECUTABLE=...`
> - pcre2 由 cmake ExternalProject 联网下载（需能访问 github.com，
>   如走代理请配置 `https_proxy` 环境变量）

### 3.3 使用

```sql
INSTALL SONAME 'ha_fastmem';        -- 或启动时 --plugin-load-add=ha_fastmem
CREATE TABLE t (id INT PRIMARY KEY, v BIGINT NOT NULL)
  ENGINE=FASTMEM;
-- 普通 HASH 索引（非唯一）也支持
CREATE TABLE t2 (id INT, k INT, PRIMARY KEY(id),
                 KEY k1 (k)) ENGINE=FASTMEM;
```

行为与 MEMORY 引擎的公共契约一致：

- 行数上限由 `max_heap_table_size` 决定（CREATE 时估算槽位）；
- `TRUNCATE` 清空并复用内存；
- 无持久化：服务器重启数据清空；
- 需要重建且含 BTREE 索引的 DDL 不支持（显式 BTREE 会报
  `HA_ERR_UNSUPPORTED`）。

## 4. 与 MEMORY 对比要点

| 特性 | MEMORY (heap) | FASTMEM |
|------|---------------|---------|
| 整表锁 | 有（THR_LOCK） | **无** |
| UPDATE 并发 | 串行 | 行级，互不阻塞 |
| 读并发 | 被写者阻塞 | 无锁 |
| 唯一键冲突预检 | 表锁下天然安全 | 桶锁 + 原子校验 |
| ref | 裸指针 | 槽号 + 代号（防悬垂） |
| 数据布局 | HASH_INFO 链表 + 块游标 | 固定槽 + chunk，memcpy 平铺 |

## 5. 限制与取舍（有意设计）

- 无事务、无外键、无持久化（与 MEMORY 一致）；
- 只有 HASH 索引；`index_prev/index_first/index_last` 返回
  `HA_ERR_WRONG_COMMAND`（优化器会避开这些访问方式）；
- 全表扫描是"松散"的（扫描中途的行集变化是允许语义）；
- 并发键变更 UPDATE 存在已记录的孤儿链节点竞态（查找与删除会自动跳过
  键不匹配/已删除节点，功能正确；见 DESIGN.md 2.5）。

## 6. 实测基准（mariadb-12.1.1 / Windows x64 真机）

> 环境：`mariadb-12.1.1-MariaDB`，端口 3309，本地连接；表为 7000 行
> 行情 K 线数据（主键 varchar(50) + 2 个索引），100 个热行；每个工作
> 进程是一个独立的 `mysql` 客户端连接；基准脚本在 `bench/` 目录。
> 完整报告：[docs/BENCHMARK.zh-CN.md](docs/BENCHMARK.zh-CN.md)。

三引擎对比（FASTMEM / 系统 MEMORY / InnoDB）：

| 场景 | FASTMEM | MEMORY | InnoDB |
|------|---------|--------|--------|
| A. 单连接 2000 条 UPDATE | **0.50 s** | 1.37 s | 0.55 s |
| A. 单连接 500 次 SUM 全扫 | 0.67 s | **0.58 s** | 1.13 s |
| B. 8 进程 × 2000 条并发 UPDATE | **1.03 s** | 8.08 s | 1.06 s |
| C. 热行碰撞 8 写者 + 4 读者 × 300 | **1.23 s** | 1.90 s | 1.62 s |
| D. 8 写者 × 500，无读者 | **0.80 s** | 2.42 s | 0.79 s |
| D. 8 写者 × 500，4 读者 | **1.41 s** | 2.86 s | 2.09 s |
| D. 8 写者 × 500，8 读者 | **1.83 s** | 3.16 s | 2.94 s |

上表每一行同时也是正确性校验：结束后 `SUM(close)` 与期望增量精确
相等——**所有轮次零丢失更新**。

要点：

- **并发写是表锁的照妖镜**：MEMORY 把 16000 次更新全部串在表锁上
  （8.08 s，慢约 8 倍）；FASTMEM 写者只触碰目标行的槽自旋锁；
- **读者永不阻塞写者**：读者 0 → 4 → 8 递增时，FASTMEM 写者耗时退化
  最缓（0.80 → 1.83 s）——FASTMEM 读是纯 seqlock 拷贝，不取任何锁；
- 单连接场景三者接近——端到端延迟被 MySQL 协议/连接层主导（本地单
  连接净开销 ~200ms），引擎内部数据路径为亚微秒级；
- 并发自增 4 进程 × 250 行：id 1..1000 连续**无重复无缺口**。

## 7. Windows 实测构建与部署（mariadb-12.1.1）

本引擎已在 `mariadb-12.1.1` 源码 + VS2022 (MSVC x64) 下编译出
`ha_fastmem.dll` 并实机验证。要点：

1. **源码与子模块**：下载 `mariadb-12.1.1` 发布包后补齐子模块——
   `extra/wolfssl/wolfssl/` 必须是 **v5.7.6-stable**
   （12.1.1 的 `user_settings.h.in` 按 5.7.6 编写，5.7.2 会缺
   `wolfSSL_CTX_get_verify_mode` 符号）；`libmariadb/` 用
   mariadb-connector-c 3.4；bison/flex 用 winflexbison。
2. **pcre2**：cmake 构建期会联网下载（external project），需能访问
   github.com（走代理时设置 `https_proxy`/`http_proxy` 环境变量）。
3. **configure**：
   ```
   cmake -S <src> -B <src>\build -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
     -DCMAKE_GENERATOR_PLATFORM=x64 -DWITH_UNIT_TESTS=OFF ^
     -DUPDATE_SUBMODULES=OFF -DBISON_EXECUTABLE=<winflexbison>\bison.exe ^
     -DFLEX_EXECUTABLE=<winflexbison>\flex.exe -DWITH_WSREP=OFF ^
     -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_OQGRAPH=NO ^
     -DPLUGIN_SPIDER=NO -DPLUGIN_TOKUDB=NO -DPLUGIN_CONNECT=NO ^
     -DPLUGIN_FEDERATED=NO -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_DUCKDB=NO ^
     -DPLUGIN_S3=NO
   ```
   然后 `PLUGIN_FASTMEM=DYNAMIC` 确认生效。
4. **构建插件**（会连带生成服务器导入库，耗时较长）：
   ```
   cmake --build <src>\build --config RelWithDebInfo --target fastmem -- -m
   ```
   产物：`<src>\build\storage\fastmem\RelWithDebInfo\ha_fastmem.dll`
5. **移植/编译注意**（相对 13.x 树的差异，已修）：
   - 12.1.1 无 `my_hasher_st`/`MY_HASH_ADD_MARIADB`，hash 用
     `my_ci_hash_sort` + nr/nr2 滚动（见 `fm_hash.cc`）；
   - `my_malloc`/`my_strdup` 首参为 PSI key（`PSI_NOT_INSTRUMENTED`）；
   - `current_thd` 宏在 `mysqld.h`，且 THD 完整定义需要
     `#define MYSQL_SERVER 1`（`fm_create.cc` 已加）；
   - `TABLE` 前置声明用 `struct TABLE;`（与 12.1.1 sql 头一致）。
6. **部署与测试**（需要管理员权限，插件目录与服务均受保护）：
   ```
   powershell -ExecutionPolicy Bypass -File deploy_admin.ps1
   ```
   脚本完成：拷贝 DLL 到 `lib\plugin`、启动服务、`INSTALL SONAME
   'ha_fastmem'`、建表冒烟、并发写入验证。
7. **基准**：`mysql -uroot < bench\bench_compare.sql`
   （FASTMEM vs MEMORY 单连接 UPDATE/INSERT/SELECT 基线）；
   多线程并发用外部客户端（如 sysbench）对同一引擎表多连接压测，
   重点观察再无表锁阻塞、读写相互不等待。

## 8. License

**GPL-2.0**（与 MariaDB 服务器一致）。本引擎移植了 MEMORY 引擎的键哈希/
比较函数（`fm_hash.cc`），同样遵循 GPL-2.0 许可。

---

[English](README.md)
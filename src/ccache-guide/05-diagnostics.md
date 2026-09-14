# 05 诊断与维护：命中率、miss 的原因、缓存清理

> 核对版本：ccache 4.13.6 与 4.14。「实测」指 [`examples/`](examples/) 下的脚本。

## 1. 看总体：`-s` 与 `--print-stats`

```bash
ccache -s          # -s / --show-stats：给人看的摘要
ccache -s -v       # -v 一次：多出配置文件路径、Uncacheable / Errors 的细项；-v 两次更细
ccache -z          # -z / --zero-stats：计数器清零，不动缓存内容与配置
```

[`01-basics`](examples/01-basics/run.sh) 里一次 miss 一次 hit 之后的 `ccache -s`：

```text
Cacheable calls:      2 /   2 (100.0%)
  Hits:               1 /   2 (50.00%)
    Direct:           1 /   1 (100.0%)
    Preprocessed:     0 /   1 ( 0.00%)
  Misses:             1 /   2 (50.00%)
Local storage:
  Cache size (GiB): 0.0 / 5.0 ( 0.00%)
  Hits:               1 /   2 (50.00%)
  Misses:             1 /   2 (50.00%)
```

- `Cacheable calls`：可缓存的调用数 / 总调用数。后者还包括链接、`-E` 之类不可缓存的调用；
- `Direct` / `Preprocessed`：命中分别来自哪种模式（[01 §4–5](01-model.md)）。`Preprocessed` 那一行的分母是
  「direct 模式没命中、回落到 preprocessor 模式」的次数；
- `Local storage` / `Remote storage`：命中来自本地还是远端。

计数器不参与任何构建决策，随时清零都不影响缓存。

**脚本里请用 `--print-stats`**：输出「计数器名 TAB 值」，名字是稳定的机器接口；`-s` 的措辞会随版本调整。
`--format json` 输出 JSON。[`examples/lib.sh`](examples/lib.sh) 里的 `expect` 就是读它。

## 2. 只看一次构建：`stats_log`

```bash
export CCACHE_STATSLOG=$PWD/build.stats   # 本次构建的计数器增量另写一份
cmake --build build
ccache --show-log-stats                   # 汇总这份日志；加 -v 看细项
ccache --print-log-stats --format json    # 机器可读
```

与「先 `-z` 再 `-s`」相比，它的好处是：不受同一缓存目录上并发构建的干扰，也不必清掉全局计数器。
实测输出见 [`04-debug-miss`](examples/04-debug-miss/run.sh)。

## 3. 为什么 miss：debug 模式

**是什么**：设 `debug = true`（或 `CCACHE_DEBUG=1`）后，每次编译额外写出一组文件，记录**参与哈希的全部输入**。
默认写在目标文件旁；设了 `debug_dir` 则按绝对路径镜像到该目录下。文件名带时间戳，多次编译不互相覆盖：

| 文件 | `debug_level` | 内容 |
|---|---|---|
| `<目标文件>.<时间戳>.ccache-input-c` | 2 | 两种模式共同哈希的二进制输入 |
| `<目标文件>.<时间戳>.ccache-input-d` | 2 | 只有 direct 模式哈希的输入 |
| `<目标文件>.<时间戳>.ccache-input-p` | 2 | 只有 preprocessor 模式哈希的输入 |
| `<目标文件>.<时间戳>.ccache-input-text` | 2 | 上面三份的可读文本版，分 COMMON / DIRECT MODE / PREPROCESSOR MODE 三节 |
| `<目标文件>.<时间戳>.ccache-log` | 1 | 这一次编译的日志 |

`debug_level` 默认 2；设 1 只写日志。

**排查步骤**：

1. 开 `debug`，构建一次；
2. 清掉产物，在「会 miss 的条件」下再构建一次；
3. `diff` 两次的 `ccache-input-text`，差异就是原因；`ccache-log` 里的 `Result:` 行是结论。

[`04-debug-miss`](examples/04-debug-miss/run.sh) 模拟两个人仅 `LANG` 不同，diff 的结果只有一处：

```text
11c11
< C
---
> zh_CN.UTF-8
```

对应 `ccache-log` 里的结论行：

```text
Result: cache_miss
Result: direct_cache_miss
Result: preprocessed_cache_miss
Result: local_storage_miss
…
```

修复是 `sloppiness = locale`，改完两人互相命中。

## 4. 全局日志：`log_file`

`log_file = <路径>` 让所有调用都往一个文件里追加日志，每行带时间与进程号；值为 `syslog` 时写 syslog。
比 debug 模式轻，适合看「远端连上了没有」「读到了哪些配置」。08 里用它观察到的几类行：

```text
Config: (/…/ccache.conf) remote_storage = http://127.0.0.1:46219/cache
Could not find remote storage helper program "ccache-storage-http"
Spawning storage helper …/ccache-storage-http for /run/user/1000/ccache-tmp/storage-http-…
Stored 6d87b2425683… in local storage (…)
```

## 5. 直接读缓存条目

```bash
ccache --inspect <条目文件>          # 打印 manifest 或结果条目的内容（嵌入的文件数据不打印）
ccache --extract-result <结果条目>   # 把结果条目里存的文件解到当前目录，名为 ccache-result.*
ccache --checksum-file <文件>        # 128 位 XXH3 校验和（- 表示标准输入）
ccache --hash-file <文件>            # 160 位 BLAKE3 哈希，调试用
```

条目文件在缓存目录的两级子目录下，文件名本身看不出类型，`--inspect` 的 `Entry type` 行会写明
`0 (result)` 或 `1 (manifest)`。manifest 的 `File paths` 一节就是 direct 模式记下的头文件清单（04 实测）。

## 6. 修复与维护

| 做什么 | 命令 | 说明 |
|---|---|---|
| 怀疑缓存里有坏目标文件 | 删掉构建树里那个文件，`CCACHE_RECACHE=1` 重新构建 | 不读缓存、重新编译并覆盖条目（04 实测 `recache = 1`） |
| 清空缓存 | `ccache -C` | `--clear`：删除全部条目，保留配置（02 实测） |
| 强制全量清理 | `ccache -c` | `--cleanup`：按上限清理并重新统计大小。平时不需要，自动清理已在进行 |
| 把本地缓存压到指定大小 | `CCACHE_MAXSIZE=10GiB ccache -c` | 临时上限只对这一次清理生效 |
| 按年龄淘汰 | `ccache --evict-older-than 7d` | 删掉最近一次使用早于该年龄的条目；后缀 `d` `s`，4.13 起另有 `h` `m` `ms`（10 实测） |
| 按工程淘汰 | `ccache --evict-namespace <名字>` | 只删某个 `namespace` 的条目，可与 `--evict-older-than` 组合（10 实测） |
| 先看会删多少 | 上面任一命令加 `--dry-run` | 4.14+。实测 `--evict-older-than 0s --dry-run` 打印 `Would remove data: 4.0 KiB` / `Would remove files: 1`，条目数不变；4.13.6 报 unrecognized option |
| 看压缩效果 | `ccache -x` | `--show-compression`：要遍历全部条目，可能较慢 |
| 重压缩 | `ccache -X 10` | `--recompress <级别>`，或 `uncompressed`；`--threads <N>` 控制并行度 |

## 7. 常见「不可缓存」计数器

`ccache -s -v` 里 Uncacheable 与 Errors 的细项，对应 `--print-stats` 的计数器名：

| 计数器 | 含义 | 怎么办 |
|---|---|---|
| `called_for_link` | 调用是链接 | 正常，无需处理 |
| `called_for_preprocessing` | 调用只做预处理 | 正常 |
| `multiple_source_files` | 一次编译多个源文件 | 构建系统层面改成一个文件一次调用，否则无法缓存 |
| `no_input_file` | 没有输入文件 | 常见于 configure 探测编译器（06 实测：一次 autotools configure 记了 5 次） |
| `autoconf_test` | autoconf 的 conftest 编译 | 正常（06 实测：3 次） |
| `unsupported_compiler_option` | 有 ccache 不支持的选项 | 开 debug 看是哪个选项；确认它不影响输出时可加进 `ignore_options` |
| `could_not_use_precompiled_header` / `preprocessor_error` | 预编译头的前置条件不满足 | 见 [06 坑](06-pitfalls.md) 里的预编译头条目 |
| `unsupported_code_directive` | 源码里有 `.incbin` 之类 | 确认被包含的文件不变时可设 `sloppiness = incbin` |
| `compiler_check_failed` | `compiler_check` 的命令执行失败 | 检查命令本身 |
| `error_hashing_extra_file` | `extra_files_to_hash` 里的文件读不到 | 检查路径 |
| `remote_storage_error` / `remote_storage_timeout` | 远端出错或超时 | 看 `log_file`；调 `data-timeout` / `request-timeout` |
| `cleanups_performed` | 发生过自动清理 | 若构建中频繁增长，说明 `max_size` 太小，条目刚存进去就被挤掉 |

## 8. miss 排查清单

1. **调用真的经过 ccache 了吗**：`ccache -z`，构建，`ccache -s` 的 `Cacheable calls` 应当增长。
   CMake + Ninja 看 `build.ninja` 里的 `LAUNCHER =` 行（[05-cmake](examples/05-cmake/run.sh)），
   Meson 看 `rule c_COMPILER` 的命令（[07-meson](examples/07-meson/run.sh)）。
2. **有没有大量不可缓存的调用**：`ccache -s -v`，对照 §7。
3. **同一条命令原地重跑也 miss**：源码里有 `__TIME__` 等宏（[02](examples/02-cache-key/run.sh)）；文件刚被改过、
   mtime 太新（[01 §5](01-model.md)）；`max_size` 太小导致刚存就被清理（`cleanups_performed`）。
4. **换个目录、换台机器才 miss**：
   - 带 `-g` 且 `hash_dir` 为真 → 工作目录进键（[03](examples/03-cross-dir/run.sh)、[06](examples/06-make-autotools/run.sh)、[07](examples/07-meson/run.sh)）；
   - 命令行里有绝对路径 → 设 `base_dir`（03）；
   - `LANG` 等语言环境不同 → `sloppiness = locale`（[04](examples/04-debug-miss/run.sh)）；
   - 编译器文件的 mtime 不同（不同机器各自安装）→ `compiler_check = content` 或命令形式（02）；
   - `namespace` 不同（[10](examples/10-ci-lifecycle/run.sh)）。
5. **仍然不明**：debug 模式 + diff（§3）。
6. **命中了，但多是 preprocessed 而少有 direct**：说明 direct 模式常常对不上而回落，手册列出的常见原因有：改了不影响
   预处理输出的源码或 `-D` / `-I`；刚改过 `base_dir`；头文件 mtime 太新；源码含 `__TIME__` 等宏；输入文件路径变了
   （影响 `__FILE__`）。preprocessed 命中每次都要跑预处理器，比 direct 命中慢。

下一篇：[06 坑与版本差异](06-pitfalls.md)。

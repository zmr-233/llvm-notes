# 02 配置：从哪读、怎么写、每个选项管什么

> 核对版本：ccache 4.13.6 与 4.14。选项的默认值与含义出自两个版本的官方手册（`doc/manual.adoc`），
> 标「实测」的行为由 [`examples/`](examples/) 或下文给出的命令验证过。

## 1. 配置从哪来：六个来源与优先级

从高到低：

| # | 来源 | 例子 |
|---|---|---|
| 1 | 命令行上的 `键=值`，写在 ccache 与编译器之间 | `ccache sloppiness=time_macros gcc -c a.c` |
| 2 | 环境变量 `CCACHE_*` | `CCACHE_DIR=/data/ccache` |
| 3 | 目录级配置文件（4.13+） | 仓库根目录下的 `ccache.conf` |
| 4 | 缓存级配置文件 | `~/.config/ccache/ccache.conf` 或 `$CCACHE_DIR/ccache.conf` |
| 5 | 系统级配置文件 | `/etc/ccache.conf` |
| 6 | 编译期默认值 | |

**例外**：设了环境变量 `CCACHE_CONFIGPATH`，就**只读它指向的这一份文件**，3、4、5 全不读
（实测：同一目录下有目录级 `ccache.conf` 时，设了 `CCACHE_CONFIGPATH` 后 `ccache -p` 显示的来源是后者）。
1、2 仍然生效。[`examples/lib.sh`](examples/lib.sh) 正是靠它把每个例子与机器上的真实配置隔开。

### 看当前生效的是什么

```bash
ccache -p                 # -p / --show-config：每项的值，括号里是来源
ccache -k max_size        # -k / --get-config <键>：只打印一项的值
ccache -s -v              # -s 统计摘要；-v 详细，开头几行列出各配置文件的路径
```

`ccache -p` 的输出长这样，括号里是来源——`default`、`environment`，或者某个配置文件的路径：

```text
(default) cache_dir = /home/me/.cache/ccache
(environment) namespace = env
(/work/proj/ccache.conf) sloppiness = locale
```

`ccache -s -v` 开头的几行回答「到底读了哪几个文件」：

```text
Cache directory:       /home/me/.cache/ccache
Config file:           /home/me/.config/ccache/ccache.conf
Directory config file:
System config file:    /etc/ccache.conf
```

### 缓存级配置文件在哪

非 Windows 系统上按下面顺序取第一个满足条件的：

1. 设了 `CCACHE_CONFIGPATH` → 它；
2. 设了 `CCACHE_DIR` → `$CCACHE_DIR/ccache.conf`；
3. 系统级配置里设了 `cache_dir` → `<cache_dir>/ccache.conf`；
4. 存在遗留目录 `~/.ccache` → `~/.ccache/ccache.conf`；
5. 设了 `XDG_CONFIG_HOME` → `$XDG_CONFIG_HOME/ccache/ccache.conf`；
6. 否则 `~/.config/ccache/ccache.conf`（macOS 为 `~/Library/Preferences/ccache/ccache.conf`）。

注意**缓存目录与配置文件默认不在一处**：缓存在 `~/.cache/ccache`，配置在 `~/.config/ccache/ccache.conf`。

### 用命令改缓存级配置

```bash
ccache -M 50GiB                # -M / --max-size：设上限，写进缓存级配置文件
ccache -F 0                    # -F / --max-files：文件数上限，0 为不限
ccache -o sloppiness=locale    # -o / --set-config 键=值：任意一项写进缓存级配置文件
ccache --config-path x.conf -o compression_level=3   # --config-path：改的是指定文件（等价于临时设 CCACHE_CONFIGPATH）
```

实测：`CCACHE_DIR=d1 ccache -M 3G` 之后，`d1/ccache.conf` 里多出一行 `max_size = 3G`；
再 `-o sloppiness=locale` 追加一行。

## 2. 语法

- 配置文件是 `键 = 值`，一行一项；`#` 开头是注释；空行与键值两侧的空白被忽略。
- **环境变量展开**：值里的 `$VAR` 或 `${VAR}` 被替换，`$$` 表示字面的 `$`（实测：`base_dir = ${HOME}/x` 展开正确）。
  变量未设置时展开为空串。
- **多行值**（4.13+）：以空格或制表符开头的行是上一行的续行，合并时用一个空格连接，中间的注释行与空行被跳过
  （实测：`ignore_options =` 后跟三行缩进内容，`ccache -p` 显示合并成一行）。
- **路径列表**用 `:` 分隔（Windows 用 `;`），如 `base_dir`、`extra_files_to_hash`。
- **大小**：`kB MB GB TB` 是十进制，`KiB MiB GiB TiB` 是二进制，不写后缀默认 GiB；`0` 表示不限。
- **布尔值**：
  - 配置文件里只能写 `true` / `false`；
  - 环境变量**设了即为真，空串也算**；写成 `0`、`false`、`disable`、`no` 会直接报错，而不是当成假
    （实测：`CCACHE_COMPRESS=0 ccache -p` 退出码 1，提示「did you mean to set CCACHE_NOCOMPRESS=true?」）；
  - 每个布尔变量都有取反形式 `CCACHE_NO…`，如 `CCACHE_NOCOMPRESS=1` 表示关闭压缩。
- **不认识的键**：在缓存级 / 系统级配置文件、环境变量、命令行里都被**静默忽略**；只有目录级配置文件会报错
  （实测，两个版本一致）。拼错一个键不会有任何提示——[`conf/check.sh`](conf/check.sh) 就是为此逐项核对的。

## 3. 目录级配置文件（4.13+）

ccache 从编译命令的工作目录开始，逐级向上找名叫 `ccache.conf` 的文件，遇到下列任一情况停止：

- 到达 `ceiling_dirs` 里列出的目录（默认是家目录）；
- 到达包含 `ceiling_markers` 所列名字的目录（默认 `.git`）——所以放在仓库根目录的 `ccache.conf` 能被找到；
- 到达属于其他用户的目录，或者跨越了文件系统边界（挂载点）。

找到的文件必须属于当前用户、不能是所有人可写，否则 ccache **报错退出**（实测：`chmod 666` 后报
「is world-writable」，退出码 1）。

**为什么要限制**：目录级文件随仓库一起被克隆下来，内容不由你控制。若允许它设置「执行什么命令、
写哪些文件、连哪个远端」，克隆一个仓库再编译就可能执行任意命令或把数据发到别处。所以它能写的选项被分成三类
（实测：逐个选项写进目录级文件跑 `ccache -p`，4.13.6 与 4.14 结果相同）：

| 类别 | 选项 |
|---|---|
| 允许 | `absolute_paths_in_stderr` `base_dir` `compiler_check` `compiler_type` `compression` `compression_level` `debug` `debug_level` `depend_mode` `direct_mode` `disable` `extra_files_to_hash` `file_clone` `hard_link` `hash_dir` `ignore_headers_in_manifest` `ignore_options` `inode_cache` `keep_comments_cpp` `msvc_dep_prefix` `msvc_utf8` `namespace` `pch_external_checksum` `read_only` `read_only_direct` `recache` `remote_only` `reshare` `response_file_format` `sloppiness` `stats`（4.13 另有 `cpp_extension`，4.14 已删除该选项） |
| 不安全：只在 `safe_dirs` 列出的目录下允许 | `compiler` `debug_dir` `libexec_dirs` `log_file` `path` `prefix_command` `prefix_command_cpp` `remote_storage` `stats_log` `temporary_dir` `umask` |
| 一律不允许 | `cache_dir` `ceiling_dirs` `ceiling_markers` `max_files` `max_size` `safe_dirs` |

违反时的报错原文：

```text
ccache: error: …/ccache.conf:2: configuration option "max_size" is not allowed in directory configuration files
ccache: error: …/ccache.conf:2: configuration option "prefix_command" is considered unsafe and is only allowed in directory configuration files located under safe_dirs
```

`safe_dirs`（只能写在目录级以外的配置里）取值：`*` 表示任何目录；以 `/*` 结尾的绝对路径表示其下任意深度；
不以 `/*` 结尾的绝对路径只匹配该目录本身。

范例：[`conf/project.ccache.conf`](conf/project.ccache.conf)。

## 4. 选项分组详解

下表「环境变量」一列里，布尔选项的取反形式（`CCACHE_NO…`）不再重复列出。

### 4.1 缓存放在哪、多大、怎么存

| 选项 | 环境变量 | 默认 | 作用 |
|---|---|---|---|
| `cache_dir` | `CCACHE_DIR` | `~/.cache/ccache`（见 01 §8） | 本地缓存目录 |
| `max_size` | `CCACHE_MAXSIZE` | 5GiB | 总大小上限，0 不限 |
| `max_files` | `CCACHE_MAXFILES` | 0 | 条目文件数上限，0 不限 |
| `compression` | `CCACHE_COMPRESS` | true | zstd 压缩。缓存所在文件系统已压缩时可关 |
| `compression_level` | `CCACHE_COMPRESSLEVEL` | 0（即 1） | 正数为常规级别，负数为「超快」级别；手册建议编译时不超过 5，更高级别留给 `ccache -X` 重压缩 |
| `file_clone` | `CCACHE_FILECLONE` | false | 用 reflink（写时复制）存取，文件系统不支持则退回复制。开启后不压缩 |
| `hard_link` | `CCACHE_HARDLINK` | false | 用硬链接存取。开启后不压缩；改动构建树里的目标文件会破坏缓存，且共享 inode 会让 make 误判需要重链接 |
| `inode_cache` | `CCACHE_INODECACHE` | true | 按设备号 + inode + 时间戳缓存文件哈希，需要 `temporary_dir` 在受支持的本地文件系统上 |
| `temporary_dir` | `CCACHE_TEMPDIR` | `$XDG_RUNTIME_DIR/ccache-tmp`，否则 `<cache_dir>/tmp` | 临时文件目录 |
| `umask` | `CCACHE_UMASK` | 空 | 缓存内新建文件与目录的权限掩码；多人共享时设 002 |
| `stats` | `CCACHE_STATS` | true | 是否更新计数器。设 false 会**同时关掉自动清理** |
| `stats_log` | `CCACHE_STATSLOG` | 空 | 另把计数器增量写进这个文件，供 `--show-log-stats` 按单次构建查看 |

### 4.2 键的构成

| 选项 | 环境变量 | 默认 | 作用 |
|---|---|---|---|
| `compiler_check` | `CCACHE_COMPILERCHECK` | `mtime` | 编译器身份怎么进键：`mtime`（mtime + 大小）、`content`（文件内容）、`none`、`string:<值>`、或一条命令（`%compiler%` 替换为编译器路径，`;` 分隔多条，哈希其输出）。实测见 02 |
| `extra_files_to_hash` | `CCACHE_EXTRAFILES` | 空 | 额外哈希这些文件的内容（路径列表）。实测见 09 |
| `hash_dir` | `CCACHE_HASHDIR` | true | 有 `-g` 时把 CWD 放进键；恰当地用了 `-fdebug-prefix-map` 或 `-fdebug-compilation-dir` 时自动不放。实测见 03 |
| `base_dir` | `CCACHE_BASEDIR` | 空 | 路径列表（4.12 起可多个）。落在其下的绝对路径先改写成相对 CWD 的路径，再算键、再交给编译器。实测见 03 |
| `namespace` | `CCACHE_NAMESPACE` | 空 | 字符串进键，逻辑上隔开不同工程的条目；可 `--evict-namespace` 单独清掉。实测见 10 |
| `ignore_options` | `CCACHE_IGNOREOPTIONS` | 空 | 空格分隔的选项，末尾可带 `*` 通配；匹配的选项不进键、也不被特殊解释 |
| `ignore_headers_in_manifest` | `CCACHE_IGNOREHEADERS` | 空 | 这些头文件（或目录下的头文件）不记进 manifest；它们变了也可能命中 |
| `keep_comments_cpp` | `CCACHE_COMMENTS` | false | preprocessor 模式哈希时保留注释，配合 `-Wdocumentation` 这类看注释的警告 |
| `sloppiness` | `CCACHE_SLOPPINESS` | 空 | 放宽某些检查以提高命中率，取值见下表 |
| `pch_external_checksum` | `CCACHE_PCH_EXTSUM` | false | 预编译头 `x.gch` 旁若有 `x.gch.sum`，哈希它而不是巨大的 PCH 本身 |

`sloppiness` 的取值（逗号或空白分隔，可多选）：

| 取值 | 放宽了什么 | 代价 |
|---|---|---|
| `time_macros` | 源码里有 `__DATE__` `__TIME__` `__TIMESTAMP__` 也照常缓存 | 这些宏的值取自入缓存那一刻（实测见 02） |
| `locale` | `LANG` `LC_ALL` `LC_CTYPE` `LC_MESSAGES` 不进键 | 缓存里的警告文本可能是另一种语言（实测见 04） |
| `pch_defines` | 使用预编译头时放宽对 `#define` 的检查 | 可能察觉不到某些宏定义的变化 |
| `include_file_mtime` `include_file_ctime` | 不再因为文件「太新」而放弃缓存 | 可能错过刚发生的修改（见 01 §5 的竞态） |
| `system_headers` | direct 模式只跟踪非系统头文件 | 系统头文件变了察觉不到（preprocessor 模式仍检查） |
| `file_stat_matches` `file_stat_matches_ctime` | 文件的 stat 信息一致就认为内容一致 | 内容变而时间戳不变时察觉不到 |
| `modules` | 允许缓存 Clang `-fmodules` 编译（还需同时开 direct 与 depend 模式） | 察觉不到模块内部状态变化 |
| `incbin` | 允许缓存含汇编 `.incbin` 的编译 | 被包含的二进制文件变了察觉不到 |
| `gcno_cwd` | 覆盖率文件 `.gcno` 不把 CWD 进键 | `.gcno` 里的目录信息可能不对 |
| `random_seed` | 忽略 `-frandom-seed` 的值 | 构建不再严格可复现 |
| `clang_index_store` `ivfsoverlay` | 忽略 Xcode 相关的 `-index-store-path`、`-ivfsoverlay` | 索引、VFS 变化察觉不到 |

### 4.3 模式与开关

| 选项 | 环境变量 | 默认 | 作用 |
|---|---|---|---|
| `direct_mode` | `CCACHE_DIRECT` | true | direct 模式，见 01 §5 |
| `depend_mode` | `CCACHE_DEPEND` | false | depend 模式，见 01 §6；须同时开着 direct 模式 |
| `read_only` | `CCACHE_READONLY` | false | 只读缓存、不写入（计数器仍更新）。缓存目录本身只读时还要另设 `temporary_dir` |
| `read_only_direct` | `CCACHE_READONLY_DIRECT` | false | 同上，且只用 direct 模式取结果 |
| `recache` | `CCACHE_RECACHE` | false | 不读缓存，但把新结果写入（覆盖）。实测见 04 |
| `disable` | `CCACHE_DISABLE` | false | 完全旁路，直接调用真编译器。单个源文件可在前 4096 字节的注释里写 `ccache:disable`。实测见 01 |
| `remote_storage` `remote_only` `reshare` | 见 [04 远端存储](04-remote-storage.md) | | |

### 4.4 怎么调用编译器

| 选项 | 环境变量 | 默认 | 作用 |
|---|---|---|---|
| `compiler` | `CCACHE_COMPILER` | 空 | 强制使用这个编译器，而不是从命令行推断 |
| `compiler_type` | `CCACHE_COMPILERTYPE` | `auto` | 按名字猜类型；非标准名字可强制为 `clang` `clang-cl` `gcc` `icl` `icx` `icx-cl` `msvc` `nvcc` `qcc`（4.14+） `other` |
| `path` | `CCACHE_PATH` | 空 | 找真编译器时搜索的目录列表；不设则沿 `PATH` 找第一个不是指向 ccache 的同名程序 |
| `prefix_command` | `CCACHE_PREFIX` | 空 | 调用编译器时加在前面的命令，如 `distcc`。实测见 09 |
| `prefix_command_cpp` | `CCACHE_PREFIX_CPP` | 空 | 调用预处理器时加在前面的命令 |
| `absolute_paths_in_stderr` | `CCACHE_ABSSTDERR` | false | 把诊断信息里的相对路径改回绝对路径（配合 `base_dir`，编译器工作目录与构建系统不一致时有用） |
| `response_file_format` | `CCACHE_RESPONSE_FILE_FORMAT` | `auto` | `@文件` 形式的参数文件按 `posix` 还是 `windows` 规则解析 |
| `msvc_dep_prefix` `msvc_utf8` | | | 仅 MSVC |
| `cpp_extension` | `CCACHE_EXTENSION` | 空 | 强制预处理输出的扩展名。**4.14 删除**：此后在普通配置里被静默忽略，在目录级配置里报 unknown option（实测） |

### 4.5 调试与诊断

| 选项 | 环境变量 | 默认 | 作用 |
|---|---|---|---|
| `debug` | `CCACHE_DEBUG` | false | 为每个目标文件写出调试文件，见 [05 诊断](05-diagnostics.md) |
| `debug_dir` | `CCACHE_DEBUGDIR` | 空 | 调试文件不写在目标文件旁，而是按绝对路径镜像到此目录下 |
| `debug_level` | `CCACHE_DEBUGLEVEL` | 2 | 1 只写 `.ccache-log`；2 另写哈希输入文件 |
| `log_file` | `CCACHE_LOGFILE` | 空 | 所有调用的日志写进这个文件；值为 `syslog` 时写 syslog |

### 4.6 找配置文件与助手程序

| 选项 | 环境变量 | 默认 | 作用 |
|---|---|---|---|
| `ceiling_dirs` | `CCACHE_CEILING_DIRS` | 家目录 | 找目录级配置文件时到此为止 |
| `ceiling_markers` | `CCACHE_CEILING_MARKERS` | `.git` | 遇到含这些名字的目录为止 |
| `safe_dirs` | `CCACHE_SAFE_DIRS` | 空 | 这些目录下的目录级配置文件可以设置「不安全」选项 |
| `libexec_dirs` | `CCACHE_LIBEXEC_DIRS` | 编译期决定（本机为 `/usr/libexec`） | 找远端存储助手程序的目录 |

## 5. 现成的配置文件

[`conf/`](conf/) 下每份文件都逐项注释了取值理由，并由 [`conf/check.sh`](conf/check.sh) 校验每个键都被 ccache 接受：

| 文件 | 场景 |
|---|---|
| [`personal.conf`](conf/personal.conf) | 个人开发机 |
| [`llvm-dev.conf`](conf/llvm-dev.conf) | 开发 LLVM：多 worktree、多构建类型 |
| [`ci.conf`](conf/ci.conf) | CI 作业 |
| [`team-shared.conf`](conf/team-shared.conf) | 一台构建服务器上多人共享本地缓存 |
| [`remote.conf`](conf/remote.conf) | 开发机只读共享远端缓存 |
| [`project.ccache.conf`](conf/project.ccache.conf) | 随仓库提交的目录级配置 |

下一篇：[03 接入构建系统](03-integration.md)。

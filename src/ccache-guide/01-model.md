# 01 模型：ccache 缓存什么、拿什么当键

> 核对版本：ccache 4.13.6 与 4.14，Linux x86_64，GCC 16.2。
> 文中「实测」指 [`examples/`](examples/) 下对应脚本里的断言，两个版本都跑通。

## 1. 是什么

ccache 站在编译器前面。构建系统每次要「把一个源文件编译成一个目标文件」（带 `-c` 的调用），
ccache 先根据这次编译的全部输入算出一个哈希值——下文叫**键**——去缓存里找：

- **命中**（hit）：把上次存下的输出原样还原——目标文件、`-MD` 写的依赖文件、编译器打到
  stderr 的警告等——真编译器根本不启动；
- **未命中**（miss）：调用真编译器，编译成功后把输出存进缓存。

别的调用它不管：链接、只预处理（`-E`）、一次编多个源文件、编译失败，都原样转交给真编译器，
只在统计里记一笔。[`01-basics`](examples/01-basics/run.sh) 逐个触发了这些情形，对应计数器
`called_for_link`、`called_for_preprocessing`、`multiple_source_files`、`compile_failed`。

ccache 的设计目标是**命中时的输出与真编译逐字节相同**。所以全部难点都在键上：

- 键里**漏掉**了影响输出的输入 → 这个输入变了还命中，拿到过期的目标文件，叫**假命中**。
  这是正确性问题，[`09-hidden-inputs`](examples/09-hidden-inputs/run.sh) 演示了一个；
- 键里**多出**了与输出无关的东西 → 结果明明一样却 miss。这只是慢，
  [`03-cross-dir`](examples/03-cross-dir/run.sh) 与 [`04-debug-miss`](examples/04-debug-miss/run.sh) 各演示了一种。

## 2. 为什么键难算

一次编译的输入散落在很多地方：

| 输入 | 难在哪 |
|---|---|
| 源文件 | 不难，读内容即可 |
| 它 `#include` 的头文件 | 是传递闭包，编译之前不知道会读到哪些；还取决于 `-I` 的顺序与文件是否存在 |
| 命令行 | 有的选项影响输出（`-O2`），有的不影响（输出文件名），有的只影响预处理（`-D`、`-I`） |
| 编译器本身 | 升级后同样的输入会产出不同的目标文件 |
| 环境变量 | 例如 `LANG` 会改变诊断信息的语言 |
| 编译器自己偷偷读的文件 | ccache 看不见，除非你告诉它 |

「头文件闭包事先未知」是核心难题。ccache 给了两种解法，就是下面的 preprocessor 模式与 direct 模式。

## 3. 两种模式都哈希的公共部分

- **编译器的身份**。默认是编译器文件的 mtime 与大小；`compiler_check` 可换成文件内容、一段
  固定字符串或一条命令的输出（实测：[`02-cache-key`](examples/02-cache-key/run.sh) 最后三段）；
- 编译器的名字，以及预处理输出的扩展名（C 为 `.i`，C++ 为 `.ii`）；
- **当前工作目录**——仅当 `hash_dir` 为真（默认）**且**生成调试信息（`-g`）时。原因是调试信息里
  会写入编译目录，见 [`03-cross-dir`](examples/03-cross-dir/run.sh)；
- `extra_files_to_hash` 列出的文件内容、`namespace` 字符串；
- 会改变编译器输出的环境变量，例如 `LANG`、`LC_ALL`、`LC_CTYPE`、`LC_MESSAGES`
  （实测：[`04-debug-miss`](examples/04-debug-miss/run.sh) 就是 diff 调试文件找到 `LANG` 这一行的）。

## 4. preprocessor 模式

**是什么**：先让编译器只做预处理（`gcc -E`），然后哈希三样东西，再加上公共部分，得到键：

1. 预处理输出；
2. 命令行，但去掉 `-I`、`-D`、`-include` 这类只影响预处理的选项；
3. 预处理阶段打到 stderr 的内容。

**为什么这样设计**：预处理输出已经把所有头文件的内容展开进来了，头文件闭包问题自然消失。
预处理还会删掉注释、不留下没用到的宏，所以这种键对「不影响输出的改动」很宽容。`-I`、`-D`
不进命令行哈希，是因为它们若有影响，必然已经体现在预处理输出里。

**代价**：每次调用（包括命中）都要完整跑一遍预处理。

**实测**（[`02-cache-key`](examples/02-cache-key/run.sh)）：

- 只改注释、或者多加一个没用到的 `-D`：direct 模式 miss，preprocessor 模式命中（计数器 `preprocessed_cache_hit`）；
- `-O2` 改 `-O0`、改头文件里被用到的宏：两种模式都 miss。

## 5. direct 模式（默认开启）

**是什么**：不跑预处理器，分两步。

1. 哈希**源文件内容 + 完整命令行 + 公共部分**，得到 manifest 的键，取出这份 **manifest**。
2. manifest 里记着以前每次编译这个源文件时读过的**每个头文件的路径与内容哈希**，以及对应的
   结果键。ccache 把这些头文件逐个重新哈希、与记录比对；某一组全部吻合，就用那一组的结果键
   取出结果——命中。

对不上（或者没有 manifest）就回落到 preprocessor 模式。编完之后，把这次读到的头文件清单
（从预处理输出里解析出来）追加进 manifest。于是同一条命令下一次就能 direct 命中——02 里
「preprocessed 命中之后，下一次变成 direct 命中」验证的就是这次追加。

manifest 可以直接看：`ccache --inspect <条目文件>` 打印其中的头文件路径列表、哈希与结果键，
见 [`04-debug-miss`](examples/04-debug-miss/run.sh) 最后一段。

**为什么这样设计**：哈希一批头文件比跑一遍预处理器便宜得多；`inode_cache`（默认开）还会按
设备号、inode 号与时间戳缓存文件的哈希，连读文件都省了。头文件按**内容**比对而不是按 mtime，
所以被重新生成、内容却没变的头文件不会让缓存失效（实测：02 里只 `touch` 头文件，仍然 direct 命中）。

**盲区**：manifest 只记「读过的头文件」，没记「如果存在就会被读到的头文件」。例如在 `-I`
搜索顺序更靠前的目录里新建一个同名头文件，理论上应该 miss，direct 模式却可能命中。ccache
通过额外记录 `-I` 目录是否存在来缓解；官方手册的判断是绝大多数情况下安全。

**何时自动停用**：

- 源码里出现 `__TIME__`（实测：02 里两次编译隔 1 秒，都 miss；设 `sloppiness = time_macros` 后命中）；
- 源文件或某个头文件的 mtime/ctime 不早于 ccache 启动时刻——防止「ccache 读完之后、编译器读之前
  文件被改」这一竞态；
- 用了它无法分析的选项，例如除 `-Wp,-MD,<路径>` 等少数形式以外的 `-Wp,…`。

## 6. depend 模式

**是什么**：设 `depend_mode = true`，并且编译命令里带 `-MD` 或 `-MMD`（让编译器自己写依赖文件）时生效。
它**从不**跑预处理器：miss 时直接编译，再从编译器写出的 `.d` 文件里读头文件清单，写进 manifest。

**为什么**：miss 的开销只剩真编译本身，不再多一遍预处理；如果编译被 distcc 之类发到远端执行，
本机也就不必做预处理。

**代价**：

- 没有 preprocessor 模式兜底，源码或命令行的任何改动都是 miss（实测：02 里 depend 模式下只改注释就 miss，
  而默认模式下同样的改动能 preprocessed 命中）；
- 用 `-MMD` 时系统头文件不进清单，其变化会被忽略；
- 它挂在 direct 模式上：`direct_mode = false` 而 `depend_mode = true` 时，两次相同的编译都是 miss
  （实测，4.13.6 与 4.14）。

## 7. 一次调用的完整路径

```text
编译器调用
  │
  ├─ 不可缓存（链接 / -E / 多源文件 / 不支持的选项 …）→ 原样执行真编译器，对应计数器 +1
  │
  ├─ direct 模式开着？
  │    是 → 哈希 源文件 + 命令行 + 公共部分 → 取 manifest → 逐个比对头文件哈希
  │           ├─ 吻合 → 取结果                                        【direct 命中】
  │           └─ 不吻合或无 manifest
  │                ├─ depend 模式生效 → 直接编译，从 .d 读头文件清单，存结果与 manifest【miss】
  │                └─ 否则 → 进入下面的 preprocessor 模式
  │    否 → 进入 preprocessor 模式
  │
  └─ preprocessor 模式：跑预处理器 → 哈希 预处理输出 + 命令行 + 公共部分
         ├─ 有结果 → 取结果，并把头文件清单追加进 manifest          【preprocessed 命中】
         └─ 无 → 真编译 → 存结果与 manifest                         【miss】
```

## 8. 本地缓存目录里有什么

- **位置**：配置项 `cache_dir`。Linux 上默认 `~/.cache/ccache`；若存在遗留的 `~/.ccache` 则用它，
  设了 `XDG_CACHE_HOME` 则用 `$XDG_CACHE_HOME/ccache`。查看当前取值：`ccache -p | grep cache_dir`
  （`-p` 即 `--show-config`，打印每项配置的值与来源）。
- **条目文件**：键的前两个十六进制位做两级子目录，剩下的做文件名，例如 `4/c/605da6bd…`。
  文件头里写着条目类型（manifest 或 result）、压缩方式、创建它的 ccache 版本（实测：04 用 `--inspect` 逐个列出）。
  direct 模式下一次成功的编译产生两个条目：一个 manifest、一个 result（实测：
  [`10-ci-lifecycle`](examples/10-ci-lifecycle/run.sh) 里 10 次编译对应 `files_in_cache = 20`）。
- **压缩**：默认 zstd；`compression_level = 0` 表示由 ccache 决定，目前即 1。开了 `file_clone`
  或 `hard_link` 时不压缩。
- **统计计数器**：分散存在各子目录的 `stats` 文件里，`ccache -s` 负责汇总。
- **容量与淘汰**：写入新结果后若超过 `max_size` 或 `max_files`，自动按 mtime 近似 LRU 清理——
  只检查一部分子目录，所以是「近似」。命中会刷新条目的 mtime。要按年龄精确淘汰用
  `ccache --evict-older-than <年龄>`（实测：10 的第 6 步）。
- **临时文件**：配置项 `temporary_dir`，默认 `$XDG_RUNTIME_DIR/ccache-tmp`（通常是 `/run/user/<UID>/ccache-tmp`，
  一般在内存里），否则 `<cache_dir>/tmp`。

下一篇：[02 配置](02-configuration.md)。

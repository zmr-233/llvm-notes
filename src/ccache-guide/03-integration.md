# 03 接入构建系统

> 核对版本：ccache 4.13.6 与 4.14；GNU Make 4.4.1、Autoconf 2.73、Automake 1.18.1、CMake 4.4.3、Ninja 1.13.2、
> Meson 1.12.0；LLVM 源码 23.1.0。「实测」指 [`examples/`](examples/) 下的脚本。
> GitHub Actions、GitLab CI、Docker 三处**未实跑**，LLVM runtimes 与自编 clang 两节是**代码阅读与推论**，均已就地标注。

## 0. 两种运行方式，怎么选

**前缀方式**：在编译命令前加 `ccache`，如 `ccache gcc -c a.c -o a.o`。

**伪装方式**：放一个名叫 `gcc`、指向 ccache 的符号链接，并让它所在的目录排在 `PATH` 最前。ccache 从 `argv[0]`
得知自己要扮演谁，再沿 `PATH` 找第一个「不是指向 ccache 自己」的同名程序当真编译器。实测
（[`01-basics`](examples/01-basics/run.sh)）：`command -v gcc` 找到的是那个链接，编译照常命中前缀方式存下的条目。
发行版的 ccache 包一般自带装满这种链接的目录，本机（Arch）是 `/usr/lib/ccache/bin`；用包管理器列出 ccache 包的文件就能找到
（Arch 上是 `pacman -Ql ccache`，`-Q` 查已安装的包，`-l` 列文件）。

**怎么选**：

1. 构建系统有「编译器启动器」的概念（CMake 的 launcher、Meson 的自动探测）→ 用它：只影响这一个工程，不动 `PATH`；
2. 没有 → 把 `ccache gcc` 塞进 `CC`（Make、Autotools）；
3. 构建脚本把 `gcc` 写死、改不动 → 才用伪装方式。它对 `PATH` 下的一切编译调用生效，也容易和其他同样靠伪装工作的
   包装器互相干扰（手册「Using ccache with other compiler wrappers」）。

## 1. Make

```bash
make -j8 CC="ccache gcc" CXX="ccache g++"
```

- `-j8`：最多 8 个任务并行。ccache 支持并发调用；
- `CC=…`、`CXX=…`：写在命令行上的变量优先于 Makefile 里的赋值与 make 的内建默认值。规则里的 `$(CC)` 被原样展开，
  交给 shell 执行时按空格拆成 `ccache` 与 `gcc` 两个词。

实测（[`06-make-autotools`](examples/06-make-autotools/run.sh)）：两个 `.c` 首次 miss；链接那一步 `$(CC) -o app a.o b.o`
也经过了 ccache，记为 `called_for_link` 并原样转交，无害；`make clean` 之后重编，两个文件都 direct 命中。

## 2. Autotools

```bash
mkdir build && cd build
../configure CC="ccache gcc" CXX="ccache g++"
make
```

- `../configure`：在单独的构建目录里运行源码树里的 configure（out-of-tree 构建）；
- `CC=…` 作为参数写在 configure 之后：configure 把它写进生成的 Makefile（实测：`CC = /usr/bin/ccache gcc`），此后的 `make` 不必再给。

configure 自己的探测也经过 ccache。实测一次 configure 期间记了 `autoconf_test` 3 次、`no_input_file` 5 次
（这些不可缓存），以及若干次正常的缓存读写。

**坑**：用户不给 `CFLAGS` 时 autoconf 默认 `-g -O2`（实测生成的 Makefile 里是 `CFLAGS = -g -O2`）。有 `-g`，`hash_dir`
就会把当前目录放进键，**另开一个构建目录就全部 miss**（实测）。解决：

```bash
../configure CC="ccache gcc" CFLAGS="-g -O2 -fdebug-prefix-map=$PWD=."
```

`-fdebug-prefix-map=<旧>=<新>`：GCC 往调试信息里写路径时，把前缀「旧」换成「新」；这里把构建目录映射成 `.`。
调试信息里不再有构建目录的绝对路径，ccache 也就不再把目录放进键。实测：两个构建目录各带各的映射，第二个 direct 命中第一个的结果。

## 3. CMake

### 3.1 推荐写法：`CMAKE_<LANG>_COMPILER_LAUNCHER`

```bash
cmake -S . -B build -G Ninja \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build build
```

- `-S .`：源码目录；`-B build`：构建目录；`-G Ninja`：生成 Ninja 构建文件；
- `-DCMAKE_C_COMPILER_LAUNCHER=ccache`：C 编译命令的启动器；`CXX` 那个管 C++。

**是什么**：CMake 把启动器放在每条**编译**命令的最前面（链接命令不加）。Ninja 生成器下，它变成 `build.ninja` 里每个
编译语句的变量 `LAUNCHER = ccache`，规则写成 `command = ${LAUNCHER}${CODE_CHECK}/usr/bin/cc …`（实测，
[`05-cmake`](examples/05-cmake/run.sh)）。另外实测到：

- configure 阶段 CMake 探测编译器用的 `try_compile` **不经过**启动器——configure 期间 ccache 计数器全为零；
- `compile_commands.json`（`-DCMAKE_EXPORT_COMPILE_COMMANDS=ON` 生成，clangd 等工具读它）里的命令**不含**启动器，
  以 `/usr/bin/cc` 开头，所以这些工具不受影响；
- 换一个构建目录重新 configure，只要不带 `-g`，编译命令一模一样，直接命中（05 的 E 段）。

### 3.2 各种写法对照

| 写法 | 值存在哪 | 怎么给 ccache 带 `KEY=VALUE` | ExternalProject 子工程能继承吗 |
|---|---|---|---|
| A 缓存变量 `-DCMAKE_<LANG>_COMPILER_LAUNCHER=ccache` | `CMakeCache.txt` | 写成 CMake 列表 `env;KEY=VALUE;ccache` | 不能 |
| B 环境变量 `CMAKE_<LANG>_COMPILER_LAUNCHER=ccache`（CMake ≥ 3.17） | 首次 configure 时读进 `CMakeCache.txt`，之后不再看环境 | 同 A | 仅当**构建期间**环境里仍有它 |
| C 全局属性 `set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE "…")` | `CMakeLists.txt` | 直接写 `KEY=VALUE ccache` | 不能 |
| E `CMakePresets.json` 里的 `cacheVariables` | 预设文件，可随仓库提交 | 同 A | 不能 |

每一行都由 05 验证。`build.ninja` 里对应的样子（路径已缩写）：

```text
# A
  LAUNCHER = /usr/bin/ccache
# C：属性值原样拼在规则命令的最前面，${LAUNCHER} 之前
  command = CCACHE_STATSLOG=…/rule.stats /usr/bin/ccache ${LAUNCHER}${CODE_CHECK}/usr/bin/cc $DEFINES …
# A 的列表形式：env 程序先设环境变量再执行 ccache，不依赖 shell
  LAUNCHER = env CCACHE_STATSLOG=…/list.stats /usr/bin/ccache
```

C 的 `KEY=VALUE` 前缀之所以能生效，是因为 Ninja 在 Unix 上用 `/bin/sh -c` 执行命令（实测：前缀里的 `CCACHE_STATSLOG`
指向的文件被创建了）。

`CMakePresets.json` 的写法（E）：

```json
{
  "version": 3,
  "configurePresets": [
    {
      "name": "ccache",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build",
      "cacheVariables": {
        "CMAKE_C_COMPILER_LAUNCHER": "ccache",
        "CMAKE_CXX_COMPILER_LAUNCHER": "ccache"
      }
    }
  ]
}
```

然后在源码目录下 `cmake --preset ccache`（`--preset <名字>`：按该预设 configure）。

**为什么子工程继承不到**：`ExternalProject_Add` 在父工程**构建**期间，对子工程另跑一次完全独立的 `cmake` configure。
父工程的缓存变量与全局属性不会自动带过去，要带就得写进它的 `CMAKE_ARGS`；而环境变量随进程继承。
所以 05 里只有 B2（configure 与 build 全程导出环境变量）让子工程用上了 ccache，B1（只在 configure 时给）不行。

### 3.3 `base_dir` 与 Ninja 的依赖跟踪

CMake 生成的编译命令里全是绝对路径，多个 checkout 之间要共享命中就得设 `base_dir`（原理见 [`03-cross-dir`](examples/03-cross-dir/run.sh)）。
改写成相对路径后，编译器写出的依赖文件里也是相对路径。实测（05 的 F 段）：`ninja -t deps`（打印 Ninja 记下的某个目标的依赖）显示

```text
CMakeFiles/demo.dir/src/lib.c.o: #deps 3, deps mtime … (VALID)
    ../proj/src/lib.c
    /usr/include/stdc-predef.h
    ../proj/src/lib.h
```

Ninja 在构建目录根执行编译命令，也按同一个目录解释依赖文件里的相对路径，所以改 `lib.h` 之后，包含它的两个源文件都被重新调度了。
只验证了 Ninja 生成器；手册提醒相对路径可能干扰其他工具的依赖检测。

## 4. Meson

```bash
meson setup build .                        # setup <构建目录> <源码目录>：配置构建目录
meson setup build . --native-file m.ini    # --native-file：机器文件，可写死编译器等
meson compile -C build                     # -C <构建目录>：在其中构建
```

Meson 会自己在 `PATH` 里找编译器缓存。实测（[`07-meson`](examples/07-meson/run.sh)）各种情形下生成的 C 编译规则：

| 情形 | 编译规则开头 |
|---|---|
| 不设 `CC`，`PATH` 里有 ccache | `ccache cc` |
| `CC=gcc` | `gcc`——设了 `CC` 就不再自动探测，这也是关掉它的办法 |
| `CC="ccache gcc"` | `ccache gcc` |
| 机器文件 `[binaries]` 里 `c = ['ccache', 'gcc']` | `ccache gcc`，只有一层 |
| 机器文件 + `CC=gcc` 同时存在 | `ccache gcc`：机器文件生效 |
| `PATH` 里 sccache 与 ccache 都有 | `sccache cc`：Meson 选了 sccache |

**坑**：Meson 默认 `buildtype=debug`，编译参数里带 `-O0 -g`（实测 `build.ninja` 的 `ARGS`），换构建目录就 miss，
原因与 Autotools 相同。修法同理是 `-fdebug-prefix-map`，未在 Meson 下单独实测。

## 5. LLVM

### 5.1 `LLVM_CCACHE_BUILD`

```bash
cmake -S llvm -B build -G Ninja -DLLVM_CCACHE_BUILD=ON \
    -DLLVM_CCACHE_DIR=/data/ccache \
    -DLLVM_CCACHE_MAXSIZE=100G
```

- `-S llvm`：LLVM 的顶层 CMake 工程在 llvm-project 仓库的 `llvm/` 子目录；
- `-DLLVM_CCACHE_BUILD=ON`：打开 LLVM 自带的 ccache 支持；
- `-DLLVM_CCACHE_DIR`、`-DLLVM_CCACHE_MAXSIZE`：可选，分别变成传给 ccache 的 `CCACHE_DIR`、`CCACHE_MAXSIZE`；
- 另有 `-DLLVM_CCACHE_PARAMS="…"`：可选，替换默认的环境变量前缀（见下）。

**对应代码**：`llvm/CMakeLists.txt` 第 341–396 行（23.1.0）。它做了四件事：

1. `find_program(CCACHE_PROGRAM ccache)`，找不到就 `FATAL_ERROR`，configure 失败（第 394 行）；
2. 非 Windows：把 `LLVM_CCACHE_PARAMS`（默认 `CCACHE_CPP2=yes CCACHE_HASHDIR=yes CCACHE_SLOPPINESS=pch_defines,time_macros`）
   以及可选的 `CCACHE_MAXSIZE=…`、`CCACHE_DIR=…` 拼在 ccache 前面，设为全局属性 `RULE_LAUNCH_COMPILE`（第 359 行）——
   也就是 §3.2 的写法 C，所以能带环境变量前缀；
3. C++ 编译器不是 Clang 时：用户没指定 `CMAKE_DISABLE_PRECOMPILE_HEADERS` 就把它设为 ON 并打印 NOTICE，指定为 OFF 则打印警告。
   注释给出的原因是 ccache issue #1668：非 Clang 编译器配合预编译头，只改宏定义时可能假命中；
4. Windows：同样关预编译头，改用 `CMAKE_<LANG>_COMPILER_LAUNCHER`；若自定义了 `LLVM_CCACHE_MAXSIZE` / `DIR` / `PARAMS`，
   直接 `FATAL_ERROR`，要求改用环境变量。

实测（[`11-llvm`](examples/11-llvm/run.sh) 的 A 段，GCC 16）configure 打印：

```text
Using ccache with precompiled headers with non-Clang compilers is not supported. CMAKE_DISABLE_PRECOMPILE_HEADERS will be set to ON. Pass -DCMAKE_DISABLE_PRECOMPILE_HEADERS=OFF to override this.
```

`CMakeFiles/rules.ninja` 里的 C++ 编译规则：

```text
command = CCACHE_DIR=… CCACHE_CPP2=yes CCACHE_HASHDIR=yes CCACHE_SLOPPINESS=pch_defines,time_macros …/ccache ${LAUNCHER}${CODE_CHECK}/usr/bin/g++ $DEFINES $INCLUDES $FLAGS -MD -MT $out -MF $DEP_FILE -o $out -c $in
```

编译 `StringRef.cpp.o` 一次 miss，删掉再编 direct 命中。

默认前缀里的三个变量：

- `CCACHE_CPP2=yes`：ccache 4.12 删除了对应的 `run_second_cpp` 功能，此后这个变量被静默忽略（实测：4.13.6 下设与不设都正常命中），无害；
- `CCACHE_HASHDIR=yes`：本来就是默认值；
- `CCACHE_SLOPPINESS=pch_defines,time_macros`：手册对预编译头场景的要求。它以环境变量传入，按优先级会**盖过**你配置文件里的
  `sloppiness`（由 [02 §1](02-configuration.md) 的优先级推出）。

### 5.2 只给 launcher

```bash
cmake -S llvm -B build -G Ninja \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
```

**对应代码**：`llvm/cmake/modules/HandleLLVMOptions.cmake` 第 1379–1405 行（23.1.0）：启动器含 `sccache` 或 `clang-cache` 时默认关预编译头；
含 `ccache` 且编译器不是 Clang 时**只打警告**，不替你关。同一文件第 1363–1368 行另有一条：GCC 默认关预编译头（注释说 GCC 14、15 上
收益很小却显著增大构建目录）。所以在 23.1.0 上用 GCC，两种写法最终都没有预编译头。实测（11 的 B 段）configure 打印了两条：

```text
Precompiled headers are disabled by default with GCC. Pass -DCMAKE_DISABLE_PRECOMPILE_HEADERS=OFF to override.
CMake Warning at cmake/modules/HandleLLVMOptions.cmake:1403 (message):
  Using ccache with precompiled headers with non-Clang compilers is not
  supported and may lead to false positives.  …
```

两种写法对照：

| | `LLVM_CCACHE_BUILD=ON` | `CMAKE_<LANG>_COMPILER_LAUNCHER=ccache` |
|---|---|---|
| 机制 | 全局属性 `RULE_LAUNCH_COMPILE` | CMake 标准的启动器变量 |
| 额外传给 ccache 的设置 | 环境变量前缀：`sloppiness=pch_defines,time_macros` 等，盖过配置文件 | 无，全听你的配置文件 |
| 非 Clang 编译器 + 预编译头 | 自动关预编译头 | 只警告 |
| 系统里没有 ccache | configure 失败 | —— |

选择：用 Clang 且开着预编译头时，`LLVM_CCACHE_BUILD` 顺手满足了手册对 PCH 的 `sloppiness` 要求；想让所有设置都来自自己的
`ccache.conf`（例如 [`conf/llvm-dev.conf`](conf/llvm-dev.conf)）时，用 launcher 更透明。

### 5.3 两个都开

实测（11 的 C 段）：规则命令是 `CCACHE_… ccache ${LAUNCHER}…`，而 `LAUNCHER = ccache`，即两层 ccache。编译一次只记了一次 miss，
没有重复查缓存、重复计数（直接跑 `ccache ccache gcc -c …` 也一样，实测）。无害，但多余，选一个即可。

### 5.4 多个构建目录互相命中

LLVM 的编译命令里 `-I` 全是绝对路径，而且包含构建目录下的 include 目录（configure 生成的头文件放在那里），所以两个构建目录的键天然不同——
11 的 B、C 段在新构建目录里编同一个文件，都没有命中 A 段的结果（实测）。

解决：`base_dir` 同时覆盖源码目录与所有构建目录。实测（11 的 D 段）：设了 `base_dir` 后新建两个构建目录，第二个 direct 命中第一个。
平时的做法是把它们放在同一个上级目录下：

```text
# 布局：/home/me/llvm/llvm-project（源码）、/home/me/llvm/build-release、/home/me/llvm/build-debug …
base_dir = /home/me/llvm
```

带 `-g` 的构建类型（Debug、RelWithDebInfo）还要按 [§2](#2-autotools) 的办法加 `-fdebug-prefix-map`。

### 5.5 runtimes 与交叉编译的子构建（代码阅读，未实跑）

- `LLVM_ENABLE_RUNTIMES` 让 compiler-rt、libc++ 等作为**外部工程**构建：`llvm/runtimes/CMakeLists.txt` 第 336–367 行调用
  `llvm_ExternalProject_Add(runtimes …)`，底层就是 §3.2 说的 ExternalProject。
- 往子构建传哪些变量由 `llvm/cmake/modules/LLVMExternalProjectUtils.cmake` 决定：第 177 行起的 `DEFAULT_PASSTHROUGH_VARIABLES`
  只有库、头文件与 Python 路径；runtimes 的 `PASSTHROUGH_PREFIXES` 是 `LLVM_ENABLE_RUNTIMES` 加工程名。
  `CMAKE_<LANG>_COMPILER_LAUNCHER` 与 `RULE_LAUNCH_COMPILE` 都不在其中。结合 05 验证过的机制，默认情况下 runtimes 的编译不经过 ccache。
- 让它经过的两个办法：
  - 用 launcher 写法，再加 `-DLLVM_EXTERNAL_PROJECT_PASSTHROUGH="CMAKE_C_COMPILER_LAUNCHER;CMAKE_CXX_COMPILER_LAUNCHER"`
    ——第 220 行的循环会把这里列出的每个变量以 `-D` 传给子构建。只开 `LLVM_CCACHE_BUILD` 时没有 launcher 变量可传，这招无效；
  - 构建全程导出环境变量 `CMAKE_C_COMPILER_LAUNCHER=ccache`、`CMAKE_CXX_COMPILER_LAUNCHER=ccache`（05 的 B2 机制）。
- 反例：`llvm/cmake/modules/CrossCompile.cmake` 第 93–94 行（交叉编译时为宿主机构建 tablegen 等工具）与 `clang/runtime/CMakeLists.txt`
  第 84–85 行（旧式的外部 compiler-rt 构建）**显式**传了 `CMAKE_<LANG>_COMPILER_LAUNCHER`。

### 5.6 用刚编出来的 clang 当编译器（推论，未实跑）

- 默认 `compiler_check = mtime`：clang 每重新构建一次，mtime 就变，此前的条目全部 miss。
- `compiler_check = content` 只哈希 clang 这**一个文件**（手册）。若 clang 以 `LLVM_LINK_LLVM_DYLIB=ON` 构建，代码大多在 `libLLVM.so` 里，
  库变了而 clang 可执行文件的字节可能不变——这就可能**假命中**。`content` 只适合静态链接的 clang；动态链接时改用
  `string:<构建系统给出的、随库一起变化的标识>`。
- clang 会自动读取与可执行文件同目录的配置文件（如 `<triple>-clang.cfg`，见 clang 用户手册「Configuration files」），用来决定默认
  target、sysroot 等。ccache 4.12 起只认命令行上显式的 `--config=`，隐式读取的文件不在键里。把这些 `.cfg` 加进
  `extra_files_to_hash`——机制与 [`09-hidden-inputs`](examples/09-hidden-inputs/run.sh) 实测的包装脚本读 `flags.txt` 相同。

## 6. CI

### 6.1 缓存的一生（实测）

[`10-ci-lifecycle`](examples/10-ci-lifecycle/run.sh) 用本地 tar 包模拟 CI 的缓存存储，连跑三个作业：

| 步骤 | 命令 | 作用 |
|---|---|---|
| 1 恢复 | 取回上次保存的 `$CCACHE_DIR` | tar 保留文件 mtime，LRU 信息随之保留 |
| 2 限额 | `ccache -M 2GiB` | 写进缓存级配置文件 |
| 3 清零 | `ccache -z` | 作业结束时的统计只属于本作业 |
| 4 构建 | —— | |
| 5 统计 | `ccache -s` | 看本作业命中率 |
| 6 淘汰 | `ccache --evict-older-than <本作业已运行秒数>s` | 命中会刷新条目 mtime，早于作业开始的条目就是本作业没用到的 |
| 7 保存 | 打包 `$CCACHE_DIR` | |

实测数字：作业 1（20 个文件）20 次 miss，40 个条目；作业 2 只改了一个文件，19 次 direct 命中、1 次 miss，淘汰前 42 个条目、淘汰后 40——
旧版本那个文件的两个条目被清掉；作业 3 工程删掉一半文件，10 次命中，淘汰后剩 20。不做第 6 步，缓存包会随历史只增不减，直到撞上 `max_size`。

### 6.2 GitHub Actions（未实跑）

[`examples/10-ci-lifecycle/github-actions.yml`](examples/10-ci-lifecycle/github-actions.yml) 用 hendrikmuhs/ccache-action：它的 restore 阶段
对应上表 1–3 步，post 阶段对应 5–7 步。据其 `action.yml` 与 `src/save.ts`（2026-09-13 核对，最新发布 v1.2.24）：

- `key`：附加进缓存键，区分作业、矩阵项；
- `max-size`：默认 500MB；
- `evict-old-files: job`：特殊值，按本作业已运行的秒数调用 `ccache --evict-older-than`，即第 6 步；
- `append-timestamp`：默认 true，保存时在键尾追加 ISO 时间戳，每次保存都是新键；恢复时由 `restore-keys` 找回较早的条目；
- `variant: sccache`：改用 sccache。

### 6.3 GitLab CI 与 Docker（依据各自文档，未实跑）

GitLab CI 只能缓存工程目录内的路径，所以把缓存目录放进工程目录：

```yaml
build:
  variables:
    CCACHE_DIR: $CI_PROJECT_DIR/.ccache
  cache:
    key: ccache-$CI_JOB_NAME
    paths:
      - .ccache
  script:
    - cmake -S . -B build -G Ninja -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    - cmake --build build
    - ccache -s
```

Docker BuildKit 的缓存挂载在同一构建机的多次 `docker build` 之间保留：

```dockerfile
RUN --mount=type=cache,target=/root/.cache/ccache \
    cmake --build build
```

## 7. distcc 等包装器

实测（[`09-hidden-inputs`](examples/09-hidden-inputs/run.sh)）：

- 正确做法是 `prefix_command = distcc`（或环境变量 `CCACHE_PREFIX=distcc`），让 ccache 在**需要真编译时**去调用包装器。
  实测包装器只在 miss 时被调用一次，命中时不调用；预处理不经过它（要经过另设 `prefix_command_cpp`）。此时 ccache 哈希的是真编译器，
  编译器升级能被察觉，条目也与不用包装器时共享；
- 不要写成 `ccache distcc gcc`，也不要让包装器伪装成编译器：ccache 会把包装器当成编译器、按它的 mtime 算键。实测这样写与上面的条目不共享；
- 编译发往远端执行时，还可以开 depend 模式，省掉本机的预处理（[01 §6](01-model.md)）。

下一篇：[04 远端存储](04-remote-storage.md)。

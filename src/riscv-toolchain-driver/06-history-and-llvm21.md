# 06 这个文件的一生，以及它在 LLVM 21 里变成了什么

> 依据：GitHub 上 `clang/lib/Driver/ToolChains/RISCVToolchain.cpp` 的完整提交历史（45 条）与三个
> 版本的文件文本（llvmorg-15.0.7 / 20.1.8 / 21.1.8 的 `BareMetal.cpp`）；行为差异全部实测
> （[`02`](examples/02-gcc-tree/run.sh)–[`05`](examples/05-flags/run.sh)）。

## 1. 时间线

| 日期 | 提交 | 发生了什么 | 进入的版本 |
|---|---|---|---|
| 2018-07 | r338385 | 文件诞生，名叫 `ToolChains/RISCV.cpp`：`riscv32-unknown-elf` 的第一个 driver 支持 | 7 |
| 2018-09-27 | `46420b6feedc` | 改名为 `RISCVToolchain.cpp`——只因为 Darwin 链接器抱怨 `ToolChains/RISCV.cpp` 与 `ToolChains/Arch/RISCV.cpp` 同名 | 8 |
| 2019-10-03 | `de61aa3118b9` | 无 GCC 时 sysroot 退到 `<Dir>/../<triple>`（`computeSysRoot` 的 else 分支） | 10 |
| 2019-11-21 | `4fccd383d571` | 支持 GCC 的 multilib（`addMultilibsFilePaths`、`findRISCVBareMetalMultilibs`）。此前两次提交又两次 revert | 10 |
| 2019-11-22 | `e0f22fe04a5c` | 无 GCC 时默认 compiler-rt（`GetDefaultRuntimeLibType`）。此前一次 revert | 10 |
| 2019-12-12 | `b2b5cac3ec07` | 默认 `-fuse-init-array`（改的是 `Generic_ELF`，本文件顺带改动） | 10 |
| 2020-02-17 | `e058667a2e01` | `-fuse-ld=lld` 可用（改成通过 `GetLinkerPath()` 找链接器） | 11 |
| 2020-11-26 | `45ba2392d7e0` | **`hasGCCToolchain` 出现**：无 GCC 时 RISC-V 改走 `BareMetal` | 12 |
| 2021-04-19 | `27edaee84e3e` | `ConstructJob` 参数顺序对齐 `BareMetal`（先 crt 再输入） | 13 |
| 2021-06-29 | `5635d2a56dab` | 正确转发 `-u` | 13 |
| 2022-02-21 | `c1f17b0a9ea0` | resource include 排在 sysroot include 之前（两次 revert 后第三次才留下） | 15 |
| 2022-06-17 | `c324c938becd` | `-X` | 15 |
| 2022-07-01 | `f553287b5889` | C++ 时加 `-lm` | 15 |
| 2023-01-31 | `edc1130c0ac0` | `SelectedMultilib` → `SelectedMultilibs`（向量） | 17 |
| 2023-07-08 | `62281227bf7c` | 去掉重复的 `-e` | 17 |
| 2023-10-11/12 | `4eecfda50a4e`、`894927b491b7` | `AddAllArgs` 改名 `addAllArgs` 并合并成一次调用 | 18 |
| 2023-10-16 | `993e83948044` | 不再给 ELF 平台传 `-Z` | 18 |
| 2024-01-26 | `be8e462a0c27` | `-mno-relax` → `--no-relax`（18 已分支，进 19） | 19 |
| 2024-02-23 | `f1e0392b822e` | `getDefaultUnwindTableLevel` 返回 `None` | 19 |
| 2025-06-06 | `a42bb8b57a6d` | `CommonArgs.h` 搬到 `clang/Driver/`（`#include` 路径变） | 21 |
| 2025-06-17 → 06-30 | `#121829`、`#121830`、`#132806`、`#132807`、`#132808`、`#134442` | 把本文件的能力一块块搬进 `BareMetal.cpp`（下文 §3） | 21 |
| 2025-06-30 | `f8cb7987c64d`（`#121831`） | **文件删除**，`Driver.cpp` 的分派改为无条件 `BareMetal` | 21 |
| 2025-07-07 | `8315167a76e4`（`#146849`） | 合并后的修补：`BareMetal::getCompilerRTPath` 在有 GCC 时回到 `<ResourceDir>/lib` | 21 |

上游的讨论帖：<https://discourse.llvm.org/t/merging-riscvtoolchain-and-baremetal-toolchains/75524>。
动机是两个类做的事重叠太多：`BareMetal` 已经是 ARM/AArch64/PPC 裸机的家，RISC-V 只因为
"要用 GCC 树"才单独一个类，而"用 GCC 树"这件事 `BareMetal` 一样可以做。

## 2. 15.0.7 → 20.1.8 的五处差异

`diff` 结果只有下面几处（不算注释里 `RISCV` → `RISC-V` 的改写）：

| 处 | 15.0.7 | 20.1.8 | 原因 |
|---|---|---|---|
| 构造函数 | `SelectedMultilib = GCCInstallation.getMultilib();` | `SelectedMultilibs.assign({...});` 与 `SelectedMultilibs.back()` | `ToolChain` 基类成员从单个变成向量（支持多层 multilib） |
| 新增 | 无 | `getDefaultUnwindTableLevel` 返回 `None`（第 89–92 行） | 裸机默认不生成 `.eh_frame` |
| `computeSysRoot` 末行 | `std::string(SysRootDir.str())` | `std::string(SysRootDir)` | `SmallString` 有了到 `std::string` 的转换（NFC） |
| `ConstructJob` 开头 | 无 | `-mno-relax` → `--no-relax`（第 164–166 行） | 功能新增 |
| `ConstructJob` 选项转发 | `AddAllArgs(CmdArgs, OPT_L)`；`AddAllArgs(CmdArgs, OPT_u)`；`AddAllArgs(CmdArgs, {T_Group, e, s, t, Z_Flag, r})` | `addAllArgs(CmdArgs, {OPT_L, OPT_u})`；`addAllArgs(CmdArgs, {T_Group, s, t, r})` | 改名；去掉重复的 `-e`；去掉 Darwin 专有的 `-Z` |

头文件的差异对应：多了 `getDefaultUnwindTableLevel` 声明；`Linker` 类加了 `final`。
也就是说，从 15 到 20 这个文件的**行为**只变了三件事：`.eh_frame` 默认不生成、`-mno-relax` 传给链接器、
`-e` 不再重复。其余是 API 跟随。

## 3. 21.1.8 里的对应物

文件没了，逻辑还在，只是搬进了 `BareMetal.cpp`。函数级映射：

| `RISCVToolchain.cpp`（20.1.8） | `BareMetal.cpp`（21.1.8） | 备注 |
|---|---|---|
| `hasGCCToolchain`（38） | `initGCCInstallation`（135）+ `detectGCCToolchainAdjacent`（149） | 拆成两个：前者只在有 `--gcc-toolchain` **或 `--gcc-install-dir`** 时跑探测；后者就是原来的"相邻 crt0.o"检查，被 `computeSysRoot`、`getCompilerRTPath`、`findMultilibs` 与链接器各自调用 |
| `Driver.cpp` 的 `if hasGCCToolchain … else BareMetal` | 无条件 `BareMetal`（`Driver.cpp:6961`） | 分叉消失 |
| 构造函数（50） | `BareMetal::BareMetal`（218） | 有 GCC 的分支逐行照抄；无 GCC 的分支是原 `BareMetal` 的（multilib.yaml、`clang-runtimes`） |
| `addMultilibsFilePaths`（25） | 同名（205） | 逐字相同 |
| `GetDefaultRuntimeLibType`（79） | 同名（381） | 条件从 `GCCInstallation.isValid()` 变成 `isRISCV() && IsGCCInstallationValid` |
| `GetUnwindLibType`（84） | 同名（389） | RISC-V 恒 `UNW_None`；其他架构走基类 |
| `getDefaultUnwindTableLevel`（89） | `BareMetal.h:55` 内联 | 全架构 `None` |
| `addClangTargetOptions`（94） | 同名（425） | 相同 |
| `AddClangSystemIncludeArgs`（101） | 同名（397） | 多了 `getStdlibIncludePath()` 与 **multilib includeSuffix** 循环（见 §4 差异 7） |
| `addLibStdCxxIncludePaths`（119） | 同名（431） | 相同，多一个 `IsGCCInstallationValid` 守卫 |
| `computeSysRoot`（130） | 同名（165） | 三级变四级：`--sysroot` → GCC 树 → 相邻目录 → `lib/clang-runtimes/<triple>`；不再返回空串 |
| 无 | `GetDefaultCXXStdlibType`（375） | 有 GCC 时 libstdc++，否则 **libc++** |
| 无 | `getCompilerRTPath`（195） | 有 GCC 或相邻 crt0 时 `<ResourceDir>/lib`（`#146849` 修补） |
| `RISCV::Linker::ConstructJob`（152） | `baremetal::Linker::ConstructJob`（578） | 见 §4 |

搬运系列各自贡献的内容（从 `BareMetal.cpp` 的 20 → 21 diff 与各 PR 标题对出来）：

- `#121829`（GCC installation detection）：`initGCCInstallation`、`detectGCCToolchainAdjacent`、构造函数的 GCC 分支、`BareMetal` 改为继承 `Generic_ELF`；
- `#121830`（crtbegin/crtend/libgloss）：链接器里的 crt 与 `-lgloss` 逻辑；
- `#132806`（link order）：`.o` 挪到 `-L` 之后、`--start-group` 包住运行库；
- `#132807`（`-u`）：转发 `-u`；
- `#132808`（sysroot）：转发 `--sysroot=`；
- `#134442`（`-m`）：`getLDMOption` 查表加 `-m`；
- `#121831`：三个默认值搬过来、删文件。

## 4. 行为差异表（实测，同一条命令两版对照）

命令：`--target=riscv32-unknown-elf --gcc-toolchain=$T --sysroot=$S --rtlib=platform -fuse-ld= hello.c`。

| # | 项 | 20.1.8（`RISCV::Linker`） | 21.1.8（`baremetal::Linker`） | 影响 |
|---|---|---|---|---|
| 1 | `-Bstatic` | 无 | 有，紧跟 `--sysroot` | 无实际差别（裸机没有 `.so`），但测试要改 |
| 2 | `-lgcc` 位置 | `--start-group -lc -lgloss --end-group -lgcc` | `--start-group -lgcc -lc -lgloss --end-group` | libgcc 反向依赖 libc 的符号（如某些软浮点里的 `memcpy`）现在能解决 |
| 3 | 用户 `.o` 的位置 | 在 `-L` 之前 | 在所有 `-L` 之后 | 对 `ld` 无差别（`-L` 是全局的） |
| 4 | 额外的 `-L` | 无 | 多一条 `-L<ResourceDir>/lib/riscv32-unknown-unknown-elf`（`LibraryPaths`） | compiler-rt 的库目录进搜索路径 |
| 5 | `-T`/`-s`/`-t`/`-r` 位置 | 在 `-L` 之后 | 与 `-L`、`-u` 一组，在工具链 `-L` 之前 | 无差别 |
| 6 | `-mno-relax` → `--no-relax` 位置 | `-m` 之前 | `-X` 之后 | 无差别 |
| 7 | multilib 时的头文件目录 | `<sysroot>/include` | `<sysroot>/<multilib 子目录>/include`，例如 `.../riscv64-unknown-elf/rv32im/ilp32/include` | **riscv-gnu-toolchain 没有这个目录**，newlib 头文件在 `<sysroot>/include`。21.1.8 上带 multilib 的 GCC 树会找不到 `stdio.h`，除非另给 `-isystem`。上游 2025-12-19 的 `e4169e7bc10f` 标题是 "Fix the missing Target-Triple-Level include path resolution in Baremetal Driver"，可能与此相关，未核实 |
| 8 | libstdc++ 头文件 | 三个目录各一次 | `include/c++/8.0.1` 出现两次（`addLibStdCxxIncludePaths` 一次，`AddClangCXXStdlibIncludeArgs` 里扫 `<sysroot>/include/c++/*` 又一次） | 无害 |
| 9 | `--gcc-install-dir=` 单独给 | 不进 `RISCVToolChain`，参数 unused | 生效 | 可以精确指定 GCC 版本了 |
| 10 | `--gcc-toolchain=` 空值 | 进 `RISCVToolChain`，探测失败，`-L/lib` + 裸 `crt0.o` | 探测失败后走无 GCC 分支：`clang-runtimes` sysroot | 上游用它写测试的手法失效，测试改成了 `aarch64/armv6m` |
| 11 | `-flto` | 不传任何东西 | `-plugin-opt=mcpu=generic-rv32 -plugin-opt=O2`（`ld.bfd` 时另加 `-plugin …/LLVMgold.so`） | LTO 参数终于能传到链接器 |
| 12 | 无 GCC 时默认链接器 | `BareMetal`（20）覆盖成 `ld.lld`，且不传 `-m` | `ld`（`GetLinkerPath` 默认），传 `-m` | 无 GCC 的用户要么装 `riscv32-unknown-elf-ld`，要么显式 `-fuse-ld=lld` |
| 13 | 无 GCC 时 C++ 库 | libstdc++（`RISCVToolChain`）/ libc++（`BareMetal`） | libc++ | |
| 14 | 无 GCC 时 crt/`-lgloss` | 相邻 crt0 时仍 `-lgloss` + `clang_rt.crt*` | 相邻 crt0 时同 20；完全没有时不加 `-lgloss` 也不加 crtbegin | |
| 15 | bindings 里的工具名 | `RISCV::Linker` | `baremetal::Linker` | 只影响 `-ccc-print-bindings` 与测试 |

差异 7 是唯一一条会让**原本能编译的命令在 21 上失败**的（需要带 multilib 的 GCC 树才会触发；
单 multilib 的树不受影响，因为 `includeSuffix` 为空）。

## 5. 如果要在 21 上继续维护一份自己的 `RISCVToolchain.cpp`

上游删掉的文件可以原样放回去，但要重新接线。清单（按 `f8cb7987c64d` 的反向操作，加上 21 期间的 API 变化）：

1. `clang/lib/Driver/CMakeLists.txt`：`add_clang_library(clangDriver …)` 的源文件列表加回 `ToolChains/RISCVToolchain.cpp`。
2. `clang/lib/Driver/Driver.cpp`：加回 `#include "ToolChains/RISCVToolchain.h"`，`getToolChain` 的 `riscv32/riscv64` case 改回
   `if (RISCVToolChain::hasGCCToolchain(...)) … else BareMetal`（或按需求改成别的判据）。
3. `RISCVToolchain.cpp` 第 10 行：`#include "CommonArgs.h"` → `#include "clang/Driver/CommonArgs.h"`（`a42bb8b57a6d`）。
4. 决定与 21 的 `BareMetal` 的分工：21 的 `BareMetal` 现在**自己会**在 `--gcc-toolchain`/`--gcc-install-dir` 下探测 GCC，
   两个类同时存在时，凡是走到 `BareMetal` 的 RISC-V 命令行为已经与 20 不同（§4 的表）。要么让 `hasGCCToolchain`
   为真时一律走自己的类（此时 `BareMetal` 的 GCC 分支只剩 ARM/PPC 用），要么干脆把自己的改动做成 `BareMetal` 的补丁。
5. 测试：`clang/test/Driver/riscv32-toolchain.c`、`riscv64-toolchain.c`、`*-toolchain-extra.c`、`baremetal-undefined-symbols.c`
   的期望在 `f8cb7987c64d` 里改成了 21 的顺序（`-lgcc` 进 group 等）；用回老类就要把这些 CHECK 行改回去，
   diff 都在那一个提交里。
6. 之前的版本差异不要漏：`SelectedMultilibs` 向量、`addAllArgs` 命名、`getDefaultUnwindTableLevel` 的存在——
   如果手里的文件来自 15.x，先把 §2 的五处套上再谈 21。

反过来，如果决定**不**保留这个文件而把改动移植到 `BareMetal.cpp`，§3 的映射表就是"改动搬到哪个函数"的答案：
`RISCV::Linker::ConstructJob` 里的每一段在 `baremetal::Linker::ConstructJob` 里都有位置对应，
只是多了 `Triple.isRISCV()` / `TC.hasValidGCCInstallation() || detectGCCToolchainAdjacent(D)` 这样的守卫，
因为同一个函数现在也服务 ARM 与 PPC。

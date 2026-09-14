# clang driver 里的 RISC-V 裸机工具链：`RISCVToolchain.cpp` 整理

`clang/lib/Driver/ToolChains/RISCVToolchain.cpp` 是 clang 为 `riscv32/64-unknown-elf`（裸机、无操作系统）
目标准备的 driver 逻辑：找 GCC 交叉工具链、选 multilib、决定头文件目录、拼出那条 `ld` 命令。
这份整理面向**对 clang driver、链接器与 C 运行库都没有基础、但要修改这个文件逻辑**的读者：
先补齐背景（driver 是什么、`ld` 命令里每个词是什么、`ToolChain` 基类给了什么、GCC 怎么被找到），
再逐段精读文件本身，最后讲它的历史与在 LLVM 21 里的去向，以及改它的方法与坑。
每个结论都配可运行的例子，用断言兑现。

## 核对环境

2026-09-14 在 Linux x86_64 上核对：

| 材料 | 版本 |
|---|---|
| `RISCVToolchain.cpp` 文本 | llvmorg-15.0.7、llvmorg-20.1.8（含此文件的最后一个大版本），另核对 18.1.8 / 19.1.7 定位变更进入的版本 |
| 其余源码（行号） | llvmorg-21.1.8 的 `clang/lib/Driver/`、`clang/include/clang/Driver/`、`clang/lib/Lex/InitHeaderSearch.cpp` |
| 命令输出 | LLVM 官方预编译包 `LLVM-20.1.8-Linux-X64` 与 `LLVM-21.1.8-Linux-X64` 里的 `clang` |
| 历史 | GitHub 上该文件的 45 条提交记录，及 `46420b6feedc`、`45ba2392d7e0`、`f8cb7987c64d` 三个提交的完整补丁 |

正文里的结论分四种依据，就地标注：**实测**（`examples/` 里的断言，两个 clang 版本都跑通）、
**代码阅读**（给出文件与行号）、**上游文档**（`clang/docs/*.rst`）、**推论**（由前三者推出，未实跑）。

## 读法

| 篇 | 内容 |
|---|---|
| [01 driver 的模型](01-driver-model.md) | driver 与 cc1 的关系；五个阶段与四个观察开关；`ToolChain` / `Tool` / `Command`；`Driver` 上的路径字段；两种 triple；`getToolChain` 的分派；参数的 claimed 位 |
| [02 链接零基础](02-linking-basics.md) | 目标文件与库、`-l`/`-L`/`--sysroot`、crt0/crtbegin/crtend、`-lc -lgloss -lm -lgcc` 各是什么、`--rtlib`/`--unwindlib`/`--stdlib`、`-m`/`-X`/`--no-relax`/`-T`/`-u`/`-r`、裸机与 Linux 链接行对照 |
| [03 `ToolChain` 基类](03-toolchain-class.md) | 三张路径表；`GetFilePath`/`GetProgramPath`/`GetLinkerPath` 的查找顺序；三个库类型与 `platform`；头文件钩子与 `-internal-isystem`；`Generic_GCC` 带来的东西；"谁调用它"总表 |
| [04 找 GCC 与 multilib](04-gcc-detection-and-multilib.md) | 一套 GCC 交叉工具链的目录形状；`GCCInstallationDetector::init` 流程；RISC-V 硬编码的七个 multilib；重用规则；默认 `-march`/`-mabi` 的来源；`multilib.yaml` |
| [05 `RISCVToolchain.cpp` 逐段精读](05-riscvtoolchain-cpp.md) | 20.1.8 全文逐函数、逐行讲解；链接行逐词回看；`RISCV::Linker` 没实现的东西 |
| [06 历史与 LLVM 21](06-history-and-llvm21.md) | 2018–2025 时间线；15.0.7 → 20.1.8 的五处差异；21 里并入 `BareMetal.cpp` 的函数映射；15 条实测行为差异；在 21 上保留或迁移此文件的接线清单 |
| [07 改它的逻辑](07-modifying.md) | 定位"这个参数谁加的"；"想改 X → 改哪里"速查；四个改法样例；`-###` / lit / 真链接三层验证；坑 |

第一次读按 01 → 07。已经熟悉 driver 与链接的读者直接看 05，遇到不明白的钩子回 03，遇到路径问题回 04。

## 目录

```text
riscv-toolchain-driver/
├── 01-driver-model.md … 07-modifying.md
└── examples/
    ├── lib.sh                  共用脚手架：找 clang、一次性目录、假工具链树、断言
    ├── run-all.sh              依次跑全部例子
    ├── 01-phases/              -ccc-print-phases / -ccc-print-bindings / -###；20 与 21 的链接 Tool 名
    ├── 02-gcc-tree/            有 GCC 树时的链接行，20 与 21 逐项对照；-v 探测输出；版本选择与 --gcc-install-dir
    ├── 03-multilib/            七个 multilib 的候选表、按 -march/-mabi 选目录、重用规则、头文件目录差异
    ├── 04-no-gcc/              相邻 crt0.o、什么都没有、20 上 --gcc-install-dir 不触发 三种情况
    ├── 05-flags/               -nostdlib 家族、-mno-relax、--rtlib、-static/-nolibc、-T/-u/-Wl,/-e 的落点、-flto、-fuse-ld、-print-*
    └── 06-lit-style/           一份上游风格的 lit 测试（test.c）与它的手工执行
```

## 跑例子

例子只用 clang 的 `-###`、`-v`、`-print-*` 观察 driver 的决策，不真正链接，所以**不需要任何 RISC-V 的
GCC、newlib 或 compiler-rt**：假的工具链目录树用空文件搭出来（上游 `clang/test/Driver/Inputs/` 也是这么做的）。
需要的只是两个 clang 可执行文件：

```bash
# 官方预编译包解开即可用；只需要 bin/clang-NN、bin/clang、bin/clang++、bin/ld.lld 几个文件
export CLANG20=/opt/LLVM-20.1.8-Linux-X64/bin/clang    # 任意 20.x：RISCVToolchain.cpp 还在
export CLANG21=/opt/LLVM-21.1.8-Linux-X64/bin/clang    # 任意 21.x：已并入 BareMetal.cpp
examples/run-all.sh                   # 全部例子；成功的只打印一行，失败的打印完整输出
bash examples/02-gcc-tree/run.sh      # 单个例子，完整输出（每条链接命令逐参数一行）
KEEP=1 bash examples/03-multilib/run.sh   # 保留一次性目录，可以进去自己敲 -###
```

缺少哪个版本对应的段落打印 `SKIP`。`06-lit-style` 另可选 `FILECHECK=<某个 LLVM 构建目录>/bin/FileCheck`，
有则真用 FileCheck 检查 `test.c` 里的 CHECK 行（官方预编译包不带 FileCheck）。

每个例子在 `mktemp -d` 建的一次性目录里运行，结束时删除；不读不写你机器上的任何工具链。

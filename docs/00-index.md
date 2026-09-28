# 索引

## 10-llvm —— LLVM 后端

| 文件 | 内容 |
|---|---|
| [11-backend-pipeline.md](10-llvm/11-backend-pipeline.md) | 代码生成流水线的钩子在哪、顺序谁定、怎么用一条命令看到整条流水线 |
| [12-observing-a-pass.md](10-llvm/12-observing-a-pass.md) | 观察一个后端 pass 的四件工具：`-print-after-all` / `-debug-only` / `-stop-after`+`-run-pass` / lit+FileCheck |
| [13-riscv-load-store-optimizer.md](10-llvm/13-riscv-load-store-optimizer.md) | `RISCVLoadStoreOptimizer` 解剖，以及它从 21.1.8 到 23.1.0 的演化：一个 pass 如何成为多个厂商扩展的共享框架 |

阅读顺序：11 → 12 → 13。11 给地图，12 给工具，13 是把两者用在一个真实 pass 上的完整例子。

## src —— 带可运行例子的专题整理

| 目录 | 内容 |
|---|---|
| [src/ccache-guide](../src/ccache-guide/README.md) | ccache：缓存键模型、配置、接入 Make / Autotools / CMake / Meson / LLVM / CI、远端存储、诊断、坑与版本差异。每个结论配可运行的例子，在 ccache 4.13.6 与 4.14 上核对 |
| [src/riscv-toolchain-driver](../src/riscv-toolchain-driver/README.md) | clang driver 里的 RISC-V 裸机工具链（`RISCVToolchain.cpp`）：driver 模型、链接零基础、`ToolChain` 基类、GCC 探测与 multilib、文件逐段精读、2018–2025 历史与并入 `BareMetal.cpp` 的映射、改法与坑。例子在 clang 20.1.8 与 21.1.8 上核对 |
| [src/git-rebase-onto](../src/git-rebase-onto/README.md) | `git rebase --onto A B C`：三个参数各决定什么、内部执行顺序与源码对应、十几种写法的结果、重复提交的两套判定（预检比 B 不比 A）、冲突时 ours/theirs、叠放分支与 `--fork-point` / `--update-refs`、merge 与 autostash 的坑。例子在 git 2.55.0 上核对 |
| [src/riscv-registers](../src/riscv-registers/README.md) | RISC-V 的整数、浮点、向量寄存器与 CSR：psABI 分工、压缩指令为什么偏向 x8–x15、LLVM 的分配顺序与保留集、调用约定与序言的三种写法、gp 链接器松弛、中断处理函数保存什么、`-march` 与 `-mabi` 的组合、trap 进出时硬件改什么。例子是一个个 C 小实验，预期输出写在注释里，在 llvmorg-21.1.8 上核对 |

# llvm-notes

学习上游 `llvm-project` 时的笔记：后端流水线、观察一个 pass 的工具、以及一个真实 pass 的解剖。
只写公开事实与从中得出的通用方法。从 [`docs/00-index.md`](docs/00-index.md) 进。

`src/` 下是带可运行例子的专题整理，目前有 [ccache](src/ccache-guide/README.md)、
[clang driver 里的 RISC-V 裸机工具链](src/riscv-toolchain-driver/README.md)、
[`git rebase --onto`](src/git-rebase-onto/README.md) 与
[RISC-V 寄存器](src/riscv-registers/README.md)。

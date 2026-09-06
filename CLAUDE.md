# CLAUDE.md — llvm-notes

## 这个仓是什么

学习 LLVM 时的笔记。读者是我本人，和替我读代码的 agent。它是自足的：不依赖任何仓外的
上下文，也不要去猜仓外有什么。

## 怎么读

从 [`docs/00-index.md`](docs/00-index.md) 进。同一组内按编号递进。

## 怎么写

- **每条命令都要说明每个参数的作用**，不收"能跑就行"的命令。
- **讲原理按「是什么 → 为什么这样设计 → 对应哪块代码」的顺序。** 读者 LLVM 零基础、
  C++ 刚入门，Linux 与 git 熟练。LLVM 概念（IR / SSA / Pass / MIR / TableGen /
  SubtargetFeature / lit / FileCheck）与 LLVM 自有惯用法（`SmallVector` `StringRef`
  `ArrayRef` `isa/cast/dyn_cast` `INITIALIZE_PASS` `LLVM_DEBUG` `cl::opt`）
  **首次出现都要解释**，读到哪讲哪，不单独开一节。
- **宁可长而讲透，不要一句"跑这个就行"。**
- **写进来之前先跑一遍。** 没实际验证过的命令和结论不写；涉及版本的结论标注在哪个
  tag 上核对的。
- 目录十位分组、组内两位递增。加新文件同时更新 `docs/00-index.md`。

## 内容边界

只写**上游 `llvm-project` 的公开事实**，以及从中得出的通用方法。

任何来自非公开来源的内容都不写——标识符、路径、机器规格、任务背景，一概不写。
不确定算不算公开，就当不算。

不要在这个仓里推测它之外还有什么。问题超出上游 LLVM 的范围时，直说"这个仓不覆盖"，
不要编。

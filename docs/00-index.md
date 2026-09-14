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

# 11 — 后端代码生成流水线：钩子在哪、顺序谁定、怎么亲眼看

## 1. 一段 C 变成汇编，中间经过什么

```
C 源码 ──clang 前端──▶ LLVM IR ──中端 pass──▶ 优化后的 IR
        ──指令选择──▶ MachineIR（MIR）──后端 pass──▶ 汇编
```

- **LLVM IR** 是与目标机器无关的中间表示，SSA 形式（每个值只被赋值一次）。文本后缀 `.ll`，二进制后缀 `.bc`。
- **MachineIR（MIR）** 是指令选择之后的表示：已经是目标机器的指令了，但寄存器还可能是"虚拟寄存器"（`%0`、`%1`，无限多个），寄存器分配之后才变成物理寄存器（`$x10`）。文本后缀 `.mir`。
- **后端 pass** 绝大多数是 `MachineFunctionPass`：一个类，`runOnMachineFunction(MachineFunction &MF)` 被每个函数调用一次，在 MIR 上做变换。

工具分工：

| 工具 | 输入 → 输出 |
|---|---|
| `clang -S -emit-llvm` | C → LLVM IR 文本 |
| `opt` | IR → IR（只跑**中端** pass，与后端无关） |
| `llc` | IR → 汇编（走完整个**后端**）。后端 pass 的实验 90% 在这里做 |
| `llvm-mc` | 汇编 ↔ 机器码（MC 层，测指令编码） |

## 2. 钩子：后端往流水线里插 pass 的地方

代码生成流水线的骨架写死在基类 `TargetPassConfig::addMachinePasses()` 里（`llvm/lib/CodeGen/TargetPassConfig.cpp`）。它在固定位置调用一组**虚函数**，每个后端 override 自己需要的那几个，把自己的 pass 插进去。**函数名就是位置**：

| 钩子 | 位置 |
|---|---|
| `addIRPasses()` | 还在 IR 层，指令选择之前 |
| `addCodeGenPrepare()` | IR 层最后的准备 |
| `addMachineSSAOptimization()` | MIR 已生成、寄存器还是虚拟的（仍是 SSA） |
| `addPreRegAlloc()` | 寄存器分配**之前** |
| `addPostRegAlloc()` | 寄存器分配**之后**，紧接着 |
| `addPreSched2()` | 寄存器分配之后、post-RA 指令调度之前 |
| `addPreEmitPass()` | 发射汇编之前 |
| `addPreEmitPass2()` | 更靠后的发射前处理（伪指令展开等） |

基类上还有 `addMachineLateOptimization()` 等其它钩子；**某个后端有没有 override 某个钩子，要自己 grep，不能假设**。

RISCV 后端（21.1.8 与 23.1.0 实测一致）override 了这些，**没有** `addMachineLateOptimization()`：

```bash
grep -n 'void RISCVPassConfig::' llvm/lib/Target/RISCV/RISCVTargetMachine.cpp
```

```
addIRPasses  addCodeGenPrepare  addPreLegalizeMachineIR  addPreRegBankSelect
addPreSched2  addPreEmitPass  addPreEmitPass2  addMachineSSAOptimization
addPreRegAlloc  addFastRegAlloc  addPostRegAlloc
```

这个差异很重要：如果一份改动说"往 `addMachineLateOptimization()` 里加一行"，在 RISCV 后端上就不是加一行，而是**新建一个 override 函数**。这类事 diff 看不出来，动手才撞上。

## 3. 亲眼看整条流水线：一条命令

```bash
llc -mtriple=riscv32 -O2 -debug-pass=Structure t.ll -o /dev/null
```

- `-mtriple=riscv32` — 目标三元组。决定用哪个后端。不给的话按宿主机猜。
- `-O2` — 优化等级。**很多 pass 只在 `getOptLevel() != None` 时才挂上去**，用 `-O0` 会看不到它们。
- `-debug-pass=Structure` — 打印流水线**结构**（pass 名列表 + 层次），不打印 IR 内容。比 `-print-after-all` 紧凑得多，适合"先看骨架"。
- `-o /dev/null` — 汇编输出丢掉，只要诊断信息（诊断走 stderr）。

输出第一行是一整条 `Pass Arguments:`，就是这次运行的全部 pass 的命令行名，按执行顺序。想定位某个 pass 的邻居：

```bash
llc -mtriple=riscv32 -O2 -debug-pass=Structure t.ll -o /dev/null 2>&1 \
  | head -1 | tr ' ' '\n' | grep -n -B3 -A3 '<pass 的命令行名>'
```

`tr ' ' '\n'` 把那一长行拆成每行一个 pass，`grep -n -B3 -A3` 给出行号和前后各三个邻居。

实测（RISCV，21.1.8，`-O2`）`riscv-load-store-opt` 的位置：

```
168 -postrapseudos
169 -riscv-post-ra-expand-pseudo
170 -kcfi
171 -riscv-load-store-opt      ← 它挂在 addPreSched2()
172 -machinedomtree
```

**建议实际跑一遍再谈顺序**，不要靠记忆或靠读 `addMachinePasses()` 推断——条件挂载（`if (TM->getOptLevel() ...)`、`if (EnableXxx)`）很多，静态读容易漏。

## 4. 一个必须知道的实现细节

**代码生成仍然使用 legacy PassManager**，中端才是新 PassManager。所以后端 pass 写法是 `struct X : public MachineFunctionPass`、用 `INITIALIZE_PASS` 宏注册、用 `getAnalysis<T>()` 取分析结果——这些在中端已经是旧写法了，在后端仍是现行写法。看教程时注意区分，否则会被"新旧两套 PassManager"绕晕。

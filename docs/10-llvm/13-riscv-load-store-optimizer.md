# 13 — `RISCVLoadStoreOptimizer`：一个 pass 的解剖，与它从 21 到 23 的演化

这个 pass 是 RISCV 后端里"把多条访存指令合成一条"的那个。它值得单独讲，因为
**上游用它作为容纳多个厂商扩展的载体**——21 到 23 之间它从 401 行长到 949 行，
长出来的部分就是"如何把一个新的厂商访存扩展接进后端"的完整范本。

以下所有事实都在 `llvmorg-21.1.8` 与 `llvmorg-23.1.0` 的源码树上实测核对过。

## 1. 21.1.8：单一用途，401 行

文件头注释直说了它的来历：pairing 逻辑改编自 `AArch64LoadStoreOpt`。

调用链：

```
runOnMachineFunction(MF)
├─ skipFunction()                          函数带 optnone 属性就跳过
├─ if (!Subtarget.useLoadStorePairs()) return false;      ← 唯一的门
└─ 遍历每个 MachineBasicBlock 的每条指令
   └─ TII->isPairableLdStInstOpc(opcode)   这条指令是不是可配对的 LW/SW/LD/SD
      └─ tryToPairLdStInst(MBBI)
         ├─ MI.hasOrderedMemoryRef()       volatile / atomic 直接放弃
         ├─ TII->isLdStSafeToPair(MI, TRI)
         ├─ findMatchingInsn(MBBI, MergeForward)   向后扫窗口找配对
         └─ mergePairedInsns(...) → tryConvertToLdStPair(First, Second)
                                    ├─ 按 opcode 选配对指令与对齐要求
                                    ├─ 校验 MMO 对齐、offset 是否 isUInt<7>
                                    └─ BuildMI(...) 建新指令，删掉原来两条
```

几个值得认识的成员：

```cpp
MachineFunctionProperties getRequiredProperties() const override {
  return MachineFunctionProperties().setNoVRegs();
}
```
声明"我要求 MIR 里已经没有虚拟寄存器"——等价于说**这个 pass 必须跑在寄存器分配之后**。框架会校验，放错位置直接报错，不会静默出错。

```cpp
void getAnalysisUsage(AnalysisUsage &AU) const override {
  AU.addRequired<AAResultsWrapperPass>();
  MachineFunctionPass::getAnalysisUsage(AU);
}
```
声明依赖别名分析（AA）。合并访存必须知道中间那些指令会不会碰同一块内存，`findMatchingInsn` 扫描时用它判断能不能跨过去。

```cpp
static cl::opt<unsigned> LdStLimit("riscv-load-store-scan-limit", cl::init(128), cl::Hidden);
```
`cl::opt` 是 LLVM 的命令行选项机制：声明一个全局对象，它自动注册成 `-riscv-load-store-scan-limit=<n>`。`cl::Hidden` 表示不出现在 `--help` 里（要用 `--help-hidden`）。这是**扫描窗口**：向后最多看 128 条指令。

### 对齐门槛（第一次实验必踩）

```cpp
case RISCV::SW: PairOpc = RISCV::MIPS_SWP; RequiredAlignment = Align(8);  break;
case RISCV::LW: PairOpc = RISCV::MIPS_LWP; RequiredAlignment = Align(8);  break;
case RISCV::SD: PairOpc = RISCV::MIPS_SDP; RequiredAlignment = Align(16); break;
case RISCV::LD: PairOpc = RISCV::MIPS_LDP; RequiredAlignment = Align(16); break;
```

两条 32 位 `sw` 要合成一条 `swp`，**基址必须 8 字节对齐**。`int*` 只保证 4 字节，所以最直觉的测试用例是不会触发的——看起来像"pass 没生效"，实际是对齐没过。

## 2. 23.1.0：同一骨架，四条路径，949 行

`runOnMachineFunction` 变成两段：

```cpp
if (STI->useMIPSLoadStorePairs() || STI->hasVendorXqcilsm()) {
    ... 与 21 相同的配对扫描 ...
}
if (!STI->is64Bit() && STI->hasStdExtZilsd()) {
    ... fixInvalidRegPairOp：post-RA 修正 ...
}
```

而 `tryConvertToLdStPair` 从"干活的"变成了**分发器**：

```cpp
bool RISCVLoadStoreOpt::tryConvertToLdStPair(First, Second) {
  // Try converting to QC_LWMI/QC_SWMI if the XQCILSM extension is enabled.
  if (!STI->is64Bit() && STI->hasVendorXqcilsm())
    return tryConvertToXqcilsmLdStPair(MF, First, Second);
  // Else try to convert them into MIPS Paired Loads/Stores.
  return tryConvertToMIPSLdStPair(MF, First, Second);
}
```

加上从 `tryToPairLdStInst` 另行分出的多条合并路径，一共四条：

| 函数 | 服务的扩展 | 干什么 |
|---|---|---|
| `tryConvertToXqcilsmMultiLdSt()` | Xqcilsm（厂商） | **3~31 条**连续 `LW`/`SW` → `QC_LWMI` / `QC_SWMI` / `QC_SETWMI` |
| `tryConvertToXqcilsmLdStPair()` | Xqcilsm（厂商） | 两条配对 |
| `tryConvertToMIPSLdStPair()` | XMIPSLSP（厂商） | 两条 → `MIPS_LWP` / `MIPS_SWP` / `MIPS_LDP` / `MIPS_SDP` |
| `fixInvalidRegPairOp()` | Zilsd（**标准**扩展） | 寄存器分配没给出合适的连续寄存器对时，把 `LD`/`SD` 拆回两条 |

`tryConvertToXqcilsmMultiLdSt()` 的判定条件值得读一遍，它是"N 条合一"这类变换的标准形状：

- 只处理 `LW`/`SW`，且 `hasOneMemOperand()`、4 字节对齐
- 基址必须是 `reg + imm` 形式，偏移满足 `isShiftedUInt<5,2>`
- 从第一条起向后收集：同 opcode、同基址寄存器、偏移严格 `+4` 递增
- **load 要求目标寄存器连续递增**（`Reg != StartReg + Index` 就断）
- store 分两种模式：全用同一个源寄存器 → `QC_SETWMI`（相当于填充）；连续递增 → `QC_SWMI`
- 长度必须 `3 ≤ Len ≤ 31`（两条的交给配对那条路径）
- 建指令时把组内所有指令的 `kill` 标志聚合、`cloneMergedMemRefs` 合并内存引用、给多出来的寄存器补 implicit operand

## 3. 门控：一律走 SubtargetFeature，不用宏

三条厂商路径的开关都是 Subtarget 上的查询：

```cpp
STI->hasVendorXqcilsm()          // 由 RISCVFeatures.td 的 FeatureVendorXqcilsm 生成
STI->useMIPSLoadStorePairs()     // = UseMIPSLoadStorePairsOpt && HasVendorXMIPSLSP
STI->hasStdExtZilsd()
```

`.td` 里长这样：

```tablegen
def FeatureVendorXqcilsm ...
def HasVendorXqcilsm
    : Predicate<"Subtarget->hasVendorXqcilsm()">,
      AssemblerPredicate<(all_of FeatureVendorXqcilsm),
                         "'Xqcilsm' (Qualcomm uC Load Store Multiple Extension)">;
```

**为什么上游坚持 SubtargetFeature 而不是 C 预处理宏**：

- 宏是**编译期**开关。同一个 clang 二进制没法同时支持开和关，也没法用 `-mattr=` 在运行时切。
- SubtargetFeature 是**运行时**开关。一个二进制同时支持两种，于是 lit 测试可以在同一棵树里既测开又测关——这是能被 CI 覆盖的前提。
- `AssemblerPredicate` 还让汇编器在扩展没开时给出可读的诊断。

给 RISCV 后端加厂商扩展时，这是上游的既定范式；用宏做门控的改动在 review 时会被要求改。

## 4. 可复现的实验

下面这套在 `llvmorg-21.1.8` 的构建上逐条实测通过。

```c
/* p.c —— 注意 aligned(8)，不加就不会触发 */
typedef struct { int a, b; } __attribute__((aligned(8))) P;
void f(P *p, int a, int b) { p->a = a; p->b = b; }
```

```bash
clang -S -emit-llvm --target=riscv32 -march=rv32imac -O2 p.c -o p.ll
```

- `--target=riscv32` — 交叉目标。不 include 任何头文件就不需要 sysroot。
- `-march=rv32imac` — 基础整数 + 乘除 + 原子 + 压缩指令。
- `-S -emit-llvm` — 停在 IR，输出文本 `.ll`。

**不开扩展**（两条 `sw`）：

```bash
llc -mtriple=riscv32 -O2 p.ll -o -
```

**开 XMIPSLSP**：

```bash
llc -mtriple=riscv32 -mattr=+Xmipslsp -use-riscv-mips-load-store-pairs=1 -O2 p.ll -o -
```

- `-mattr=+Xmipslsp` — 打开这个厂商扩展的 SubtargetFeature。
- `-use-riscv-mips-load-store-pairs=1` — 这条路径还额外挂了一个 `cl::opt` 开关（`useLoadStorePairs()` 是 `UseMIPSLoadStorePairsOpt && HasVendorXMIPSLSP`，两个都要）。**只给 `-mattr` 不给这个，什么也不会发生**。

得到：

```asm
	mips.swp	a1, a2, 0(a0)
```

**用 `-run-pass` 单独跑**（推荐的迭代方式）：

```bash
llc -mtriple=riscv32 -O2 -stop-after=prologepilog p.ll -o p.mir
llc -mtriple=riscv32 -mattr=+Xmipslsp -use-riscv-mips-load-store-pairs=1 \
    -run-pass=riscv-load-store-opt p.mir -o -
```

MIR 输出里能直接看到：

```
MIPS_SWP killed renamable $x11, killed renamable $x12, renamable $x10, 0 ::
    (store (s32) into %ir.0, align 8, !tbaa !6), (store (s32) into %ir.4, !tbaa !11)
```

注意 `align 8` ——对齐信息就在 MachineMemOperand 里，pass 读的就是它。

## 5. 现成的测试范本

| 版本 | 文件 | 形态 |
|---|---|---|
| 21 & 23 | `llvm/test/CodeGen/RISCV/load-store-pair.ll` | `.ll` 输入，多个 `RUN:` 行覆盖开/关扩展的组合 |
| 23 | `llvm/test/CodeGen/RISCV/xqcilsm-lwmi-swmi.mir` | **MIR 输入 + `-run-pass`**，一个函数一个边界情况 |
| 23 | `llvm/test/CodeGen/RISCV/xqcilsm-lwmi-swmi-multiple.mir` | 同上，N 条合并 |
| 23 | `llvm/test/CodeGen/RISCV/xqcilsm-memset.ll` | 端到端 |
| 23 | `llvm/test/MC/RISCV/xqcilsm-{valid,invalid,aliases-valid}.s` | MC 层：汇编与编码 |

`.mir` 那两个是最值得抄的：

```
# RUN: llc -mtriple=riscv32 -mattr=+xqcilsm -run-pass=riscv-load-store-opt %s -o - | FileCheck %s
--- |
  define void @pair_two_lw_into_qc_lwmi() nounwind { ret void }
  define void @no_pair_if_different_base_regs() nounwind { ret void }
  define void @no_pair_if_alignment_lt_4() nounwind { ret void }
  ...
```

每个函数名就是一条判定规则，**正例与反例成对写**。给一个访存合并 pass 写测试，这个清单基本就是需求列表：不同基址不合、对齐不够不合、偏移不连续不合、寄存器不连续不合、越界不合、`x0` 不合。

## 6. 这段演化说明了什么

对"想给 RISCV 后端加自己的访存扩展"这件事，21 → 23 的那 610 行差异就是最直接的答案：不是新开一个文件、新注册一个 pass，而是**在既有 pass 里加一条分支加一个 feature**。这样做的收益是别名分析、扫描窗口、`kill` 标志维护、memref 合并这些容易写错的部分完全复用，而且未来跟上游同步时不会冲突。

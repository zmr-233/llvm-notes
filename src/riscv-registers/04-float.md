# 04 浮点寄存器

## 1. f0–f31

- 32 个，每个 FLEN 位：只有 F 时 32 位，有 D 时 64 位。
- 有 D 时，单精度值放进 64 位的寄存器要做 NaN-boxing：高 32 位必须全是 1。按单精度读一个高
  32 位不全为 1 的寄存器，读到的是 NaN。QEMU v11.1.1 `target/riscv/internals.h` 的
  check_nanbox_s：高 32 位不全为 1 就返回 0x7fc00000（单精度的默认 NaN）。
- 开 Zfinx 时处理器里没有 f0–f31，浮点指令直接读写 x 寄存器（第 4 节）。

## 2. ABI 名字与保存责任

```
f0–f7     ft0–ft7    临时          调用者保存
f8–f9     fs0–fs1    保存          ilp32f/ilp32d 下被调用者保存
f10–f11   fa0–fa1    参数 / 返回   调用者保存
f12–f17   fa2–fa7    参数          调用者保存
f18–f27   fs2–fs11   保存          ilp32f/ilp32d 下被调用者保存
f28–f31   ft8–ft11   临时          调用者保存
```

- 名字取自 `RISCV/RISCVRegisterInfo.td:380` 起的定义。排布和整数寄存器平行：f8–f15 是 fs0、fs1、
  fa0–fa5，压缩的浮点访存指令（c.flw、c.fsw、c.fld、c.fsd）的 3 位字段能表示的就是这 8 个
  （`RISCV/RISCVRegisterInfo.td:456` 的 FPR32C 类）。
- fs 寄存器只在 ilp32f、ilp32d 下是被调用者保存：`RISCV/RISCVCallingConv.td:21–27` 的
  `CSR_ILP32F_LP64F`、`CSR_ILP32D_LP64D` 在整数列表之外加了 F8、F9、F18–F27；ilp32 用的
  `CSR_ILP32_LP64` 里没有浮点寄存器，所以 ilp32 下 32 个浮点寄存器全是调用者保存。
  这一点对中断处理函数的大小影响很大，见 03 第 8 节。

## 3. fcsr 与 mstatus.FS

- fcsr（CSR 0x003）由两段组成：
  - frm：位 7:5，舍入模式。也可以单独用 CSR 0x002 访问。
  - fflags：位 4:0，累积的异常标志，从高到低是 NV（非法操作）、DZ（除以零）、OF（上溢）、
    UF（下溢）、NX（不精确）。也可以单独用 CSR 0x001 访问。
  - 地址见 `RISCV/RISCVSystemOperands.td:73–75`；位的划分见 QEMU `target/riscv/cpu_bits.h` 的
    FSR_RD_SHIFT（5）和 FPEXC_NX … FPEXC_NV（0x01 … 0x10）。
- LLVM 把 frm、fflags 当作寄存器 FRM、FFLAGS 建模：
  - 读写它们的伪指令从 `RISCV/RISCVInstrInfo.td:2041` 开始定义。
  - 浮点指令的舍入模式字段写的是「动态」（dyn，即按 frm 的当前值舍入）时，
    `RISCV/RISCVISelLowering.cpp:21998` 的 AdjustInstrPostInstrSelection 给它加一个隐式读 FRM 的操作数。
    这样它和改写 frm 的指令之间有了数据依赖，指令调度不会调换两者的顺序。
  - 两者都在保留集里（`RISCV/RISCVRegisterInfo.cpp:165` 起），寄存器分配不会拿它们放值。
- mstatus.FS（位 14:13）是浮点单元的状态开关。FS 为 Off 时，任何浮点指令都触发非法指令异常：
  QEMU `target/riscv/tcg/insn_trans/trans_rvf.c.inc` 的 REQUIRE_FPU 在 FS 为 DISABLED 时直接判为
  非法指令。裸机启动代码要在执行第一条浮点指令之前把 FS 设成非 Off。

## 4. -march 与 -mabi 的组合

`-march` 决定有哪些指令可用，`-mabi` 决定函数之间用哪些寄存器传浮点值。实验 `ex/float.c`，
同一个 `float fadd(float a, float b) { return a + b; }`：

```
-march          -mabi    生成
rv32imc         ilp32    call __addsf3
rv32imfc        ilp32    fmv.w.x fa5,a1 ; fmv.w.x fa4,a0 ; fadd.s fa5,fa4,fa5 ; fmv.x.w a0,fa5
rv32imfc        ilp32f   fadd.s fa0,fa0,fa1
rv32imc_zfinx   ilp32    fadd.s a0,a0,a1
rv32imc         ilp32f   警告后按 ilp32 生成，同第一行
rv32imc_zfinx   ilp32f   警告后 clang 段错误（21.1.8）
```

- 没有 F：没有浮点指令，调用软浮点库函数 `__addsf3`（由 compiler-rt 或 libgcc 提供）。
- 有 F、ilp32：能用 fadd.s，但 ilp32 规定 float 参数和返回值经整数寄存器传。fmv.w.x 把整数寄存器里的
  32 位原样搬进浮点寄存器，fmv.x.w 反过来，每个函数边界都要这样搬。换来的是能和按 ilp32 编译的库、
  目标文件链在一起。
- 有 F、ilp32f：参数在 fa0、fa1，返回值在 fa0，一条指令。
- Zfinx：浮点运算的操作数就是 x 寄存器，参数本来就在整数寄存器里，所以配 ilp32。
- 没有 F 却要 ilp32f：driver 不拦。后端打印
  `Hard-float 'f' ABI can't be used for a target that doesn't support the F instruction set extension (ignoring target-abi)`，
  丢掉 `-mabi`，按 ilp32 生成。
- Zfinx 配 ilp32f：打印同一条警告后，clang 21.1.8 在寄存器分配之后的 Post-RA pseudo instruction
  expansion 里段错误，栈顶是 `TargetInstrInfo::lowerCopy`。这个组合本身是错的，应当报错退出。

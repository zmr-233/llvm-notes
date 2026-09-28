# 06 CSR 与 trap

CSR（Control and Status Register）是一组独立编址的控制、状态寄存器，不在 x0–x31 里，
只能用 csr 开头的指令访问。本篇的硬件行为按 QEMU v11.1.1 `target/riscv/` 的源码核对，
CSR 的名字和地址按 `RISCV/RISCVSystemOperands.td` 核对。

## 1. 地址本身带着权限

CSR 地址 12 位，其中两段有固定含义：

- 位 11:10 为 11 表示只读，其他值表示可读写。
- 位 9:8 是能访问它的最低特权级：00 为 U，01 为 S，10 为 H（虚拟化），11 为 M。

```
mstatus  0x300 = 00 11 0000 0000   可读写，M 级
cycle    0xC00 = 11 00 0000 0000   只读，U 级就能读
mhartid  0xF14 = 11 11 0001 0100   只读，M 级
vlenb    0xC22 = 11 00 0010 0010   只读，U 级就能读
```

QEMU `target/riscv/tcg/csr.c` 的 riscv_csrrw_check：`get_field(csrno, 0xC00) == 3` 判只读，
写只读 CSR 返回非法指令；`get_field(csrno, 0x300)` 取出最低特权级，当前特权级不够也返回非法指令。

## 2. 访问指令

- `csrrw rd, csr, rs1`：读出旧值写进 rd，再把 rs1 写进 CSR。
- `csrrs rd, csr, rs1`：读出旧值写进 rd，再把 CSR 中 rs1 为 1 的那些位置 1。
- `csrrc rd, csr, rs1`：读出旧值写进 rd，再把 CSR 中 rs1 为 1 的那些位清 0。
- 各有立即数版本 `csrrwi`、`csrrsi`、`csrrci`，rs1 的位置换成一个 5 位的无符号立即数。
- `csrr`、`csrw`、`csrs`、`csrc`、`csrsi`、`csrci` 等是伪指令，由上面几条配 x0 构成；
  x0 在这里还决定读不读、写不写 CSR，见 02 第 1 节。

实验 `ex/csr.c`：

```
写法                   真实指令                        编码
csrr a0, mstatus       csrrs  a0, mstatus, zero        30002573
csrr a0, 0x300         csrrs  a0, mstatus, zero        30002573
csrsi mstatus, 8       csrrsi zero, mstatus, 0x8       30046073
csrci mstatus, 8       csrrci zero, mstatus, 0x8       30047073
csrw cycle, a0         csrrw  zero, cycle, a0          c0051073
```

- 编码的高 12 位就是 CSR 地址。按名字写和按编号写，生成的编码完全一样；名字只是汇编器里的一张表
  （`RISCVSystemOperands.td`）。
- `csrsi mstatus, 8` 把 mstatus 的位 3（MIE，M 级全局中断开关）置 1，`csrci` 把它清 0。
- 最后一行往只读的 cycle 写值，编译和汇编都不报错；llvm-mc 单独汇编 `csrw cycle, a0` 也不报错。
  只读、特权级这两项检查在处理器执行时做（第 1 节），汇编器不做。

## 3. 常用的 M 级 CSR

地址见 `RISCV/RISCVSystemOperands.td`（行号为 21.1.8）；位的定义见 QEMU `target/riscv/cpu_bits.h`。

- 身份（:285–288、:296）：misa 0x301（实现了哪些扩展）、mvendorid 0xF11、marchid 0xF12、
  mimpid 0xF13、mhartid 0xF14（当前 hart 的编号）。
- mstatus 0x300（:295）。本专题用到的位：
  - MIE，位 3：M 级全局中断开关。
  - MPIE，位 7：进入 trap 时保存下来的 MIE。
  - MPP，位 12:11：进入 trap 之前所在的特权级。
  - FS，位 14:13：浮点单元状态，Off 时浮点指令非法（04 第 3 节）。
  - VS，位 10:9：向量单元状态，Off 时向量指令非法（05 第 5 节）。
  - RV32 上另有 mstatush 0x310（:303），放高 32 位的那些字段。
- mtvec 0x305（:300）：trap 入口。低 2 位是模式，其余位是基址 BASE：
  - 模式 0：所有 trap 都跳到 BASE。
  - 模式 1：中断跳到 BASE + 4 × 中断编号，异常仍跳到 BASE。
- mepc 0x341（:311）：被打断的那条指令的地址，mret 从这里返回。
- mcause 0x342（:312）：最高位 1 表示中断、0 表示异常，其余位是编号。
- mtval 0x343（:313）：附加信息，例如出错的地址。
- mscratch 0x340（:310）：硬件不使用，留给 trap 处理代码暂存一个值。
  例如 `csrrw sp, mscratch, sp` 一条指令交换 sp 和 mscratch，可以在进入 trap 时换到另一个栈。
- mie 0x304（:299）、mip 0x344（:316）：各类中断的使能位和挂起位。M 级软件中断、定时器中断、
  外部中断分别在位 3、7、11（QEMU 的 IRQ_M_SOFT、IRQ_M_TIMER、IRQ_M_EXT），和 mcause 里这三种
  中断的编号相同。
- 计数器：mcycle 0xB00、minstret 0xB02（:367–368），RV32 上高 32 位在 mcycleh 0xB80、
  minstreth 0xB82（:375–376）；mcountinhibit 0x320（:387）可以让它们停止计数。
  U 级可读的只读版本：cycle 0xC00、time 0xC01、instret 0xC02（:110–112）。
- 物理内存保护：pmpcfg0–15 在 0x3A0–0x3AF，pmpaddr0–63 在 0x3B0–0x3EF（:335–343）。

## 4. 一个 M 级中断什么时候被接受

QEMU `target/riscv/tcg/cpu_helper.c` 的 riscv_cpu_local_irq_pending，只看 M 级中断的部分：

- 先取 mip & mie：挂起了、并且在 mie 里使能了的中断（`target/riscv/cpu.c` 的 riscv_cpu_all_pending）。
- 再看全局开关：当前在 M 级运行时，要 mstatus.MIE 为 1；当前在比 M 低的特权级运行时，不看 MIE，
  M 级中断总是可以打断它。

只跑在 M 级的程序要开定时器中断，就是两步：mie 的位 7 置 1，mstatus 的位 3 置 1（`csrsi mstatus, 8`）。

## 5. trap 进出时硬件改什么

进入 M 级 trap 时（QEMU `target/riscv/tcg/cpu_helper.c` 的 riscv_cpu_do_interrupt）：

```
mstatus.MPIE ← mstatus.MIE
mstatus.MPP  ← 当前特权级
mstatus.MIE  ← 0
mcause       ← 编号 | (是中断 ? 最高位 : 0)
mepc         ← pc
mtval        ← 附加信息
特权级        ← M
pc           ← mtvec 的 BASE（模式 1 且是中断时再加 4 × 编号）
```

执行 mret 时（QEMU `target/riscv/tcg/op_helper.c` 的 helper_mret）：

```
mstatus.MIE  ← mstatus.MPIE
mstatus.MPIE ← 1
特权级        ← mstatus.MPP
mstatus.MPP  ← U（没有实现 U 时为 M）
pc           ← mepc
```

- x1–x31、f 寄存器、v 寄存器一个都不动。保存和恢复它们全靠软件，也就是 03 第 8 节里编译器为
  中断处理函数生成的那些存取。
- 进入 trap 时 MIE 被清 0，处理函数又运行在 M 级，按第 4 节，它执行期间不会被 M 级中断再次打断；
  mret 把 MIE 恢复成进入前的值。

## 6. 编译器和 CSR

- 编译器不把 CSR 当作可分配的寄存器。C 代码读写 CSR 只能用内联汇编，例如 `ex/csr.c` 的写法；
  LLVM 认得 `mstatus` 这些名字，是因为 `RISCVSystemOperands.td` 里有名字到地址的表。
- 被 LLVM 建模成寄存器的只有会被普通指令隐式读写的几个状态：FRM、FFLAGS（04 第 3 节），
  VL、VTYPE、VXRM、VXSAT（05 第 5 节）。它们都在保留集里。

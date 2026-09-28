# 02 整数寄存器 x0–x31

## 1. x0

x0 读出恒为 0，写进去的值被丢掉。有了它，很多操作不需要专门的指令，一条普通指令配上 x0 就能表示。
实验 `ex/x0.c`（`-march=rv32im`，`-mllvm -riscv-no-aliases`）：

```
写法               真实指令
li   a0, 0         addi  a0, zero, 0
ret                jalr  zero, 0(ra)
csrr a0, mcause    csrrs a0, mcause, zero
csrw mtvec, a0     csrrw zero, mtvec, a0
```

- jalr 把下一条指令的地址写进 rd，然后跳到 rs1 + 偏移。rd 写 x0，就是只跳转、不留返回地址，这就是 ret。
- 同一类的还有下面几条，用 llvm-mc（LLVM 的独立汇编器）加 `-M no-aliases` 在 21.1.8 上核对过：
  ```
  mv   a0, a1      addi a0, a1, 0
  nop              addi zero, zero, 0
  j    L           jal  zero, L
  beqz a0, L       beq  a0, zero, L
  neg  a0, a1      sub  a0, zero, a1
  ```

x0 在 CSR 指令里多一层意思。按 QEMU v11.1.1 `target/riscv/tcg/insn_trans/trans_rvi.c.inc` 的
trans_csrrw、trans_csrrs、trans_csrrc：

- csrrs、csrrc 的 rs1 是 x0 时，指令不写 CSR。所以用 csrr 读一个只读 CSR 不会触发异常。
- csrrw 的 rd 是 x0 时，指令不读 CSR。有些 CSR 读一次就有副作用，csrw 因此不会误触发。
- 判断的依据是寄存器编号是不是 0，不看寄存器里的值。把 rs1 换成恰好装着 0 的 a5，csrrs 仍然算一次写。

向量指令 vsetvli 里 x0 另有含义，见 05。

## 2. psABI 规定的名字和分工

```
x0        zero     恒为 0
x1        ra       返回地址          调用者保存
x2        sp       栈指针            被调用者保存
x3        gp       全局指针          不参与分配
x4        tp       线程指针          不参与分配
x5–x7     t0–t2    临时              调用者保存
x8        s0/fp    保存 / 帧指针     被调用者保存
x9        s1       保存              被调用者保存
x10–x11   a0–a1    参数 / 返回值     调用者保存
x12–x17   a2–a7    参数              调用者保存
x18–x27   s2–s11   保存              被调用者保存
x28–x31   t3–t6    临时              调用者保存
```

- 名字取自 LLVM 的寄存器定义：`RISCV/RISCVRegisterInfo.td:94` 起，每个寄存器定义的第三个参数
  就是 ABI 名字，例如 `def X8_H : RISCVReg<8, "x8", ["s0", "fp"]>`。
- 保存责任取自 LLVM 的被调用者保存列表（`RISCV/RISCVCallingConv.td:16–19`），与上面一致，
  只有 ra 例外，见 03 第 3 节。
- 编号看起来零散：s0、s1 在 x8–x9，s2 却跳到 x18。排在 x8–x15 这一段的，正好是 s0、s1 和
  a0–a5；压缩指令里 3 位的寄存器字段能表示的，就是这 8 个（第 4 节）。
- E 扩展只保留 x0–x15。这 16 个里 zero、ra、sp、gp、tp、t0–t2、s0–s1、a0–a5 每一类都有，
  ilp32e 就定义在这 16 个上（03 第 4 节）。

## 3. 硬件区别对待的地方

除了 x0，基础指令集里 x1–x31 在编码上完全对称，任何指令的 rd、rs1、rs2 字段都能写任何一个。
区别只出现在下面几处。

- 返回地址栈的提示。有些处理器用一个小的硬件栈预测函数的返回地址：jal、jalr 的 rd 是 x1 或 x5 时
  往里压，jalr 的 rs1 是 x1 或 x5 时往外弹。所以返回地址只放在 ra（x1）或 t0（x5）。
  LLVM 为此不让普通的间接跳转用这两个寄存器：`RISCV/RISCVRegisterInfo.td:278` 的注释写明了原因，
  下面 :282 的 GPRJALR 类去掉了 x0–x5。`-msave-restore` 把 t0 当第二个链接寄存器用（03 第 2 节）。
- 压缩指令的隐含寄存器。c.lwsp、c.swsp、c.addi16sp、c.addi4spn 的基址固定是 sp，
  指令里不占寄存器字段。c.jal 固定写 ra，而且只在 RV32 上有（`RISCV/RISCVInstrInfoC.td:419–420`）。
- 压缩指令的 3 位寄存器字段，见第 4 节。

## 4. 压缩指令为什么偏向 x8–x15

C 扩展把常用指令编成 16 位。16 位里放不下三个 5 位的寄存器字段，于是压缩指令分两种：

- 用 5 位字段，任何寄存器都行：c.add、c.mv、c.addi、c.li、c.slli、c.lwsp、c.swsp 等。
  代价是操作数少：c.add、c.addi、c.slli 的目的寄存器必须同时是第一个源寄存器。
- 用 3 位字段，只能是 x8–x15：c.lw、c.sw、c.addi4spn、c.srli、c.srai、c.andi、c.sub、c.xor、
  c.or、c.and、c.beqz、c.bnez。

LLVM 里 3 位字段对应寄存器类 GPRC（`RISCV/RISCVRegisterInfo.td:286`），只含 x10–x15 和 x8–x9。
上面那些指令的操作数都声明成 GPRC，例如 `RISCV/RISCVInstrInfoC.td:318` 的 c.lw、:361 的 c.sw、
:463 的 c.andi。

压缩发生在寄存器分好之后。`RISCV/RISCVAsmPrinter.cpp:261` 的 EmitToStreamer 在输出每条指令前调用
`RISCVRVC::compress`，查有没有等价的 16 位形式；这张对照表就是 `RISCVInstrInfoC.td` 后半部分的
CompressPat，例如 :862 把「两个操作数都在 GPRC 里、偏移满足条件的 LW」对应到 C_LW。
所以寄存器分配选了哪个寄存器，直接决定这条指令能不能压缩。

实验 `ex/rvc.c`，同样是取 `p[1]`，把指针固定在不同寄存器里：

```
指针在        生成                                            字节
a0 (x10)     c.lw a0,4(a0) ; c.jr ra                          4
t0 (x5)      c.mv t0,a0 ; lw a0,4(t0) ; c.jr ra               8
s2 (x18)     c.addi sp,-16 ; c.swsp s2,12(sp) ; c.mv s2,a0
             lw a0,4(s2) ; c.lwsp s2,12(sp) ; c.addi sp,16
             c.jr ra                                          16
```

- t0、s2 不在 x8–x15，lw 只能用 4 字节的形式。
- s2 还是被调用者保存寄存器，用了就要存取，又多出 4 条。

## 5. LLVM 的分配顺序

- `RISCV/RISCVRegisterInfo.td:246–253`：GPR 类里寄存器的排列顺序，就是分配时尝试的顺序：
  a0–a7、t0–t2、t3–t6、s0–s1、s2–s11，最后是 zero、ra、sp、gp、tp。:246 的注释写的是
  「caller-save, callee-save, specials」。
  - 调用者保存的排在前面：值不跨过函数调用时，用它们不产生序言和尾声（`ex/save.c` 的 leaf）。
  - 被调用者保存的排在后面：用了就要存取。值要跨过调用时，调用者保存寄存器会被调用破坏，
    分配器只能选它们，或者把值存到栈上（`ex/save.c` 的 keep）。
  - zero、sp、gp、tp 在保留集里，不会被分配（第 6 节）。ra 可以分配，但它在 LLVM 的被调用者
    保存列表里，用了就要存（03 第 3 节）。
- 偏向 x8–x15。`RISCV/RISCVRegisterInfo.td:88` 的注释和其后的定义：x1–x7、x16–x31 这些不在
  GPRC 里的寄存器带 `CostPerUse = [0, 1]`，意思是有两套代价表，第二套里每用一次这些寄存器代价加 1。
  `RISCV/RISCVRegisterInfo.cpp:891` 的 getRegisterCostTableIndex 决定用哪一套：
  - 21.1.8：只要有 Zca 就用第二套。`-mllvm -riscv-disable-cost-per-use` 可以关掉（:32 的 `cl::opt`）。
  - 23.1.0 的同一个函数多了一个条件：函数要带 optsize 属性，即 `-Os` 或 `-Oz` 编译。
  - 效果是分配器在其他条件相同时，优先选 x8–x15。

## 6. 保留集

`RISCV/RISCVRegisterInfo.cpp:123` 的 getReservedRegs 返回寄存器分配不能碰的寄存器：

- x0：在 `.td` 里标了 `isConstant`（`RISCVRegisterInfo.td:97`），:134 把这类寄存器统一保留。
- sp、gp、tp：总是保留（:139–141）。
- s0：函数需要帧指针时保留（:143），见 03 第 5 节。
- s1：函数既要把栈重新对齐、又有运行时才知道大小的栈对象时，保留作 base pointer（:147；
  `RISCV/MCTargetDesc/RISCVBaseInfo.cpp:129` 的 getBPReg 返回 X9）。
- E 扩展下的 x16–x31（:154）。
- 用户要求保留的寄存器（:130）。
- 还有 vl、vtype、frm、fflags 这些不属于通用寄存器的状态（:159 起），见 04、05。

## 7. 书

Colombet《LLVM Code Generation》：

- p.340 起「Describing registers」（第 11 章）：寄存器和寄存器类在 TableGen 里怎么写。
- p.474：保留寄存器怎样经 getReservedRegs 冻结，寄存器分配因此不用它们。
- p.518：分配顺序由寄存器类的定义决定，以及可以通过哪些钩子调整。

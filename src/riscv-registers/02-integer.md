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

除了 x0，基础指令集里 x1–x31 在编码上完全对称：32 位指令的 rd（写哪个寄存器）、rs1、rs2
（读哪个寄存器）各占 5 位，能写 0–31 中任何一个编号。把 `add a0, a1, a2` 的 a0 换成 s5，
硬件执行起来没有区别。区别只在三处：

- x1、x5 是链接寄存器（3.1）；
- 有些压缩指令把 sp、ra、x0 写死在操作码里（3.2）；
- 压缩指令的 3 位寄存器字段（第 4 节）。

本节引用的 RISC-V 规范按 riscv-isa-manual 的 20250508 标签，`rv32.adoc`、`c-st-ext.adoc`
指它 `src/` 下的两个文件。

### 3.1 链接寄存器 x1、x5

先定义要用到的几个词。

- jal 和 jalr：
  ```
  jal  rd, 偏移         rd ← pc+4 ；pc ← pc+偏移
  jalr rd, 偏移(rs1)    rd ← pc+4 ；pc ← rs1+偏移
  ```
  RISC-V 没有专门的调用、返回指令。`call f` 是 `jal ra, f` 或 auipc 加 `jalr ra`，`ret` 是
  `jalr zero, 0(ra)`，调用函数指针是 `jalr ra, 0(指针)`。
- 分支预测：处理器取指走在执行前面，一条跳转的目标还没算出来，后面的指令已经在取了。
  jalr 的目标在寄存器里，取指时只能猜；猜错了，取进来的指令作废，损失若干周期。
- 返回地址栈（return-address stack，RAS）：预测器里一个小的硬件栈。遇到调用，把返回地址压进去；
  遇到返回，弹出栈顶当作预测的目标。
- hint：写在编码里给硬件的提示，只影响性能，不改变执行结果。

调用和返回用的都是 jal、jalr，处理器只能看寄存器编号来分辨。规范把 x1（ra）和 x5（t0）叫作
链接寄存器，规定 RAS 这样动（`rv32.adoc:518` 起的正文和 :526 的表）：

```
jal   rd 是链接寄存器                压
jalr  rd 是，rs1 不是                压          jalr ra, 0(a0)     调用函数指针
jalr  rd 不是，rs1 是                弹          jalr zero, 0(ra)   ret
jalr  rd、rs1 都是，编号不同          先弹再压    规范说是给协程切换用的（:551）
jalr  rd、rs1 都是，编号相同          压          jalr ra, 0(ra)     call 展开成 auipc ra 加这条
jalr  rd、rs1 都不是                 不动        jalr zero, 0(a5)   普通间接跳转
```

这些规则不影响执行结果，没有 RAS 的处理器不看它们。但它们要求编译器不把跳转目标放在 ra、t0 里：

- 调用函数指针写成 `jalr ra, 0(t0)`：rd、rs1 都是链接寄存器且编号不同，先弹再压。弹掉的是
  当前函数自己的返回地址，等它 ret 时栈顶已经不对。
- 间接尾调用写成 `jalr zero, 0(t0)`：被当成返回，拿栈顶当预测目标，真正的目标却是函数指针；
  栈还少了一项，后面的返回跟着错位。

编号相同那一行只压不弹，普通的 `call f` 就靠它：目标文件里 `call f` 是 `auipc ra, …` 加
`jalr ra, …(ra)`，rd、rs1 都是 ra。规范说这样定是为了让这一对指令能合并成一条执行（macro-op fusion，`rv32.adoc:553`）。

LLVM 用寄存器类落实这一点。寄存器类是一个操作数允许使用的寄存器集合，分配器只在里面挑；
值如果待在集合外的寄存器里，就插一条拷贝挪进来。

- 间接调用 PseudoCALLIndirect（`RISCV/RISCVInstrInfo.td:1793`）和间接跳转 PseudoBRIND
  （:1734，switch 编成跳转表时用它）的操作数类是 GPRJALR（`RISCV/RISCVRegisterInfo.td:282`），
  即 GPR 去掉 x0–x5。:278 的注释说明，去掉 x1、x5 是因为返回地址栈；x0、x2、x3、x4 本来就在
  保留集里（第 6 节），一起去掉只是让 TableGen 少生成几个寄存器类。
- 间接尾调用 PseudoTAILIndirect（`RISCVInstrInfo.td:1822`）的操作数类是 GPRTC
  （`RISCVRegisterInfo.td:293`），只有 x6–x7、x10–x17、x28–x31：去掉了 x5，也去掉了全部被调用者
  保存寄存器。:288 的注释说明后者的原因：尾声先把它们恢复成旧值再跳，地址放在里面会被覆盖。

实验 `ex/jalr.c`（`-march=rv32im -Os`），把函数指针固定在不同寄存器里，摘出和跳转有关的几条：

```
指针固定在   调用函数指针
t1          addi t1,a0,0 ; jalr ra,0(t1)
t0          addi t0,a0,0 ; addi a0,t0,0 ; jalr ra,0(a0)             多挪一次

指针固定在   间接尾调用
t1          addi t1,a0,0 ; jalr zero,0(t1)
t0          addi t0,a0,0 ; addi t1,t0,0 ; jalr zero,0(t1)           多挪一次
s2          addi s2,a0,0 ; addi t1,s2,0 ; lw s2,12(sp) ; … ; jalr zero,0(t1)
```

- 每行第一条 addi 来自把指针固定到该寄存器的写法本身。
- s2 那行：地址先挪进 t1，再恢复 s2，最后用 t1 跳。
- 这个限制只在编译器里。手写 `jalr ra, 0(t0)` 照样能汇编（`ex/rvc-fixed.S` 最后一行）。

x5 做第二个链接寄存器，规范在 JAL 一节的注释里说明了用处：调用保存、恢复寄存器的小段库代码
（规范叫 millicode）时，不必动 ra；选 x5，是因为它在标准调用约定里是临时寄存器，编码又和 x1
只差一位（`rv32.adoc:443` 起）。`-msave-restore`（03 第 2 节）就是这样用的：

- `call t0, __riscv_save_1` 在目标文件里是 `auipc t0, …` 加 `jalr t0, …(t0)`，rd、rs1 是同一个
  链接寄存器，按上表是压。此刻 ra 里是函数自己的返回地址，不能覆盖。
- llvmorg-21.1.8 的 `compiler-rt/lib/builtins/riscv/save.S` 里，RV32 的 `__riscv_save_1` 以
  `jr t0` 结尾（:95），即 `jalr zero, 0(t0)`，是弹。一压一弹正好配对。

### 3.2 压缩指令写死的寄存器

C 扩展把常用指令编成 16 位，16 位里放不下三个 5 位字段。规范 C 扩展一章的概述列出了能压缩的
情形（`c-st-ext.adoc:14` 起）：

- 立即数或偏移小；
- 某个寄存器是 x0、ra 或 sp；
- 目的寄存器就是第一个源寄存器；
- 用的是最常用的 8 个寄存器，即 x8–x15（第 4 节）。

第二种情形的做法是寄存器不占字段，由操作码决定，省下的位给立即数和另一个寄存器：

- 基址写死是 sp：c.lwsp、c.swsp，以及 c.addi16sp（sp 加一个 16 的倍数）、c.addi4spn
  （sp 加一个立即数，结果写进 x8–x15 之一）。单独给 sp 一套访存指令，规范给的理由是在栈上
  存取太常见（`c-st-ext.adoc:175` 起）。
- 目的寄存器写死是 ra：c.jal、c.jalr。
- 目的寄存器写死是 x0：c.j、c.jr。

实验 `ex/rvc-fixed.S`：一组 32 位写法交给汇编器，开 C 扩展，看各自压成什么。

```
写法                压成                    字节
lw   a0, 4(sp)      c.lwsp a0, 4(sp)       2     基址写死是 sp，数据寄存器是 5 位字段
lw   t1, 4(sp)      c.lwsp t1, 4(sp)       2
lw   a0, 4(a1)      c.lw   a0, 4(a1)       2     基址不是 sp，两个 3 位字段
lw   a0, 4(t1)      lw                     4
addi a0, sp, 8      c.addi4spn a0, sp, 8   2
addi t1, sp, 8      addi                   4     c.addi4spn 的目的寄存器是 3 位字段
addi sp, sp, -64    c.addi16sp sp, -64     2
addi a0, a0, -64    addi                   4     普通 c.addi 的立即数只有 -32…31
jal  ra, L          c.jal L                2
jal  t0, L          jal t0, L              4
jal  zero, L        c.j L                  2
jalr ra, 0(t0)      c.jalr t0              2
```

- 16 位的调用只有 c.jal、c.jalr，目的寄存器都是 ra，所以 `call t0, …` 压不成 2 字节。
- c.jal 只在 RV32 上有，RV64 上同一组编码是 c.addiw（`c-st-ext.adoc:479`、:576）。LLVM 里
  `RISCV/RISCVInstrInfoC.td:420` 的 C_JAL 和 :425 的 C_ADDIW 操作码都是 `0b001, 0b01`，C_JAL
  带 IsRV32 条件（:419）。实验 cell 2 按 RV64 汇编，`jal ra, L` 是 4 字节。
- LLVM 里写死的寄存器出现在两处。一是操作数的寄存器类只含一个寄存器，例如 C_ADDI16SP 的操作数
  类 SP（`RISCVInstrInfoC.td:438`）只有 X2。二是压缩对照表 CompressPat 直接写寄存器名：
  ```
  (JAL X1, …)          → C_JAL        :912，只在 IsRV32 下
  (JAL X0, …)          → C_J          :967
  (JALR X0, rs1, 0)    → C_JR         :1012
  (JALR X1, rs1, 0)    → C_JALR       :1024
  (ADDI X2, X2, …)     → C_ADDI16SP   :924
  ```

### 3.3 三处对寄存器分配的影响

- 链接寄存器：硬限制。GPRJALR、GPRTC 里没有 ra、t0，分配器不会选它们，需要时插拷贝。
- 写死的 sp、ra、x0：分配器不用做什么。sp 在保留集里，栈访问本来就用 sp；调用本来就写 ra。
  序言、尾声里的存取因此几乎都能压成 c.swsp、c.lwsp，各实验里的 `c.swsp ra, 12(sp)` 都是这样来的。
- 3 位字段：没有硬限制，只是用了 x8–x15 以外的寄存器，那条指令就压不了。LLVM 用代价让分配器
  偏向 x8–x15（第 5 节）。

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

# 04 分支与跳转

## 1. 比较：没有标志位

x86、Arm 这类指令集有一组标志位（进位、零、负数等），比较指令设置它们，分支指令读它们。RISC-V
没有标志位，比较的结果只有两个去处：写进一个通用寄存器，或者直接决定一次分支。

实验 `ex/cmp.c`（`-march=rv32im -Os`）：

```
C                                  生成
return a < b;      (int)           slt   a0, a0, a1
return a < b;      (unsigned)      sltu  a0, a0, a1
return a == b;                     xor   a0, a0, a1 ; sltiu a0, a0, 1
if (a < b) g();                    bge   a0, a1, 跳过 ; tail g
if (a > b) g();                    bge   a1, a0, 跳过 ; tail g
if (a < b) g();    (unsigned)      bgeu  a0, a1, 跳过 ; tail g
```

- slt、sltu：rs1 < rs2 时 rd 写 1，否则写 0，分有符号、无符号两条（`rv32.adoc:380` 起）。
- 没有「相等则置 1」的指令。先 xor，相等时结果为 0；再 `sltiu rd, rs, 1`，即 rs < 1 无符号，只有 rs 为
  0 时成立。汇编器把后者叫伪指令 seqz（`rv32.adoc:314` 起）。
- 条件分支自己比较两个寄存器，条件成立就跳（`rv32.adoc:570` 起）。一共六条：beq、bne、blt、bge、
  bltu、bgeu。
- 没有 bgt、ble、bgtu、bleu，把两个操作数对调就能表示（`rv32.adoc:575–576`）：a > b 等价于 b < a。
  汇编器接受 `bgt a0, a1, L`，汇编成 `blt a1, a0, L`。
- if 的条件成立时要执行调用，所以编译器用相反的条件跳过调用：a < b 的反面是 a >= b，即 bge。
  a > b 的反面是 a <= b，即 b >= a，写成 `bge a1, a0`，两个操作数对调。
- `rv32.adoc:599` 起的注释说明了这样设计的理由：比较和跳转合成一条指令，放得进普通的流水线，
  不需要额外的标志位状态，也不用占一个临时寄存器，代码更短。

## 2. 三种跳转和它们的范围

```
指令           做什么                                      范围                    格式
beq 等         条件成立时 pc ← pc + 偏移                   -4096…+4094             B
jal rd, L      rd ← pc+4 ；pc ← pc + 偏移                  -1 MiB…+1 MiB-2         J
jalr rd, i(rs) rd ← pc+4 ；pc ← (rs + i)，最低位清 0        rs 可以是任何地址       I
```

- 偏移都相对这条指令自己的地址，且是 2 的倍数（01 第 5 节）。范围见 psABI:652–656，也见
  `rv32.adoc:558` 起（条件分支 ±4 KiB）和 :431 起（jal ±1 MiB）。
- jalr 的目标由寄存器给出，距离不受限制（`rv32.adoc:458` 起）。
- auipc 加 jalr 可以跳到相对 pc ±2 GiB 的任何地方（`rv32.adoc:483`）：auipc 装 D 的高 20 位，jalr 补低
  12 位，算法同 03 第 4 节。
- 伪指令：`j L` 是 `jal zero, L`；`ret` 是 `jalr zero, 0(ra)`；`call`、`tail`、`jump` 展开成 auipc 加 jalr（第 4 节）。
- rd、rs1 写哪个寄存器，还关系到处理器的返回地址预测，见 06。

## 3. 距离不够时谁来补

一个 if 要跳过的代码可能很长，超出 beq 的 ±4 KiB。补救在三个地方发生，做法相同：条件分支换成
相反条件的短分支，跳过一条更远的跳转。

```
距离                      写法
±4 KiB 以内               beq a0, a1, L
±1 MiB 以内               bne a0, a1, 1f ; jal zero, L ; 1:
更远                      bne a0, a1, 1f ; auipc t, …  ; jalr zero, …(t) ; 1:
```

最后一种要占用一个寄存器 t 暂存地址。

### 编译器

实验 `ex/far.c`：`if (a != b) asm volatile(".space N");`，N 是要跳过的字节数。

- `.space N` 是汇编指示，塞 N 字节的 0。编译器估算内联汇编的长度时专门认它：
  `llvm/lib/CodeGen/TargetInstrInfo.cpp:109` 起的注释说，这是为了在测试里造出任意长的代码。

```
N = 16         beq a0, a1, .LBB0_2
N = 8192       bne a0, a1, .LBB1_1 ; jal zero, .LBB1_2
N = 1048576    bne a0, a1, .LBB2_1 ; jump .LBB2_2, a0
```

- 做这件事的是 BranchRelaxation 这个 pass（pass 是编译器后端里依次执行的一个处理步骤），在
  `llvm/lib/CodeGen/BranchRelaxation.cpp`。RISC-V 在 `RISCV/RISCVTargetMachine.cpp:578` 把它加进流水线，
  位置在输出机器码之前（:563 的 addPreEmitPass）。这时寄存器已经分好，每条指令的长度可以估算出来。
- 它逐个检查分支，问目标「这个偏移放得下吗」：`RISCV/RISCVInstrInfo.cpp:1600` 的
  isBranchOffsetInRange，beq 这类是 13 位，jal 是 21 位，jump 是 32 位。
- 放不下 21 位时，:1294 的 insertIndirectBranch 插入 `jump 目标, 寄存器`（伪指令 PseudoJump）。
  - 暂存用的寄存器由 RegScavenger 找（:1327）。RegScavenger 是寄存器分配之后找一个此刻没被占用的
    物理寄存器的工具。far_ 里找到的是比较完就不再用的 a0。
  - 找不到空闲寄存器时，借用 s11（RVE 下是 s1）：跳转前把它存到栈上，跳转目标处插一个块把它取回，
    jump 先跳到这个块（:1336 起）。
  - 为此，函数估计长度超出 20 位有符号数时，序言里预留一个栈槽（`RISCV/RISCVFrameLowering.cpp:1748`
    起）。far_ 开头多出的 `addi sp, sp, -16` 就是这个栈槽，这里没用上。
- `-mno-relax` 反汇编 far_ 的 jump：auipc 在 0x202c，目标在 0x102034，D = 0x100008，得到
  `auipc a0, 0x100 ; jalr zero, 0x8(a0)`。

### 汇编器

实验 `ex/far.s`：手写一条 beq，跳过 N 字节。

```
N = 16         beq a0, a1, L
N = 8192       bne a0, a1, 0x8 ; jal zero, L
N = 1048576    error: fixup value out of range
```

- 汇编器发现分支的偏移超出 -4096…+4094（`RISCV/MCTargetDesc/RISCVAsmBackend.cpp:107` 的
  fixupNeedsRelaxationAdvanced），就把 beq 换成 PseudoLongBEQ（:186–187），编码时展开成相反条件的
  分支加 jal（`RISCV/MCTargetDesc/RISCVMCCodeEmitter.cpp:289` 起的 expandLongCondBr）。
- jal 也够不着时报错（`RISCVAsmBackend.cpp:503–504`）。汇编器不会再换成 auipc 加 jalr：那要一个
  空闲寄存器，而汇编器不知道哪个寄存器此刻没在用。编译器知道，所以第三种写法只有编译器会生成。

### 链接器

链接器做的是反方向的事：call、tail 一开始就写成能跳 ±2 GiB 的 auipc 加 jalr，链接时目标够近就改短，
见下一节。

## 4. call、tail 与链接器松弛

实验 `ex/call.s`：

```
f:  call g
    tail g
g:  ret
```

目标文件里（`-mrelax`）：

```
call g    auipc ra, 0 ; jalr ra, 0(ra)       R_RISCV_CALL_PLT g，R_RISCV_RELAX
tail g    auipc t1, 0 ; jalr zero, 0(t1)     R_RISCV_CALL_PLT g，R_RISCV_RELAX
```

- 编译时不知道 g 离多远，所以 call、tail 一律先写成能跳 ±2 GiB 的 auipc 加 jalr，共 8 字节。汇编器
  编码时展开这些伪指令（`RISCV/MCTargetDesc/RISCVMCCodeEmitter.cpp:145` 起的 expandFunctionCall，
  far.c 里的 jump 也在这里展开）。
- tail 用 t1 暂存地址，不能用 ra：g 返回时要直接回到 f 的调用者，ra 里必须还是那个地址。开 Zicfilp
  扩展时改用 t2（`RISCV/MCTargetDesc/RISCVBaseInfo.h:210` 起）。
- 每对 auipc、jalr 只有一条 R_RISCV_CALL_PLT，挂在 auipc 上，覆盖两条指令。旁边的 R_RISCV_RELAX
  表示允许链接器改写这一对。
- 链接器不改写时，按 03 第 4 节的办法填：以 auipc 的地址算一次 D，高位写进 auipc，同一个 D 的低位
  写进后面 4 字节处的 jalr（`lld/ELF/Arch/RISCV.cpp:410` 起）。

链接之后（`just link`）：

```
-march=rv32i      jal ra, g          jal zero, g         各 4 字节
-march=rv32ic     c.jal g            c.j g               各 2 字节
```

- 链接器松弛：链接时知道了 g 的地址，发现 jal 够得着，就把 8 字节的一对换成 4 字节的 jal，后面的
  代码跟着前移。开 C 扩展、距离在 ±2 KiB 以内时换成 2 字节的 c.jal、c.j
  （`lld/ELF/Arch/RISCV.cpp:732` 起的 relaxCall，c.jal 只在 RV32 上有）。
- 用 `-mno-relax` 编译时没有 R_RISCV_RELAX，链接器不改短，只按 D 填立即数（`ex/call.s` cell 5）：
  call 的 auipc 在 0，g 在 0x10，jalr 的立即数是 0x10；tail 的 auipc 在 8，立即数是 8。

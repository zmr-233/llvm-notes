# 03 访存与取地址

## 1. 访存指令只有一种寻址方式

- 读：`lw rd, imm(rs1)`，从地址 rs1 + imm 读 4 字节放进 rd。
- 写：`sw rs2, imm(rs1)`，把 rs2 写到地址 rs1 + imm。
- 地址一律是「一个寄存器加一个 12 位有符号偏移」，读是 I 型，写是 S 型（`rv32.adoc:706` 起）。
  没有「绝对地址」「寄存器加寄存器」之类的其他寻址方式。
- 宽度（`rv32.adoc:712` 起）：
  ```
  lw / sw     4 字节
  lh / sh     2 字节，lh 读进来后符号扩展
  lhu         2 字节，读进来后零扩展
  lb / sb     1 字节，lb 符号扩展
  lbu         1 字节，零扩展
  ```
  写没有「有无符号」之分，sh、sb 只写 rs2 的低 2、1 字节。RV64 另有 8 字节的 ld、sd 和零扩展的 lwu。
- 实验 `ex/global.c` 的 get_sc、get_uc：读 `signed char` 用 lb，读 `unsigned char` 用 lbu，
  C 的类型决定了用哪一条。

所以要访问一个地址任意的全局变量，得先把地址的大部分装进一个寄存器，剩下的低 12 位交给访存指令
的偏移。这正是 02 第 2 节那种「高 20 位加低 12 位」的拆法。拆的时候以什么为基准，有两种做法。

## 2. 前提词

- 重定位（relocation）：目标文件里的一条记录，意思是「这个位置的这几位，等链接时知道了某个符号的
  地址，按某种规则算出来填进去」。编译一个 .c 文件时，全局变量的最终地址还不知道，指令里先填 0，
  由重定位交给链接器。01 第 6 节的 fixup 在汇编器里，重定位是它留到目标文件里的那一部分。
- `%hi(sym)`、`%lo(sym)` 这类写法：汇编里的运算符，表示「sym 的地址按某种规则取出的一部分」。
  汇编器看到它，就在这个位置记一条对应类型的重定位。
- 代码模型（code model）：约定用哪种指令序列算出符号的地址，因而决定了代码和数据能放在多大的地址
  范围里（psABI:7 起）。clang 用 `-mcmodel=` 选。`--target=riscv32-unknown-elf` 不加这个选项时，
  实验里生成的是 medlow 的写法。

## 3. 两种代码模型

实验 `ex/global.c`，`int g; int get(void) { return g; }` 等几个函数：

```
-mcmodel=medlow                            -mcmodel=medany
get:   lui a0, %hi(g)                      get:   .Lpcrel_hi0:
       lw  a0, %lo(g)(a0)                         auipc a0, %pcrel_hi(g)
                                                  lw    a0, %pcrel_lo(.Lpcrel_hi0)(a0)
addr:  lui  a0, %hi(g)                     addr:  .Lpcrel_hi2:
       addi a0, a0, %lo(g)                        auipc a0, %pcrel_hi(g)
                                                  addi  a0, a0, %pcrel_lo(.Lpcrel_hi2)
```

medlow（psABI:21 起）：

- 按绝对地址拆：`%hi(g)`、`%lo(g)` 就是 g 的地址按 02 第 2 节拆出的 Hi20、Lo12（psABI:543–544）。
- 对应的重定位是 R_RISCV_HI20 和 R_RISCV_LO12_I（读、算地址）或 R_RISCV_LO12_S（写）。
- lui 加一个 12 位偏移能表示的地址就是它能访问的范围：RV32 上是整个地址空间；RV64 上是最低 2 GiB
  和最高 2 GiB（psABI:23–25）。

medany（psABI:62 起）：

- `auipc rd, imm` 把 auipc 这条指令自己的地址加上 imm << 12，写进 rd（`rv32.adoc:342` 起）。
  除了 jal、jalr 把 pc+4 写进 rd，它是唯一能把 pc 的值写进通用寄存器的指令。
- 按「g 的地址减去 auipc 的地址」这个差拆。能访问的是代码附近 ±2 GiB（psABI:64–65）。
- 只要代码和数据之间的相对距离不变，整段程序搬到哪个地址都能正确运行。
- 对应的重定位是 R_RISCV_PCREL_HI20 和 R_RISCV_PCREL_LO12_I / R_RISCV_PCREL_LO12_S。
- 第二条指令的 `%pcrel_lo` 括号里写的是 auipc 前面的标签 `.Lpcrel_hiN`，不是 g，下一节讲原因。

## 4. %pcrel_lo 的括号里为什么是标签

### 算式

设 auipc 的地址是 P，目标的地址是 S。以用 jalr 跳过去为例：

```
1: auipc t0, Hi20         t0 ← P + (Hi20 << 12)
   jalr  x0, Lo12(t0)     pc ← t0 + Lo12
```

要跳到 S，只需 `(Hi20 << 12) + Lo12 = S - P`。记 D = S - P，两个立即数都从 D 拆出来，拆法和 02 第 2 节
一样：

```
Hi20 = (D + 0x800) >> 12
Lo12 = D - (Hi20 << 12)          范围 -2048…2047
```

- 第二条指令（jalr、lw、sw、addi 都一样）算的是「寄存器加立即数」，不读 pc。它自己的地址不出现在
  任何一个式子里。
- `%pcrel_lo` 名字里的「pcrel」，指的是相对 auipc 的 pc，不是相对第二条指令的 pc。
- psABI:686–687 写的就是这两个式子，其中的 `hi20_reloc_offset` 是 auipc 的地址。

### 括号里的标签

第二条指令要填 Lo12，需要知道 S 和 P，而它自己两样都不知道：

- S 记在 auipc 的 `%pcrel_hi(S)` 上；
- P 就是 auipc 的地址。

所以 `%pcrel_lo` 的括号里写 auipc 的标签：顺着它找到 auipc，从 auipc 上拿 S，auipc 所在的地址就是 P。

psABI:673 起把这写成了规定：

```
auipc 处   R_RISCV_PCREL_HI20     → 目标符号
第二条处   R_RISCV_PCREL_LO12_I   → auipc 的标签
```

链接器从 LO12 找到标签，在标签处找到 HI20，用 HI20 的符号算 D。

为什么不让第二条指令直接写目标符号：

- Lo12 必须和 Hi20 从同一个 D 拆出来，否则 `+0x800` 的进位对不上。
- 第二条指令不一定紧跟在 auipc 后面，一条 auipc 也可以配好几条第二条指令。psABI:692 起的例子里，
  一条 auipc 之后，lw 和 sw 用同一个标签。这几条指令各在不同的地址，只有 P 是共同的。

### 实验

实验 `ex/pcrel.s`：手写 auipc 加 jalr，跳到 1 MiB 之外的 label。auipc 在 4，label 在 0x100c04，
D = 0x100c00，低 12 位 0xc00 不小于 0x800，能看到进位。

```
cell 1  -mno-relax，汇编器直接算       auipc t0, 0x101
                                       jalr  zero, -0x400(t0)
                                       4 + 0x101000 - 0x400 = 0x100c04

cell 2  -mrelax，看重定位              偏移 4：R_RISCV_PCREL_HI20    label
                                       偏移 8：R_RISCV_PCREL_LO12_I  .Ltmp0（即 1:，指向 auipc）

cell 3  -mrelax，交给 ld.lld 链接      和 cell 1 一模一样

cell 4  两条之间插一条 addi            jalr 挪到 0xc，立即数仍是 -0x400
        （ex/pcrel-gap.s）

cell 5  %pcrel_lo(label)               error: could not find corresponding %pcrel_hi
        （ex/pcrel-bad.s）
```

- Hi20 是 0x101 而不是 0x100，Lo12 是 -0x400：这就是进位。
- cell 4 说明第二条指令的地址不参与：它挪了 4 字节，立即数没变。如果按它自己的地址算，立即数会差 4。

### 汇编器、链接器里的对应代码

- 汇编器：`RISCV/MCTargetDesc/RISCVAsmBackend.cpp:656` 的 getPCRelHiFixup 顺着 `%pcrel_lo` 括号里的
  标签，找到标签处那条指令上的 `%pcrel_hi`，找不到就报 cell 5 的错（:716–719）。找到后在 :745–746
  算值：目标符号的偏移减去 auipc 的偏移，也就是 D。
- 链接器：`lld/ELF/InputSection.cpp:663` 起的注释和 :669 的 getRISCVPCRelHi20 做同样的查找；:883–885
  用 HI20 的目标符号求值，求值时的「当前位置」取的是标签的地址，也就是 auipc 的地址。
  `lld/ELF/Arch/RISCV.cpp:433` 起再按 `Lo12 = D - (Hi20 << 12)` 填进第二条指令。

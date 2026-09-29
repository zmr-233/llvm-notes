# 02 装常数

RISC-V 没有「把任意 32 位常数装进寄存器」的单条指令：一条指令只有 32 位，放不下 32 位的常数和
操作码。本篇讲常数怎么拆成几条指令，以及这套拆法为什么要 `+0x800`。第 03 篇的地址也按同样的
规则拆。

## 1. 两条基本指令

- `addi rd, rs1, imm`：rd = rs1 + imm。imm 是 12 位有符号数，范围 -2048…2047，使用前符号扩展
  （`rv32.adoc:304`）。rs1 写 zero 时就是装一个小常数，伪指令 `li a0, 5` 就是 `addi a0, zero, 5`。
- `lui rd, imm`：把 20 位的 imm 放到 rd 的第 31–12 位，低 12 位清零（`rv32.adoc:338` 起）。
  RV64 上这 32 位结果再符号扩展成 64 位，例如 `lui a0, 0x80000` 得到 0xffffffff80000000（psABI:58）。

## 2. 32 位常数：lui 加 addi

实验 `ex/li.c`（`-march=rv32im -Os`）：

```
常数          生成的指令
2047          addi a0, zero, 0x7ff
-2048         addi a0, zero, -0x800
0x12345000    lui  a0, 0x12345
0x12345678    lui  a0, 0x12345 ; addi a0, a0, 0x678
0x12345800    lui  a0, 0x12346 ; addi a0, a0, -0x800
0x12345fff    lui  a0, 0x12346 ; addi a0, a0, -0x1
2048          addi a0, zero, 0x1 ; slli a0, a0, 0xb
```

一个 32 位常数 V 拆成高 20 位 Hi20 和低 12 位 Lo12，要满足 `(Hi20 << 12) + Lo12 = V`，其中 Lo12 是 addi
用的 12 位有符号数：

```
Lo12 = V 的低 12 位，当作 12 位有符号数          范围 -2048…2047
Hi20 = (V + 0x800) >> 12，取低 20 位
```

为什么加 0x800：

- V 的低 12 位小于 0x800 时，它当作有符号数是正的，Hi20 就是 V 的高 20 位。0x12345678 的低 12 位
  是 0x678，Hi20 = 0x12345。
- V 的低 12 位大于等于 0x800 时，它当作有符号数是负的，等于低 12 位减 0x1000。addi 会减掉这
  0x1000，所以 Hi20 要比 V 的高 20 位多 1，补回来。0x12345800 的低 12 位 0x800 当作有符号数是
  -2048，Hi20 = 0x12346，0x12346000 - 0x800 = 0x12345800。
- 先加 0x800 再右移 12 位，正好在第 11 位是 1 时向第 12 位进 1，两种情况一个式子就能算。

同一个式子在工具链里出现了好几次：

- 编译器装常数：`RISCV/MCTargetDesc/RISCVMatInt.cpp:90–91`。
- 汇编器填 `%hi`：`RISCV/MCTargetDesc/RISCVAsmBackend.cpp:500–501`，注释写的是「第 11 位是 1 就加 1，
  补偿低 12 位是负数」。
- 链接器填 R_RISCV_HI20 这类重定位：`lld/ELF/Arch/RISCV.cpp:87` 的 hi20。
- psABI:543–544 写的地址拆法，:686–687 写的相对 pc 的拆法（03）。

## 3. 拆法不止一种

2048 按上面的式子是 `lui a0, 1 ; addi a0, a0, -0x800`，编译器却生成了 `addi a0, zero, 1 ; slli a0, a0, 11`
（先装 1，再左移 11 位）。

- 编译器装常数的入口是 `RISCVMatInt.cpp:257` 的 generateInstSeq。它先按第 2 节的办法得到一个序列，
  再试别的办法，:261 起就是其中一种：常数末尾有 0 时，先装去掉末尾 0 的数，再用 slli 左移回去。
- 新写法条数更少，或者左移前要装的数落在 -32…31 之内（且目标处理器不做 lui、addi 融合），就换成它
  （:267 起的注释）。后一种情况的理由是开 C 扩展时 `addi rd, zero, 小数` 和 `slli` 都能压成 16 位：
  2048 用 c.li 加 c.slli 是 4 字节；lui 加 addi 是 c.lui 加 4 字节的 addi（-0x800 超出 c.addi 的范围），
  共 6 字节。这里没开 C 也这样选，注释说是为了让开不开 C 生成的代码差别小。
- 手写汇编里的 `li` 伪指令也走同一套代码：`RISCV/AsmParser/RISCVAsmParser.cpp:3446` 的 emitLoadImm
  调用 RISCVMatInt。

## 4. RV64：64 位常数与常量池

64 位的常数要分几段装：先用 lui、addi 装出最高的一段，再反复「slli 左移腾出低位，addi 补上 12 位」。
最坏要 8 条（`RISCVMatInt.cpp:112` 起的注释）。

实验 `ex/li64.c`，`long c64(void) { return 0x123456789abcdef0; }`，`-march=rv64im -O2`：

```
默认                                    lui  a0, %hi(.LCPI0_0)
                                        ld   a0, %lo(.LCPI0_0)(a0)
-mllvm -riscv-max-build-ints-cost=8     lui、addi，再 slli、addi 三轮，共 8 条
```

- 常量池：编译器放在只读数据里的常数。`.LCPI0_0` 是存这个 8 字节常数的位置，用 lui 加 ld 读回来，
  和 03 里访问全局变量的写法一样。
- 用指令装还是从常量池读，看条数：`RISCV/RISCVISelLowering.cpp:6589`，序列不超过门限就用指令装。
- 门限由 `RISCV/RISCVSubtarget.cpp:148` 的 getMaxBuildIntsCost 给出：默认是处理器调度模型里访存的
  延迟加 1。那里的注释说，从常量池读要一条算地址、一条访存，而算地址和装常数用的 addi、slli 通常
  一个周期完成。设了 `-riscv-max-build-ints-cost`（:51 声明的 `cl::opt`）就用设的值，但不小于 2。
- 实验没有指定处理器，默认门限小于 8，所以默认走常量池；把门限设成 8，就改用 8 条指令装。
- 超过门限时还有两个分支（`RISCVISelLowering.cpp:6592` 起）：按体积优化时直接用常量池；否则先试
  一种用两个寄存器拼的写法，还不行才用常量池。

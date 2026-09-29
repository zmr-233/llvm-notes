# RISC-V 指令集基础

指令怎么编码、常数怎么装进寄存器、怎么访问内存和全局变量、分支和跳转能跳多远，跳转距离不够时
编译器、汇编器、链接器分别补在哪一步，一次函数调用从 call 到 ret 的全过程，以及处理器怎么预测
返回地址。每个结论要么有 `ex/` 下的实验可以复现，要么注明在哪份文档或源码的哪一行核对过。

寄存器本身（x0–x31 的分工、CSR）和调用约定的各种变化在 [riscv-registers](../riscv-registers/README.md)。
XLEN、扩展、`-march`、`-mabi`、伪指令、链接器松弛这些词在它的
[01-basics.md](../riscv-registers/01-basics.md) 里定义，本专题直接使用。

## 读的顺序

1. [01-encoding.md](01-encoding.md)：指令长度，六种 32 位格式，立即数的各位放在编码的哪里
2. [02-constants.md](02-constants.md)：用 addi、lui 装常数，`+0x800` 的进位，RV64 的长常数与常量池
3. [03-addressing.md](03-addressing.md)：访存指令；全局变量的两种寻址（`%hi`/`%lo` 与
   `%pcrel_hi`/`%pcrel_lo`）；`%pcrel_lo` 的括号里为什么是 auipc 的标签；代码模型
4. [04-control.md](04-control.md)：比较与条件分支；jal、jalr 的范围；距离不够时编译器、汇编器、
   链接器各做什么；call 与 tail
5. [05-calls.md](05-calls.md)：从零讲函数调用。call 与 ret，栈与栈帧，两种保存责任，参数与返回值，
   序言与尾声，叶函数与尾调用
6. [06-ras.md](06-ras.md)：返回地址栈按 jalr 的寄存器编号压、弹；它为什么限制了间接调用、间接尾调用
   能用的寄存器；x5 与 millicode（-msave-restore）；millicode 与微码的区别

## 版本与出处

- 实验输出来自 LLVM 官方发布的 llvmorg-21.1.8 Linux x86-64 预编译包。
- LLVM 源码行号按 llvmorg-21.1.8（提交 2078da43e25a）。文中 `RISCV/` 是 `llvm/lib/Target/RISCV/`
  的简写；其他目录写全路径，如 `lld/ELF/Arch/RISCV.cpp`。
- 指令集规范按 riscv-isa-manual 仓库（github.com/riscv/riscv-isa-manual）的 20250508 标签核对。
  文中 `intro.adoc`、`rv32.adoc` 指它 `src/` 下的这两个文件。
- psABI（RISC-V ELF psABI，规定目标文件格式、重定位、代码模型）按 riscv-elf-psabi-doc 仓库
  （github.com/riscv-non-isa/riscv-elf-psabi-doc）的 v1.0 标签核对。文中 `psABI` 指其中的 `riscv-elf.adoc`；
  05 引用的 `riscv-cc.adoc` 是同一标签下讲调用约定的文件。
- compiler-rt 的 `lib/builtins/riscv/save.S`、`restore.S` 按 llvmorg-21.1.8。
- 06 第 9 节引用的 Linux 文档按 Linux 7.2.3 源码树。
- justfile 在 just 1.58.0 上核对。

## 跑实验

每个实验是 `ex/` 下的一个 C 文件或汇编文件（`.s`）。文件开头的注释按 cell 排：一段说明、一条命令、
这条命令的预期输出、看点。在本目录下复制命令运行，对照输出。C 文件的注释以 `//` 开头，汇编文件
以 `#` 开头（RISC-V 汇编的注释符）。

### 准备 .env

在本目录下新建 `.env`（已写进 `.gitignore`，不入库）。四个键都要写，没有默认值，
缺哪个，用到它的命令就报错退出：

```
CLANG=/path/to/bin/clang
OBJDUMP=/path/to/bin/llvm-objdump
READELF=/path/to/bin/llvm-readelf
LLD=/path/to/bin/ld.lld
```

- `CLANG`：能生成 RISC-V 代码的 clang。上游发布的 clang 默认带 RISC-V 后端。汇编文件也交给它。
- `OBJDUMP`：反汇编用。
- `READELF`：读重定位用。
- `LLD`：`just link` 用。

官方预编译包的 `bin/` 下四个都有。

### just 动词

`just` 读本目录的 `justfile`。四个动词都把中间文件放在 `mktemp -d` 建的临时目录里，命令结束即删。

- `just asm <文件> <编译参数…>`
  运行 `$CLANG --target=riscv32-unknown-elf <编译参数> -S -o - <文件>`，再删掉以 `.` 开头的
  汇编指示行、注释行、空行，以及标签后面 `# @函数名` 这种注释，只留标签和指令。
  - `-S`：只编译到汇编，不生成目标文件。
  - `-o -`：输出到标准输出。
- `just dis <文件> <编译参数…>`
  编译或汇编成目标文件（`-c`），再运行 `$OBJDUMP -d -M no-aliases`，删掉开头几行文件信息。
  - `-d`：反汇编代码段。
  - `-M no-aliases`：按真实指令打印（`jalr zero, 0x0(ra)`），不折回 `ret` 这类伪指令。
  - 每行是「偏移: 编码  指令」。编码是 4 个十六进制位的，是 2 字节的压缩指令；8 个的是 4 字节指令。
  - 一行 `...` 是 objdump 对一长串 0 字节的省略。
- `just reloc <文件> <编译参数…>`
  编译或汇编成目标文件，运行 `$READELF -r --wide`，列出重定位项。
  - `-r`：打印重定位表。
  - `--wide`：长行不截断。
- `just link <文件> <编译参数…>`
  编译或汇编成目标文件，运行 `$LLD --image-base=0 -Ttext=0 -e 0` 链接，再像 `dis` 一样反汇编。
  - `-Ttext=0`：代码段放在地址 0，链接后的地址和目标文件里的偏移一致，方便对照。
  - `--image-base=0`：ld.lld 默认要求段地址不小于映像基址 0x10000，不加这一项，上一项会报错。
  - `-e 0`：入口地址设为 0。实验文件里没有 `_start`，不指定入口 ld.lld 会警告。

### 编译参数

- `--target=riscv32-unknown-elf`：justfile 固定加上。生成 32 位 RISC-V、没有操作系统（裸机）的 ELF 代码。
  `-march` 以 `rv64` 开头时，clang 把它换成 riscv64（`clang/lib/Driver/Driver.cpp:834` 起），
  `ex/li64.c` 就是这样得到 64 位代码的。
- `-march=rv32i`、`rv32im`、`rv32ic`：可用的指令。`i` 是基础整数指令集，`m` 是乘除，`c` 是 16 位压缩指令。
- `-mabi=ilp32`、`lp64`：调用约定，见 riscv-registers 的 01。
- `-Os`、`-O2`：按代码体积、按速度优化。
- `-mcmodel=medlow`、`medany`：代码模型，见 03。
- `-mrelax`、`-mno-relax`：是否允许链接器松弛。关掉时，汇编器能算的立即数自己算好；打开时，
  汇编器把它们留给链接器，并附上可以改写的标记。
- `-mllvm <选项>`：把选项原样交给 LLVM 后端。后端的选项在源码里用 `cl::opt` 声明，这是 LLVM
  自己的命令行选项机制；clang 的命令行不认识这些选项，要经 `-mllvm` 转交。
  - `-mllvm -riscv-no-aliases`：汇编输出按真实指令打印。
  - `-mllvm -riscv-max-build-ints-cost=N`：见 02 第 4 节。
- `-Wa,<参数>`：把逗号后面的参数转交给汇编器。`ex/far.s` 用 `-Wa,--defsym,SPACE=N` 定义汇编符号
  SPACE 的值。

## 实验一览

- `ex/formats.s`：六种指令格式的编码（01）
- `ex/li.c`：32 位常数怎么装（02）
- `ex/li64.c`：RV64 的 64 位常数与常量池（02）
- `ex/global.c`：全局变量的两种寻址，lb 与 lbu（03）
- `ex/pcrel.s`：`%pcrel_hi`、`%pcrel_lo` 怎么配对；`ex/pcrel-gap.s`、`ex/pcrel-bad.s` 是它的变体（03）
- `ex/cmp.c`：比较与条件分支，没有标志位（04）
- `ex/far.c`：跳得越来越远时编译器生成什么（04）
- `ex/far.s`：手写的 beq 跳得太远时汇编器怎么办（04）
- `ex/call.s`：call、tail 与链接器松弛（04）
- `ex/ret.c`：参数与返回值放在哪，RV32 与 RV64 对比（05）
- `ex/frame.c`：序言与尾声、叶函数、尾调用，call/tail/ret 的真实指令，-msave-restore（05、06）

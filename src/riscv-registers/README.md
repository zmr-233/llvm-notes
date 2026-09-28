# RISC-V 寄存器

RISC-V 有哪些寄存器（整数、浮点、向量、CSR），psABI 怎么给它们分工，LLVM 怎么描述和分配它们。
每个结论要么有 `ex/` 下的实验可以复现，要么注明在哪份源码的哪一行核对过。

## 读的顺序

1. [01-basics.md](01-basics.md)：前提词，五类寄存器的全貌
2. [02-integer.md](02-integer.md)：整数寄存器 x0–x31；x0；链接寄存器与压缩指令写死的寄存器；压缩指令为什么偏向 x8–x15；
   LLVM 的分配顺序与保留集
3. [03-calls.md](03-calls.md)：调用约定：保存责任、序言的三种写法、参数与返回值、fp、gp、tp、中断处理函数
4. [04-float.md](04-float.md)：浮点寄存器、fcsr、`-march` 与 `-mabi` 的组合
5. [05-vector.md](05-vector.md)：向量寄存器与 vl、vtype、vlenb
6. [06-csr.md](06-csr.md)：CSR 的地址、访问指令、常用 CSR、trap 进出时硬件改什么

## 版本与出处

- 实验输出来自 LLVM 官方发布的 llvmorg-21.1.8 Linux x86-64 预编译包。换一个 clang，寄存器编号、
  指令顺序可能不同，文中讲的机制不变。
- LLVM 源码行号按 llvmorg-21.1.8（提交 2078da43e25a）。文中 `RISCV/` 是 `llvm/lib/Target/RISCV/` 的简写。
- trap 和 CSR 访问时硬件做什么，编译器实验看不到，按 QEMU v11.1.1 的 `target/riscv/` 源码核对。
  QEMU 是按 RISC-V 规范实现的模拟器。
- RISC-V 规范按 riscv-isa-manual 仓库的 20250508 标签核对，只在 02 第 3 节引用。
- 书：Quentin Colombet，《LLVM Code Generation》，Packt 2025，页码按印刷版。
- justfile 在 just 1.58.0 上核对。

## 跑实验

每个实验是 `ex/` 下的一个 C 文件（`ex/rvc-fixed.S` 是汇编文件，同样交给 clang），gp 实验是
`ex/gp/` 目录。文件开头的注释按 cell 排：一段说明、一条命令、这条命令的预期输出、看点。
在本目录下复制命令运行，对照输出。

### 准备 .env

在本目录下新建 `.env`（已写进 `.gitignore`，不入库）。四个键都要写，没有默认值，
缺哪个，用到它的命令就报错退出：

```
CLANG=/path/to/bin/clang
OBJDUMP=/path/to/bin/llvm-objdump
READELF=/path/to/bin/llvm-readelf
LLD=/path/to/bin/ld.lld
```

- `CLANG`：能生成 RISC-V 代码的 clang。上游发布的 clang 默认带 RISC-V 后端。
- `OBJDUMP`：反汇编用。
- `READELF`：读符号表（函数大小）和重定位用。
- `LLD`：只有 gp 实验用。

官方预编译包的 `bin/` 下四个都有。想看另一个 clang 生成什么，把 `.env` 指过去即可。

### just 动词

`just` 读本目录的 `justfile`。五个动词都把中间文件放在 `mktemp -d` 建的临时目录里，命令结束即删。

- `just asm <文件> <编译参数…>`
  运行 `$CLANG --target=riscv32-unknown-elf <编译参数> -S -o - <文件>`，再删掉以 `.` 开头的
  汇编指示行、注释行、空行，以及标签后面 `# @函数名` 这种注释，只留标签和指令。
  - `-S`：只编译到汇编，不生成目标文件。
  - `-o -`：输出到标准输出。
- `just dis <文件> <编译参数…>`
  编译成目标文件（`-c`），再运行 `$OBJDUMP -d -M no-aliases`，删掉开头几行文件信息。
  - `-d`：反汇编代码段。
  - `-M no-aliases`：按真实指令打印（`c.lw`、`csrrs`、`jalr zero, …`），不折回 `li`、`ret` 这类伪指令。
  - 每行是「偏移: 编码  指令」。编码是 4 个十六进制位的，是 2 字节的压缩指令；8 个的是 4 字节指令。
- `just size <文件> <编译参数…>`
  编译成目标文件，运行 `$READELF -s --wide`，取出类型为 FUNC 的符号的大小，即每个函数的字节数。
  - `-s`：打印符号表。
  - `--wide`：长行不截断。
- `just reloc <文件> <编译参数…>`
  编译或汇编成目标文件，运行 `$READELF -r --wide`，列出重定位项，即链接器要回填或可以改写的位置。
  - `-r`：打印重定位表。
- `just gp <启动文件> <链接参数…>`
  gp 实验专用，步骤写在 `ex/gp/main.c` 开头。

### 编译参数

实验里反复出现的：

- `--target=riscv32-unknown-elf`：justfile 固定加上。生成 32 位 RISC-V、没有操作系统（裸机）的 ELF 代码。
- `-march=rv32imc`：可用的指令。`rv32` 表示整数寄存器 32 位，后面每个字母或 `_z…` 是一个扩展，见 01。
- `-mabi=ilp32`：调用约定，见 01。
- `-Os`：按代码体积优化。
- `-mllvm <选项>`：把选项原样交给 LLVM 后端。后端的选项在源码里用 `cl::opt` 声明，这是 LLVM
  自己的命令行选项机制；clang 的命令行不认识这些选项，要经 `-mllvm` 转交。

### 看大小时的一个前提

`size` 和 `dis` 看的都是目标文件，也就是链接之前。目标文件里一条 `call f` 或 `tail f` 固定是
auipc 加 jalr 两条共 8 字节；链接时如果目标够近，链接器会把它改写得更短，这叫链接器松弛
（relaxation）。`ex/gp/main.c` 的 cell 1 里，`call main` 链接后只剩 2 字节。带调用的函数，
链接后会比这里看到的小。

## 实验一览

- `ex/x0.c`：x0 与伪指令（02）
- `ex/jalr.c`：间接调用、间接尾调用不用 t0 做目标寄存器（02）
- `ex/rvc-fixed.S`：压缩指令写死的 sp、ra、x0，以及 RV64 没有 c.jal（02）
- `ex/rvc.c`：压缩指令只认 x8–x15（02）
- `ex/save.c`：保存责任、`-msave-restore`、Zcmp、帧指针（03）
- `ex/save-many.c`：要存的寄存器多时，三种序言写法的大小（03）
- `ex/args.c`：参数与返回值，ilp32 与 ilp32e（03）
- `ex/gp/`：gp 与链接器松弛（03）
- `ex/tp.c`：tp 与线程局部变量（03）
- `ex/isr.c`：中断处理函数保存什么（03）
- `ex/float.c`：`-march` 与 `-mabi` 的六种组合（04）
- `ex/vector.c`：v 寄存器、vl、vtype、v0 掩码（05）
- `ex/csr.c`：CSR 地址与访问指令（06）

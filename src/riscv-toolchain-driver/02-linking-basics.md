# 02 链接零基础：那行 `ld` 命令里每个词是什么

> 这一篇不讲 clang 源码，讲 `RISCVToolchain.cpp` 生成的那条链接命令所依赖的全部背景：
> 目标文件、库、启动文件、运行库、链接器选项。已经熟悉 GNU 链接的读者可以只看 §8 的对照表。
> 命令输出来自 [`02-gcc-tree`](examples/02-gcc-tree/run.sh) 与 [`05-flags`](examples/05-flags/run.sh)。

先把 20.1.8 对 `clang --target=riscv32-unknown-elf --gcc-toolchain=$T --sysroot=$T/riscv32-unknown-elf hello.c`
生成的链接命令摆在这里，下面逐词解释（`$T` 是一套 GCC 交叉工具链的安装前缀，`$G` 是它里面的
`lib/gcc/riscv32-unknown-elf/8.0.1`，`$S` 是 `$T/riscv32-unknown-elf`）：

```text
"$G/../../../../bin/riscv32-unknown-elf-ld"
  "--sysroot=$S"
  "-m" "elf32lriscv"
  "-X"
  "$S/lib/crt0.o"
  "$G/crtbegin.o"
  "/tmp/hello-xxxx.o"
  "-L$G"
  "-L$S/lib"
  "--start-group" "-lc" "-lgloss" "--end-group"
  "-lgcc"
  "$G/crtend.o"
  "-o" "a.out"
```

## 1. 目标文件、静态库、动态库

**目标文件**（`.o`）是编译一个源文件的产物：机器码 + 一张**符号表**（这个文件定义了哪些
函数/变量，引用了哪些还没定义的）+ 重定位信息（哪些地址要等链接时再填）。

**静态库**（`libfoo.a`）就是一堆 `.o` 用 `ar` 打成的包，外加一个索引。链接器对它的处理规则
是理解后面一切的关键：**只从库里取出"能解决当前未定义符号"的那些 `.o`**，其余不要。
所以库在命令行上的**位置**有意义：链接器从左到右扫，遇到 `.o` 就全收下并记下它引用的未定义
符号，遇到 `.a` 就从里面挑能补上这些符号的成员。如果 `-lfoo` 写在引用它的 `.o` 之前，扫到
`libfoo.a` 时还没有任何未定义符号，库里什么都不会取，之后再出现引用就是 `undefined reference`。
这就是为什么上面的命令里用户的 `.o` 在前、`-lc -lgloss -lgcc` 在后。

**动态库**（`.so`）在裸机上不存在：没有操作系统就没有加载器去做运行时链接。所以 RISC-V
裸机工具链里没有 `-shared`、`-pie`、`-dynamic-linker` 这些概念，`RISCV::Linker` 一个都不生成；
21 的 `BareMetal` 还显式加了 `-Bstatic`（告诉 `ld` 之后的 `-l` 只找 `.a`）。对比 Linux 目标
（`--target=riscv32-unknown-linux-gnu`）的链接行，多出来的 `-dynamic-linker /lib/ld-linux-riscv32-ilp32.so.1`、
`--eh-frame-hdr`、`crt1.o crti.o … crtn.o`、`--as-needed -lgcc_s`，都是有操作系统才需要的东西。

## 2. `-l`、`-L`、`--sysroot`：库怎么找

- `-lc` 意思是"找一个叫 `libc.a`（动态优先时先找 `libc.so`）的文件"。去哪找：`-L` 给的目录，
  按出现顺序；再加链接器自己的默认目录。
- `-L$G`、`-L$S/lib` 是 driver 替你加的：GCC 安装目录（`libgcc.a` 在那）和目标 sysroot 的
  `lib`（`libc.a`、`libm.a`、`libgloss.a` 在那）。用户自己的 `-L` 也会被原样转发。
- `--sysroot=$S` 是给**链接器**看的：链接脚本里的 `SEARCH_DIR("=/lib")` 那种带 `=` 的路径以它为
  根。driver 只在用户显式给了 `--sysroot` 时才转发这一项（`RISCVToolchain.cpp` 第 161 行）；
  没给的话它自己推出来的 sysroot 只用于拼路径，不告诉链接器。

`-print-search-dirs` 能直接打印 driver 手里的两张表（`programs:` 与 `libraries:`），
`-print-file-name=crt0.o` 能打印 driver 会把某个文件解析成哪个绝对路径；找不到时原样返回
文件名（实测 `-print-file-name=libc.a` 返回 `libc.a`，因为假树里没放这个文件），
链接命令里也就会出现一个裸的 `crt0.o`，然后由链接器去 `-L` 目录里找——这就是 04 例子里
"什么都没有"的情况下你看到 `"crt0.o"` 不带路径的原因。

## 3. 启动文件：`crt0.o`、`crtbegin.o`、`crtend.o`

程序不是从 `main` 开始执行的。**`crt0.o`**（C runtime zero）是入口：设栈指针、把 `.bss`
清零、把 `.data` 从 ROM 拷到 RAM（裸机常见）、调用全局构造函数、然后 `call main`，`main` 返回后
`call exit`。在 newlib 世界里它由 libgloss 提供，装在 `<sysroot>/lib/crt0.o`。**它必须是第一个
输入**，因为默认入口符号 `_start` 在它里面，而且很多链接脚本假定 `.text` 从它开始。

**`crtbegin.o` / `crtend.o`** 是 GCC 提供的一对"括号"：定义 `.init_array`/`.fini_array`
（或旧式 `.ctors`/`.dtors`）区段的开头和结尾标记，以及 `__EH_FRAME_BEGIN__` 之类异常处理表的
边界。它们要**夹住所有用户目标文件和库**——`crtbegin.o` 紧跟在 `crt0.o` 之后，`crtend.o` 在
所有 `-l` 之后。谁提供它们取决于运行库：GCC 的在 `$G/crtbegin.o`；compiler-rt 的叫
`clang_rt.crtbegin.o`，在 clang 资源目录下（`lib/clang/21/lib/riscv32-unknown-unknown-elf/`）。
`RISCVToolchain.cpp` 第 181–192 行就是在这两套名字之间二选一。

`-nostartfiles` 去掉这三个文件（用户自己提供入口，常见于带自己启动代码的固件）；
`-nostdlib` 去掉这三个文件**和**所有默认库；`-nodefaultlibs` 只去掉默认库、保留启动文件
（实测：[`05-flags`](examples/05-flags/run.sh) 前三段）。

## 4. 默认库：`-lc -lgloss -lm -lgcc` 各是什么

裸机 C 程序需要的库分层如下（这是 newlib 的分法，riscv-gnu-toolchain 就是这么装的）：

| 库 | 内容 | 谁提供 |
|---|---|---|
| `libc.a` | `printf`、`malloc`、`memcpy`……C 标准库本体 | newlib |
| `libm.a` | 数学函数 | newlib |
| `libgloss.a` | **板级支持**：`_write`、`_sbrk`、`_exit` 这些 libc 底下的系统调用桩。裸机没有 OS，必须有人提供，newlib 把它们单独放在这里（默认实现走半主机或空转） | libgloss（newlib 的一部分） |
| `libgcc.a` | **编译器运行库**：编译器内部会生成对它的调用来做硬件不直接支持的事——32 位 RISC-V 上的 64 位除法（`__divdi3`）、软浮点（`__addsf3`）、`__clzsi2`…… | GCC |
| `libclang_rt.builtins.a` | `libgcc.a` 的 LLVM 等价物 | compiler-rt |

为什么 `-lc -lgloss` 要用 `--start-group … --end-group` 包起来：`libc.a` 调用 `libgloss.a` 里的
`_write`，而 `libgloss.a` 又可能调用 `libc.a` 里的东西。按 §1 的单向扫描规则，A 引用 B、B 又引用 A
时一次扫描不够；`--start-group` 让链接器在这组库上**反复扫直到没有新的符号被解决**。
`-lgcc` 放在组外、组后：所有东西都可能引用它，它自己不引用别人。（21 把 `-lgcc` 挪进了组内，
06 篇的差异表有说明。）

`-lm` 只在 C++ 模式下由 driver 加（第 214 行）。C 程序要用 `sin` 得自己写 `-lm`——这是照搬
GCC 的行为。

## 5. 编译器运行库与 unwind 库：`--rtlib`、`--unwindlib`

上游文档 `clang/docs/Toolchain.rst` 把"运行库"分了好几层，`RISCVToolchain.cpp` 关心两层：

- **compiler runtime**：libgcc 或 compiler-rt builtins（上表最后两行）。`--rtlib=libgcc|compiler-rt|platform`
  选择；`platform` 表示"用这个 ToolChain 的默认值"，也就是 `GetDefaultRuntimeLibType()`。
  RISC-V 的默认值是：**找到了 GCC 安装就用 libgcc，否则 compiler-rt**（第 79 行）。
- **unwind 库**：C++ 异常展开需要的 `_Unwind_*` 函数（libgcc 自带一份，LLVM 的叫 libunwind）。
  RISC-V 裸机工具链直接回答 `UNW_None`（第 84 行）：不链接任何 unwind 库，`--unwindlib=` 给了
  也不看。这不影响 C++ 异常本身能不能用——用 libstdc++ 时 `libgcc.a` 里就有展开器，用 libc++
  时你得自己 `-lunwind`。

`-print-libgcc-file-name` 打印 driver 会用哪一个：默认打印 `libgcc.a`；加 `--rtlib=compiler-rt`
打印 `.../lib/clang/21/lib/riscv32-unknown-unknown-elf/libclang_rt.builtins.a`（实测）。注意
compiler-rt 那个是**绝对路径**而不是 `-lclang_rt.builtins`——04 例子里链接行上出现的就是绝对路径，
所以它不受 `-L` 顺序影响。

## 6. C++ 标准库：`-stdlib`

`--stdlib=libstdc++|libc++|platform`。RISC-V 裸机的默认值是 libstdc++（`ToolChain` 基类的默认，
`ToolChain.h:505`；`RISCVToolChain` 没有覆盖）。选了 libstdc++，driver 要做两件事：
编译时给 cc1 加三个 `-internal-isystem`（`$S/include/c++/8.0.1`、`…/riscv32-unknown-elf`、
`…/backward`，第 119–128 行），链接时加 `-lstdc++ -lm`（第 211–215 行）。libstdc++ 的
C++ ABI 部分（`libsupc++`）在静态链接时**不会**被自动加上，上游文档明说了这一点。

## 7. 链接器本身的几个选项

| 选项 | 含义 | 谁加的 |
|---|---|---|
| `-m elf32lriscv` / `elf64lriscv` | 链接器的"仿真"：目标格式与位宽。GNU ld 一个二进制能链多种格式，靠它选。RISC-V 的名字是 `elf` + 位宽 + `l`（小端）+ `riscv` | `RISCVToolchain.cpp` 第 167–173 行硬编码；21 改成查 `getLDMOption()` 表（`CommonArgs.cpp:541`） |
| `-X` | `--discard-locals`：丢掉临时局部符号（`.L` 开头的）。RISC-V 汇编器为松弛生成大量 `.L` 标号，不丢会让符号表很大 | 第 174 行，2022 年加的 |
| `--no-relax` | 关闭**链接器松弛**：RISC-V 的 `call`、`lui+addi` 序列在链接时可能被缩短成更短的指令，这需要链接器改代码。`-mno-relax` 时编译器不产生松弛重定位，链接器也得关掉 | 第 164 行，只在 `-mno-relax` 时 |
| `-T script.ld` | 链接脚本（裸机几乎必有：内存布局、段放哪）。`-T` 属于 `T_Group`，`-Ttext=` 等也在里面 | 转发用户的 |
| `-e sym` | 入口符号 | 转发用户的，走"链接器输入"通道（下节） |
| `-u sym` | 强制认为 `sym` 未定义，逼链接器从库里取出定义它的成员（常用于拉进中断向量表） | 转发 |
| `-s` / `-t` | 去符号表 / 跟踪打开的文件 | 转发 |
| `-r` | 可重定位输出（"部分链接"，产出还是 `.o`） | 转发 |
| `-Wl,x` / `-Xlinker x` | 原样传给链接器的任意选项 | 转发，走"链接器输入"通道 |
| `-fuse-ld=lld` / `ld` / `bfd` | 选链接器程序：`ld.lld`、`ld`（默认）、`ld.bfd` | `ToolChain::GetLinkerPath`（03 篇） |

**"链接器输入"通道**：`Options.td` 里标了 `LinkerInput` 的选项（`-l`、`-e`、`-Xlinker`、`-Wl,`
展开后的每一项、`-r`……）不被当作普通选项，而是与 `.o` 文件一起当作"输入"，由
`AddLinkerInputs`（`CommonArgs.cpp:452`）**按命令行相对顺序**一起输出。实测的一条命令
`-T link.ld -u foo -Wl,--defsym=X=1 -Xlinker --gc-sections -e _entry -s -L/opt/mylib -lmylib hello.c`
在 20.1.8 上落成：

```text
... "crtbegin.o" "--defsym=X=1" "--gc-sections" "-e" "_entry" "-lmylib" "/tmp/hello-xxxx.o"
    "-u" "foo" "-L/opt/mylib" "-L$G" "-L$S/lib" "-T" "link.ld" "-s" "--start-group" "-lc" ...
```

`-lmylib` 在 `hello.o` 之前——因为你在命令行上就是这么写的（按 §1 的规则这会导致
`libmylib.a` 里什么都取不到，这是用户的错，driver 忠实保留）。而 `-u`、`-L`、`-T`、`-s` 是
普通选项，由 `ConstructJob` 在固定位置输出。`-r` 是个小 bug：它同时带 `LinkerInput` 标志又出现在
`addAllArgs` 列表里，所以链接行上出现两次（20 与 21 都是）。

## 8. 裸机（`riscv32-unknown-elf`）与 Linux（`riscv32-unknown-linux-gnu`）链接行对照

同一份 `hello.c`，`--gcc-toolchain` 指向对应的假树，`-fuse-ld=ld`，两版 clang 输出一致：

| | 裸机（`RISCV::Linker` / `baremetal::Linker`） | Linux（`gnutools::Linker`，`Gnu.cpp:283`） |
|---|---|---|
| 入口文件 | `crt0.o` | `crt1.o` + `crti.o`（还有 `crtn.o` 收尾） |
| 动态链接 | 无 | `-dynamic-linker /lib/ld-linux-riscv32-ilp32.so.1`、默认 PIE |
| 异常表头 | 无 | `--eh-frame-hdr` |
| 默认库 | `--start-group -lc -lgloss --end-group -lgcc` | `-lgcc --as-needed -lgcc_s --no-as-needed -lc -lgcc --as-needed -lgcc_s --no-as-needed` |
| 库目录 | `$G`、`$S/lib` | `$G/lib32/ilp32`、`sysroot/lib32/ilp32`、`sysroot/usr/lib32/ilp32`…… |
| 哈希风格 | 无 | `--hash-style=gnu` |

看到这张表就明白 `RISCVToolchain.cpp` 为什么只有 230 行：它是 `Gnu.cpp` 里那个 300 多行的
Linux 链接器去掉一切"有操作系统才需要的东西"、换上 newlib 那一套启动文件与库之后的样子。
`Gnu.cpp` 的 `gnutools::Linker` 在读它的时候是最好的参照物：凡是 Linux 那边有而这边没有的
（`-static`、`-shared`、`-pie`、sanitizer 运行库、`-pthread`、OpenMP、LTO 插件参数……），要么裸机
不需要，要么就是 `RISCV::Linker` 没实现——05 篇末尾列了这张"没实现"清单。

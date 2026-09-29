# 07 用公共代码换体积

06 第 8 节的 millicode 是一种省体积的办法：许多函数都要做的同一件事只写一份，各处调用它，多几次
跳转，换来更小的代码。LLVM 里这个思路有三种形态：

- `-msave-restore`：人手写好的公共序言、尾声，放在库里；
- Machine Outliner：编译器在编译时找出重复的指令序列，现场生成公共片段；
- push/pop 指令：把存取寄存器做成一条硬件指令，连跳转都省了。

本篇讲这三者的关系和实测，最后列出 llvmorg-21.1.8 上还空着的地方。

## 1. 前提词

- 代码体积：本篇指 `.text` 段的字节数，也就是机器指令占的空间。
- `-Oz`：比 `-Os` 更偏重体积的优化级别。clang 给按 `-Oz` 编译的函数加上 minsize 属性，后端据此决定
  要不要做某些以速度换体积的变换。
- 外提（outlining）：把重复出现的一段指令抽成一个新函数，原处换成对它的调用。
- 基本块：一段连续的指令，只能从第一条进入、从最后一条离开，中间没有跳进跳出。
- LTO（link-time optimization）：编译时只生成 LLVM IR，链接时把整个程序的 IR 合在一起再优化、生成
  机器码。不开 LTO 时，每个 .c 文件单独生成机器码，彼此看不见。

## 2. 三种形态

### 2.1 -msave-restore：库里的公共序言、尾声

06 第 8 节讲过它怎么调用、怎么返回，riscv-registers 的 03 第 2 节量过它的大小。这里补两点：

- 它只管序言和尾声，函数体里别的重复代码不管。
- 目标支持 push/pop 指令时它不生效：`RISCV/RISCVMachineFunctionInfo.h:124–128` 的
  useSaveRestoreLibCalls 要求 `!isPushable(MF)`。有更好的硬件指令，就不再用库函数。

### 2.2 Machine Outliner：编译器现场生成

是什么。`llvm/lib/CodeGen/MachineOutliner.cpp` 开头的注释：把每个基本块里的每条指令放进一棵后缀树，
反复查询其中重复出现的指令序列；一段序列出现得够多，就值得抽成一个函数。后缀树是一种能快速找出
所有重复子串的数据结构，这里的「字符」是一条条机器指令。

在哪一步。它作用于寄存器分配之后的机器指令，在输出汇编之前：`llvm/lib/CodeGen/TargetPassConfig.cpp:1224`
起把它加进流水线，位置在各后端的 addPreEmitPass 之后（`RISCV/RISCVTargetMachine.cpp:566` 起的注释）。
这时每条指令都定了下来，能按字节数算省多少。

通用部分只管找重复，怎么调用、怎么返回由各后端提供，注释里列出了必须实现的几个钩子：
getOutliningCandidateInfo、buildOutlinedFrame、insertOutlinedCall 等。RISC-V 的实现在
`RISCV/RISCVInstrInfo.cpp`（llvmorg-21.1.8），分两种：

- 序列以返回结尾：原处换成 `tail OUTLINED_FUNCTION_N`，返回指令一起挪进新函数（:3465 起，:3561 起）。
- 其他序列：原处换成 `call t0, OUTLINED_FUNCTION_N`（:3557 起），新函数末尾加一条 `jalr zero, 0(t0)`，
  即 `jr t0`（:3545 起）。

第二种就是 millicode 的调用方式：返回地址放在 t0，ra 不动，返回地址栈一压一弹正好配对（06 第 8 节）。
由此有两条限制：

- 序列里改了 t0，或者调用处的 t0 还有用，这个位置就不能外提（:3434–3442）。
- 序列里不能含调用。调用按约定会改写 t0（t0 是调用者保存寄存器），也会改写 ra，而外提出的函数没有
  地方保存 ra。

什么时候跑：

- RISC-V 声明支持默认外提（`RISCV/RISCVTargetMachine.cpp:193–194`），默认只对 minsize 函数外提
  （`RISCVInstrInfo.cpp:3379–3382`）。所以 `-Oz` 会外提，`-Os` 不会。
- `-mno-outline`：关掉。
- `-mllvm -enable-machine-outliner`：对所有函数都跑，`-Os` 也不例外。这是 `TargetPassConfig.cpp:133` 起声明的
  `cl::opt`，不带值时等于 `always`。
- clang 21.1.8 对 riscv32 不认 `-moutline`，报 warning 后忽略（`ex/outline.c` cell 2）。上游后来加上了：
  提交 ea7d852a70e8（2026-08-25）的 `clang/lib/Driver/ToolChains/CommonArgs.cpp:3012` 注释写着 `-moutline`
  支持 AArch64、ARM、RISC-V 和 X86。

怎么算划不划算（:3446 起的 getOutliningCandidateInfo）：

- 原处每次调用算 8 字节，即 `call t0` 展开成的 auipc 加 jalr。新函数末尾的 `jr t0` 算 2 字节（有 C 扩展）
  或 4 字节。
- 以返回结尾的那种，原处算 4 加 2（或 4 加 4）字节，:3468 的注释自己标了 FIXME，怀疑 jalr 怎么能压缩。
- 通用部分算收益：不外提时的总字节数，减去外提后的总字节数（各处调用加新函数本身），
  `llvm/include/llvm/CodeGen/MachineOutliner.h:242–261`。收益不小于 `-outliner-benefit-threshold`
  （默认 1 字节，`MachineOutliner.cpp:129`）才外提。

### 2.3 push/pop：做进硬件

Zcmp 的 `cm.push`、`cm.popret` 一条 2 字节指令就完成存寄存器、开栈帧，或者取回、还栈、返回
（riscv-registers 的 03 第 2 节）。LLVM 21.1.8 认两种：标准的 Zcmp，和 Qualcomm 的 Xqccmp
（`RISCV/RISCVMachineFunctionInfo.cpp:88–109` 的 getPushPopKind）。:104 的注释说，Xqccmp 就是 Zcmp，
只是压栈的顺序与帧指针的约定兼容。

和前两种比，它不用跳转，也不必像 `__riscv_save_N` 那样按组多存寄存器。代价是要硬件支持。

## 3. 实测

实验 `ex/outline.c`，`-march=rv32imc -mabi=ilp32`：

- mid_mul、mid_div、mid_rem：开头算同一个 s，最后一步不同。
- end_add、end_sub、end_xor：都先调用 use，之后只差一步运算，然后是同样的尾声。

cell 1，`-Oz` 下外提出两个函数：

```
OUTLINED_FUNCTION_0   mid_* 开头算 s 的 15 条指令     三处 call t0 调用，末尾 c.jr t0
OUTLINED_FUNCTION_1   end_* 的尾声                  三处 tail 跳来，末尾 c.jr ra
                      c.lwsp ra ; c.lwsp s0 ; c.addi sp, 16 ; c.jr ra
```

OUTLINED_FUNCTION_1 就是编译器替这个文件现场生成的 `__riscv_restore`。

cell 2、3，`just size` 打印 `.text` 的字节数，链接前和链接后各一个：

```
选项                                       链接前    链接后
-Os                                         246      228
-Oz                                         204      156
-Oz -mno-outline                            246      228
-Os -mllvm -enable-machine-outliner         204      156
-Oz -msave-restore                          202      142     不含 __riscv_save/restore 本体
-march=rv32imc_zcmp -Oz                     166      136
-march=rv32imc_zcmp -Oz -mno-outline        216      198
```

- `-Oz` 与 `-Os` 的差别全来自外提：关掉外提后两者一样大。
- 要看链接后的大小。
  - 目标文件里每个 call、tail 都是 8 字节的 auipc 加 jalr。
  - 链接器松弛之后，`call t0` 变成 4 字节的 `jal t0`。c.jal 只能写 ra，所以不能更短。
  - tail 能缩成 2 字节的 c.j。
  - 这是本例的 -Oz 比 -Os 在链接前少 42 字节、链接后少 72 字节的原因。
- Zcmp 下，end_* 的尾声只剩一条 `cm.popret`，没什么可抽。外提只抽出 mid_* 那段，仍然少了 62 字节。
- 例子很小，只说明机制在起作用。哪种组合在真实程序上最好，要拿成规模的程序量链接后的大小。

## 4. 查一个构建用了哪种

看链接好的 ELF 就能分辨，下面用 .env 里的工具：

- 外提：`$READELF -s a.elf | grep OUTLINED_FUNCTION`。`-s` 打印符号表，外提出的函数是名为
  `OUTLINED_FUNCTION_N` 的局部符号。
- `-msave-restore`：同一条命令找 `__riscv_save_`、`__riscv_restore_`。
- push/pop：`$OBJDUMP -d a.elf | grep cm.push`。
- 如果 ELF 去掉了符号表，就看反汇编里有没有 `jal t0` 和 `jalr zero, 0(t0)` 成对出现。

本节的第一条命令在 `ex/outline.c` 用 `-Oz -msave-restore` 链接出的 ELF 上核对过：它列出
`OUTLINED_FUNCTION_0`（LOCAL），以及未定义的 `__riscv_save_1`、`__riscv_restore_1`。

## 5. llvmorg-21.1.8 上还空着的地方

- 代价按链接前的长度估算。原处的 `call t0` 算 8 字节，链接后常常只有 4 字节，所以会低估外提的收益。
  以返回结尾的那种，:3468 自带 FIXME。
- 含调用的序列不能外提。AArch64 的外提有五种构造方式（`AArch64/AArch64InstrInfo.cpp:9002–9008`），
  其中包括把返回地址存到栈上或别的寄存器、外提以调用结尾的序列。RISC-V 只有 2.2 节那两种。
- 外提只在一个模块里找重复。不开 LTO 时，一个模块就是一个 .c 文件，跨文件的重复看不见。
- Zcmt（表跳转：`cm.jalt` 用 2 字节按下标调用一张表里的函数）只有指令定义，汇编器、反汇编器认得，
  编译器不会生成（`RISCV/RISCVInstrInfoZc.td:263–281`）。lld 里没有把调用改写成表跳转的松弛，
  21.1.8 没有，提交 ea7d852a70e8（2026-08-25）也没有。
- 自定义指令接入外提前要检查描述是否完整。外提按每条指令声明的读写来判断能不能抽、能不能用 t0，
  包括隐式读写的寄存器（TableGen 里的 Uses、Defs）。一条指令如果隐式改了 t0 或 sp 却没有写明，
  外提就可能把它抽错。

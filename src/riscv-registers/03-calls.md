# 03 调用约定

本篇的实验都用 `-march=rv32imc -mabi=ilp32 -Os`，除非另外写明。

## 1. 保存责任落在谁身上

实验 `ex/save.c` cell 1。`g` 只有声明，编译器看不到它的内部，只能按调用约定假设：g 会改写所有
调用者保存寄存器，不会改写被调用者保存寄存器。

```
leaf   slli a2,a0,1 ; add a0,a0,a1 ; add a0,a0,a2 ; ret
tail   addi a0,a0,1 ; tail g
keep   addi sp,sp,-16 ; sw ra,12(sp) ; sw s0,8(sp) ; mv s0,a0
       call g ; add a0,a0,s0
       lw ra,12(sp) ; lw s0,8(sp) ; addi sp,sp,16 ; ret
```

- leaf：不调用别的函数，只用调用者保存的 a0–a2，没有序言和尾声。
- tail：调用 g 之后不再用 x，于是直接跳到 g，由 g 返回到 tail 的调用者。tail 没改 ra，不用存。
- keep：`call g` 之后还要用 x。x 进来时在 a0，g 可以改 a0，所以先挪进 s0。s0 是被调用者保存
  寄存器，keep 用了它，就要替自己的调用者保住：`sw s0` / `lw s0`。`call g` 会改写 ra，keep 最后
  `ret` 要用进来时的 ra，所以 ra 也存。
- keep 只存 8 字节，却开了 16 字节的栈：ilp32 要求 sp 16 字节对齐（第 4 节）。

这条规则在 LLVM 里落在两处：

- 每条调用指令带一个寄存器掩码，列出调用之后仍保持原值的寄存器，即被调用者保存列表
  （`RISCV/RISCVRegisterInfo.cpp:811` 的 getCallPreservedMask，按 ABI 返回
  `CSR_ILP32_LP64_RegMask` 等）。一个值要跨过调用继续用，分配器只能把它放进掩码里的寄存器，
  或者存到栈上。
- 函数自己改了列表里的哪个寄存器，序言就存哪个、尾声就取哪个（列表由 getCalleeSavedRegs 给出）。

## 2. 序言和尾声的三种写法

实验 `ex/save.c` cell 2–4，`ex/save-many.c`。keep 要存 ra、s0；keep4 要存 ra、s0–s3。
下面的字节数是目标文件里的，链接前。

```
选项                   keep 的序言 … 尾声                                  keep   keep4
默认                   addi sp; sw ra; sw s0 … lw ra; lw s0; addi sp; ret   26     56
-msave-restore         call t0, __riscv_save_1 … tail __riscv_restore_1     28     46
-march=rv32imc_zcmp    cm.push {ra, s0}, -16 … cm.popret {ra, s0}, 16       16     32
```

- `-msave-restore`：序言和尾声换成调用库函数 `__riscv_save_N`、`__riscv_restore_N`，N 是要存的
  s 寄存器个数。这两组函数由 compiler-rt 或 libgcc 提供。
  - 调用写的是 `call t0, …`，返回地址放进 t0：此刻 ra 里还是 keep 自己的返回地址，不能覆盖。
    t0 是硬件认作链接寄存器的另一个编号（02 第 3 节）。
  - llvmorg-21.1.8 的 `compiler-rt/lib/builtins/riscv/save.S` 里，RV32 上 `__riscv_save_0` 到
    `__riscv_save_3` 是同一个入口，存 ra、s0、s1、s2；`__riscv_save_4` 到 `__riscv_save_7` 是
    另一个入口，存 ra 和 s0–s6。存的比需要的多，换来函数本身只有首尾两条调用。
  - 每条调用在目标文件里是 8 字节。只存一个 s0 时，它比默认写法还大；要存 4 个时就小了。
    链接器松弛还能把调用缩短（`ex/gp/main.c` cell 1）。
- Zcmp：`cm.push {ra, s0}, -16` 一条 2 字节指令完成存 ra、s0 和 sp 减 16；`cm.popret` 取回、
  sp 加回、返回。
  - 寄存器列表只能是 {ra}、{ra, s0}、{ra, s0-s1} … {ra, s0-s9}、{ra, s0-s11}，即从 s0 开始连续
    的一段（`RISCV/MCTargetDesc/RISCVBaseInfo.h:600` 的 RLISTENCODE）。LLVM 的分配顺序里
    s0、s1、s2… 依次排列（02 第 5 节），用到的 s 寄存器通常正好是这样一段。
  - keep4 里还出现了 `cm.mvsa01 s1, s0`：一条 2 字节指令把 a0、a1 分别挪进 s1、s0。两个目的
    寄存器只能在 s0–s7 里（`RISCV/RISCVRegisterInfo.td:304` 的 SR07 类）。

## 3. ra 归谁

psABI 把 ra 算作调用者保存。LLVM 却把 X1 放进了被调用者保存列表：`RISCV/RISCVCallingConv.td:16`
是 `CSR_ILP32E_LP64E = X1, X8, X9`，:18 的 `CSR_ILP32_LP64` 在它的基础上加 X18–X27。

两种说法生成的代码一致：

- 序言这一侧。函数改了列表里的哪个寄存器，序言就存哪个。call 伪指令声明了 `Defs = [X1]`
  （`RISCV/RISCVInstrInfo.td:1780`），即它会改写 X1，所以函数里只要有 call，就改了 ra，序言就存 ra，
  也就是 keep 里的 `sw ra`。
- 调用这一侧。X1 在寄存器掩码里，表示「调用后 X1 保持原值」；但 call 指令自己定义了 X1，
  调用之后 ra 仍然被当作已改写。

## 4. 参数与返回值

实验 `ex/args.c`。

```
-march=rv32imc -mabi=ilp32    many 的 a–h → a0–a7          i → 0(sp)
-march=rv32ec  -mabi=ilp32e   many 的 a–f → a0–a5          g h i → 0(sp) 4(sp) 8(sp)
两种都一样                     add64 的 a → a0,a1   b → a2,a3   返回值 → a0,a1
```

- 参数寄存器按顺序分配：ilp32 用 x10–x17，ilp32e 用 x10–x15（`RISCV/RISCVCallingConv.cpp:130`、:134）。
  放不下的参数由调用者放在自己的栈上，被调函数进入时从 0(sp) 往上排。
- 返回值在 a0。RV32 上的 64 位整数拆成两个寄存器，低 32 位在编号小的那个：add64 的 a 在 a0（低）、
  a1（高），返回值同样在 a0、a1。
- 栈对齐：ilp32e 是 4 字节，其他 ABI 是 16 字节（`RISCV/RISCVFrameLowering.cpp:35`）。

## 5. fp：s0

实验 `ex/save.c` cell 5，加 `-fno-omit-frame-pointer`，让每个函数都维护帧指针。

- 三个函数都多了 `addi s0, sp, 16`：s0 指向进入函数时的 sp。
- 栈上的布局是 ra 在 s0-4，上一层的 s0 在 s0-8。沿着 s0 可以一层层找到每一层的返回地址，
  栈回溯靠的就是这条链，所以 leaf、tail 也存了 ra 和 s0。
- s0 被占作帧指针，进了保留集（02 第 6 节），keep 只好改用 s1 保存 x，多存一个 s1。

## 6. gp 与链接器松弛

实验 `ex/gp/`，步骤和四个 cell 写在 `ex/gp/main.c` 开头。

- gp 的值由启动代码设置：`la gp, __global_pointer$`。`__global_pointer$` 由链接脚本定义，
  `ex/gp/link.ld` 把它定在数据起点往后 0x800 处，这样 12 位有符号偏移（-2048 到 +2047）
  正好覆盖从数据起点开始的 4 KiB。
- 编译器不知道 gp 的值，照常生成 `lui` 加访存两条。链接器知道每个符号的最终地址，发现目标在
  gp 前后 2 KiB 内，就把两条改写成一条 `访存 偏移(gp)`：
  ```
  不开 gp 松弛    lui a1, 0x80010 ; lw a0, 0x0(a1) ; … ; sw a0, 0x0(a1)    main 16 字节
  --relax-gp      lw a0, -0x800(gp) ; … ; sw a0, -0x800(gp)                main 12 字节
  ```
- ld.lld 默认不做这项改写，要加 `--relax-gp`（`lld/ELF/Driver.cpp:1520`，默认值 false）。
  普通的调用缩短则默认就做：`call main` 链接后是 2 字节的 `c.jal`。
- 链接器只改写带 `R_RISCV_RELAX` 重定位的位置。编译、汇编时加 `-mrelax`，汇编器就在可以缩短的
  指令对上附这个标记；`.option norelax` 包住的指令不附（`ex/gp/main.c` cell 3 用 `just reloc` 对比）。
- 启动代码装 gp 的 `la` 包在 `.option norelax` 里：如果它被改写成相对 gp 的形式，就是在 gp 还没
  装好时读 gp。ld.lld 21.1.8 的 gp 松弛只改写 `lui` 开头的指令对，不改写 `la` 展开成的
  `auipc`+`addi`，所以去掉 norelax 在它上面结果不变（cell 4）；写上 norelax，结果就不依赖链接器
  这一点的具体实现。
- LLVM 从不分配 gp（02 第 6 节）。

## 7. tp

实验 `ex/tp.c`。`__thread` 变量每个线程一份，按「tp + 偏移」访问：

```
lui a0, %tprel_hi(per_thread)
add a1, a0, tp, %tprel_add(per_thread)
lw  a0, %tprel_lo(per_thread)(a1)
```

- `%tprel_hi`、`%tprel_add`、`%tprel_lo` 是交给链接器填入偏移的标记，偏移是变量相对本线程
  存储块起点的距离。
- 编译器只读 tp，不写 tp，也从不把 tp 分配给别的值（02 第 6 节）。tp 由启动代码或操作系统设置。

## 8. 中断处理函数

实验 `ex/isr.c`。`__attribute__((interrupt("machine")))` 告诉 clang 这是 M 级中断的入口。

```
isr_leaf     存 a0 a1（它自己用到的）; cnt++ ; 取回 a0 a1 ; mret
isr_call     开 64 字节栈 ; 存 ra t0–t6 a0–a7 共 16 个 ; call work ; 全部取回 ; mret
plain_call   tail work
```

- 普通函数只需保住被调用者保存的那一半。中断可能打断任何一条指令，被打断的代码在调用者保存
  寄存器里也可能有正在用的值，所以中断处理函数改动的每个寄存器都要保住。
- isr_call 调用了看不到内部的 work，work 按约定可以改任何调用者保存寄存器，于是 16 个全存。
  s0–s11 不用存，work 自己会保住它们。
- 返回用 mret 而不是 ret，它从 mepc 取回被打断的地址（06 第 5 节）。
- 实现：`RISCV/RISCVRegisterInfo.cpp:74` 起，函数带 interrupt 属性时，getCalleeSavedRegs 换成
  `CSR_Interrupt` 一族列表。`RISCV/RISCVCallingConv.td:49` 的 `CSR_Interrupt` 是 X1 和 X5–X31，
  即除了 zero、sp、gp、tp 以外的全部。有 F 时换成 :52 的 `CSR_XLEN_F32_Interrupt`，再加上全部 32 个
  浮点寄存器；E 扩展下换成 :74 起的 `…_RVE`，去掉 x16–x31。列表里的寄存器，函数实际改了才存。

四种配置下的大小（`ex/isr.c` cell 2）：

```
-march=rv32imc  -mabi=ilp32     isr_call  80 字节   16 个整数寄存器
-march=rv32imfc -mabi=ilp32f    isr_call 160 字节   再加 20 个浮点寄存器：ft0–ft11、fa0–fa7
-march=rv32imfc -mabi=ilp32     isr_call 208 字节   再加 32 个浮点寄存器
-march=rv32ec   -mabi=ilp32e    isr_call  60 字节   ra、t0–t2、a0–a5 共 10 个
```

- ilp32f 下 fs0–fs11 是被调用者保存（04 第 2 节），work 会保住它们，isr_call 不用存。
- ilp32 下浮点寄存器全是调用者保存，work 可以改任何一个，isr_call 只好 32 个全存。

## 9. 书

Colombet《LLVM Code Generation》p.414 起「Describing the calling convention」（第 15 章）：
调用约定和 CalleeSavedRegs 在 TableGen 里怎么写。

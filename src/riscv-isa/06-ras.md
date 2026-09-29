# 06 返回地址预测与链接寄存器

jalr 的 rd、rs1 写哪个寄存器，执行结果只由 05 第 2 节那两行定义决定。但处理器的返回地址预测会看
寄存器的编号，于是编号选错了，程序照样正确，只是变慢。本篇讲这套规则，以及它为什么限制了编译器
能用哪些寄存器做跳转。

riscv-registers 的 02 第 3.1 节从寄存器的角度讲过同一件事，本篇一步步推演返回地址栈怎么变。

## 1. 前提词

- 分支预测：处理器取指走在执行前面。一条跳转的目标还没算出来，后面的指令已经在取了。jalr 的目标
  在寄存器里，取指时只能猜。猜错了，取进来的指令作废，损失若干周期。
- 返回地址栈（return-address stack，RAS）：预测器里一个小的硬件栈。软件的返回地址存在 ra 和各层栈帧里
  （05 第 6 节），ret 要等 ra 从栈上读回来才知道去哪。处理器等不及，就自己维护一份副本：认出调用，
  就把返回地址压进 RAS；认出返回，就弹出栈顶，当作预测的目标。
- hint：写在编码里给硬件的提示，只影响性能，不改变执行结果。
- 链接寄存器：规范把 x1（ra）和 x5（t0）叫作链接寄存器（`rv32.adoc:437–439`）。

## 2. 规则：只看寄存器编号

RISC-V 没有专门的调用、返回指令，都是 jal、jalr。处理器认调用、认返回，只能看 rd、rs1 是不是链接
寄存器，看不到编译器的意图。规范规定 RAS 这样动（`rv32.adoc:518` 起的正文和 :526 的表）：

```
jal   rd 是链接寄存器                压          jal ra, f            调用
jalr  rd 是，rs1 不是                压          jalr ra, 0(a0)       调用函数指针
jalr  rd 不是，rs1 是                弹          jalr zero, 0(ra)     ret
jalr  rd、rs1 都是，编号不同          先弹再压     jalr ra, 0(t0)       协程切换（第 5 节）
jalr  rd、rs1 都是，编号相同          压          jalr ra, 0(ra)       call 展开成 auipc ra 加这条（第 4 节）
jalr  rd、rs1 都不是                 不动        jalr zero, 0(a5)     普通间接跳转
```

- 弹的时候，弹出来的地址就是这次跳转的预测目标。
- 规则按 hint 的方式写（「should push」），没有 RAS 的处理器可以不看。下文的推演假设处理器严格按表做。
- 这张表等于一个约定：只在真的调用、返回时用链接寄存器，处理器就能预测准。编译器用错了，程序执行
  结果不变，因为 ra 和栈上的值都没错，只是预测会错。
- `rv32.adoc:546` 起的注释说明了为什么这样设计：别的指令集在间接跳转指令里加专门的提示位，RISC-V
  借用寄存器编号和调用约定，省下编码空间。

## 3. 推演用的场景

main 调用 G，G 调用 F，F 里通过函数指针 p 调用。

- r_main：G 返回到 main 的地址；
- r_G：F 返回到 G 的地址；
- r_F：p 返回到 F 的地址。

RAS 写成一行，右端是栈顶。F 开始执行时：

```
main: call G    压 r_main    RAS: … r_main
G:    call F    压 r_G       RAS: … r_main r_G
```

## 4. 编号相同：只压

先看 call 为什么用 ra 暂存。目标文件里的 `call f` 是 `auipc ra, … ; jalr ra, …(ra)`（`ex/frame.c`
cell 2）。auipc 要一个寄存器暂存算出的高位地址，紧接着的 jalr 反正要把返回地址写进 ra，ra 的旧值
无论如何都会被这次调用覆盖：

- 用 ra 暂存，不额外破坏任何寄存器；
- 换成 t1，就平白多改了一个 t1。

调用者在序言里存 ra，是因为这次调用的 jalr 会写 ra，和 auipc 用哪个寄存器暂存无关。tail 不能用 ra 暂存，
因为 ra 里的返回地址要留给被跳到的函数，所以借 t1（05 第 7 节）。

再看 RAS。这条 jalr 的 rd、rs1 都是 ra。如果「两个都是链接寄存器」一律先弹再压，每个远调用都会像
第 5 节那样弹掉当前函数的返回地址。所以规范把编号相同的情况单独列出来，只压。`rv32.adoc:553–555`
给的理由是让 `auipc ra, imm20 ; jalr ra, imm12(ra)`（以及 lui 开头的同样写法）能被处理器合并成一条来
执行（macro-op fusion）。合并以后，它就是一条目标可以很远的调用。

## 5. 编号不同：先弹再压

这一行指 rd、rs1 中一个是 ra、一个是 t0，即 `jalr ra, 0(t0)` 或 `jalr t0, 0(ra)`。规范说它是给协程用的
（`rv32.adoc:551–552`），只写了这一句。

协程是两段代码轮流执行，每次让出时，跳到对方上次停下的地方，同时记下自己停在哪。拿
`jalr ra, 0(t0)` 来说：

- 跳到 t0 里记着的对方的位置，像一次返回，所以弹；
- 把自己下一条的地址写进 ra，像一次调用，所以压。

这一行对普通调用的影响是：函数指针不能放在 t0 里调用。假如 F 把 p 放在 t0，写成 `jalr ra, 0(t0)`，
本意是一次普通调用，应该只压 r_F。处理器却按这一行先弹再压：

```
F:  jalr ra, 0(t0)   弹出 r_G 当作这次跳转的预测目标，实际去 p：错
                     再压 r_F                         RAS: … r_main r_F
p:  ret              弹 r_F，实际回 r_F：对            RAS: … r_main
F:  ret              弹 r_main，实际回 r_G：错         RAS: …
G:  ret              弹出更下面的一项，实际回 r_main：错
```

被弹掉的 r_G 是 F 自己将来要返回到的地方。它丢了以后，F、G 以及再往外每一层的 ret 拿到的都是错的
一项。

换成 `jalr ra, 0(t1)`，rd 是链接寄存器、rs1 不是，只压 r_F：

```
F:  jalr ra, 0(t1)   压 r_F                           RAS: … r_main r_G r_F
p:  ret              弹 r_F：对
F:  ret              弹 r_G：对
G:  ret              弹 r_main：对
```

指针放在 ra 里，写出来是 `jalr ra, 0(ra)`，按第 4 节那一行只压，预测不会错。LLVM 的做法更简单：间接调用
一律不用 x1、x5（第 7 节）。

## 6. 只弹：ret 与间接尾调用

`jalr zero, 0(ra)` 是 ret。从编码上看，ret 和间接尾调用是同一种指令：`jalr zero, 0(某寄存器)`，不写
返回地址，跳到寄存器里的地址。区别只在寄存器里装的是什么：

- ret 的寄存器里是返回地址；
- 间接尾调用的寄存器里是函数地址。

处理器分辨两者只能看编号：rs1 是 ra 或 t0 就当作返回，其他编号就当作普通的间接跳转。

F 里写 `return p();`，编译器生成间接尾调用（05 第 7 节）。函数指针放在哪个寄存器有两条限制：

- 不能放 ra：尾调用时 ra 里必须还是 r_G，p 的 ret 要直接回到 G。
- 不能放 t0：原因是 RAS。

```
写成 jalr zero, 0(t1)：rs1 不是链接寄存器，RAS 不动     RAS: … r_main r_G
p:  ret     弹 r_G，实际回 r_G（ra 没被动过）：对

写成 jalr zero, 0(t0)：rs1 是链接寄存器，被当成返回，弹
F:  跳转    弹出 r_G 当作预测目标，实际去 p：错          RAS: … r_main
p:  ret     弹 r_main，实际回 r_G：错
G:  ret     弹出更下面的一项：错
```

## 7. LLVM 怎么落实

LLVM 用寄存器类限制跳转用的寄存器。寄存器类是一个操作数允许使用的寄存器集合，寄存器分配器只在
里面挑；值如果待在集合外的寄存器里，就插一条拷贝挪进来。llvmorg-21.1.8：

- 间接调用 PseudoCALLIndirect（`RISCV/RISCVInstrInfo.td:1793`）的操作数类是 GPRJALR
  （`RISCV/RISCVRegisterInfo.td:282`），去掉了 x0–x5，其中去掉 x1、x5 是因为 RAS（:278 的注释）。
- 间接尾调用 PseudoTAILIndirect（`RISCVInstrInfo.td:1822`）的操作数类是 GPRTC（`RISCVRegisterInfo.td:293`），
  只有 x6–x7、x10–x17、x28–x31：没有 ra、t0，也没有 s 寄存器。去掉 s 是因为尾声会先把它们恢复成
  旧值再跳，地址放在里面会被覆盖（:288 的注释）。

实验在 riscv-registers 的 `ex/jalr.c`，本目录下也能跑：

```
just asm ../riscv-registers/ex/jalr.c -march=rv32im -mabi=ilp32 -Os -mllvm -riscv-no-aliases
```

它把函数指针固定在不同寄存器里再调用。固定在 t0 时，间接调用多一条 `addi a0, t0, 0`，挪进 a0 再
`jalr ra, 0(a0)`；间接尾调用多一条 `addi t1, t0, 0`，挪进 t1 再 `jalr zero, 0(t1)`。输出和看点写在该文件
的注释里，讲解在 riscv-registers 的 02 第 3.1 节。

## 8. x5 与 millicode

x1 之外再设一个链接寄存器 x5，`rv32.adoc:443–449` 的注释给了用途和选它的理由：

- 用途：调用 millicode 时不必动 ra。millicode 是规范对一类小段库代码的叫法，例如在压缩代码里用来
  保存、恢复寄存器的例程。
- 选 x5：它在标准调用约定里是临时寄存器，函数可以随意改；编码又和 x1 只差一位。

`-msave-restore` 就是这样用的。它把序言、尾声换成调用 compiler-rt 或 libgcc 里的 `__riscv_save_N`、
`__riscv_restore_N`。`ex/frame.c` cell 3、cell 4 里的 keep：

```
auipc t0, 0x0 ; jalr t0, 0x0(t0)      call t0, __riscv_save_1       返回地址放 t0
addi  s0, a0, 0x0
auipc ra, 0x0 ; jalr ra, 0x0(ra)      call g
add   a0, a0, s0
auipc t1, 0x0 ; jalr zero, 0x0(t1)    tail __riscv_restore_1        不写返回地址
```

llvmorg-21.1.8 的 compiler-rt 里，RV32 的这两个函数（`compiler-rt/lib/builtins/riscv/`）：

```
save.S:86–95       __riscv_save_3、_2、_1、_0 是同一个入口
                   addi sp, sp, -16
                   sw s2, 0(sp) ; sw s1, 4(sp) ; sw s0, 8(sp) ; sw ra, 12(sp)
                   jr t0                     即 jalr zero, 0(t0)，回到 keep

restore.S:83–92    __riscv_restore_3、_2、_1、_0 是同一个入口
                   lw s2, 0(sp) ; lw s1, 4(sp) ; lw s0, 8(sp) ; lw ra, 12(sp)
                   addi sp, sp, 16
                   ret                       回到 keep 的调用者，不回 keep
```

- save 必须用 t0 带返回地址。调用 save 的那一刻，ra 里是 keep 自己的返回地址，还没存，存它正是 save
  的工作。写成 `call __riscv_save_1` 的话，ra 在存之前就被覆盖了。
- 返回地址不放 t1 而放 t0，是因为处理器认 x5 为链接寄存器，这一对调用、返回仍然能被预测。
- restore 不回到 keep。它是被尾调用的，恢复完 ra 以后直接 ret 到 keep 的调用者。

RAS 的变化，设进入 keep 时栈顶是 keep 的返回地址 r_keep：

```
call t0, save       jalr t0, 0(t0)：rd、rs1 是同一个链接寄存器，压      RAS: … r_keep r_save
save 的 jr t0       jalr zero, 0(t0)：rs1 是链接寄存器，弹 r_save：对     RAS: … r_keep
call g … g 的 ret   一压一弹                                             RAS: … r_keep
tail restore        jalr zero, 0(t1)：都不是链接寄存器，不动               RAS: … r_keep
restore 的 ret      弹 r_keep，实际回 keep 的调用者：对
```

r_save 指 save 返回到 keep 的地址，即 `call t0, …` 的下一条。每个压、弹都对上了。

编译器也会自己生成这种用 t0 调用的公共片段，见 07。

## 9. millicode 不是微码

微码（microcode）是另一回事，名字相近，容易混：

- millicode 是普通的 RISC-V 指令，放在 compiler-rt 或 libgcc 里，链接进程序，能反汇编出来。它的特别之处
  只在调用约定不标准：返回地址放在 t0。
- 微码在处理器内部，是处理器用来实现一部分指令和内部功能的一层。它不属于指令集，程序看不到，内容
  和格式由处理器厂商掌握。
- 厂商会发布微码更新来修处理器的问题，由操作系统在启动时加载进处理器。Linux 7.2.3 的
  `Documentation/arch/x86/microcode.rst` 讲了 x86 上的加载方式：:11 起说明用途，:18 起是启动早期从
  initrd 里加载。Linux 发行版把更新文件打成软件包，例如 Arch Linux 的 intel-ucode、amd-ucode。
- 微码更新改变的是处理器的行为，不改动任何程序的代码。

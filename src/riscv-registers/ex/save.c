// 调用者保存与被调用者保存：一个值要不要跨过函数调用继续用，决定了序言里存什么。
// 讲解见 ../03-calls.md 第 1、2、3、5 节。
//
// g 只有声明，编译器看不到它的内部，只能按调用约定假设：g 会改写所有调用者保存寄存器，
// 不会改写被调用者保存寄存器。
//
// ---- cell 1：默认写法 ----
//
//   $ just asm ex/save.c -march=rv32imc -mabi=ilp32 -Os
//
//     leaf:
//             slli    a2, a0, 1
//             add     a0, a0, a1
//             add     a0, a0, a2
//             ret
//     tail:
//             addi    a0, a0, 1
//             tail    g
//     keep:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             sw      s0, 8(sp)                       # 4-byte Folded Spill
//             mv      s0, a0
//             call    g
//             add     a0, a0, s0
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             lw      s0, 8(sp)                       # 4-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//
// 看点：
//   - leaf 不调用别的函数，只用调用者保存的 a0–a2，没有序言和尾声。
//   - tail 调用 g 之后不再用 x，于是直接跳到 g（tail g），由 g 返回到 tail 的调用者。
//     tail 自己没改 ra，不用存 ra。
//   - keep 在 call g 之后还要用 x。x 进来时在 a0，g 可以改 a0，所以先挪进 s0。
//     s0 是被调用者保存寄存器，keep 用了它，就要替自己的调用者保住它：sw s0 / lw s0。
//   - call g 会把返回地址写进 ra，keep 最后 ret 要用进来时的 ra，所以 ra 也要存。
//   - 「4-byte Folded Spill / Reload」是 LLVM 给序言、尾声里的存取加的注释。
//
// ---- cell 2：-msave-restore ----
//
// -msave-restore：序言和尾声改成调用库函数 __riscv_save_N / __riscv_restore_N，
// N 是要存的 s 寄存器个数。
//
//   $ just asm ex/save.c -march=rv32imc -mabi=ilp32 -Os -msave-restore
//
//     leaf:
//             slli    a2, a0, 1
//             add     a0, a0, a1
//             add     a0, a0, a2
//             ret
//     tail:
//             addi    a0, a0, 1
//             tail    g
//     keep:
//             call    t0, __riscv_save_1
//             mv      s0, a0
//             call    g
//             add     a0, a0, s0
//             tail    __riscv_restore_1
//
// 看点：
//   - call t0, __riscv_save_1：返回地址写进 t0 而不是 ra。此刻 ra 里还是 keep 自己的
//     返回地址，不能覆盖。t0（x5）和 ra（x1）是硬件当作链接寄存器的两个编号。
//   - tail __riscv_restore_1：由它恢复寄存器，再直接返回到 keep 的调用者。
//   - 这两个函数由 compiler-rt 或 libgcc 提供，不在本目录。llvmorg-21.1.8 的
//     compiler-rt/lib/builtins/riscv/save.S 里，RV32 上 __riscv_save_0 到 __riscv_save_3
//     是同一个入口：开 16 字节栈，存 ra、s0、s1、s2，然后 jr t0 回来。
//
// ---- cell 3：Zcmp ----
//
// -march=rv32imc_zcmp：再加上 Zcmp 扩展，它提供 cm.push、cm.popret 等压栈、出栈指令。
//
//   $ just asm ex/save.c -march=rv32imc_zcmp -mabi=ilp32 -Os
//
//     leaf:
//             slli    a2, a0, 1
//             add     a0, a0, a1
//             add     a0, a0, a2
//             ret
//     tail:
//             addi    a0, a0, 1
//             tail    g
//     keep:
//             cm.push {ra, s0}, -16
//             mv      s0, a0
//             call    g
//             add     a0, a0, s0
//             cm.popret       {ra, s0}, 16
//
// 看点：
//   - cm.push {ra, s0}, -16：存 ra、s0，sp 减 16，一条 2 字节指令。
//   - cm.popret {ra, s0}, 16：取回 ra、s0，sp 加 16，然后返回。
//   - 寄存器列表只能是 {ra}、{ra, s0}、{ra, s0-s1} … {ra, s0-s9}、{ra, s0-s11}，
//     即从 s0 开始连续的一段（llvmorg-21.1.8 RISCV/MCTargetDesc/RISCVBaseInfo.h:600）。
//
// ---- cell 4：三种写法的字节数 ----
//
//   $ just size ex/save.c -march=rv32imc -mabi=ilp32 -Os
//
//     leaf           10 字节
//     tail           10 字节
//     keep           26 字节
//
//   $ just size ex/save.c -march=rv32imc -mabi=ilp32 -Os -msave-restore
//
//     leaf           10 字节
//     tail           10 字节
//     keep           28 字节
//
//   $ just size ex/save.c -march=rv32imc_zcmp -mabi=ilp32 -Os
//
//     leaf           10 字节
//     tail           10 字节
//     keep           16 字节
//
// 看点：
//   - keep：默认 26 字节，-msave-restore 28 字节，Zcmp 16 字节。
//   - -msave-restore 在这里反而更大：目标文件里 call t0, __riscv_save_1 和
//     tail __riscv_restore_1 各是 auipc+jalr 两条共 8 字节。链接器松弛能把调用缩短
//     （见 ex/gp/main.c），这里看的是链接前。
//   - 要存的寄存器一多，结论就变了，见 ex/save-many.c。
//
// ---- cell 5：开帧指针 ----
//
// -fno-omit-frame-pointer：每个函数都维护帧指针。RISC-V 的帧指针是 s0（x8），别名 fp。
//
//   $ just asm ex/save.c -march=rv32imc -mabi=ilp32 -Os -fno-omit-frame-pointer
//
//     leaf:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             sw      s0, 8(sp)                       # 4-byte Folded Spill
//             addi    s0, sp, 16
//             slli    a2, a0, 1
//             add     a0, a0, a1
//             add     a0, a0, a2
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             lw      s0, 8(sp)                       # 4-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//     tail:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             sw      s0, 8(sp)                       # 4-byte Folded Spill
//             addi    s0, sp, 16
//             addi    a0, a0, 1
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             lw      s0, 8(sp)                       # 4-byte Folded Reload
//             addi    sp, sp, 16
//             tail    g
//     keep:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             sw      s0, 8(sp)                       # 4-byte Folded Spill
//             sw      s1, 4(sp)                       # 4-byte Folded Spill
//             addi    s0, sp, 16
//             mv      s1, a0
//             call    g
//             add     a0, a0, s1
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             lw      s0, 8(sp)                       # 4-byte Folded Reload
//             lw      s1, 4(sp)                       # 4-byte Folded Reload
//             addi    sp, sp, 16
//             ret
//
// 看点：
//   - 三个函数都多了 addi s0, sp, 16：s0 指向进入函数时的 sp。
//   - 栈上的布局是 ra 在 s0-4，上一层的 s0 在 s0-8。沿着 s0 可以一层层找到每一层的
//     返回地址，栈回溯靠的就是这个，所以 leaf、tail 也要存 ra 和 s0。
//   - s0 被占作帧指针，keep 改用 s1 保存 x，于是多存一个 s1。

int g(int);

int leaf(int a, int b) { return a * 3 + b; }

int tail(int x) { return g(x + 1); }

int keep(int x) { return g(x) + x; }

// 序言与尾声：一个函数进入、调用别的函数、返回时各做了什么。讲解见 ../05-calls.md 第 2、6、7 节，
// cell 3、4 见 ../06-ras.md 第 8 节。
//
// g 只有声明，编译器看不到它的内部，只能按调用约定假设它会改哪些寄存器。
// leaf 不调用别的函数；keep 在 call g 之后还要用 x；tail 的最后一件事是调用 g。
//
// ---- cell 1：汇编 ----
//
// -march=rv32im 不开 C；-Os 按代码体积优化。
//
//   $ just asm ex/frame.c -march=rv32im -mabi=ilp32 -Os
//
//     leaf:
//             slli    a2, a0, 1
//             add     a0, a0, a1
//             add     a0, a2, a0
//             ret
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
//     tail:
//             addi    a0, a0, 1
//             tail    g
//
// 看点：
//   - keep 的前三条是序言：开 16 字节栈帧，存 ra、存 s0。最后四条是尾声：取回 ra、s0，还栈，ret。
//   - mv s0, a0：x 进来时在 a0，g 可以改 a0，x 在 call g 之后还要用，所以挪进 s0。
//     s0 是被调用者保存寄存器，keep 用了它，就得替自己的调用者保住旧值。
//   - call g 会把返回地址写进 ra，覆盖 keep 自己的返回地址，所以序言先存 ra。
//   - keep 只存 8 字节，却开了 16 字节：进入函数时 sp 必须是 16 的倍数。
//   - leaf 不调用别的函数，ra 不会被覆盖，只用 a0–a2，没有序言和尾声。
//   - tail 调用 g 之后什么也不做，直接跳到 g（tail g），g 返回时直接回到 tail 的调用者。
//   - 「4-byte Folded Spill / Reload」是 LLVM 给序言、尾声里的存取加的注释。
//
// ---- cell 2：真实指令 ----
//
// 反汇编目标文件，看 call、tail、ret 这三个伪指令各是哪条指令。
//
//   $ just dis ex/frame.c -march=rv32im -mabi=ilp32 -Os
//
//     00000000 <leaf>:
//            0: 00151613      slli    a2, a0, 0x1
//            4: 00b50533      add     a0, a0, a1
//            8: 00a60533      add     a0, a2, a0
//            c: 00008067      jalr    zero, 0x0(ra)
//
//     00000010 <keep>:
//           10: ff010113      addi    sp, sp, -0x10
//           14: 00112623      sw      ra, 0xc(sp)
//           18: 00812423      sw      s0, 0x8(sp)
//           1c: 00050413      addi    s0, a0, 0x0
//           20: 00000097      auipc   ra, 0x0
//           24: 000080e7      jalr    ra, 0x0(ra) <keep+0x10>
//           28: 00850533      add     a0, a0, s0
//           2c: 00c12083      lw      ra, 0xc(sp)
//           30: 00812403      lw      s0, 0x8(sp)
//           34: 01010113      addi    sp, sp, 0x10
//           38: 00008067      jalr    zero, 0x0(ra)
//
//     0000003c <tail>:
//           3c: 00150513      addi    a0, a0, 0x1
//           40: 00000317      auipc   t1, 0x0
//           44: 00030067      jalr    zero, 0x0(t1) <tail+0x4>
//
// 看点：
//   - ret 是 jalr zero, 0x0(ra)：跳到 ra，不写返回地址。
//   - call g 是 auipc ra + jalr ra, 0x0(ra)：暂存地址用的也是 ra，反正 jalr 要把返回地址写进 ra。
//   - tail g 是 auipc t1 + jalr zero, 0x0(t1)：不写返回地址，也不能动 ra，所以借 t1 暂存。
//   - 立即数都是 0，g 的地址由链接器填（../04-control.md 第 4 节）。
//     `<keep+0x10>` 这类注释是 objdump 按立即数 0 算出的地址，不是真正的目标。
//
// ---- cell 3：-msave-restore ----
//
// -msave-restore：序言和尾声改成调用 compiler-rt 或 libgcc 里的 __riscv_save_N、
// __riscv_restore_N，N 是要存的 s 寄存器个数。
//
//   $ just dis ex/frame.c -march=rv32im -mabi=ilp32 -Os -msave-restore
//
//     00000000 <leaf>:
//            0: 00151613      slli    a2, a0, 0x1
//            4: 00b50533      add     a0, a0, a1
//            8: 00a60533      add     a0, a2, a0
//            c: 00008067      jalr    zero, 0x0(ra)
//
//     00000010 <keep>:
//           10: 00000297      auipc   t0, 0x0
//           14: 000282e7      jalr    t0, 0x0(t0) <keep>
//           18: 00050413      addi    s0, a0, 0x0
//           1c: 00000097      auipc   ra, 0x0
//           20: 000080e7      jalr    ra, 0x0(ra) <keep+0xc>
//           24: 00850533      add     a0, a0, s0
//           28: 00000317      auipc   t1, 0x0
//           2c: 00030067      jalr    zero, 0x0(t1) <keep+0x18>
//
//     00000030 <tail>:
//           30: 00150513      addi    a0, a0, 0x1
//           34: 00000317      auipc   t1, 0x0
//           38: 00030067      jalr    zero, 0x0(t1) <tail+0x4>
//
// 看点：
//   - keep 开头的 auipc t0 + jalr t0, 0x0(t0) 是 call t0, __riscv_save_1：返回地址写进 t0，
//     因为此刻 ra 里是 keep 自己的返回地址，还没存。
//   - 结尾的 auipc t1 + jalr zero, 0x0(t1) 是 tail __riscv_restore_1：它恢复 ra、s0，
//     再直接返回到 keep 的调用者，不再回到 keep。
//   - 跳到哪个函数要看下一个 cell 的重定位。
//
// ---- cell 4：每对 auipc、jalr 跳到哪 ----
//
//   $ just reloc ex/frame.c -march=rv32im -mabi=ilp32 -Os -msave-restore
//
//      Offset     Info    Type                Sym. Value  Symbol's Name + Addend
//     00000010  00000713 R_RISCV_CALL_PLT       00000000   __riscv_save_1 + 0
//     00000010  00000033 R_RISCV_RELAX                     0
//     0000001c  00000813 R_RISCV_CALL_PLT       00000000   g + 0
//     0000001c  00000033 R_RISCV_RELAX                     0
//     00000028  00000913 R_RISCV_CALL_PLT       00000000   __riscv_restore_1 + 0
//     00000028  00000033 R_RISCV_RELAX                     0
//     00000034  00000813 R_RISCV_CALL_PLT       00000000   g + 0
//     00000034  00000033 R_RISCV_RELAX                     0
//
// 看点：
//   - 偏移 0x10、0x1c、0x28 是 keep 里三对 auipc、jalr，依次是 __riscv_save_1、g、__riscv_restore_1。
//   - 偏移 0x34 是 tail 里的 tail g。

int g(int);

int leaf(int a, int b) { return a * 3 + b; }

int keep(int x) { return g(x) + x; }

int tail(int x) { return g(x + 1); }

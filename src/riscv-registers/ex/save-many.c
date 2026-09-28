// 要跨过调用保存 4 个值时，三种序言/尾声写法的大小。讲解见 ../03-calls.md 第 2 节。
//
// ---- cell 1：默认写法 ----
//
//   $ just asm ex/save-many.c -march=rv32imc -mabi=ilp32 -Os
//
//     keep4:
//             addi    sp, sp, -32
//             sw      ra, 28(sp)                      # 4-byte Folded Spill
//             sw      s0, 24(sp)                      # 4-byte Folded Spill
//             sw      s1, 20(sp)                      # 4-byte Folded Spill
//             sw      s2, 16(sp)                      # 4-byte Folded Spill
//             sw      s3, 12(sp)                      # 4-byte Folded Spill
//             mv      s2, a3
//             mv      s3, a2
//             mv      s0, a1
//             mv      s1, a0
//             call    g
//             mul     a1, s0, s1
//             add     s0, s0, s2
//             mul     a2, s0, s3
//             add     a0, a0, a1
//             add     a0, a0, a2
//             lw      ra, 28(sp)                      # 4-byte Folded Reload
//             lw      s0, 24(sp)                      # 4-byte Folded Reload
//             lw      s1, 20(sp)                      # 4-byte Folded Reload
//             lw      s2, 16(sp)                      # 4-byte Folded Reload
//             lw      s3, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 32
//             ret
//
// 看点：
//   - a、b、c、d 都要在 call g 之后使用，于是挪进 s0–s3，加上 ra 共存 5 个寄存器。
//
// ---- cell 2：-msave-restore 与 Zcmp ----
//
//   $ just asm ex/save-many.c -march=rv32imc -mabi=ilp32 -Os -msave-restore
//
//     keep4:
//             call    t0, __riscv_save_4
//             mv      s2, a3
//             mv      s3, a2
//             mv      s0, a1
//             mv      s1, a0
//             call    g
//             mul     a1, s0, s1
//             add     s0, s0, s2
//             mul     a2, s0, s3
//             add     a0, a0, a1
//             add     a0, a0, a2
//             tail    __riscv_restore_4
//
//   $ just asm ex/save-many.c -march=rv32imc_zcmp -mabi=ilp32 -Os
//
//     keep4:
//             cm.push {ra, s0-s3}, -32
//             mv      s2, a3
//             mv      s3, a2
//             cm.mvsa01       s1, s0
//             call    g
//             mul     a1, s0, s1
//             add     s0, s0, s2
//             mul     a2, s0, s3
//             add     a0, a0, a1
//             add     a0, a0, a2
//             cm.popret       {ra, s0-s3}, 32
//
// 看点：
//   - -msave-restore 仍然只有首尾两条调用。llvmorg-21.1.8 的 compiler-rt 里，RV32 上
//     __riscv_save_4 到 __riscv_save_7 是同一个入口，存 ra 和 s0–s6 共 8 个：
//     换来的是代码短，代价是运行时多存几个用不到的寄存器。
//   - Zcmp 版本多了一条 cm.mvsa01 s1, s0：一条 2 字节指令把 a0、a1 分别挪进 s1、s0。
//     它的两个目的寄存器只能是 s0–s7（llvmorg-21.1.8 RISCV/RISCVRegisterInfo.td:304 的 SR07）。
//
// ---- cell 3：字节数 ----
//
//   $ just size ex/save-many.c -march=rv32imc -mabi=ilp32 -Os
//
//     keep4          56 字节
//
//   $ just size ex/save-many.c -march=rv32imc -mabi=ilp32 -Os -msave-restore
//
//     keep4          46 字节
//
//   $ just size ex/save-many.c -march=rv32imc_zcmp -mabi=ilp32 -Os
//
//     keep4          32 字节
//
// 看点：
//   - 默认 56 字节，-msave-restore 46 字节，Zcmp 32 字节。对比 ex/save.c 只存一个 s0 时，
//     -msave-restore 的调用开销是固定的，要存的寄存器越多越划算。

int g(int);

int keep4(int a, int b, int c, int d) { return g(a) + a * b + c * d + b * c; }

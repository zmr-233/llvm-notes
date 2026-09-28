// 中断处理函数要保存什么。讲解见 ../03-calls.md 第 8 节。
//
// __attribute__((interrupt("machine")))：告诉 clang 这是 M 级中断的入口。编译器因此
// 用 mret 返回，并且把函数改动的每个寄存器都保存下来，不只保存被调用者保存的那一半。
//
// ---- cell 1：汇编 ----
//
//   $ just asm ex/isr.c -march=rv32imc -mabi=ilp32 -Os
//
//     isr_leaf:
//             addi    sp, sp, -16
//             sw      a0, 12(sp)                      # 4-byte Folded Spill
//             sw      a1, 8(sp)                       # 4-byte Folded Spill
//             lui     a0, %hi(cnt)
//             lw      a1, %lo(cnt)(a0)
//             addi    a1, a1, 1
//             sw      a1, %lo(cnt)(a0)
//             lw      a0, 12(sp)                      # 4-byte Folded Reload
//             lw      a1, 8(sp)                       # 4-byte Folded Reload
//             addi    sp, sp, 16
//             mret
//     isr_call:
//             addi    sp, sp, -64
//             sw      ra, 60(sp)                      # 4-byte Folded Spill
//             sw      t0, 56(sp)                      # 4-byte Folded Spill
//             sw      t1, 52(sp)                      # 4-byte Folded Spill
//             sw      t2, 48(sp)                      # 4-byte Folded Spill
//             sw      a0, 44(sp)                      # 4-byte Folded Spill
//             sw      a1, 40(sp)                      # 4-byte Folded Spill
//             sw      a2, 36(sp)                      # 4-byte Folded Spill
//             sw      a3, 32(sp)                      # 4-byte Folded Spill
//             sw      a4, 28(sp)                      # 4-byte Folded Spill
//             sw      a5, 24(sp)                      # 4-byte Folded Spill
//             sw      a6, 20(sp)                      # 4-byte Folded Spill
//             sw      a7, 16(sp)                      # 4-byte Folded Spill
//             sw      t3, 12(sp)                      # 4-byte Folded Spill
//             sw      t4, 8(sp)                       # 4-byte Folded Spill
//             sw      t5, 4(sp)                       # 4-byte Folded Spill
//             sw      t6, 0(sp)                       # 4-byte Folded Spill
//             call    work
//             ...（16 条 lw，按相同偏移取回这 16 个寄存器）
//             addi    sp, sp, 64
//             mret
//     plain_call:
//             tail    work
//
// 看点：
//   - isr_leaf 只改了 a0、a1，就只存这两个，最后 mret。
//   - isr_call 调用了看不到内部的 work。按约定 work 可以改任何调用者保存寄存器，
//     所以 ra、t0–t6、a0–a7 共 16 个全存，开 64 字节栈。
//     s0–s11 没有存，因为 work 自己会保住它们。gp、tp 也没有存。
//   - plain_call 是普通函数，同样的函数体只有一条 tail work。
//
// ---- cell 2：四种配置下的字节数 ----
//
//   $ just size ex/isr.c -march=rv32imc -mabi=ilp32 -Os
//
//     isr_leaf       30 字节
//     isr_call       80 字节
//     plain_call      8 字节
//
//   $ just size ex/isr.c -march=rv32imfc -mabi=ilp32f -Os
//
//     isr_leaf       30 字节
//     isr_call      160 字节
//     plain_call      8 字节
//
//   $ just size ex/isr.c -march=rv32imfc -mabi=ilp32 -Os
//
//     isr_leaf       30 字节
//     isr_call      208 字节
//     plain_call      8 字节
//
//   $ just size ex/isr.c -march=rv32ec -mabi=ilp32e -Os
//
//     isr_leaf       30 字节
//     isr_call       60 字节
//     plain_call      8 字节
//
// 看点：
//   - 有 F 扩展、ABI 是 ilp32f 时，isr_call 翻倍：work 可以改的还包括 20 个调用者保存的
//     浮点寄存器（ft0–ft11、fa0–fa7），于是多了 20 条 fsw、20 条 flw，栈开到 144 字节。
//   - 同样有 F、ABI 换成 ilp32 时更大：ilp32 下 32 个浮点寄存器全是调用者保存，
//     work 都可以改，32 个全存。
//   - RVE 下只有 16 个整数寄存器，要存的是 ra、t0–t2、a0–a5 共 10 个。
//   - 硬件进入 trap 时一个通用寄存器也不替软件保存（见 ../06-csr.md 第 5 节），
//     这里的存取全部是编译器生成的代码。

extern volatile int cnt;
void work(void);

__attribute__((interrupt("machine"))) void isr_leaf(void) { cnt++; }

__attribute__((interrupt("machine"))) void isr_call(void) { work(); }

void plain_call(void) { work(); }

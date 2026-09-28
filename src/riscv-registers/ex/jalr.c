// 函数指针待在哪个寄存器里，LLVM 最后用哪个寄存器做间接跳转。讲解见 ../02-integer.md 第 3.1 节。
//
// ra（x1）和 t0（x5）是链接寄存器：jalr 的 rd、rs1 是不是它们，决定返回地址栈压还是弹。
// 所以间接调用、间接尾调用的目标地址不放在这两个寄存器里。尾调用的目标地址也不放在
// 被调用者保存寄存器里，因为尾声会先把它们恢复成旧值，再跳。
//
// 每个函数先用两行把指针固定在指定寄存器里（写法同 rvc.c）：
//   register int (*q)(void) asm("t0") = f;   指定变量 q 放在 t0
//   asm("" : "+r"(q));                       空的内联汇编，声明自己会读写 q，
//                                            编译器因此必须让 q 此刻真的待在 t0 里
// 然后调用 q。via_* 在调用之后还要加 1，是普通调用；tail_* 直接返回 q() 的结果，是尾调用。
//
// ---- cell 1：真实指令 ----
//
// -march=rv32im 里没有 C，指令都按 4 字节的原形打印。
// -mllvm -riscv-no-aliases 不折回伪指令，jalr 的 rd、rs1 都写出来。
//
//   $ just asm ex/jalr.c -march=rv32im -mabi=ilp32 -Os -mllvm -riscv-no-aliases
//
//     via_t1:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             addi    t1, a0, 0
//             jalr    ra, 0(t1)
//             addi    a0, a0, 1
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 16
//             jalr    zero, 0(ra)
//     via_t0:
//             addi    sp, sp, -16
//             sw      ra, 12(sp)                      # 4-byte Folded Spill
//             addi    t0, a0, 0
//             addi    a0, t0, 0
//             jalr    ra, 0(a0)
//             addi    a0, a0, 1
//             lw      ra, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 16
//             jalr    zero, 0(ra)
//     tail_t1:
//             addi    t1, a0, 0
//             jalr    zero, 0(t1)
//     tail_t0:
//             addi    t0, a0, 0
//             addi    t1, t0, 0
//             jalr    zero, 0(t1)
//     tail_s2:
//             addi    sp, sp, -16
//             sw      s2, 12(sp)                      # 4-byte Folded Spill
//             addi    s2, a0, 0
//             addi    t1, s2, 0
//             lw      s2, 12(sp)                      # 4-byte Folded Reload
//             addi    sp, sp, 16
//             jalr    zero, 0(t1)
//
// 看点：
//   - jalr ra, 0(x) 是间接调用，jalr zero, 0(x) 是间接尾调用，jalr zero, 0(ra) 是 ret。
//   - 每个函数里第一条 addi x, a0, 0 是「固定到某寄存器」这个写法本身带来的。
//   - via_t1、tail_t1：t1 直接做 jalr 的 rs1。
//   - via_t0：多一条 addi a0, t0, 0，把地址挪回 a0 再 jalr ra, 0(a0)。
//     t0 不在间接调用允许的寄存器类 GPRJALR 里。
//   - tail_t0：多一条 addi t1, t0, 0，挪进 t1 再跳。t0 也不在间接尾调用的 GPRTC 里。
//   - tail_s2：地址先挪进 t1，然后 lw s2 恢复 s2，最后用 t1 跳。地址如果留在 s2，
//     就被恢复出来的旧值覆盖了。

int via_t1(int (*f)(void)) {
  register int (*q)(void) asm("t1") = f;
  asm("" : "+r"(q));
  return q() + 1;
}

int via_t0(int (*f)(void)) {
  register int (*q)(void) asm("t0") = f;
  asm("" : "+r"(q));
  return q() + 1;
}

int tail_t1(int (*f)(void)) {
  register int (*q)(void) asm("t1") = f;
  asm("" : "+r"(q));
  return q();
}

int tail_t0(int (*f)(void)) {
  register int (*q)(void) asm("t0") = f;
  asm("" : "+r"(q));
  return q();
}

int tail_s2(int (*f)(void)) {
  register int (*q)(void) asm("s2") = f;
  asm("" : "+r"(q));
  return q();
}

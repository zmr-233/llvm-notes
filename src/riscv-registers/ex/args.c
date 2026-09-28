// 参数和返回值放在哪个寄存器；ilp32 与 ilp32e 的区别。讲解见 ../03-calls.md 第 4 节。
//
// ---- cell 1：ilp32 ----
//
//   $ just asm ex/args.c -march=rv32imc -mabi=ilp32 -Os
//
//     many:
//             lw      t0, 0(sp)
//             add     a0, a0, a1
//             add     a2, a2, a3
//             add     a4, a4, a5
//             add     a0, a0, a2
//             add     a4, a4, a6
//             add     a0, a0, a4
//             add     a0, a0, a7
//             add     a0, a0, t0
//             ret
//     add64:
//             add     a1, a1, a3
//             add     a0, a0, a2
//             sltu    a2, a0, a2
//             add     a1, a1, a2
//             ret
//
// 看点：
//   - many 的前 8 个参数 a–h 依次在 a0–a7，第 9 个参数 i 在调用者的栈上，
//     进入函数时位于 0(sp)，所以第一条是 lw t0, 0(sp)。
//   - 返回值放在 a0。
//   - add64 的 long long 在 RV32 上占两个寄存器：a 在 a0（低 32 位）、a1（高 32 位），
//     b 在 a2、a3，返回值在 a0、a1。sltu 算的是低 32 位相加的进位。
//
// ---- cell 2：ilp32e ----
//
// -march=rv32ec：基础集换成只有 16 个整数寄存器的 E。-mabi=ilp32e 是配套的调用约定。
//
//   $ just asm ex/args.c -march=rv32ec -mabi=ilp32e -Os
//
//     many:
//             lw      t0, 8(sp)
//             lw      t1, 4(sp)
//             lw      t2, 0(sp)
//             add     a0, a0, a1
//             add     a2, a2, a3
//             add     a4, a4, a5
//             add     a0, a0, a2
//             add     a0, a0, a4
//             add     a0, a0, t2
//             add     t0, t0, t1
//             add     a0, a0, t0
//             ret
//     add64:
//             add     a1, a1, a3
//             add     a0, a0, a2
//             sltu    a2, a0, a2
//             add     a1, a1, a2
//             ret
//
// 看点：
//   - 参数寄存器只剩 a0–a5（x10–x15），g、h、i 三个参数都在栈上：0(sp)、4(sp)、8(sp)。
//   - add64 两种约定下一样，四个半截都放得进 a0–a3。
//   - 临时寄存器 t0–t2 是 x5–x7，RVE 里仍然有。

int many(int a, int b, int c, int d, int e, int f, int g, int h, int i) {
  return a + b + c + d + e + f + g + h + i;
}

long long add64(long long a, long long b) { return a + b; }

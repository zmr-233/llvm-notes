// 很多压缩指令的寄存器字段只有 3 位，只能表示 x8–x15。同样是取 p[1]，指针放在不同的
// 寄存器里，生成的指令长度就不同。讲解见 ../02-integer.md 第 4 节。
//
// in_t0 和 in_s2 用两行把指针固定在指定的寄存器里：
//   register int *q asm("t0") = p;   指定变量 q 放在 t0
//   asm("" : "+r"(q));               一条空的内联汇编，声明自己会读写 q。编译器因此必须
//                                    在这里让 q 真的待在 t0 里，不能把 q 优化回 a0
//
// ---- cell 1：反汇编 ----
//
//   $ just dis ex/rvc.c -march=rv32imc -mabi=ilp32 -Os
//
//     00000000 <in_a0>:
//            0: 4148          c.lw    a0, 0x4(a0)
//            2: 8082          c.jr    ra
//
//     00000004 <in_t0>:
//            4: 82aa          c.mv    t0, a0
//            6: 0042a503      lw      a0, 0x4(t0)
//            a: 8082          c.jr    ra
//
//     0000000c <in_s2>:
//            c: 1141          c.addi  sp, -0x10
//            e: c64a          c.swsp  s2, 0xc(sp)
//           10: 892a          c.mv    s2, a0
//           12: 00492503      lw      a0, 0x4(s2)
//           16: 4932          c.lwsp  s2, 0xc(sp)
//           18: 0141          c.addi  sp, 0x10
//           1a: 8082          c.jr    ra
//
// 看点：
//   - in_a0：基址寄存器 a0 是 x10，在 x8–x15 里，c.lw 能编码，2 字节。
//   - in_t0：基址寄存器 t0 是 x5，c.lw 编码不了，只能用 4 字节的 lw。
//     前面的 c.mv 是「把指针固定到 t0」这个写法本身带来的。
//   - in_s2：基址 s2 是 x18，同样只能用 lw。s2 还是被调用者保存寄存器，函数用了它，
//     就得在入口存（c.swsp）、出口取（c.lwsp），并为此开栈、关栈（两条 c.addi sp）。
//   - c.mv、c.swsp、c.lwsp 用的是 5 位寄存器字段，t0、s2 都能编码。
//
// ---- cell 2：每个函数的字节数 ----
//
//   $ just size ex/rvc.c -march=rv32imc -mabi=ilp32 -Os
//
//     in_a0           4 字节
//     in_t0           8 字节
//     in_s2          16 字节

int in_a0(int *p) { return p[1]; }

int in_t0(int *p) {
  register int *q asm("t0") = p;
  asm("" : "+r"(q));
  return q[1];
}

int in_s2(int *p) {
  register int *q asm("s2") = p;
  asm("" : "+r"(q));
  return q[1];
}

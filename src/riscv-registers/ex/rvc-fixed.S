// 有些压缩指令的寄存器不占字段，写死在操作码里：基址是 sp，或者目的寄存器是 ra、x0。
// 下面每行是一条 32 位写法。开了 C 扩展，汇编器逐条看能不能换成等价的 16 位形式。
// 讲解见 ../02-integer.md 第 3.2 节。
//
// .S 文件交给 clang 时，clang 先做一遍 C 预处理再汇编，所以 // 注释可以用。
//
// ---- cell 1：RV32 ----
//
//   $ just dis ex/rvc-fixed.S -march=rv32imc -mabi=ilp32
//
//     00000000 <L>:
//            0: 4512          c.lwsp  a0, 0x4(sp)
//            2: 4312          c.lwsp  t1, 0x4(sp)
//            4: c21a          c.swsp  t1, 0x4(sp)
//            6: 41c8          c.lw    a0, 0x4(a1)
//            8: 00432503      lw      a0, 0x4(t1)
//            c: 0045a303      lw      t1, 0x4(a1)
//           10: 0028          c.addi4spn      a0, sp, 0x8
//           12: 00810313      addi    t1, sp, 0x8
//           16: 00858513      addi    a0, a1, 0x8
//           1a: 7139          c.addi16sp      sp, -0x40
//           1c: fc050513      addi    a0, a0, -0x40
//           20: 37c5          c.jal   0x0 <L>
//           22: fdfff2ef      jal     t0, 0x0 <L>
//           26: bfe9          c.j     0x0 <L>
//           28: 9282          c.jalr  t0
//
// 看点（对照文件末尾的源码）：
//   - lw、sw 的基址是 sp：压成 c.lwsp、c.swsp。数据寄存器用 5 位字段，t1 也能压。
//   - 基址不是 sp：c.lw 的数据寄存器和基址都是 3 位字段，只能在 x8–x15。
//     t1 出现在哪个位置都压不了。
//   - addi x, sp, 8：c.addi4spn 的源写死是 sp，目的寄存器是 3 位字段，a0 能压，t1 不能。
//   - addi a0, a1, 8：目的和源不同，源又不是 sp，没有 16 位形式。
//   - addi sp, sp, -64：c.addi16sp 只给 sp 用，立即数是 16 的倍数。同样的 -64 加到 a0 上，
//     超出了普通 c.addi 的 -32…31。
//   - jal：目的是 ra 压成 c.jal，是 x0 压成 c.j，是 t0 压不了。
//   - jalr ra, 0(t0)：压成 c.jalr t0，c.jalr 的目的寄存器写死是 ra。编译器不会生成这种写法
//     （jalr.c），手写照样能汇编，汇编器不管返回地址栈。
//
// ---- cell 2：RV64 ----
//
// -march 以 rv64 开头时，clang 把 --target 里的 riscv32 换成 riscv64
// （clang/lib/Driver/Driver.cpp:834 起）。
//
//   $ just dis ex/rvc-fixed.S -march=rv64imc -mabi=lp64
//
//     0000000000000000 <L>:
//            0: 4512          c.lwsp  a0, 0x4(sp)
//            2: 4312          c.lwsp  t1, 0x4(sp)
//            4: c21a          c.swsp  t1, 0x4(sp)
//            6: 41c8          c.lw    a0, 0x4(a1)
//            8: 00432503      lw      a0, 0x4(t1)
//            c: 0045a303      lw      t1, 0x4(a1)
//           10: 0028          c.addi4spn      a0, sp, 0x8
//           12: 00810313      addi    t1, sp, 0x8
//           16: 00858513      addi    a0, a1, 0x8
//           1a: 7139          c.addi16sp      sp, -0x40
//           1c: fc050513      addi    a0, a0, -0x40
//           20: fe1ff0ef      jal     ra, 0x0 <L>
//           24: fddff2ef      jal     t0, 0x0 <L>
//           28: bfe1          c.j     0x0 <L>
//           2a: 9282          c.jalr  t0
//
// 看点：
//   - 只有 jal ra, L 换了形式，是 4 字节的 jal。RV64 没有 c.jal，这组编码在 RV64 上是 c.addiw。
//   - 它多占 2 字节，后面几条的偏移跟着后移；c.j 离 L 远了 2 字节，编码也就不同。

L:
  lw   a0, 4(sp)
  lw   t1, 4(sp)
  sw   t1, 4(sp)
  lw   a0, 4(a1)
  lw   a0, 4(t1)
  lw   t1, 4(a1)
  addi a0, sp, 8
  addi t1, sp, 8
  addi a0, a1, 8
  addi sp, sp, -64
  addi a0, a0, -64
  jal  ra, L
  jal  t0, L
  jal  zero, L
  jalr ra, 0(t0)
